//! `CliEvent` → `CodeEvent` 的归一，以及事件环（供 `run_log` 落盘）。
//!
//! 两层结构里这是"中间那一层"：provider 只负责把各家 CLI 的行解析成
//! [`CliEvent`]（随时可变），这里把它翻译成对外稳定的 `CodeEvent`。
//!
//! 事件**不逐行推 IPC**：需要人决策的工具调用逐条上报（它本身就是阻塞点），
//! 其余走现有的 5 秒进度节流；事件本身在本进程留最近 [`CAPACITY`] 条，
//! 任务结束时作为 `run_log` 的一段落盘。

use std::collections::VecDeque;
use std::path::Path;
use std::sync::Mutex;

use protocol::code_event::{CodeEvent, CodeEventKind};

use super::provider::CliEvent;
use super::risk;

/// 保留的事件条数上限。与 `Activity` 的原始行环同量级，避免内存无界。
const CAPACITY: usize = 200;

/// 进度摘要里单条动作的字符上限。
///
/// 模型输出与命令摘要都可能很长，而详情页只展示几行：截断比让一段结论
/// 把其它动作挤出视野更有用（完整内容在 `run_log` 里）。
const PROGRESS_LINE_CHARS: usize = 180;

/// 解析路径（stdout）里的 CLI 自报 id 前缀。
///
/// 钩子路径分配的 `call_<n>` 才是工具级审批的主键；CLI 自报的 id 可能与环境里的
/// 其它 id 撞号，加前缀后两者永远不会在同一个命名空间里被误配。
const CLI_CALL_PREFIX: &str = "cli_";

/// 一次任务的事件流。
#[derive(Debug)]
pub(crate) struct EventLog {
    task_id: String,
    provider: String,
    session_id: Mutex<Option<String>>,
    /// 该 provider 的每次工具调用都会先经过钩子端点。
    ///
    /// 为真时**抑制 stdout 侧的 `ToolUse`**：钩子那条已经带了风险与摘要，
    /// 再记一条没有 `call_id` 的重复事件只会让 `run_log` 里同一次调用出现两次。
    hook_covers_tools: bool,
    /// 配置里追加的风险规则（只能加严）。
    extra_rules: Vec<protocol::RiskRule>,
    events: Mutex<VecDeque<CodeEvent>>,
}

impl EventLog {
    pub(crate) fn new(task_id: &str, provider: &str, hook_covers_tools: bool) -> Self {
        Self {
            task_id: task_id.to_string(),
            provider: provider.to_string(),
            session_id: Mutex::new(None),
            hook_covers_tools,
            extra_rules: Vec::new(),
            events: Mutex::new(VecDeque::with_capacity(CAPACITY)),
        }
    }

    /// 挂上配置里追加的风险规则。放在构造之后而不是参数里：
    /// 绝大多数测试只关心事件映射，不该为规则多传一个参数。
    pub(crate) fn with_rules(mut self, rules: Vec<protocol::RiskRule>) -> Self {
        self.extra_rules = rules;
        self
    }

    /// 翻译一条 CLI 事件并入环。返回翻译结果（未知类型已经由 provider 过滤）。
    pub(crate) fn record_cli(
        &self,
        event: CliEvent,
        worktree: &Path,
        at: i64,
    ) -> Option<CodeEvent> {
        // 钩子已经为这次调用记过一条（带风险与摘要），解析路径不再重复上报。
        if self.hook_covers_tools && matches!(event, CliEvent::ToolUse { .. }) {
            return None;
        }

        let mut session = None;
        let mut call_id = None;
        let kind = match event {
            CliEvent::Started { session_id } => {
                if let Some(id) = session_id.clone() {
                    if let Ok(mut slot) = self.session_id.lock() {
                        *slot = Some(id.clone());
                    }
                    session = session_id;
                }
                CodeEventKind::StepStarted {
                    name: "CLI 启动".to_string(),
                }
            }
            CliEvent::Text { text } => CodeEventKind::Text { text },
            CliEvent::ToolUse {
                name,
                detail,
                input,
                call_id: cli_id,
            } => {
                // 解析路径的 id 单独一个命名空间：钩子路径用 `call_<n>`，
                // 那是审批对账的主键；CLI 自报的 id 只用于观测，不能混进去。
                call_id = cli_id.map(|id| format!("{CLI_CALL_PREFIX}{id}"));
                let input = input.unwrap_or_else(|| serde_json::json!({}));
                let assessment = risk::assess_with(&name, &input, worktree, &self.extra_rules);
                // `detail` 只作为兜底：风险引擎给的摘要已经脱敏，优先用它。
                let input_digest = if assessment.digest.is_empty() {
                    detail
                } else {
                    assessment.digest
                };
                CodeEventKind::ToolUse {
                    tool: name,
                    input_digest,
                    risk: assessment.risk,
                }
            }
            CliEvent::ToolResult { ok, summary } => CodeEventKind::ToolResult { ok, summary },
            CliEvent::Usage {
                prompt_tokens,
                completion_tokens,
            } => CodeEventKind::Usage {
                prompt_tokens,
                completion_tokens,
            },
            CliEvent::Notification { code, message } => {
                CodeEventKind::Notification { code, message }
            }
            CliEvent::Failed { message } => CodeEventKind::Failed { message },
        };

        let event = CodeEvent {
            task_id: self.task_id.clone(),
            provider: self.provider.clone(),
            session_id: session,
            call_id,
            kind,
            at,
        };
        self.push(event.clone());
        Some(event)
    }

