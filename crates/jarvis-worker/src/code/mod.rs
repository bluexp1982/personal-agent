//! 编码任务的执行编排。
//!
//! 分工与其它任务一致：worker 决定"怎么跑"，service 决定"能不能跑、花了多少"。
//! 这里只做五件事：
//!
//! 1. 准备工作树（仓库外，独立分支）；
//! 2. 写该任务的 CLI 配置并拉起 CLI（令牌来自 `Start`）；
//! 3. 把 CLI 输出转成进度事件与运行日志，并按节流上报；
//! 4. 提交到任务分支，产出 `diff` / `change_summary` / `run_log` 三件产物；
//! 5. 请求审批，批准后合并回原分支。
//!
//! **不做**状态裁决：任务成功与否由服务端按技能 `outputs` 判定。

pub(crate) mod config;
pub(crate) mod events;
pub(crate) mod hooks;
pub(crate) mod log;
pub(crate) mod process;
pub(crate) mod provider;
pub(crate) mod risk;
pub(crate) mod worktree;

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use protocol::{IpcMessage, StepSpec};
use tokio::sync::{mpsc, Semaphore};

use crate::ipc::Client;
use crate::runner::Control;

use self::config::CodeConfig;
use self::events::EventLog;
use self::hooks::{ApprovalPolicy, HookOptions, ToolDecisions};
use self::log::LineRing;
use self::provider::{CliEvent, CodingProvider, HookSpec, RunRequest};

/// 技能里用来声明"这个任务要走编码 CLI"的能力名。
pub(crate) const CODE_TOOL: &str = "code.exec";

/// 计划骨架。CLI 自己会决定真实步骤，这里只给出用户能理解的阶段。
const STEPS: [&str; 4] = ["准备隔离项目", "执行编码", "生成改动与日志", "合并前确认"];

/// 进度上报间隔：非实时方案下，每 5 秒一条足够让人看出"在动"。
const PROGRESS_INTERVAL: Duration = Duration::from_secs(5);

/// 一次进度摘要带几条动作。
///
/// 详情页的过程区最多展示 6 行，多了也看不完；真正的完整流水在 `run_log`。
const PROGRESS_LINES: usize = 6;

/// 一次编码任务最多接受的需求长度。再长说明用户该写文档而不是派任务。
const MAX_INSTRUCTION_CHARS: usize = 8_000;

/// worker 侧的编码能力入口。
#[derive(Debug)]
pub(crate) struct Runtime {
    config: CodeConfig,
    semaphore: Arc<Semaphore>,
}

/// service 侧路由下发的每任务覆盖项。
///
/// 全为 `None` 时行为与升级前完全一致（用 worker 的进程级配置）。
#[derive(Debug, Clone, Default)]
pub(crate) struct CodeOptions {
    pub(crate) provider: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) bin: Option<std::path::PathBuf>,
    /// 路由理由（人话），写进 `change_summary` 顶部。
    pub(crate) route_reason: Option<String>,
}

impl Runtime {
    pub(crate) fn from_env() -> Self {
        let config = CodeConfig::from_env();
        let permits = config.max_concurrent;
        Self {
            config,
            semaphore: Arc::new(Semaphore::new(permits)),
        }
    }

    /// 能力是否启用。未启用时 `code-task` 技能不会被加载。
    pub(crate) fn enabled(&self) -> bool {
        self.config.enabled
    }

    pub(crate) fn provider_id(&self) -> &str {
        &self.config.provider
    }

