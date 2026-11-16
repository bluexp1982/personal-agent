//! 编码过程的统一事件契约。
//!
//! 两层结构：
//! - **解析层** `CliEvent` 留在 `jarvis-worker`，跟着各家 CLI 的版本走，随时可变；
//! - **契约层** 就是这里的 `CodeEvent`，对外稳定，字段只增不删。
//!
//! 本模块只描述"发生了什么"，不携带模型正文，也不进任务状态机：它是过程信息，
//! 任务状态仍然只有 `TaskState` 那一套。

use serde::{Deserialize, Serialize};

/// 一次工具调用的风险等级。
///
/// 沿用技能体系已有的三档（`crates/jarvis-worker/src/skills/mod.rs:risk_rank`），
/// 不另造词表。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RiskLevel {
    /// 只读：读文件、列目录、搜索、只读 git 查询。
    Read,
    /// 可回滚写：工作树内改/建文件、`git add`、装依赖。
    ReversibleWrite,
    /// 不可逆：删文件、`git push` / `reset --hard` / `clean -fd`、工作树外路径、
    /// 起网络服务、执行任意 shell。
    IrreversibleWrite,
}

impl RiskLevel {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::ReversibleWrite => "reversible_write",
            Self::IrreversibleWrite => "irreversible_write",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "read" => Some(Self::Read),
            "reversible_write" => Some(Self::ReversibleWrite),
            "irreversible_write" => Some(Self::IrreversibleWrite),
            _ => None,
        }
    }

    /// 是否必须人工确认。规则引擎解析不了的东西一律落到这一档。
    pub const fn needs_human(self) -> bool {
        matches!(self, Self::IrreversibleWrite)
    }

    /// 用于审批卡的固定文案，避免前后端各写一套。
    pub const fn label(self) -> &'static str {
        match self {
            Self::Read => "只读",
            Self::ReversibleWrite => "可回滚写",
            Self::IrreversibleWrite => "不可逆操作",
        }
    }
}

/// 编码过程中产生的一条标准事件。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodeEvent {
    pub task_id: String,
    /// provider id：`opencode` / `codebuddy` / `codex` / `claude`。
    pub provider: String,
    /// CLI 自报的会话 id（可能为空：部分 CLI 首行才给）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// 本次工具调用的稳定标识：工具级审批按它对账；非工具事件为空。
    ///
    /// 由 worker 在**钩子入口**分配，不用 CLI 自报的 `tool_use_id`：
    /// 钩子的输入里拿不到它，两处对不上就没法把"发出去的 id"和"回来的 id"配对。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    pub kind: CodeEventKind,
    /// 发生时间（毫秒时间戳），用于客户端排序与"卡了多久"的判断。
    pub at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CodeEventKind {
    /// 一轮/一步开始。
    StepStarted {
        name: String,
    },
    /// 模型输出文本（增量或整段）。
    Text {
        text: String,
    },
    /// 工具调用即将发生（已过钩子，或不需要钩子的 provider）。
    ToolUse {
        tool: String,
        /// 脱敏 + 截断后的输入摘要，不是原文。
        input_digest: String,
        risk: RiskLevel,
    },
    /// 工具执行完成。
    ToolResult {
        ok: bool,
        summary: String,
    },
    /// CLI 自报用量（仅供参考，权威计数在代理侧）。
    Usage {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        prompt_tokens: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        completion_tokens: Option<u64>,
    },
    /// CLI 的通知/权限提示。钩子没拦住时，这是最后一道观测信号。
    Notification {
        code: String,
        message: String,
    },
    /// 结束。
    Finished {
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    Failed {
        message: String,
    },
}

/// 已接入的编码 CLI。新增 provider 时**只改这一处**：
/// service 的启动校验、`GET /api/code/providers` 与 worker 的 `from_name` 都读它。
pub const SUPPORTED_CODE_PROVIDERS: &[&str] = &["opencode", "codebuddy", "codex", "claude"];

/// 配置里追加的一条风险规则（`code.tool_approval.extra_rules`）。
///
/// **只能加严，不能降级**：命中后按 `max(内置档, rule.risk)` 取档，所以
/// `risk = read` 没有意义也没有实现（启动校验直接拒绝）。规则未命中时无副作用。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RiskRule {
    /// 规则名，进审计与审批卡（要能一眼看出是哪条配置命中的）。
    pub name: String,
    /// 只对某个工具生效（大小写不敏感）；为空表示对所有工具生效。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// 工具名或参数压平后包含任一子串即命中；不能为空。
    #[serde(default)]
    pub contains: Vec<String>,
    pub risk: RiskLevel,
}

