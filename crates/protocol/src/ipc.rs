//! `jarvis-service` 与 `jarvis-worker` 之间的 IPC 契约。
//!
//! 格式：JSON-lines，每行一个 [`Envelope`]；信封带 `v` 版本号，两端独立升级时
//! 明确拒绝不兼容，而不是靠字段缺失去猜。
//!
//! 方向约定：
//! - service → worker：`start` / `resume` / `cancel` / `shutdown` / `tool_call` /
//!   `model_result`
//! - worker → service：`hello` / `heartbeat` / `plan_created` / `step_*` /
//!   `approval_required` / `artifact_created` / `task_finished` / `task_failed` /
//!   `tool_result` / `model_call`
//!
//! 单一扁平枚举而不是嵌套信封：JSON 少一层、抓包好读，serde 也不用处理
//! "内部 tag + 外部 tag" 的冲突。

use serde::{Deserialize, Serialize};

/// IPC 契约版本。任何破坏性改动都必须进位，服务端据此拒绝旧/新 worker。
///
/// v2 相对 v1 新增 `model_call` / `model_result`；v3 新增 `tool_approval_required`
/// （工具级审批）；v4 给 `resume` 增加 `remember`（本任务内同类放行）；
/// v5 给 `SkillManifest` 增加 `source` / `plugin_id` / `fetch`，并新增
/// `local_tool_call` / `local_tool_result`（技能读项目文件的反向调用）。
///
/// 加字段本身可向后兼容，但按项目惯例仍进位：混跑旧 worker 时"用户勾了记住、
/// worker 静默忽略"是最难解释的一种失败，不如在 `Envelope` 版本校验处直接拒绝。
pub const IPC_VERSION: u32 = 5;

/// 技能可读项目文件的工具白名单。
///
/// 只有这四个只读工具能经 [`IpcMessage::LocalToolCall`] 执行。`preview_url` 不在其中：
/// 它的产出是"让客户端打开一个页面"，而技能跑在 worker，没有客户端连接可依附。
///
/// 白名单放在协议层而不是 service 内部，是为了让 worker 侧在发起前就能自查，
/// 不必等一次往返才发现拼错了工具名。
pub const LOCAL_TOOL_WHITELIST: &[&str] =
    &["read_file", "list_dir", "search_file", "search_content"];

/// 单行上限 1 MiB。超限直接断开，避免一条消息打爆内存。
pub const MAX_LINE_BYTES: usize = 1024 * 1024;

/// 单个产物正文的字节上限（截断后）。
///
/// 取 256 KiB 而不是贴着行上限：JSON 转义后最坏情况接近翻倍，
/// 加上信封与其它字段还要留余量，否则一条"合法"的产物会把整条连接打断。
pub const MAX_ARTIFACT_BYTES: usize = 256 * 1024;

/// 单次模型返回正文的字节上限。
///
/// 比产物上限小得多：一步只写一段结论，超长答案说明模型跑偏了，
/// 截断比让一条 IPC 消息逼近行上限更安全。
pub const MAX_MODEL_TEXT_BYTES: usize = 64 * 1024;

/// 技能清单。worker 在 `hello` 里上报，服务端据此校验产物与展示能力。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkillManifest {
    pub name: String,
    pub version: String,
    /// `read` / `reversible_write` / `irreversible_write`
    pub risk_level: String,
    #[serde(default)]
    pub triggers: Vec<String>,
    #[serde(default)]
    pub required_tools: Vec<String>,
    /// 产物种类；任务完成时服务端逐项校验。
    #[serde(default)]
    pub outputs: Vec<String>,
    /// 需要人工确认的步骤名；为空表示该技能全只读。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_before: Option<String>,
    /// 有序步骤名，worker 按此执行。
    #[serde(default)]
    pub steps: Vec<String>,
    /// `builtin` / `user` / `third_party`。空值按 `builtin` 处理
    /// （老 worker 不带该字段，语义上就是内置技能）。
    #[serde(default)]
    pub source: String,
    /// 插件 id；只有 `third_party` 才有。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<String>,
    /// 取资料的显式声明。缺省表示该技能不取外部资料。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fetch: Option<crate::skill::SkillFetch>,
}