    /// 执行一个编码任务。所有失败都转成 `TaskFailed`，不向调用方返回错误。
    ///
    /// `options` 是 service 侧路由的结论：provider / model / bin 都按任务下发。
    /// 全为空的形态等价于"用 worker 自己的环境变量"，也就是升级前的行为。
    ///
    /// 参数多是因为它要把一次任务的全部上下文原样传给 CLI；打包成结构体只是
    /// 把同样的字段挪个位置，调用方还得拆一次，不值得。clippy 的新 lint 会按
    /// 7 个参数报警，这里显式保留。
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn execute(
        &self,
        client: Client,
        task_id: String,
        input: serde_json::Value,
        token: Option<String>,
        options: CodeOptions,
        guidance: String,
        mut control: mpsc::Receiver<Control>,
    ) {
        let task_id = task_id.as_str();

        // ---- 前置检查：任何一项不满足都立刻失败，别让用户等到 CLI 启动才看到原因
        if !self.config.enabled {
            return fail(
                &client,
                task_id,
                "code_unavailable",
                "编码能力未启用：在配置里打开 code.enabled 后重试",
                false,
            )
            .await;
        }

        // 路由结果优先；没有就是老行为（worker 进程级配置）。
        let provider_id = options
            .provider
            .clone()
            .unwrap_or_else(|| self.config.provider.clone());
        let model = options
            .model
            .clone()
            .unwrap_or_else(|| self.config.model.clone());

        let Some(provider) = provider::from_name(&provider_id) else {
            return fail(
                &client,
                task_id,
                "code_unavailable",
                &format!(
                    "provider \"{provider_id}\" 未实现；当前支持 {}",
                    protocol::SUPPORTED_CODE_PROVIDERS.join(" / ")
                ),
                false,
            )
            .await;
        };

        let (Some(root), Some(proxy_url)) = (
            self.config.worktree_root.as_ref(),
            self.config.proxy_url.as_ref(),
        ) else {
            return fail(
                &client,
                task_id,
                "code_unavailable",
                "服务端未下发 worktree 目录或代理地址：服务与 worker 版本可能不一致",
                false,
            )
            .await;
        };

        let Some(token) = token else {
            return fail(
                &client,
                task_id,
                "code_unavailable",
                "缺少本次任务的代理令牌：请重试；若持续出现请检查服务端版本",
                false,
            )
            .await;
        };

        // 每任务的 bin 优先于进程级 `code.bin`；都没有就交给 provider 的 PATH 查找。
        let bin = options.bin.as_deref().or(self.config.bin.as_deref());
        let Some(exe) = provider.resolve(bin) else {
            return fail(
                &client,
                task_id,
                "code_unavailable",
                &format!(
                    "找不到 {} 可执行文件：安装后重试，或在 code.bin 指定完整路径",
                    provider.id()
                ),
                false,
            )
            .await;
        };

        let parsed = match parse_input(&input) {
            Ok(parsed) => parsed,
            Err(hint) => {
                return fail(&client, task_id, "invalid_request", hint, false).await;
            }
        };

        tracing::info!(
            task_id,
            provider = provider.id(),
            repo = %parsed.repo.display(),
            "开始编码任务"
        );

        // ---- 计划骨架
        let steps: Vec<StepSpec> = STEPS
            .iter()
            .enumerate()
            .map(|(seq, name)| StepSpec {
                seq: seq as i64,
                name: (*name).to_string(),
            })
            .collect();
        if !client
            .send(IpcMessage::PlanCreated {
                task_id: task_id.to_string(),
                steps,
            })
            .await
        {
            return;
        }

        // ---- 并发位：编码任务很重，默认一次只跑一个
        let _permit = match self.semaphore.acquire().await {
            Ok(permit) => permit,
            Err(_) => return,
        };

        // 审批策略随任务下发；缺省沿用 worker 侧配置（默认 request）。
        let policy = ApprovalPolicy::from_input(&input, self.config.approval);
        tracing::info!(
            %task_id,
            policy = policy.as_str(),
            "编码任务的审批策略"
        );

        // ---- 1. 工作树
        step(&client, task_id, 0).await;
        let workspace = match worktree::prepare(&parsed.repo, root, task_id).await {
            Ok(workspace) => workspace,
            Err(err) => {
                let retryable = err.code() == "code_failed";
                return fail(&client, task_id, err.code(), &err.hint(), retryable).await;
            }
        };
        output(
            &client,
            task_id,
            0,
            &format!(
                "工作树就绪：分支 {}（基于 {}）",
                workspace.branch, workspace.base_branch
            ),
        )
        .await;

        // ---- 2. 拉起 CLI
        step(&client, task_id, 1).await;

        // 事件流与决策端点的生命周期都跟着这一次执行。
        let events = Arc::new(
            EventLog::new(task_id, provider.id(), provider.injects_hook())
                .with_rules(self.config.extra_rules.clone()),
        );
        let decisions = Arc::new(ToolDecisions::new());

        // 钩子侧必须比 service 的审批 TTL 早一点放弃，否则 CLI 会先被卡死。
        let hook_timeout = self
            .config
            .tool_approval_ttl
            .saturating_sub(Duration::from_secs(5))
            .min(hooks::DEFAULT_TIMEOUT)
            .max(Duration::from_secs(10));

        // 端点必须比 CLI 先就绪：钩子连不上时所有写操作都会被驳回，
        // 任务会"莫名失败"，不如在这里就给出明确原因。
        let endpoint = match hooks::start(
            HookOptions {
                task_id: task_id.to_string(),
                provider: provider.id().to_string(),
                worktree: workspace.path.clone(),
                approval_enabled: self.config.tool_approval,
                always_ask: self.config.always_ask.clone(),
                policy,
                extra_rules: self.config.extra_rules.clone(),
                timeout: hook_timeout,
            },
            client.clone(),
            decisions.clone(),
            events.clone(),
        )
        .await
        {
            Ok(endpoint) => endpoint,
            Err(err) => {
                return fail(
                    &client,
                    task_id,
                    "code_failed",
                    &format!(
                        "启动工具决策端点失败（{err}）：工作树 {} 已保留",
                        workspace.path.display()
                    ),
                    true,
                )
                .await;
            }
        };

        let request = RunRequest {
            model: model.clone(),
            worktree: workspace.path.clone(),
            config_dir: workspace.config_dir.clone(),
            proxy_url: proxy_url.clone(),
            token,
            prompt: compose_prompt(&parsed.instruction, &guidance),
            hook: Some(HookSpec {
                socket: endpoint.socket.clone(),
                // shim 就是 worker 自己：不依赖用户机器的 Node/Python。
                shim: std::env::current_exe()
                    .unwrap_or_else(|_| std::path::PathBuf::from("jarvis-worker")),
                timeout_secs: hook_timeout.as_secs(),
            }),
        };

        if let Err(err) = provider.write_config(&request) {
            provider.cleanup(&request);
            return fail(
                &client,
                task_id,
                "code_failed",
                &format!("写入 CLI 配置失败：{err}"),
                true,
            )
            .await;
        }

        // 运行前记下主仓库状态：CLI 若绕过工作树去改主仓库，事后要能立刻指出来，
        // 而不是让我们看到"无改动 → 成功"。
        let repo_before = worktree::status_of(&workspace.repo)
            .await
            .unwrap_or_default();

        let mut command = provider.command(&exe, &request);
        // provider 需要额外注入的环境变量（模型档位、后台任务开关等）统一在这里落，
        // 免得每个实现都在 `command()` 里重复一遍 env 拼装。
        match provider.hook_env(&request) {
            Ok(pairs) => {
                for (key, value) in pairs {
                    command.env(key, value);
                }
            }
            Err(err) => {
                provider.cleanup(&request);
                return fail(
                    &client,
                    task_id,
                    "code_failed",
                    &format!("注入 CLI 环境变量失败：{err}"),
                    true,
                )
                .await;
            }
        }
        let activity = Arc::new(Mutex::new(Activity::default()));
        let ticker = spawn_progress(
            client.clone(),
            task_id.to_string(),
            activity.clone(),
            events.clone(),
        );

        let run = {
            let activity = activity.clone();
            let events = events.clone();
            let parser = provider.as_ref();
            let worktree = workspace.path.clone();
            process::run(
                command,
                self.config.timeout,
                &mut control,
                &decisions,
                |line| {
                    record(parser, &activity, &events, &worktree, line);
                },
            )
            .await
        };

        ticker.abort();
        // 工作树内的 CLI 配置必须先清掉，后面才有 `git add -A` 与 diff。
        provider.cleanup(&request);
        drop(endpoint);

        let run = match run {
            Ok(run) => run,
            Err(err) => {
                return fail(
                    &client,
                    task_id,
                    "code_failed",
                    &format!("无法启动编码 CLI：{err}"),
                    true,
                )
                .await;
            }
        };

        if run.canceled {
            tracing::info!(task_id, "编码任务被取消，保留工作树");
            return;
        }

        let snapshot = activity
            .lock()
            .map(|activity| activity.snapshot())
            .unwrap_or_default();
        let log_tail = activity
            .lock()
            .map(|activity| activity.ring.tail())
            .unwrap_or_default();
        if let Some(session_id) = snapshot.session_id.as_deref() {
            worktree::remember_session(&workspace, session_id);
        }

        // 越界检查：任务工作树之外的主仓库不允许出现新改动。
        let repo_after = worktree::status_of(&workspace.repo)
            .await
            .unwrap_or_default();
        if repo_after != repo_before {
            let changed = status_delta(&repo_before, &repo_after);
            return fail_with_log(
                &client,
                task_id,
                &format!(
                    "编码 CLI 改动了任务工作树之外的仓库（{}）：{}。\n\
                     这些改动不在本次任务的隔离范围内，因此没有自动回滚——请人工检查并清理后重试。",
                    workspace.repo.display(),
                    changed
                ),
                &snapshot,
                &events,
                &log_tail,
                &run.stderr_tail,
            )
            .await;
        }

        if run.timed_out {
            return fail_with_log(
                &client,
                task_id,
                &format!(
                    "执行超时（{} 秒），已终止进程组：{}",
                    self.config.timeout.as_secs(),
                    workspace.path.display()
                ),
                &snapshot,
                &events,
                &log_tail,
                &run.stderr_tail,
            )
            .await;
        }

        if !run.success() {
            let reason = snapshot
                .last_error
                .clone()
                .unwrap_or_else(|| format!("退出码 {}", exit_label(run.exit_code)));
            return fail_with_log(
                &client,
                task_id,
                &format!(
                    "编码 CLI 执行失败（{reason}）：{}",
                    workspace.path.display()
                ),
                &snapshot,
                &events,
                &log_tail,
                &run.stderr_tail,
            )
            .await;
        }

        // ---- 3. 提交并产出三件产物
        step(&client, task_id, 2).await;
        let committed = match worktree::commit(
            &workspace.path,
            &format!("agent: {task_id} {}", first_line(&parsed.instruction)),
        )
        .await
        {
            Ok(committed) => committed,
            Err(err) => {
                return fail(&client, task_id, err.code(), &err.hint(), true).await;
            }
        };

        let (stat, patch) = match worktree::diff(&workspace.path, &workspace.base_branch).await {
            Ok(diff) => diff,
            Err(err) => {
                return fail(&client, task_id, err.code(), &err.hint(), true).await;
            }
        };

        output(
            &client,
            task_id,
            2,
            &format!(
                "{}；{}",
                if committed {
                    "已提交到任务分支"
                } else {
                    "没有产生改动"
                },
                summarize_stat(&stat)
            ),
        )
        .await;

        send_artifact(
            &client,
            task_id,
            "diff",
            &format!(
                "{}\n\n{}",
                if stat.trim().is_empty() {
                    "（无改动）"
                } else {
                    stat.trim()
                },
                patch.trim()
            ),
        )
        .await;
        send_artifact(
            &client,
            task_id,
            "change_summary",
            &change_summary(
                &workspace,
                &stat,
                &snapshot,
                run.exit_code,
                provider.id(),
                &model,
                options.route_reason.as_deref(),
            ),
        )
        .await;
        send_artifact(
            &client,
            task_id,
            "run_log",
            &run_log(
                &workspace,
                &snapshot,
                &events,
                &run.stderr_tail,
                &log_tail,
                policy,
            ),
        )
        .await;

        // 没改动就没有可合并的东西：审批一张空卡片只会让用户困惑。
        if stat.trim().is_empty() {
            let _ = client
                .send(IpcMessage::TaskFinished {
                    task_id: task_id.to_string(),
                    summary: format!("编码任务完成，未产生改动（分支 {}）", workspace.branch),
                })
                .await;
            return;
        }

        // ---- 4. 合并前确认
        step(&client, task_id, 3).await;
        if !client
            .send(IpcMessage::ApprovalRequired {
                task_id: task_id.to_string(),
                action: "merge_changes".to_string(),
                target: Some(workspace.branch.clone()),
                impact: Some(format!(
                    "将把 {} 合并回 {}，改动不可撤销（分支与工作树会保留）",
                    workspace.branch, workspace.base_branch
                )),
            })
            .await
        {
            return;
        }

        tracing::info!(task_id, "已请求合并审批，等待恢复");
        loop {
            match control.recv().await {
                Some(Control::Resume) => break,
                // CLI 已退出，不该再有工具级裁决；迟到的按噪声忽略，别当成取消。
                Some(Control::ToolDecision { .. }) => continue,
                Some(Control::Cancel) | None => {
                    tracing::info!(task_id, "审批期间被取消或连接关闭，保留工作树");
                    return;
                }
            }
        }

        if let Err(err) = worktree::merge(
            &workspace.repo,
            &workspace.path,
            &workspace.branch,
            &format!("agent: {task_id}"),
        )
        .await
        {
            return fail(&client, task_id, err.code(), &err.hint(), false).await;
        }

        output(
            &client,
            task_id,
            3,
            &format!("已合并到 {}", workspace.base_branch),
        )
        .await;

        let _ = client
            .send(IpcMessage::TaskFinished {
                task_id: task_id.to_string(),
                summary: format!(
                    "编码任务完成：{} 已合并回 {}",
                    workspace.branch, workspace.base_branch
                ),
            })
            .await;
    }
}