impl RiskRule {
    /// 这条规则是否命中一次工具调用。
    ///
    /// `subject` 是"工具名 + 压平后的参数"（小写），由 worker 侧拼好传进来：
    /// 规则匹配不依赖各家 CLI 的字段名，只依赖文本。
    pub fn matches(&self, tool: &str, subject: &str) -> bool {
        if let Some(expected) = &self.tool {
            if !expected.eq_ignore_ascii_case(tool) {
                return false;
            }
        }
        self.contains
            .iter()
            .any(|needle| !needle.is_empty() && subject.contains(&needle.to_lowercase()))
    }
}

/// 工具级审批的支持程度。
///
/// `Degraded` 的含义固定为"驳回等于终止会话 + 保留工作树"，客户端据此把按钮
/// 文案从"驳回并跳过"换成"驳回并终止"（方案 5.3 兜底规则第 1 条）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalSupport {
    /// 有官方"工具执行前"拦截点，可以只阻断单次调用。
    Native,
    /// 能做，但语义有损（典型：只能终止整个会话）。
    Degraded,
    /// 做不到，只能合并前审批。
    Unsupported,
}

impl ApprovalSupport {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::Degraded => "degraded",
            Self::Unsupported => "unsupported",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "native" => Some(Self::Native),
            "degraded" => Some(Self::Degraded),
            "unsupported" => Some(Self::Unsupported),
            _ => None,
        }
    }

    /// 驳回是否会终止整个会话。客户端只用它决定按钮文案。
    pub const fn reject_terminates(self) -> bool {
        matches!(self, Self::Degraded | Self::Unsupported)
    }
}

/// 一个 provider 的静态能力。
///
/// 这是**声明**，不是探测结果：运行时失败（钩子注入失败、端点连不上）走
/// `CodeEventKind::Notification`，不回头改这张表。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    pub tool_approval: ApprovalSupport,
    /// 能否给正在跑的会话追加需求（阶段一/二都不支持，留作能力位）。
    pub append_message: bool,
    /// 能否换模型档位（只承诺下一次任务生效）。
    pub switch_model: bool,
    /// 是否有结构化的过程事件。
    pub stream_events: bool,
}

impl Capabilities {
    fn new(
        tool_approval: ApprovalSupport,
        append_message: bool,
        switch_model: bool,
        stream_events: bool,
    ) -> Self {
        Self {
            tool_approval,
            append_message,
            switch_model,
            stream_events,
        }
    }
}

/// provider id → 静态能力。未接入的 id 返回 `None`。
///
/// 为什么不放在各自的实现里：service 也要读同一张表（`GET /api/code/providers`），
/// 而 service 不加载 provider 实现。放这里，两边共用一份，漂移由单测兜住。
pub fn provider_capabilities(provider: &str) -> Option<Capabilities> {
    match provider {
        "opencode" => Some(Capabilities::new(
            // `--auto` 下没有单条门禁：只能事后观测 + 整任务终止。
            ApprovalSupport::Degraded,
            false,
            true,
            true,
        )),
        "codebuddy" => Some(Capabilities::new(
            // `PreToolUse` 钩子返回 deny 只阻断本次调用（S1 实测）。
            ApprovalSupport::Native,
            false,
            true,
            true,
        )),
        "codex" => Some(Capabilities::new(
            // 钩子能力待 spike（见方案 13.2 S10）：未验证前按"做不到"记，
            // 绝不在能力表里写一个没实测过的"支持"。
            ApprovalSupport::Unsupported,
            false,
            true,
            true,
        )),
        "claude" => Some(Capabilities::new(
            // 与 CodeBuddy 同源的钩子契约，仍以 S11 实测为准（`Degraded` 是保守值）。
            ApprovalSupport::Native,
            false,
            true,
            true,
        )),
        _ => None,
    }
}

