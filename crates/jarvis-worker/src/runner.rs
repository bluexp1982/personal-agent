//! 任务执行循环。
//!
//! 分工：
//! - **worker** 决定"这一步要问什么、拿到结果接到哪里"；
//! - **service** 决定"用哪个模型、还能不能再调、花了多少"。
//!
//! 所以这里的每次模型调用都是一次 IPC 往返。模型未启用、超时或返回错误时，
//! 任务**不会失败**：这一步退回确定性输出（有参考资料就引资料，没有就写"已完成"），
//! 沿用 V1 定下的原则——模型不可用不能让人办不成事。
//! 唯一的例外是 `budget_exceeded`：预算是硬约束，超了必须停，否则"可控成本"是空话。
//!
//! 这里**不做**任何状态裁决：不判断任务是否成功、不写数据库——那是服务端的事。

use std::sync::Arc;

use protocol::{IpcMessage, StepSpec};
use tokio::sync::mpsc;

use crate::ipc::Client;
use crate::local_tool::LocalToolClient;
use crate::model::ModelClient;
use crate::skills::LoadedSkill;
use crate::tools::ToolRegistry;

/// 单步输出上限（字符）。超过说明模型跑偏，截断比让产物变成流水账好。
const STEP_MAX_CHARS: usize = 800;

/// 一页参考信息最多带多少字进 prompt：再多会挤掉输入与已完成步骤。
const REFERENCE_MAX_CHARS: usize = 1_200;

/// 一次执行的输入。
#[derive(Debug, Clone)]
pub(crate) struct TaskJob {
    pub(crate) task_id: String,
    pub(crate) task_type: String,
    pub(crate) skill: Option<String>,
    pub(crate) input: serde_json::Value,
    /// 编码任务的一次性代理令牌；普通任务为 `None`。
    pub(crate) token: Option<String>,
    /// service 侧路由结论：provider / model / bin 按任务下发，全空即老行为。
    pub(crate) code: crate::code::CodeOptions,
}

/// 执行期间可能收到的控制信号。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Control {
    Resume,
    Cancel,
    /// 针对某一次工具调用的裁决：由钩子端点的等待者消费。
    ///
    /// 为什么复用这条通道而不是另开一条：`Resume` 本来就是"服务端推动继续"，
    /// 工具级裁决只是"继续/驳回到某一步"，语义同一族，多一条通道只会多一处断线处理。
    ToolDecision {
        call_id: String,
        approved: bool,
        reason: Option<String>,
        /// 用户勾了「本任务内不再询问这类操作」。
        remember: bool,
    },
}

/// 已取消、但可能还没开始的任务。
///
/// 取消是 HTTP 请求触发的，而 `Start` 是服务端在 `tokio::spawn` 里异步发出的——
/// 用户点完"取消"再点"派活"的窗口里，`Cancel` 完全可能比 `Start` 先到。
/// 没有这个集合，那种任务会照常跑一遍 CLI，而界面上早就显示"已取消"了。
///
/// 带 TTL 而不是永久记住：重试会复用同一个 `task_id`，一条陈旧的取消记录会让
/// 下一次执行被误跳过一次。30 秒足够覆盖调度窗口，也短于任何人工重试的间隔。
#[derive(Debug, Default)]
pub(crate) struct CancelledTasks {
    entries: std::collections::VecDeque<(String, std::time::Instant)>,
}

impl CancelledTasks {
    /// 取出后清除：同一个 `task_id` 的取消只生效一次。
    const TTL: std::time::Duration = std::time::Duration::from_secs(30);

    /// 条目上限。取消记录不是审计，溢出时丢最旧的。
    pub(crate) const LIMIT: usize = 256;

    pub(crate) fn mark(&mut self, task_id: &str) {
        self.mark_at(task_id, std::time::Instant::now());
    }

    /// 是否在有效期内存过取消；命中即清除。
    pub(crate) fn take(&mut self, task_id: &str) -> bool {
        self.take_at(task_id, std::time::Instant::now())
    }