/// 需求 + 技能正文里的边界说明。
///
/// 边界必须和需求一起交给 CLI：只写需求时模型会合理地"顺手"装个依赖、跑个 git push，
/// 而那两件事恰恰是这次任务不允许的。
/// 列出"运行后新出现"的仓库状态行，最多 5 条。
///
/// 只报告新增项：用户自己在跑任务期间改文件属于正常操作，不该算违规。
fn status_delta(before: &str, after: &str) -> String {
    let before: std::collections::HashSet<&str> = before.lines().map(str::trim).collect();
    let fresh: Vec<&str> = after
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !before.contains(line))
        .take(5)
        .collect();

    if fresh.is_empty() {
        return "（状态变化无法定位到具体文件）".to_string();
    }
    fresh.join("；")
}

/// 退出码的可读形式。`None` 在 unix 上通常是"被信号终止"，不是 0。
fn exit_label(code: Option<i32>) -> String {
    match code {
        Some(code) => code.to_string(),
        None => "无（可能被信号终止）".to_string(),
    }
}

fn compose_prompt(instruction: &str, guidance: &str) -> String {
    let guidance = guidance.trim();
    if guidance.is_empty() {
        return instruction.to_string();
    }
    format!("{instruction}\n\n---\n\n{guidance}")
}