    /// 直接入环（钩子路径用自己的 `call_id` 补一条 ToolUse）。
    pub(crate) fn push(&self, event: CodeEvent) {
        let Ok(mut events) = self.events.lock() else {
            return;
        };
        if events.len() == CAPACITY {
            events.pop_front();
        }
        events.push_back(event);
    }

    /// 当前会话 id。
    pub(crate) fn session_id(&self) -> Option<String> {
        self.session_id
            .lock()
            .map(|slot| slot.clone())
            .unwrap_or_default()
    }

    /// 最近 `count` 条"人话"动作，供 5 秒进度摘要下发。
    ///
    /// 两处与"给日志看"不同，因为这份摘要只给详情页展示：
    /// - 过滤 `Usage`：模型每轮都会报一次，留着会把真正的动作挤出摘要；
    /// - 单行截到 [`PROGRESS_LINE_CHARS`]：详情页只展示几行。
    ///
    /// 顺序保持时间正序（最旧的在前），客户端按行拼接即可。
    pub(crate) fn progress_lines(&self, count: usize) -> Vec<String> {
        let Ok(events) = self.events.lock() else {
            return Vec::new();
        };
        events
            .iter()
            .rev()
            .filter(|event| !matches!(event.kind, CodeEventKind::Usage { .. }))
            .take(count)
            .map(|event| clamp_chars(event.kind.describe().trim(), PROGRESS_LINE_CHARS))
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    }

    /// 整段 JSONL，用于 `run_log`。
    pub(crate) fn jsonl(&self) -> String {
        let Ok(events) = self.events.lock() else {
            return String::new();
        };
        events
            .iter()
            .filter_map(|event| serde_json::to_string(event).ok())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.events.lock().map(|events| events.len()).unwrap_or(0)
    }
}