    pub(crate) fn forget(&mut self, task_id: &str) {
        self.entries.retain(|(id, _)| id != task_id);
    }

    fn mark_at(&mut self, task_id: &str, now: std::time::Instant) {
        self.purge(now);
        if self.entries.iter().any(|(id, _)| id == task_id) {
            return;
        }
        if self.entries.len() >= Self::LIMIT {
            self.entries.pop_front();
        }
        self.entries.push_back((task_id.to_string(), now));
    }

    fn take_at(&mut self, task_id: &str, now: std::time::Instant) -> bool {
        self.purge(now);
        match self.entries.iter().position(|(id, _)| id == task_id) {
            Some(index) => {
                self.entries.remove(index);
                true
            }
            None => false,
        }
    }

    fn purge(&mut self, now: std::time::Instant) {
        self.entries
            .retain(|(_, at)| now.duration_since(*at) < Self::TTL);
    }
}

/// 一次模型调用的结局。分类而非 `Result`：四种结局的处理方式完全不同。
#[derive(Debug)]
enum ModelAttempt {
    /// 拿到文本。
    Text(String),
    /// 模型未启用：整段任务退回确定性执行，不再逐次往返。
    Disabled,
    /// 本次调用失败：这一步降级，任务继续。
    Degraded(String),
    /// 超预算：任务必须停。
    Budget,
    /// 用户取消或连接断开。
    Canceled,
}

/// 一步能拿到的外部参考信息。
#[derive(Debug, Clone)]
struct Reference {
    text: String,
    sources: Vec<(String, i64)>,
}