/// 解析任务入参。失败返回给用户的中文提示。
struct CodeInput {
    repo: std::path::PathBuf,
    instruction: String,
}

fn parse_input(value: &serde_json::Value) -> Result<CodeInput, &'static str> {
    let repo = value
        .get("repo")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|repo| !repo.is_empty())
        .ok_or("缺少 repo：请在任务里指定仓库路径")?;

    let instruction = value
        .get("instruction")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .ok_or("缺少 instruction：请写一句要改什么")?;

    if instruction.chars().count() > MAX_INSTRUCTION_CHARS {
        return Err("instruction 过长（上限 8000 字），请把需求写短一些");
    }

    Ok(CodeInput {
        repo: std::path::PathBuf::from(repo),
        instruction: instruction.to_string(),
    })
}

/// 一次执行的累计状态，由 CLI 输出行驱动。
#[derive(Debug)]
struct Activity {
    events: usize,
    tools: usize,
    session_id: Option<String>,
    last_action: String,
    last_text: String,
    last_error: Option<String>,
    prompt_tokens: u64,
    completion_tokens: u64,
    /// CLI 原始输出的尾部：排障时比"解析后的事件"更有用。
    ring: LineRing,
}

impl Default for Activity {
    fn default() -> Self {
        Self {
            events: 0,
            tools: 0,
            session_id: None,
            last_action: String::new(),
            last_text: String::new(),
            last_error: None,
            prompt_tokens: 0,
            completion_tokens: 0,
            ring: LineRing::new(200, 32 * 1024),
        }
    }
}