impl CodeEventKind {
    /// 用于 `run_log` 与进度摘要的一行人话。
    pub fn describe(&self) -> String {
        match self {
            Self::StepStarted { name } => format!("开始：{name}"),
            Self::Text { text } => format!("输出：{text}"),
            Self::ToolUse {
                tool,
                input_digest,
                risk,
            } => format!("工具：{tool}（{}）{input_digest}", risk.label()),
            Self::ToolResult { ok, summary } => {
                let mark = if *ok { "完成" } else { "失败" };
                format!("{mark}：{summary}")
            }
            Self::Usage {
                prompt_tokens,
                completion_tokens,
            } => format!(
                "用量：输入 {} / 输出 {}",
                prompt_tokens.unwrap_or(0),
                completion_tokens.unwrap_or(0)
            ),
            Self::Notification { code, message } => format!("通知[{code}]：{message}"),
            Self::Finished { ok, reason } => match reason {
                Some(reason) => format!("{}：{reason}", if *ok { "结束" } else { "中止" }),
                None => "结束".to_string(),
            },
            Self::Failed { message } => format!("失败：{message}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(kind: CodeEventKind) -> CodeEvent {
        CodeEvent {
            task_id: "task_1".to_string(),
            provider: "codebuddy".to_string(),
            session_id: Some("s1".to_string()),
            call_id: None,
            kind,
            at: 1_700_000_000_000,
        }
    }

    #[test]
    fn risk_level_roundtrip_and_ordering() {
        for risk in [
            RiskLevel::Read,
            RiskLevel::ReversibleWrite,
            RiskLevel::IrreversibleWrite,
        ] {
            assert_eq!(RiskLevel::parse(risk.as_str()), Some(risk));
        }
        assert!(RiskLevel::Read < RiskLevel::ReversibleWrite);
        assert!(RiskLevel::ReversibleWrite < RiskLevel::IrreversibleWrite);
        assert!(RiskLevel::IrreversibleWrite.needs_human());
        assert!(!RiskLevel::ReversibleWrite.needs_human());
        assert_eq!(RiskLevel::parse("whatever"), None);
    }

    #[test]
    fn events_roundtrip_including_tool_use() {
        let event = sample(CodeEventKind::ToolUse {
            tool: "Bash".to_string(),
            input_digest: "rm -rf build".to_string(),
            risk: RiskLevel::IrreversibleWrite,
        });
        let line = serde_json::to_string(&event).expect("序列化失败");
        assert!(line.contains(r#""kind":"tool_use""#), "{line}");
        assert!(line.contains(r#""risk":"irreversible_write""#), "{line}");
        let back: CodeEvent = serde_json::from_str(&line).expect("反序列化失败");
        assert_eq!(back, event);
    }

    #[test]
    fn new_kinds_stay_compatible_with_missing_optional_fields() {
        // 老记录（没有 session_id / call_id / reason）必须仍能读出来。
        let raw =
            r#"{"task_id":"t1","provider":"opencode","kind":{"kind":"finished","ok":true},"at":1}"#;
        let event: CodeEvent = serde_json::from_str(raw).expect("解析失败");
        assert!(event.session_id.is_none());
        assert!(event.call_id.is_none());
        match event.kind {
            CodeEventKind::Finished { ok, reason } => {
                assert!(ok);
                assert!(reason.is_none());
            }
            other => panic!("类型不符: {other:?}"),
        }
    }

    #[test]
    fn describe_is_human_readable_for_each_kind() {
        assert!(sample(CodeEventKind::StepStarted {
            name: "解析".to_string()
        })
        .kind
        .describe()
        .contains("解析"));
        assert_eq!(
            sample(CodeEventKind::ToolResult {
                ok: false,
                summary: "denied".to_string()
            })
            .kind
            .describe(),
            "失败：denied"
        );
    }

    #[test]
    fn every_supported_provider_declares_its_capabilities() {
        // 注册表与能力表必须同进同出：新增一个 id 却忘了给能力，
        // 客户端会拿到一个空白能力位，按钮就成了猜的。
        for id in SUPPORTED_CODE_PROVIDERS {
            assert!(
                provider_capabilities(id).is_some(),
                "{id} 在注册表里却没有能力声明"
            );
        }
        assert!(provider_capabilities("nope").is_none());
    }

    #[test]
    fn capability_table_matches_the_documented_matrix() {
        // 这几条是方案第 5.2 章的四 CLI 能力矩阵，改表就要同步改文档。
        let opencode = provider_capabilities("opencode").expect("缺 opencode");
        assert_eq!(opencode.tool_approval, ApprovalSupport::Degraded);
        assert!(opencode.tool_approval.reject_terminates());

        let codebuddy = provider_capabilities("codebuddy").expect("缺 codebuddy");
        assert_eq!(codebuddy.tool_approval, ApprovalSupport::Native);
        assert!(!codebuddy.tool_approval.reject_terminates());

        // 阶段二/三都不做追加需求；这一位留给后续版本，别提前置 true。
        for id in SUPPORTED_CODE_PROVIDERS {
            let caps = provider_capabilities(id).expect("缺能力");
            assert!(!caps.append_message, "{id} 不该声明支持追加需求");
            assert!(caps.stream_events, "{id} 都应能给出结构化事件");
        }
    }

    #[test]
    fn capabilities_roundtrip_as_plain_snake_case_json() {
        let caps = provider_capabilities("codebuddy").expect("缺 codebuddy");
        let line = serde_json::to_string(&caps).expect("序列化失败");
        assert!(line.contains(r#""tool_approval":"native""#), "{line}");
        let back: Capabilities = serde_json::from_str(&line).expect("反序列化失败");
        assert_eq!(back, caps);

        for support in [
            ApprovalSupport::Native,
            ApprovalSupport::Degraded,
            ApprovalSupport::Unsupported,
        ] {
            assert_eq!(ApprovalSupport::parse(support.as_str()), Some(support));
        }
        assert_eq!(ApprovalSupport::parse("maybe"), None);
    }
}