/// 参数多是因为它要拿齐"一次任务能用到的一切"；打包成结构体只是把同样的
/// 字段挪个位置，调用方还得拆一次。clippy 的新 lint 按 7 个参数报警，这里显式保留。
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run(
    client: Client,
    skills: Arc<Vec<LoadedSkill>>,
    tools: Arc<ToolRegistry>,
    model: Arc<ModelClient>,
    local: Arc<LocalToolClient>,
    code: Arc<crate::code::Runtime>,
    job: TaskJob,
    mut control: mpsc::Receiver<Control>,
) {
    let task_id = job.task_id.clone();

    // 1. 解析技能名：优先 `skill` 字段，其次 `skill:` 前缀。
    let skill_name = job
        .skill
        .clone()
        .or_else(|| job.task_type.strip_prefix("skill:").map(str::to_string));

    let Some(skill) = skills
        .iter()
        .find(|candidate| Some(&candidate.manifest.name) == skill_name.as_ref())
    else {
        tracing::warn!(%task_id, ?skill_name, "技能不存在或已被禁用");
        fail(&client, &task_id, "skill_unknown", "技能不可用，请检查配置").await;
        return;
    };

    let manifest = skill.manifest.clone();

    // 1.5 编码任务：交给 code 模块接管，不走"每步一次模型调用"的循环。
    //
    // 判据是技能声明的能力名而不是技能名：以后再加一个需要跑 CLI 的技能时，
    // 这里不用改，只要它的 `required_tools` 里写上 `code.exec`。
    if manifest
        .required_tools
        .iter()
        .any(|tool| tool == crate::code::CODE_TOOL)
    {
        tracing::info!(%task_id, "按编码任务执行");
        code.execute(
            client,
            task_id,
            job.input,
            job.token,
            job.code,
            skill.body.clone(),
            control,
        )
        .await;
        return;
    }

    // 2. 上报计划
    let steps: Vec<StepSpec> = manifest
        .steps
        .iter()
        .enumerate()
        .map(|(index, name)| StepSpec {
            seq: index as i64,
            name: name.clone(),
        })
        .collect();

    if !client
        .send(IpcMessage::PlanCreated {
            task_id: task_id.clone(),
            steps,
        })
        .await
    {
        return;
    }

    // 3. 逐步执行
    let mut collected: Vec<String> = Vec::new();
    let mut sources: Vec<(String, i64)> = Vec::new();
    let mut model_enabled = true;
    let submit = job.input.get("submit").and_then(|value| value.as_bool()) == Some(true);

    for (index, name) in manifest.steps.iter().enumerate() {
        if let Ok(Control::Cancel) = control.try_recv() {
            tracing::info!(%task_id, "收到取消，停止执行");
            return;
        }

        if !client
            .send(IpcMessage::StepStarted {
                task_id: task_id.clone(),
                seq: index as i64,
                name: name.clone(),
            })
            .await
        {
            return;
        }

        // 需要外部信息的步骤先取资料：模型看到的是"资料 + 指令"，
        // 而不是被要求自己编一段查询结果。
        let reference = gather_reference(
            &client, &tools, &local, &manifest, &task_id, name, &job.input,
        )
        .await;
        if let Some(reference) = &reference {
            merge_sources(&mut sources, &reference.sources);
        }

        let mut output = None;
        if model_enabled {
            let system = step_system(skill);
            let prompt = step_prompt(
                skill,
                name,
                index,
                manifest.steps.len(),
                &job.input,
                &collected,
                reference.as_ref(),
            );

            match call_model(
                &model,
                &client,
                &mut control,
                &task_id,
                "step",
                &system,
                &prompt,
            )
            .await
            {
                ModelAttempt::Text(text) => {
                    let text = text.trim();
                    output = Some(if text.is_empty() {
                        degrade_output(name, "模型没有返回内容", reference.as_ref())
                    } else {
                        truncate(text, STEP_MAX_CHARS)
                    });
                }
                ModelAttempt::Disabled => {
                    tracing::info!(%task_id, "模型未启用，整段任务退回确定性执行");
                    model_enabled = false;
                }
                ModelAttempt::Degraded(reason) => {
                    tracing::warn!(%task_id, %reason, "步骤模型调用失败，降级为确定性输出");
                    output = Some(degrade_output(name, &reason, reference.as_ref()));
                }
                ModelAttempt::Budget => {
                    fail_budget(&client, &task_id).await;
                    return;
                }
                ModelAttempt::Canceled => {
                    tracing::info!(%task_id, "模型调用期间被取消，停止执行");
                    return;
                }
            }
        }

        let output = output.unwrap_or_else(|| deterministic_step(name, reference.as_ref()));
        collected.push(output.clone());

        if !client
            .send(IpcMessage::StepOutput {
                task_id: task_id.clone(),
                seq: index as i64,
                summary: output,
            })
            .await
        {
            return;
        }

        // 4. 停止点：只有显式要求提交时才请求审批
        let is_stop_point = manifest.stop_before.as_deref() == Some(name.as_str());
        if is_stop_point && submit {
            if !client
                .send(IpcMessage::ApprovalRequired {
                    task_id: task_id.clone(),
                    action: "submit_form".to_string(),
                    target: Some(format!("skill:{}", manifest.name)),
                    impact: Some("模拟提交：确认后不可撤销".to_string()),
                })
                .await
            {
                return;
            }

            tracing::info!(%task_id, "已请求审批，等待恢复");
            loop {
                match control.recv().await {
                    Some(Control::Resume) => {
                        tracing::info!(%task_id, "收到恢复，继续执行");
                        break;
                    }
                    // 技能执行路径不开工具级审批：这里的裁决没有等待者，忽略即可。
                    Some(Control::ToolDecision { .. }) => continue,
                    Some(Control::Cancel) | None => {
                        tracing::info!(%task_id, "审批期间被取消或连接关闭，停止执行");
                        return;
                    }
                }
            }
        }
    }

    // 5. 产物与终态。产物种类必须与技能的 outputs 对齐，服务端会逐项校验。
    let summary = collected.join("\n");
    for kind in &manifest.outputs {
        let content = if model_enabled {
            let system = synthesis_system(skill, kind);
            let prompt = synthesis_prompt(&job.input, &collected, &sources);
            match call_model(
                &model,
                &client,
                &mut control,
                &task_id,
                "synthesis",
                &system,
                &prompt,
            )
            .await
            {
                ModelAttempt::Text(text) if !text.trim().is_empty() => {
                    with_sources(text.trim().to_string(), &sources)
                }
                ModelAttempt::Text(_) => {
                    tracing::warn!(%task_id, "归纳产物为空，回退为步骤汇总");
                    render_artifact(kind, &task_id, skill, &collected, &job.input, &sources)
                }
                ModelAttempt::Disabled | ModelAttempt::Degraded(_) => {
                    render_artifact(kind, &task_id, skill, &collected, &job.input, &sources)
                }
                ModelAttempt::Budget => {
                    fail_budget(&client, &task_id).await;
                    return;
                }
                ModelAttempt::Canceled => return,
            }
        } else {
            render_artifact(kind, &task_id, skill, &collected, &job.input, &sources)
        };

        // 正文随事件上传，由服务端落盘；这里裁剪到协议上限，避免一条事件打断连接。
        let content = protocol::clip_artifact_content(&with_sources(content, &sources));
        let size = content.len() as i64;
        if !client
            .send(IpcMessage::ArtifactCreated {
                task_id: task_id.clone(),
                kind: kind.clone(),
                size,
                mime: Some("text/plain".to_string()),
                content,
            })
            .await
        {
            return;
        }
    }

    let _ = client
        .send(IpcMessage::TaskFinished {
            task_id,
            summary: truncate(&summary, 200),
        })
        .await;
}