#[derive(Debug, Default, Clone)]
struct Snapshot {
    events: usize,
    tools: usize,
    /// 环形缓冲里实际留下的原始输出行数（不代表总输出量）。
    cli_lines: usize,
    session_id: Option<String>,
    last_action: String,
    last_text: String,
    last_error: Option<String>,
    prompt_tokens: u64,
    completion_tokens: u64,
}

impl Activity {
    fn snapshot(&self) -> Snapshot {
        Snapshot {
            events: self.events,
            tools: self.tools,
            cli_lines: self.ring.len(),
            session_id: self.session_id.clone(),
            last_action: self.last_action.clone(),
            last_text: self.last_text.clone(),
            last_error: self.last_error.clone(),
            prompt_tokens: self.prompt_tokens,
            completion_tokens: self.completion_tokens,
        }
    }
}

fn record(
    provider: &dyn CodingProvider,
    activity: &Arc<Mutex<Activity>>,
    events: &EventLog,
    worktree: &Path,
    line: &str,
) {
    // 原始行先进环：哪怕这一行解析不出来，排障时也要能看到它。
    if let Ok(mut activity) = activity.lock() {
        activity.ring.push(line);
    }

    let Some(event) = provider.parse(line) else {
        return;
    };

    // 契约层事件：风险判定、脱敏都在这里完成，`run_log` 落的就是它。
    events.record_cli(event.clone(), worktree, now_ms());

    let Ok(mut activity) = activity.lock() else {
        return;
    };
    activity.events += 1;

    match event {
        CliEvent::Started { session_id } => {
            if session_id.is_some() {
                activity.session_id = session_id;
            }
            activity.last_action = "开始一轮".to_string();
        }
        CliEvent::Text { text } => {
            activity.last_text = text;
            activity.last_action = "输出结论".to_string();
        }
        CliEvent::ToolUse { name, detail, .. } => {
            activity.tools += 1;
            activity.last_action = if detail.is_empty() {
                name
            } else {
                format!("{name} {detail}")
            };
        }
        CliEvent::ToolResult { ok, summary } => {
            activity.last_action = if ok {
                format!("工具完成 {summary}")
            } else {
                format!("工具失败 {summary}")
            };
        }
        CliEvent::Notification { code, message } => {
            // 钩子没拦住时的最后一道观测信号：出现即告警。
            activity.last_action = format!("通知[{code}] {message}");
        }
        CliEvent::Usage {
            prompt_tokens,
            completion_tokens,
        } => {
            activity.prompt_tokens += prompt_tokens.unwrap_or(0);
            activity.completion_tokens += completion_tokens.unwrap_or(0);
        }
        CliEvent::Failed { message } => {
            activity.last_error = Some(message);
        }
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

/// 每 5 秒把累计进度报一条，避免逐行 IPC。
fn spawn_progress(
    client: Client,
    task_id: String,
    activity: Arc<Mutex<Activity>>,
    events: Arc<EventLog>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(PROGRESS_INTERVAL);
        let mut last_events = 0;
        loop {
            interval.tick().await;
            let snapshot = activity
                .lock()
                .map(|activity| activity.snapshot())
                .unwrap_or_default();

            if snapshot.events == last_events {
                continue;
            }
            last_events = snapshot.events;

            // 契约层事件比解析层更能说明"在干什么"：它带风险等级与脱敏摘要。
            // 一次带最近几条动作（多行），而不是只给最后一条——详情页要能看出
            // "刚才做了三件事"，只给一条等于每 5 秒重置一次上下文。
            let lines = events.progress_lines(PROGRESS_LINES);
            let summary = if lines.is_empty() {
                if snapshot.tools == 0 {
                    format!("已收到 {} 条输出", snapshot.events)
                } else {
                    snapshot.last_action.clone()
                }
            } else {
                lines.join("\n")
            };

            if !client
                .send(IpcMessage::StepOutput {
                    task_id: task_id.clone(),
                    seq: 1,
                    summary,
                })
                .await
            {
                return;
            }
        }
    })
}