/// 按字符截断，超出以 `…` 结尾（按字节切会切断中文）。
fn clamp_chars(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= max {
        return text.to_string();
    }
    text.chars().take(max).collect::<String>() + "…"
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn worktree() -> PathBuf {
        PathBuf::from("/work/repo")
    }

    fn log() -> EventLog {
        // 不带钩子的形态：解析路径的 `ToolUse` 需要真的入环。
        EventLog::new("task_1", "opencode", false)
    }

    #[test]
    fn cli_events_are_normalised_with_risk_and_digest() {
        let log = log();
        let event = log
            .record_cli(
                CliEvent::ToolUse {
                    name: "Bash".to_string(),
                    detail: "rm -rf ~/Documents/notes".to_string(),
                    input: Some(serde_json::json!({"command": "rm -rf ~/Documents/notes"})),
                    call_id: Some("call_1".to_string()),
                },
                &worktree(),
                1,
            )
            .expect("应翻译成功");

        assert_eq!(event.provider, "opencode");
        assert_eq!(event.task_id, "task_1");
        // CLI 自报的 id 走 `cli_` 命名空间，不能与钩子分配的 `call_<n>` 混用。
        assert_eq!(event.call_id.as_deref(), Some("cli_call_1"));
        match event.kind {
            CodeEventKind::ToolUse {
                tool,
                input_digest,
                risk,
            } => {
                assert_eq!(tool, "Bash");
                assert_eq!(input_digest, "rm -rf ~/Documents/notes");
                assert_eq!(risk, protocol::RiskLevel::IrreversibleWrite);
            }
            other => panic!("类型不符: {other:?}"),
        }
        assert_eq!(log.len(), 1);
    }

    #[test]
    fn session_id_is_remembered() {
        let log = log();
        log.record_cli(
            CliEvent::Started {
                session_id: Some("s1".to_string()),
            },
            &worktree(),
            1,
        );
        assert_eq!(log.session_id().as_deref(), Some("s1"));
    }

    #[test]
    fn ring_is_bounded_and_jsonl_is_one_line_per_event() {
        let log = log();
        for index in 0..(CAPACITY + 5) {
            log.record_cli(
                CliEvent::Text {
                    text: format!("第 {index} 条"),
                },
                &worktree(),
                index as i64,
            );
        }
        assert_eq!(log.len(), CAPACITY, "事件环必须有上界");

        let jsonl = log.jsonl();
        assert_eq!(jsonl.lines().count(), CAPACITY);
        for line in jsonl.lines() {
            let value: serde_json::Value = serde_json::from_str(line).expect("必须是合法 JSON");
            assert_eq!(value["provider"], "opencode");
        }
        // 最老的几条已被挤出
        assert!(!jsonl.contains("第 0 条"));
    }

    #[test]
    fn hook_covered_tools_are_not_recorded_twice() {
        // codebuddy 的每次工具调用都会先过钩子：钩子那条带风险与摘要，
        // 解析路径再记一条就会让同一个调用在 run_log 里出现两次。
        let log = EventLog::new("task_1", "codebuddy", true);
        let recorded = log.record_cli(
            CliEvent::ToolUse {
                name: "Bash".to_string(),
                detail: "rm -rf build".to_string(),
                input: Some(serde_json::json!({"command": "rm -rf build"})),
                call_id: Some("toolu_1".to_string()),
            },
            &worktree(),
            1,
        );
        assert!(recorded.is_none(), "钩子已覆盖时不该再入环");
        assert_eq!(log.len(), 0);

        // 非工具事件照常入环：文本与用量仍然只能从 stdout 拿。
        assert!(log
            .record_cli(
                CliEvent::Text {
                    text: "改好了".to_string(),
                },
                &worktree(),
                2,
            )
            .is_some());
        assert_eq!(log.len(), 1);
    }

    #[test]
    fn progress_lines_are_human_readable() {
        let log = log();
        log.record_cli(
            CliEvent::ToolResult {
                ok: false,
                summary: "hook blocked".to_string(),
            },
            &worktree(),
            1,
        );
        assert_eq!(
            log.progress_lines(1),
            vec!["失败：hook blocked".to_string()]
        );
    }

    #[test]
    fn progress_lines_skip_usage_and_clamp_long_text() {
        let log = log();
        log.record_cli(
            CliEvent::ToolUse {
                name: "Bash".to_string(),
                detail: "cargo test".to_string(),
                input: Some(serde_json::json!({"command": "cargo test"})),
                call_id: None,
            },
            &worktree(),
            1,
        );
        log.record_cli(
            CliEvent::Usage {
                prompt_tokens: Some(10),
                completion_tokens: Some(2),
            },
            &worktree(),
            2,
        );
        log.record_cli(
            CliEvent::Text {
                text: "啊".repeat(400),
            },
            &worktree(),
            3,
        );

        let lines = log.progress_lines(6);
        assert_eq!(lines.len(), 2, "用量行不该进摘要");
        assert!(lines[0].contains("Bash"), "{lines:?}");
        // 400 字截到 180 + 省略号。
        assert_eq!(lines[1].chars().count(), 181, "{lines:?}");
        assert!(lines[1].ends_with('…'));
        // 顺序是时间正序：工具在前，结论在后。
        assert!(lines[0].starts_with("工具："));
    }

    #[test]
    fn progress_lines_keep_only_the_tail() {
        let log = log();
        for index in 0..10 {
            log.record_cli(
                CliEvent::ToolResult {
                    ok: true,
                    summary: format!("第 {index} 步"),
                },
                &worktree(),
                index,
            );
        }
        let lines = log.progress_lines(3);
        assert_eq!(lines.len(), 3);
        assert!(lines[2].contains("第 9 步"), "{lines:?}");
        assert!(lines[0].contains("第 7 步"), "{lines:?}");
    }
}