/// 调一次模型，并在等待期间响应取消。
///
/// 取消不是错误：用户按了停止，就不该再产生这一步的输出。
async fn call_model(
    model: &ModelClient,
    client: &Client,
    control: &mut mpsc::Receiver<Control>,
    task_id: &str,
    purpose: &str,
    system: &str,
    prompt: &str,
) -> ModelAttempt {
    let call = model.call(client, task_id, purpose, system, prompt, None);
    tokio::pin!(call);

    let reply = loop {
        tokio::select! {
            biased;
            signal = control.recv() => match signal {
                Some(Control::Cancel) | None => return ModelAttempt::Canceled,
                Some(Control::Resume) | Some(Control::ToolDecision { .. }) => continue,
            },
            reply = &mut call => break reply,
        }
    };

    match reply {
        Ok(reply) if reply.is_ok() => ModelAttempt::Text(reply.text),
        Ok(reply) => match reply.code() {
            Some("model_disabled") => ModelAttempt::Disabled,
            Some("budget_exceeded") => ModelAttempt::Budget,
            _ => ModelAttempt::Degraded(reply.error.unwrap_or_else(|| "模型调用失败".to_string())),
        },
        Err(err) => ModelAttempt::Degraded(err),
    }
}

/// 取这一步需要的外部资料。
///
/// 触发条件与取什么，全部来自技能的 `fetch` 声明——不再看步骤名里有没有
/// 「查询」两个字。旧写法是隐性契约：外部插件写出来的技能永远猜不到
/// 自己的步骤名得叫什么，结果就是"看起来有资料、跑起来一片未获取"。
///
/// 参数里没有声明的那个字段时**不**拿 `example.com` 之类的默认值凑数，
/// 而是明确写"没有可引用的外部信息"。
async fn gather_reference(
    connection: &Client,
    tools: &ToolRegistry,
    local: &LocalToolClient,
    manifest: &protocol::SkillManifest,
    task_id: &str,
    step_name: &str,
    input: &serde_json::Value,
) -> Option<Reference> {
    let fetch = manifest.fetch.as_ref()?;
    if fetch.step != step_name {
        return None;
    }

    let field = fetch.from.as_str();
    let value = input
        .get(field)
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty());

    let Some(value) = value else {
        return Some(Reference {
            text: format!("任务没有提供 `{field}`，因此这一步没有可引用的外部信息。"),
            sources: Vec::new(),
        });
    };

    let tool = fetch.tool;
    let args = reference_args(tool, value, input);

    // 文件工具在本机跑（要路径准入与项目根），网络工具在 worker 本地跑。
    if tool.is_local_tool() {
        let text = match local.call(connection, task_id, tool.as_str(), args).await {
            Ok(reply) if reply.is_ok() => format!("项目文件（{value}）：\n{}", reply.content),
            Ok(reply) => format!(
                "读取失败（{}）：这一步没有文件内容。",
                reply.error.unwrap_or_default()
            ),
            Err(err) => format!("读取失败（{err}）：这一步没有文件内容。"),
        };
        return Some(Reference {
            text: truncate(&text, REFERENCE_MAX_CHARS),
            sources: Vec::new(),
        });
    }

    match tools.call(tool.as_str(), &args).await {
        Ok(output) => {
            // 搜索类工具没有来源：用它拼一个只会诱导模型去引用搜索引擎。
            let label = output
                .source_url
                .clone()
                .unwrap_or_else(|| value.to_string());
            let sources = output
                .source_url
                .clone()
                .map(|url| vec![(url, output.fetched_at)])
                .unwrap_or_default();

            Some(Reference {
                text: truncate(
                    &format!("参考信息（{label}）：{}", output.summary),
                    REFERENCE_MAX_CHARS,
                ),
                sources,
            })
        }
        Err(err) => Some(Reference {
            text: format!("查询失败（{err}）：这一步没有外部信息，缺失就写「未获取」。"),
            sources: Vec::new(),
        }),
    }
}