async fn step(client: &Client, task_id: &str, seq: i64) {
    let _ = client
        .send(IpcMessage::StepStarted {
            task_id: task_id.to_string(),
            seq,
            name: STEPS[seq as usize].to_string(),
        })
        .await;
}

async fn output(client: &Client, task_id: &str, seq: i64, summary: &str) {
    let _ = client
        .send(IpcMessage::StepOutput {
            task_id: task_id.to_string(),
            seq,
            summary: summary.to_string(),
        })
        .await;
}

async fn send_artifact(client: &Client, task_id: &str, kind: &str, content: &str) {
    let content = protocol::clip_artifact_content(content);
    let size = content.len() as i64;
    let _ = client
        .send(IpcMessage::ArtifactCreated {
            task_id: task_id.to_string(),
            kind: kind.to_string(),
            size,
            mime: Some("text/plain".to_string()),
            content,
        })
        .await;
}

async fn fail(client: &Client, task_id: &str, code: &str, hint: &str, retryable: bool) {
    tracing::warn!(task_id, code, hint, "编码任务失败");
    let _ = client
        .send(IpcMessage::TaskFailed {
            task_id: task_id.to_string(),
            code: code.to_string(),
            hint: hint.to_string(),
            retryable,
        })
        .await;
}

/// 失败时把现场写进 `run_log`：否则用户只看得到一句 hint，无从判断是环境问题还是代码问题。
async fn fail_with_log(
    client: &Client,
    task_id: &str,
    hint: &str,
    snapshot: &Snapshot,
    events: &EventLog,
    cli_tail: &str,
    stderr_tail: &[String],
) {
    let mut text = String::new();
    text.push_str("# 运行日志（失败）\n\n");
    text.push_str(&format!(
        "- 事件数：{}\n- 工具调用：{}\n",
        snapshot.events, snapshot.tools
    ));
    if let Some(error) = &snapshot.last_error {
        text.push_str(&format!("- CLI 报错：{error}\n"));
    }
    if !stderr_tail.is_empty() {
        text.push_str("\n## stderr\n\n");
        text.push_str(&stderr_tail.join("\n"));
        text.push('\n');
    }
    if !cli_tail.trim().is_empty() {
        text.push_str("\n## CLI 输出（尾部）\n\n");
        text.push_str(cli_tail.trim());
        text.push('\n');
    }
    push_event_log(&mut text, events);

    send_artifact(client, task_id, "run_log", &text).await;
    fail(client, task_id, "code_failed", hint, true).await;
}