/// 计划里的一步。`seq` 从 0 开始。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepSpec {
    pub seq: i64,
    pub name: String,
}

/// 回给 worker 的工具级裁决。
///
/// 与 [`crate::approval::ApprovalDecision`] 不是一回事：后者是"对一张审批单的决定"，
/// 带 `pending` / `expired`；这里只有"放行/驳回"两种可执行动作。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolDecisionKind {
    Approve,
    Reject,
}

impl ToolDecisionKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Approve => "approve",
            Self::Reject => "reject",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "approve" => Some(Self::Approve),
            "reject" => Some(Self::Reject),
            _ => None,
        }
    }

    /// 是否放行。驳回时钩子要回 `permissionDecision: deny`。
    pub const fn approved(self) -> bool {
        matches!(self, Self::Approve)
    }
}

/// 一条 IPC 消息。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IpcMessage {
    // ---- worker → service ----
    Hello {
        version: String,
        ipc_version: u32,
        skills: Vec<SkillManifest>,
    },
    Heartbeat {
        active_tasks: Vec<String>,
    },
    PlanCreated {
        task_id: String,
        steps: Vec<StepSpec>,
    },
    StepStarted {
        task_id: String,
        seq: i64,
        name: String,
    },
    StepOutput {
        task_id: String,
        seq: i64,
        summary: String,
    },
    ApprovalRequired {
        task_id: String,
        action: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        impact: Option<String>,
    },
    /// 工具级审批：CLI 已算出要调什么工具，钩子正阻塞等这个决定。
    ///
    /// 与 `ApprovalRequired` 的区别是"粒度"：这条只针对某一次调用（`call_id`），
    /// 决定回传后 CLI 继续跑，而不是整任务等合并确认。
    ///
    /// `digest` 已经在 worker 侧脱敏截断，service 原样写卡，不再做二次加工。
    ToolApprovalRequired {
        task_id: String,
        /// 本次调用的稳定标识，由 worker 在钩子入口分配，service 原样回传。
        call_id: String,
        #[serde(default)]
        provider: String,
        tool: String,
        /// `read` / `reversible_write` / `irreversible_write`
        risk: String,
        #[serde(default)]
        digest: String,
        /// 命中的规则名，只进审计，不展示。
        #[serde(default)]
        rules: Vec<String>,
    },
    /// 产物就绪。
    ///
    /// `content` 是产物正文；服务端是唯一写盘方，worker 不碰数据目录。
    /// 加字段而不升版本：旧端会忽略未知字段，新端对旧 worker 用 `default` 兜住。
    ArtifactCreated {
        task_id: String,
        kind: String,
        /// 正文的实际字节数（截断后），与 `content` 保持一致。
        size: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mime: Option<String>,
        #[serde(default)]
        content: String,
    },
    TaskFinished {
        task_id: String,
        summary: String,
    },
    TaskFailed {
        task_id: String,
        code: String,
        hint: String,
        retryable: bool,
    },
    /// 工具调用结果（worker → service）。
    ///
    /// `call_id` 由 service 生成，用于把结果配回等待中的那次调用；
    /// 不携带正文，只有摘要与来源，避免把整页塞进事件与日志。
    ToolResult {
        call_id: String,
        ok: bool,
        #[serde(default)]
        summary: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source_url: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        fetched_at: Option<i64>,
        #[serde(default)]
        size: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// 请求服务端代调一次模型（worker → service）。
    ///
    /// worker 不持有 API Key、不实现模型协议：它只负责拼 prompt 与使用结果，
    /// 预算、审计、密钥都收敛在 service 一侧。
    ///
    /// `purpose` 取 `step` / `synthesis`，只用于审计分类，不参与逻辑判断。
    ModelCall {
        call_id: String,
        task_id: String,
        purpose: String,
        system: String,
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max_tokens: Option<u32>,
    },
    /// 技能要读项目文件（worker → service）。
    ///
    /// 方向与 [`IpcMessage::ToolCall`] 相反：那条是服务端让 worker 去读外部世界，
    /// 这条是 worker 让服务端去读本地磁盘。之所以必须绕回服务端，是因为
    /// 路径准入（项目根、软链接不越界、密钥类文件拦截）只实现在 service，
    /// 而 worker 既不查库也不知道任务属于哪个目录。
    ///
    /// `tool` 只能取 [`LOCAL_TOOL_WHITELIST`] 里的名字，由 service 强制校验。
    LocalToolCall {
        call_id: String,
        task_id: String,
        tool: String,
        #[serde(default)]
        args: serde_json::Value,
    },

    // ---- service → worker ----
    Start {
        task_id: String,
        task_type: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        skill: Option<String>,
        #[serde(default)]
        input: serde_json::Value,
        /// 编码任务专用的一次性代理令牌（普通任务为空）。
        ///
        /// 加字段而不升版本：旧 worker 会忽略未知字段；新 worker 收到旧 service
        /// 的 `Start` 时会因缺失该字段把编码任务判成 `code_unavailable`，
        /// 而不是拿着空 token 去撞代理。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token: Option<String>,
        /// 本次任务选中的编码 CLI（`opencode` / `codebuddy` / `codex` / `claude`）。
        ///
        /// 为空时 worker 回退到自己的 `PERSONAL_AGENT_CODE_PROVIDER`：这是老 service
        /// 与新 worker 混跑时的行为，与升级前完全一致。路由发生在 service 侧
        /// （方案 10.1），所以 provider 必须随任务下发，而不是 worker 进程级配置。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        provider: Option<String>,
        /// 本次任务选中的模型档位对应的模型名。为空回退 `PERSONAL_AGENT_CODE_MODEL`。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        /// 该 provider 的可执行文件路径（来自 `code.providers.<id>.bin`）。
        /// worker 不读配置文件，路径必须由 service 解析后下发。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        bin: Option<String>,
        /// 路由理由（人话，进 `change_summary` 顶部与审计）。为空表示"没路由"。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        route_reason: Option<String>,
    },
    /// 唤醒等待中的任务。
    ///
    /// `call_id` + `decision` 非空时表示"对某一次工具调用的裁决"，worker 转成
    /// `Control::ToolDecision`；为空时是老的"任务级继续"语义。
    /// 两个字段都可选且不序列化空值：老 worker 收到的仍是 `{"type":"resume","task_id":...}`。
    Resume {
        task_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        call_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        decision: Option<ToolDecisionKind>,
        /// 「本任务内不再询问这类操作」。老 service 不传，worker 按 `false` 处理。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        remember: Option<bool>,
    },
    Cancel {
        task_id: String,
    },
    Shutdown,
    /// 工具调用请求（service → worker）。
    ///
    /// 只允许只读工具：对话里绝不通过它触发写操作。
    ToolCall {
        call_id: String,
        tool: String,
        #[serde(default)]
        args: serde_json::Value,
    },
    /// 模型调用结果（service → worker）。
    ///
    /// 失败也用同一条消息回传：`ok=false` + `error`，等待方据此降级，
    /// 不需要额外的错误事件类型。
    ModelResult {
        call_id: String,
        ok: bool,
        #[serde(default)]
        text: String,
        #[serde(default)]
        prompt_tokens: u32,
        #[serde(default)]
        completion_tokens: u32,
        /// 网关未返回 `usage` 时为 `true`，审计据此区分真实值与估算值。
        #[serde(default)]
        tokens_estimated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// 技能读项目文件的结果（service → worker）。
    ///
    /// 失败也用同一条消息回传：`ok=false` + `error`，等待方据此写「未获取」，
    /// 不需要额外的错误事件类型。`content` 已由 service 按工具自身预算截断，
    /// worker 直接塞进参考资料，不再二次加工。
    LocalToolResult {
        call_id: String,
        ok: bool,
        #[serde(default)]
        content: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
}

impl IpcMessage {
    /// 是否为 worker 发给服务端的消息。
    pub fn is_from_worker(&self) -> bool {
        matches!(
            self,
            Self::Hello { .. }
                | Self::Heartbeat { .. }
                | Self::PlanCreated { .. }
                | Self::StepStarted { .. }
                | Self::StepOutput { .. }
                | Self::ApprovalRequired { .. }
                | Self::ToolApprovalRequired { .. }
                | Self::ArtifactCreated { .. }
                | Self::TaskFinished { .. }
                | Self::TaskFailed { .. }
                | Self::ToolResult { .. }
                | Self::ModelCall { .. }
                | Self::LocalToolCall { .. }
        )
    }

    /// 是否为服务端发给 worker 的消息。
    pub fn is_from_service(&self) -> bool {
        matches!(
            self,
            Self::Start { .. }
                | Self::Resume { .. }
                | Self::Cancel { .. }
                | Self::Shutdown
                | Self::ToolCall { .. }
                | Self::ModelResult { .. }
                | Self::LocalToolResult { .. }
        )
    }
}

/// 线缆信封。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub v: u32,
    pub message: IpcMessage,
}

#[derive(Debug, thiserror::Error)]
pub enum IpcError {
    #[error("消息过长：{len} 字节，上限 {MAX_LINE_BYTES}")]
    TooLong { len: usize },
    #[error("消息不是合法 JSON: {0}")]
    Malformed(#[from] serde_json::Error),
    #[error("IPC 版本不兼容：收到 v{found}，期望 v{expected}")]
    VersionMismatch { found: u32, expected: u32 },
}

impl Envelope {
    pub fn new(message: IpcMessage) -> Self {
        Self {
            v: IPC_VERSION,
            message,
        }
    }

    /// 序列化为一行（不含换行符）。
    pub fn to_line(&self) -> Result<String, IpcError> {
        Ok(serde_json::to_string(self)?)
    }

    /// 解析一行并校验版本。
    pub fn from_line(line: &str) -> Result<Self, IpcError> {
        if line.len() > MAX_LINE_BYTES {
            return Err(IpcError::TooLong { len: line.len() });
        }
        let envelope: Self = serde_json::from_str(line)?;
        if envelope.v != IPC_VERSION {
            return Err(IpcError::VersionMismatch {
                found: envelope.v,
                expected: IPC_VERSION,
            });
        }
        Ok(envelope)
    }
}

/// 把产物正文裁剪到 [`MAX_ARTIFACT_BYTES`] 以内，截断时追加一行说明。
///
/// 按字符边界裁剪而不是字节切片：产物是给人看的文本，半个汉字比少几行更难接受。
pub fn clip_artifact_content(content: &str) -> String {
    if content.len() <= MAX_ARTIFACT_BYTES {
        return content.to_string();
    }

    const MARKER: &str = "\n\n…（正文超过上限，已截断）";
    let budget = MAX_ARTIFACT_BYTES.saturating_sub(MARKER.len());
    let mut kept = String::with_capacity(budget + MARKER.len());
    let mut used = 0usize;
    for ch in content.chars() {
        let width = ch.len_utf8();
        if used + width > budget {
            break;
        }
        kept.push(ch);
        used += width;
    }
    kept.push_str(MARKER);
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(message: IpcMessage) {
        let line = Envelope::new(message.clone())
            .to_line()
            .expect("序列化失败");
        let back = Envelope::from_line(&line).expect("反序列化失败");
        assert_eq!(back.v, IPC_VERSION);
        assert_eq!(back.message, message);
    }

    #[test]
    fn service_commands_roundtrip() {
        roundtrip(IpcMessage::Start {
            task_id: "task_1".to_string(),
            task_type: "skill:trip-plan".to_string(),
            skill: Some("trip-plan".to_string()),
            input: serde_json::json!({ "destination": "上海" }),
            token: None,
            provider: None,
            model: None,
            bin: None,
            route_reason: None,
        });
        roundtrip(IpcMessage::Resume {
            task_id: "task_1".to_string(),
            call_id: None,
            decision: None,
            remember: None,
        });
        roundtrip(IpcMessage::Resume {
            task_id: "task_1".to_string(),
            call_id: Some("call_3".to_string()),
            decision: Some(ToolDecisionKind::Reject),
            remember: None,
        });
        roundtrip(IpcMessage::Resume {
            task_id: "task_1".to_string(),
            call_id: Some("call_4".to_string()),
            decision: Some(ToolDecisionKind::Approve),
            remember: Some(true),
        });
        roundtrip(IpcMessage::Cancel {
            task_id: "task_1".to_string(),
        });
        roundtrip(IpcMessage::Shutdown);
    }

    #[test]
    fn start_without_token_is_parseable() {
        // 旧 service 发来的 Start 没有 token 字段：必须能解析成 None，
        // 而不是整条消息被拒（那样旧 service 与新 worker 直接无法协作）。
        let line = format!(
            r#"{{"v":{IPC_VERSION},"message":{{"type":"start","task_id":"t1","task_type":"skill:trip-plan","input":{{}}}}}}"#
        );
        let envelope = Envelope::from_line(&line).expect("旧格式应可解析");
        match envelope.message {
            IpcMessage::Start { token, .. } => assert!(token.is_none()),
            other => panic!("消息类型不符: {other:?}"),
        }
    }

    #[test]
    fn start_token_is_omitted_when_absent() {
        let line = Envelope::new(IpcMessage::Start {
            task_id: "t1".to_string(),
            task_type: "skill:code-task".to_string(),
            skill: Some("code-task".to_string()),
            input: serde_json::json!({}),
            token: None,
            provider: None,
            model: None,
            bin: None,
            route_reason: None,
        })
        .to_line()
        .expect("序列化失败");
        assert!(!line.contains("token"), "空 token 不应出现在线缆上: {line}");
    }

    #[test]
    fn start_without_routing_keeps_the_old_shape() {
        // 路由是可选增强：没配 `code.routing` 时线缆上不能多出四个空字段，
        // 否则老 service 的日志、抓包与回归断言全部要跟着改。
        let line = Envelope::new(IpcMessage::Start {
            task_id: "t1".to_string(),
            task_type: "skill:code-task".to_string(),
            skill: Some("code-task".to_string()),
            input: serde_json::json!({}),
            token: None,
            provider: None,
            model: None,
            bin: None,
            route_reason: None,
        })
        .to_line()
        .expect("序列化失败");
        for key in ["provider", "model", "bin", "route_reason"] {
            assert!(!line.contains(key), "空 {key} 不应上线缆: {line}");
        }
    }

    #[test]
    fn start_with_routing_roundtrips() {
        let message = IpcMessage::Start {
            task_id: "t1".to_string(),
            task_type: "skill:code-task".to_string(),
            skill: Some("code-task".to_string()),
            input: serde_json::json!({}),
            token: Some("tok".to_string()),
            provider: Some("codex".to_string()),
            model: Some("deepseek-v4.1-flash".to_string()),
            bin: Some("/usr/local/bin/codex".to_string()),
            route_reason: Some("单文件脚本 → 快档".to_string()),
        };
        let line = Envelope::new(message.clone())
            .to_line()
            .expect("序列化失败");
        assert!(line.contains(r#""provider":"codex""#), "{line}");
        assert!(line.contains("route_reason"), "{line}");
        let back = Envelope::from_line(&line).expect("反序列化失败");
        assert_eq!(back.message, message);
    }

    #[test]
    fn resume_without_decision_keeps_the_old_shape() {
        // 任务级审批（合并确认）仍然只发 task_id，线缆形状不能漂移。
        let line = Envelope::new(IpcMessage::Resume {
            task_id: "t1".to_string(),
            call_id: None,
            decision: None,
            remember: None,
        })
        .to_line()
        .expect("序列化失败");
        assert!(!line.contains("call_id"), "空 call_id 不应上线缆: {line}");
        assert!(!line.contains("decision"), "空 decision 不应上线缆: {line}");
        assert!(line.contains(r#""type":"resume""#));
    }

    #[test]
    fn resume_with_tool_decision_roundtrips() {
        let line = Envelope::new(IpcMessage::Resume {
            task_id: "t1".to_string(),
            call_id: Some("call_7".to_string()),
            decision: Some(ToolDecisionKind::Reject),
            remember: None,
        })
        .to_line()
        .expect("序列化失败");
        assert!(line.contains(r#""decision":"reject""#), "{line}");
        match Envelope::from_line(&line).expect("解析失败").message {
            IpcMessage::Resume {
                call_id, decision, ..
            } => {
                assert_eq!(call_id.as_deref(), Some("call_7"));
                assert_eq!(decision, Some(ToolDecisionKind::Reject));
            }
            other => panic!("消息类型不符: {other:?}"),
        }
        assert!(
            !line.contains("remember"),
            "没勾选时 remember 不应上线缆: {line}"
        );
    }

    #[test]
    fn resume_remember_roundtrips_and_old_payload_stays_valid() {
        let line = Envelope::new(IpcMessage::Resume {
            task_id: "t1".to_string(),
            call_id: Some("call_8".to_string()),
            decision: Some(ToolDecisionKind::Approve),
            remember: Some(true),
        })
        .to_line()
        .expect("序列化失败");
        assert!(line.contains(r#""remember":true"#), "{line}");

        match Envelope::from_line(&line).expect("解析失败").message {
            IpcMessage::Resume { remember, .. } => assert_eq!(remember, Some(true)),
            other => panic!("消息类型不符: {other:?}"),
        }

        // 老 service 的载荷没有 remember：按 None 解析，行为是"不记住"。
        let old = format!(
            r#"{{"v":{IPC_VERSION},"message":{{"type":"resume","task_id":"t1","call_id":"call_1","decision":"approve"}}}}"#
        );
        match Envelope::from_line(&old).expect("老载荷应可解析").message {
            IpcMessage::Resume { remember, .. } => assert_eq!(remember, None),
            other => panic!("消息类型不符: {other:?}"),
        }
    }

    #[test]
    fn tool_decision_kind_parses_both_states() {
        for kind in [ToolDecisionKind::Approve, ToolDecisionKind::Reject] {
            assert_eq!(ToolDecisionKind::parse(kind.as_str()), Some(kind));
        }
        assert_eq!(ToolDecisionKind::parse("pending"), None);
        assert!(ToolDecisionKind::Approve.approved());
        assert!(!ToolDecisionKind::Reject.approved());
    }

    #[test]
    fn tool_approval_required_is_a_worker_message() {
        let message = IpcMessage::ToolApprovalRequired {
            task_id: "t1".to_string(),
            call_id: "call_1".to_string(),
            provider: "codebuddy".to_string(),
            tool: "Bash".to_string(),
            risk: "irreversible_write".to_string(),
            digest: "git push origin main".to_string(),
            rules: vec!["external_command".to_string()],
        };
        assert!(message.is_from_worker());
        assert!(!message.is_from_service());
    }

    #[test]
    fn local_tool_call_travels_from_worker_to_service() {
        let message = IpcMessage::LocalToolCall {
            call_id: "local_1".to_string(),
            task_id: "task_1".to_string(),
            tool: "read_file".to_string(),
            args: serde_json::json!({ "path": "src/main.rs" }),
        };
        assert!(message.is_from_worker(), "技能读文件是 worker 发起的");
        assert!(!message.is_from_service());
        roundtrip(message);

        let result = IpcMessage::LocalToolResult {
            call_id: "local_1".to_string(),
            ok: true,
            content: "fn main() {}".to_string(),
            error: None,
        };
        assert!(result.is_from_service());
        assert!(!result.is_from_worker());
        roundtrip(result);
    }

    #[test]
    fn local_tool_whitelist_is_read_only_and_excludes_preview() {
        // 写操作与"让客户端开页面"都不能进技能路径：
        // 前者缺审批通道，后者依赖客户端连接，而技能跑在 worker。
        for tool in LOCAL_TOOL_WHITELIST {
            assert!(
                matches!(
                    *tool,
                    "read_file" | "list_dir" | "search_file" | "search_content"
                ),
                "白名单里出现了未预期的工具: {tool}"
            );
        }
        assert!(!LOCAL_TOOL_WHITELIST.contains(&"preview_url"));
    }

    #[test]
    fn skill_manifest_fetch_is_wire_compatible() {
        // fetch 的 from/tool 必须序列化成 frontmatter 里那套字符串，
        // 否则同一个概念在 SKILL.md 与线缆上会有两种写法。
        let manifest = SkillManifest {
            name: "demo".to_string(),
            version: "0.1.0".to_string(),
            risk_level: "read".to_string(),
            triggers: Vec::new(),
            required_tools: Vec::new(),
            outputs: vec!["report".to_string()],
            stop_before: None,
            steps: vec!["查资料".to_string()],
            source: "third_party".to_string(),
            plugin_id: Some("com.example.demo".to_string()),
            fetch: Some(crate::skill::SkillFetch {
                step: "查资料".to_string(),
                from: crate::skill::FetchSource::Path,
                tool: crate::skill::FetchTool::ReadFile,
            }),
        };

        let line = Envelope::new(IpcMessage::Hello {
            version: "0.1.0".to_string(),
            ipc_version: IPC_VERSION,
            skills: vec![manifest.clone()],
        })
        .to_line()
        .expect("序列化失败");

        assert!(line.contains(r#""from":"path""#), "{line}");
        assert!(line.contains(r#""tool":"read_file""#), "{line}");

        match Envelope::from_line(&line).expect("解析失败").message {
            IpcMessage::Hello { skills, .. } => assert_eq!(skills, vec![manifest]),
            other => panic!("消息类型不符: {other:?}"),
        }
    }

    #[test]
    fn old_skill_manifest_without_source_still_parses() {
        // 老 worker 不带 source / plugin_id / fetch：按空值兜住，
        // 服务端把空 source 当 builtin，行为与升级前一致。
        let line = format!(
            r#"{{"v":{IPC_VERSION},"message":{{"type":"hello","version":"0.1.0","ipc_version":{IPC_VERSION},"skills":[{{"name":"trip-plan","version":"0.1.0","risk_level":"read","outputs":["plan_table"],"steps":["解析","查询"]}}]}}}}"#
        );
        match Envelope::from_line(&line).expect("老报文应可解析").message {
            IpcMessage::Hello { skills, .. } => {
                assert_eq!(skills[0].source, "");
                assert!(skills[0].plugin_id.is_none());
                assert!(skills[0].fetch.is_none());
            }
            other => panic!("消息类型不符: {other:?}"),
        }
    }

    #[test]
    fn worker_events_roundtrip() {
        roundtrip(IpcMessage::Hello {
            version: "0.1.0".to_string(),
            ipc_version: IPC_VERSION,
            skills: vec![SkillManifest {
                name: "trip-plan".to_string(),
                version: "0.1.0".to_string(),
                risk_level: "read".to_string(),
                triggers: vec!["出行".to_string()],
                required_tools: vec!["web.fetch".to_string()],
                outputs: vec!["plan_table".to_string()],
                stop_before: None,
                steps: vec!["解析".to_string(), "查询".to_string()],
                source: "builtin".to_string(),
                plugin_id: None,
                fetch: Some(crate::skill::SkillFetch {
                    step: "查询".to_string(),
                    from: crate::skill::FetchSource::Url,
                    tool: crate::skill::FetchTool::WebFetch,
                }),
            }],
        });
        roundtrip(IpcMessage::Heartbeat {
            active_tasks: vec!["task_1".to_string()],
        });
        roundtrip(IpcMessage::PlanCreated {
            task_id: "task_1".to_string(),
            steps: vec![StepSpec {
                seq: 0,
                name: "解析".to_string(),
            }],
        });
        roundtrip(IpcMessage::ApprovalRequired {
            task_id: "task_1".to_string(),
            action: "submit_form".to_string(),
            target: Some("example.com".to_string()),
            impact: Some("不可撤销".to_string()),
        });
        roundtrip(IpcMessage::ToolApprovalRequired {
            task_id: "task_1".to_string(),
            call_id: "call_3".to_string(),
            provider: "codebuddy".to_string(),
            tool: "Bash".to_string(),
            risk: "irreversible_write".to_string(),
            digest: "rm -rf build".to_string(),
            rules: vec!["delete_command".to_string()],
        });
        roundtrip(IpcMessage::ArtifactCreated {
            task_id: "task_1".to_string(),
            kind: "plan_table".to_string(),
            size: 42,
            mime: Some("text/plain".to_string()),
            content: "行程草案".to_string(),
        });
        roundtrip(IpcMessage::ToolCall {
            call_id: "call_1".to_string(),
            tool: "web.fetch".to_string(),
            args: serde_json::json!({ "url": "https://example.com" }),
        });
        roundtrip(IpcMessage::ToolResult {
            call_id: "call_1".to_string(),
            ok: true,
            summary: "Example Domain".to_string(),
            source_url: Some("https://example.com".to_string()),
            fetched_at: Some(1_700_000_000_000),
            size: 1256,
            error: None,
        });
        roundtrip(IpcMessage::TaskFailed {
            task_id: "task_1".to_string(),
            code: "worker_lost".to_string(),
            hint: "执行进程中断".to_string(),
            retryable: true,
        });
        roundtrip(IpcMessage::ModelCall {
            call_id: "model_1".to_string(),
            task_id: "task_1".to_string(),
            purpose: "step".to_string(),
            system: "你是行程助手".to_string(),
            prompt: "当前步骤：查询参考信息".to_string(),
            max_tokens: Some(800),
        });
        roundtrip(IpcMessage::ModelResult {
            call_id: "model_1".to_string(),
            ok: true,
            text: "上海 10 月 28 日多云".to_string(),
            prompt_tokens: 320,
            completion_tokens: 48,
            tokens_estimated: false,
            error: None,
        });
        roundtrip(IpcMessage::ModelResult {
            call_id: "model_2".to_string(),
            ok: false,
            text: String::new(),
            prompt_tokens: 0,
            completion_tokens: 0,
            tokens_estimated: false,
            error: Some("model_disabled".to_string()),
        });
    }

    #[test]
    fn rejects_version_mismatch() {
        let line = r#"{"v":999,"message":{"type":"shutdown"}}"#;
        assert!(matches!(
            Envelope::from_line(line),
            Err(IpcError::VersionMismatch { found: 999, .. })
        ));
    }

    #[test]
    fn rejects_malformed_and_oversized() {
        assert!(matches!(
            Envelope::from_line("not-json"),
            Err(IpcError::Malformed(_))
        ));

        let huge = "x".repeat(MAX_LINE_BYTES + 1);
        assert!(matches!(
            Envelope::from_line(&huge),
            Err(IpcError::TooLong { .. })
        ));
    }

    #[test]
    fn clip_keeps_short_content_untouched() {
        let short = "行程草案";
        assert_eq!(clip_artifact_content(short), short);
    }

    #[test]
    fn clip_respects_byte_budget_and_char_boundary() {
        // 每个汉字 3 字节，构造刚好超限的正文
        let chunk = "行".repeat(MAX_ARTIFACT_BYTES);
        let clipped = clip_artifact_content(&chunk);
        assert!(clipped.len() <= MAX_ARTIFACT_BYTES, "裁剪后仍超限");
        assert!(clipped.ends_with("已截断）"), "缺少截断说明");
        // 截断点必须落在字符边界，否则 from_utf8 会失败
        assert!(std::str::from_utf8(clipped.as_bytes()).is_ok());
    }

    #[test]
    fn direction_helpers_are_exclusive() {
        let from_worker = IpcMessage::Heartbeat {
            active_tasks: Vec::new(),
        };
        assert!(from_worker.is_from_worker());
        assert!(!from_worker.is_from_service());

        let from_service = IpcMessage::Shutdown;
        assert!(from_service.is_from_service());
        assert!(!from_service.is_from_worker());
    }

    #[test]
    fn json_contains_version_and_type() {
        let value: serde_json::Value = serde_json::from_str(
            &Envelope::new(IpcMessage::Heartbeat {
                active_tasks: Vec::new(),
            })
            .to_line()
            .expect("序列化失败"),
        )
        .expect("反序列化失败");

        assert_eq!(value["v"], IPC_VERSION);
        assert_eq!(value["message"]["type"], "heartbeat");
    }
}