/// 按工具语义把「一个取值」拼成参数。
fn reference_args(
    tool: protocol::skill::FetchTool,
    value: &str,
    input: &serde_json::Value,
) -> serde_json::Value {
    use protocol::skill::FetchTool;

    match tool {
        FetchTool::WebFetch => serde_json::json!({ "url": value }),
        // 条数固定 6：技能不需要为"搜几条"多一个字段，
        // 而 6 条足够判断一页在讲什么，也不会把上下文撑爆。
        FetchTool::WebSearch => serde_json::json!({ "query": value, "limit": 6 }),
        FetchTool::Weather => {
            let days = input
                .get("days")
                .and_then(serde_json::Value::as_u64)
                .unwrap_or(3)
                .clamp(1, 7);
            serde_json::json!({ "city": value, "days": days })
        }
        FetchTool::ReadFile | FetchTool::ListDir => serde_json::json!({ "path": value }),
        FetchTool::SearchFile | FetchTool::SearchContent => serde_json::json!({ "pattern": value }),
    }
}

fn deterministic_step(step_name: &str, reference: Option<&Reference>) -> String {
    match reference {
        Some(reference) => format!("{step_name}：{}", reference.text),
        None => format!("已完成：{step_name}"),
    }
}

fn degrade_output(step_name: &str, reason: &str, reference: Option<&Reference>) -> String {
    match reference {
        Some(reference) => format!(
            "{step_name}：模型未参与（{reason}）；参考：{}",
            reference.text
        ),
        None => format!("{step_name}：模型未参与（{reason}）"),
    }
}

fn step_system(skill: &LoadedSkill) -> String {
    format!(
        "你在执行技能「{name}」，风险等级 {risk}。下面是技能说明书，按它工作。\n\
         \n{body}\n\
         \n输出要求：\n\
         - 只输出**当前这一步**的结果，纯文本，不要复述其它步骤，不要写标题或序号；\n\
         - 数字与事实只能来自提供的输入与参考资料，缺失就写“未获取”，绝不编造；\n\
         - 不要声称已经执行任何写操作（下单、提交、支付）。",
        name = skill.manifest.name,
        risk = skill.manifest.risk_level,
        body = skill.body,
    )
}

fn step_prompt(
    skill: &LoadedSkill,
    step_name: &str,
    index: usize,
    total: usize,
    input: &serde_json::Value,
    collected: &[String],
    reference: Option<&Reference>,
) -> String {
    let mut prompt = String::new();
    prompt.push_str("任务输入：\n");
    prompt.push_str(&input.to_string());
    prompt.push_str("\n\n");

    prompt.push_str("已完成的步骤：\n");
    if collected.is_empty() {
        prompt.push_str("（无）\n");
    } else {
        for (seq, (name, output)) in skill.manifest.steps.iter().zip(collected).enumerate() {
            prompt.push_str(&format!("{}. {name}：{output}\n", seq + 1));
        }
    }

    prompt.push_str(&format!(
        "\n当前步骤（第 {}/{} 步）：{step_name}\n",
        index + 1,
        total
    ));

    if let Some(reference) = reference {
        prompt.push_str("\n参考资料：\n");
        prompt.push_str(&reference.text);
        prompt.push('\n');
    }

    prompt
}