fn change_summary(
    workspace: &worktree::Workspace,
    stat: &str,
    snapshot: &Snapshot,
    exit_code: Option<i32>,
    provider: &str,
    model: &str,
    route_reason: Option<&str>,
) -> String {
    let mut text = String::new();
    text.push_str("# 改动摘要\n\n");
    // 用户看到的 diff 一样，但成本与风险不一样：执行者必须写在最上面。
    match route_reason.filter(|reason| !reason.trim().is_empty()) {
        // 路由理由一起写：出问题时能复盘"为什么这次用了它"，而不是靠猜。
        Some(reason) => text.push_str(&format!(
            "本次由 `{provider}` + `{model}` 执行（路由原因：{reason}）\n\n"
        )),
        None => text.push_str(&format!("本次由 `{provider}` + `{model}` 执行\n\n")),
    }
    text.push_str(&format!(
        "- 分支：{}（基于 {}）\n",
        workspace.branch, workspace.base_branch
    ));
    text.push_str(&format!("- 工作树：{}\n", workspace.path.display()));
    text.push_str(&format!("- 退出码：{}\n", exit_label(exit_code)));
    text.push_str(&format!("- 工具调用：{} 次\n", snapshot.tools));
    text.push_str(&format!(
        "- CLI 自报用量：input {} / output {}（仅供参照，以代理侧记账为准）\n",
        snapshot.prompt_tokens, snapshot.completion_tokens
    ));

    if stat.trim().is_empty() {
        // 没有改动就不该有审批卡：先说清楚，否则用户会等一张永远不会出现的卡。
        text.push_str("\n> 本次没有产生任何文件改动，因此不会请求合并确认。\n");
    }

    text.push_str("\n## 改动\n\n");
    if stat.trim().is_empty() {
        text.push_str("（无改动）\n");
    } else {
        text.push_str(stat.trim());
        text.push('\n');
    }

    if !snapshot.last_text.trim().is_empty() {
        text.push_str("\n## CLI 结论\n\n");
        text.push_str(snapshot.last_text.trim());
        text.push('\n');
    }

    text
}

/// 审批方式的中文名：写进 run_log，事后能回答"这次为什么没弹卡"。
fn approval_label(policy: ApprovalPolicy) -> &'static str {
    match policy {
        ApprovalPolicy::Request => "请求审批（命中审批档即问人）",
        ApprovalPolicy::Auto => "帮我审批（只对安装/删除/危险脚本等问人）",
        ApprovalPolicy::Trust => "完全放行（工具级不再逐条询问，改动仍需确认合并）",
    }
}