fn synthesis_system(skill: &LoadedSkill, kind: &str) -> String {
    format!(
        "你在为技能「{name}」整理最终产物「{kind}」。技能说明书如下，产物必须符合它的要求。\n\
         \n{body}\n\
         \n输出要求：\n\
         - 纯文本，结论在前，可直接给用户看；\n\
         - 数据只能来自步骤结果与参考资料，缺失就写“未获取实时数据”，不要编造价格、班次或时间；\n\
         - 不要提及“步骤”“模型”这类实现细节。",
        name = skill.manifest.name,
        body = skill.body,
    )
}

fn synthesis_prompt(
    input: &serde_json::Value,
    collected: &[String],
    sources: &[(String, i64)],
) -> String {
    let mut prompt = String::new();
    prompt.push_str("任务输入：\n");
    prompt.push_str(&input.to_string());
    prompt.push_str("\n\n各步骤结果：\n");
    for (index, output) in collected.iter().enumerate() {
        prompt.push_str(&format!("{}. {output}\n", index + 1));
    }

    if !sources.is_empty() {
        prompt.push_str("\n可引用的来源：\n");
        for (url, fetched_at) in sources {
            prompt.push_str(&format!("- {url}（采集于 {}）\n", format_ts(*fetched_at)));
        }
    }

    prompt
}

/// 去重合并来源：同一地址只保留第一次采集时间。
fn merge_sources(into: &mut Vec<(String, i64)>, extra: &[(String, i64)]) {
    for (url, fetched_at) in extra {
        if !into.iter().any(|(existing, _)| existing == url) {
            into.push((url.clone(), *fetched_at));
        }
    }
}

/// 加上"参考来源"尾巴。
///
/// 产物会脱离对话被单独打开，来源必须跟着正文走，否则读者无从核对。
fn with_sources(mut text: String, sources: &[(String, i64)]) -> String {
    if sources.is_empty() || text.contains("参考来源：") {
        return text;
    }

    text.push_str("\n\n参考来源：\n");
    for (url, fetched_at) in sources {
        text.push_str(&format!("- {url}（采集于 {}）\n", format_ts(*fetched_at)));
    }
    text
}

async fn fail(client: &Client, task_id: &str, code: &str, hint: &str) {
    let _ = client
        .send(IpcMessage::TaskFailed {
            task_id: task_id.to_string(),
            code: code.to_string(),
            hint: hint.to_string(),
            retryable: false,
        })
        .await;
}

/// 超预算的收场：错误码固定，客户端可据此提示"缩小范围或调高上限"。
async fn fail_budget(client: &Client, task_id: &str) {
    fail(
        client,
        task_id,
        "budget_exceeded",
        "单任务模型用量已超上限（12 次 / 60k tokens / 15 分钟），可缩小范围或调高 task 配置后重试",
    )
    .await;
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    text.chars().take(max).collect::<String>() + "…"
}

/// 渲染产物正文（模型不可用时的回退路径）。
///
/// 内容必须能独立说明"这次任务做了什么、依据是什么"——产物一旦落盘就会脱离
/// 对话上下文被单独打开，只写"已完成"等于没写。
fn render_artifact(
    kind: &str,
    task_id: &str,
    skill: &LoadedSkill,
    outputs: &[String],
    input: &serde_json::Value,
    sources: &[(String, i64)],
) -> String {
    let mut text = String::new();
    text.push_str(&format!("产物：{kind}\n"));
    text.push_str(&format!(
        "技能：{} v{}\n",
        skill.manifest.name, skill.manifest.version
    ));
    text.push_str(&format!("任务：{task_id}\n"));
    if !input.is_null() && input.as_object().is_some_and(|map| !map.is_empty()) {
        text.push_str(&format!("参数：{input}\n"));
    }
    text.push_str("\n--- 步骤 ---\n");

    for (index, name) in skill.manifest.steps.iter().enumerate() {
        let output = outputs
            .get(index)
            .map(String::as_str)
            .unwrap_or("（无输出）");
        text.push_str(&format!("[{}] {name}\n{output}\n\n", index + 1));
    }

    text.push_str("--- 说明 ---\n");
    text.push_str("本产物由内置技能按固定步骤生成，未经过人工复核。\n");
    with_sources(text, sources)
}

/// Unix 毫秒 → `YYYY-MM-DD HH:MM:SS UTC`。
///
/// 不引日期库：产物里只需要一个人类可读的时间戳，为它加一个依赖不划算。
fn format_ts(ms: i64) -> String {
    let seconds = ms.div_euclid(1_000);
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02} UTC",
        rest / 3_600,
        (rest % 3_600) / 60,
        rest % 60
    )
}

/// 天数 → 公历年月日（Howard Hinnant 的 civil_from_days）。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    (year, month as u32, day as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancelled_tasks_skip_only_the_next_start() {
        let mut cancelled = CancelledTasks::default();
        let now = std::time::Instant::now();

        cancelled.mark_at("task_1", now);
        assert!(
            cancelled.take_at("task_1", now),
            "提前到达的取消应让 Start 跳过执行"
        );
        assert!(
            !cancelled.take_at("task_1", now),
            "同一个 task_id 只生效一次：重试会复用它"
        );
    }

    #[test]
    fn cancelled_tasks_expire() {
        let mut cancelled = CancelledTasks::default();
        let now = std::time::Instant::now();
        cancelled.mark_at("task_1", now);

        let later = now + CancelledTasks::TTL + std::time::Duration::from_secs(1);
        assert!(
            !cancelled.take_at("task_1", later),
            "过期记录不该误跳之后的执行"
        );
    }

    #[test]
    fn cancelled_tasks_are_bounded() {
        let mut cancelled = CancelledTasks::default();
        let now = std::time::Instant::now();
        for index in 0..(CancelledTasks::LIMIT + 10) {
            cancelled.mark_at(&format!("task_{index}"), now);
        }
        assert_eq!(
            cancelled.entries.len(),
            CancelledTasks::LIMIT,
            "条目数必须有上限，避免长跑进程无限增长"
        );
    }

    #[test]
    fn forget_drops_pending_cancel() {
        let mut cancelled = CancelledTasks::default();
        cancelled.mark("task_1");
        cancelled.forget("task_1");
        assert!(!cancelled.take("task_1"), "任务结束后不该留下取消记录");
    }

    fn sample_skill() -> LoadedSkill {
        let (manifest, body) = protocol::parse_builtin(
            "---\nname: trip-plan\nversion: 0.1.0\nrisk_level: read\n\
             required_tools:\n  - web.fetch\noutputs: [plan_table]\n\
             steps:\n  - 解析出行需求\n  - 查询参考信息\n---\n正文说明",
        )
        .expect("解析失败");
        LoadedSkill { manifest, body }
    }

    #[test]
    fn truncate_marks_cut_text() {
        assert_eq!(truncate("abcdef", 3), "abc…");
        assert_eq!(truncate("abc", 3), "abc");
    }

    #[test]
    fn artifact_text_carries_steps_and_input() {
        let skill = sample_skill();
        let text = render_artifact(
            "plan_table",
            "task_1",
            &skill,
            &["已完成：解析出行需求".to_string()],
            &serde_json::json!({ "destination": "上海" }),
            &[("https://example.com".to_string(), 1_700_000_000_000)],
        );

        assert!(text.contains("产物：plan_table"));
        assert!(text.contains("[1] 解析出行需求"));
        // 步骤数多于输出数时用占位符补齐，避免产物里出现空行
        assert!(text.contains("[2] 查询参考信息\n（无输出）"));
        assert!(text.contains("destination"));
        assert!(text.contains("参考来源："));
        assert!(text.contains("2023-11-14 22:13:20 UTC"));
    }

    #[test]
    fn timestamps_are_utc_and_zero_epoch_is_1970() {
        assert_eq!(format_ts(0), "1970-01-01 00:00:00 UTC");
        assert_eq!(format_ts(1_700_000_000_000), "2023-11-14 22:13:20 UTC");
    }

    #[test]
    fn step_prompt_lists_done_steps_and_current() {
        let skill = sample_skill();
        let prompt = step_prompt(
            &skill,
            "查询参考信息",
            1,
            2,
            &serde_json::json!({ "city": "上海" }),
            &["已解析：下周三".to_string()],
            Some(&Reference {
                text: "上海 10 月 28 日多云".to_string(),
                sources: Vec::new(),
            }),
        );

        assert!(prompt.contains("已完成的步骤"));
        assert!(prompt.contains("1. 解析出行需求：已解析：下周三"));
        assert!(prompt.contains("当前步骤（第 2/2 步）：查询参考信息"));
        assert!(prompt.contains("参考资料：\n上海 10 月 28 日多云"));
    }

    /// 取资料只看 `fetch` 声明：步骤名不匹配就什么都不做，
    /// 输入缺字段就明说"没有提供"，绝不拿默认值凑数。
    #[tokio::test]
    async fn gather_reference_follows_the_declared_fetch() {
        use protocol::skill::{FetchSource, FetchTool, SkillFetch};

        let (tx, _rx) = mpsc::channel(1);
        let client = Client::for_test(tx);
        let tools = ToolRegistry::new();
        let local = LocalToolClient::new(std::time::Duration::from_millis(50));

        let mut manifest = sample_skill().manifest;
        manifest.fetch = Some(SkillFetch {
            step: "查询参考信息".to_string(),
            from: FetchSource::Url,
            tool: FetchTool::WebFetch,
        });

        // 别的步骤：不取资料，也不发 IPC。
        assert!(
            gather_reference(
                &client,
                &tools,
                &local,
                &manifest,
                "task_1",
                "解析出行需求",
                &serde_json::json!({})
            )
            .await
            .is_none(),
            "非声明步骤不该触发取资料"
        );

        // 声明步骤但没给 url：明确写"没有提供"，且不产生来源。
        let reference = gather_reference(
            &client,
            &tools,
            &local,
            &manifest,
            "task_1",
            "查询参考信息",
            &serde_json::json!({}),
        )
        .await
        .expect("声明步骤应给出提示");

        assert!(reference.text.contains("url"), "{}", reference.text);
        assert!(reference.sources.is_empty(), "没有资料就不该有来源");
    }

    /// 没有 `fetch` 声明的技能（如 bill-explain）任何步骤都不取资料。
    #[tokio::test]
    async fn skill_without_fetch_never_fetches() {
        let (tx, _rx) = mpsc::channel(1);
        let client = Client::for_test(tx);
        let tools = ToolRegistry::new();
        let local = LocalToolClient::new(std::time::Duration::from_millis(50));
        let manifest = sample_skill().manifest;

        assert!(manifest.fetch.is_none());
        assert!(
            gather_reference(
                &client,
                &tools,
                &local,
                &manifest,
                "task_1",
                "查询",
                &serde_json::json!({ "url": "https://example.com" })
            )
            .await
            .is_none(),
            "没有声明就不该按步骤名猜"
        );
    }

    #[test]
    fn sources_are_deduped_and_appended_once() {
        let mut sources = Vec::new();
        merge_sources(
            &mut sources,
            &[
                ("https://example.com".to_string(), 1),
                ("https://a.com".to_string(), 2),
            ],
        );
        merge_sources(&mut sources, &[("https://example.com".to_string(), 99)]);
        assert_eq!(sources.len(), 2);
        assert_eq!(sources[0].1, 1, "同一地址应保留首次采集时间");

        let once = with_sources("正文".to_string(), &sources);
        let twice = with_sources(once.clone(), &sources);
        assert_eq!(once, twice, "已有来源块时不应重复追加");
        assert!(once.contains("https://a.com"));
    }
}