fn run_log(
    workspace: &worktree::Workspace,
    snapshot: &Snapshot,
    events: &EventLog,
    stderr_tail: &[String],
    cli_tail: &str,
    policy: ApprovalPolicy,
) -> String {
    let mut text = String::new();
    text.push_str("# 运行日志\n\n");
    text.push_str(&format!("- 审批方式：{}\n", approval_label(policy)));
    text.push_str(&format!("- 工作树：{}\n", workspace.path.display()));
    text.push_str(&format!("- 事件数：{}\n", snapshot.events));
    text.push_str(&format!("- 工具调用：{}\n", snapshot.tools));
    text.push_str(&format!("- 保留输出行数：{}\n", snapshot.cli_lines));
    text.push_str(&format!("- 最近动作：{}\n", snapshot.last_action));

    if let Some(session_id) = &snapshot.session_id {
        text.push_str(&format!("- CLI 会话：{session_id}\n"));
    }
    if let Some(error) = &snapshot.last_error {
        text.push_str(&format!("- CLI 报错：{error}\n"));
    }
    if !stderr_tail.is_empty() {
        text.push_str("\n## stderr（尾部）\n\n");
        text.push_str(&stderr_tail.join("\n"));
        text.push('\n');
    }
    if !cli_tail.trim().is_empty() {
        text.push_str("\n## CLI 输出（尾部）\n\n");
        text.push_str(cli_tail.trim());
        text.push('\n');
    }
    push_event_log(&mut text, events);

    text
}

/// 事件段：一行一个 `CodeEvent`，事后可按 `call_id` 与审批记录对账。
fn push_event_log(text: &mut String, events: &EventLog) {
    let jsonl = events.jsonl();
    if jsonl.trim().is_empty() {
        return;
    }
    text.push_str("\n## 过程事件（JSONL）\n\n```jsonl\n");
    text.push_str(jsonl.trim());
    text.push_str("\n```\n");
}

fn summarize_stat(stat: &str) -> String {
    stat.lines()
        .last()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .unwrap_or("无改动统计")
        .to_string()
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").chars().take(60).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_requires_repo_and_instruction() {
        assert!(parse_input(&serde_json::json!({})).is_err());
        assert!(parse_input(&serde_json::json!({ "repo": "/tmp/x" })).is_err());
        assert!(parse_input(&serde_json::json!({ "repo": "  ", "instruction": "改" })).is_err());
        assert!(
            parse_input(&serde_json::json!({ "repo": "/tmp/x", "instruction": "  " })).is_err()
        );
    }

    #[test]
    fn input_accepts_trimmed_values() {
        let input = parse_input(&serde_json::json!({
            "repo": "  /tmp/repo  ",
            "instruction": "  修复登录超时  "
        }))
        .expect("应解析成功");
        assert_eq!(input.repo, std::path::PathBuf::from("/tmp/repo"));
        assert_eq!(input.instruction, "修复登录超时");
    }

    #[test]
    fn input_rejects_oversized_instruction() {
        let long = "啊".repeat(MAX_INSTRUCTION_CHARS + 1);
        assert!(
            parse_input(&serde_json::json!({ "repo": "/tmp/x", "instruction": long })).is_err()
        );
    }

    #[test]
    fn summarize_stat_uses_last_line() {
        let stat = " a.txt | 2 ++\n b.txt | 1 +\n 2 files changed, 3 insertions(+)";
        assert_eq!(summarize_stat(stat), "2 files changed, 3 insertions(+)");
        assert_eq!(summarize_stat(""), "无改动统计");
    }

    #[test]
    fn change_summary_marks_estimate_source() {
        let workspace = worktree::Workspace {
            repo: std::path::PathBuf::from("/tmp/repo"),
            path: std::path::PathBuf::from("/tmp/wt"),
            branch: "agent/t1".to_string(),
            base_branch: "main".to_string(),
            config_dir: std::path::PathBuf::from("/tmp/conf"),
        };
        let snapshot = Snapshot {
            tools: 3,
            last_text: "已修复".to_string(),
            prompt_tokens: 100,
            completion_tokens: 20,
            ..Snapshot::default()
        };

        let text = change_summary(
            &workspace,
            " a | 1 +\n 1 file changed",
            &snapshot,
            Some(0),
            "opencode",
            "deepseek-v4.1-flash",
            None,
        );
        assert!(text.contains("agent/t1"));
        assert!(text.contains("1 file changed"));
        assert!(
            text.contains("以代理侧记账为准"),
            "不能让用户误以为这是准确计费"
        );
        assert!(text.contains("已修复"));

        // 带路由理由时写在最上面：用户要能复盘"为什么这次用了它"。
        let routed = change_summary(
            &workspace,
            " a | 1 +",
            &snapshot,
            Some(0),
            "codex",
            "strong-model",
            Some("多文件项目（首选可用）"),
        );
        assert!(
            routed.contains("路由原因：多文件项目（首选可用）"),
            "{routed}"
        );
    }
}
