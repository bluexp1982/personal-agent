//! 任务载荷与状态机定义。
//!
//! 状态机是**显式表**：合法转移写在 `can_transition`，非法转移由服务端拒绝。
//! 不要在业务代码里散落 `if state == ...` 判断——那会让"哪些路径可达"无法验证。

use serde::{Deserialize, Serialize};

use crate::approval::Approval;
use crate::cursor::Cursor;
use crate::error::ApiError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskState {
    Queued,
    Running,
    NeedsInput,
    NeedsApproval,
    Succeeded,
    Failed,
    Canceled,
}

impl TaskState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::NeedsInput => "needs_input",
            Self::NeedsApproval => "needs_approval",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Canceled => "canceled",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "queued" => Some(Self::Queued),
            "running" => Some(Self::Running),
            "needs_input" => Some(Self::NeedsInput),
            "needs_approval" => Some(Self::NeedsApproval),
            "succeeded" => Some(Self::Succeeded),
            "failed" => Some(Self::Failed),
            "canceled" => Some(Self::Canceled),
            _ => None,
        }
    }

    /// 终态：不再接受任何转移（重试是新建一次执行，不是转移）。
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Canceled)
    }

    /// 用户可主动取消的状态。
    pub const fn is_cancelable(self) -> bool {
        matches!(
            self,
            Self::Queued | Self::Running | Self::NeedsInput | Self::NeedsApproval
        )
    }

    /// 合法转移表。返回 false 时调用方须按冲突处理，不得强行写库。
    pub const fn can_transition(self, next: Self) -> bool {
        use TaskState::{Canceled, Failed, NeedsApproval, NeedsInput, Queued, Running, Succeeded};
        matches!(
            (self, next),
            (Queued, Running)
                | (Queued, Canceled)
                | (Running, NeedsApproval)
                | (Running, NeedsInput)
                | (Running, Succeeded)
                | (Running, Failed)
                | (Running, Canceled)
                | (NeedsApproval, Running)
                | (NeedsApproval, Failed)
                | (NeedsApproval, Canceled)
                | (NeedsInput, Running)
                | (NeedsInput, Canceled)
                | (NeedsInput, Failed)
                // 重启回收：执行中断后回到待重试（语义上等价于重新排队）。
                | (Running, Queued)
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanStepState {
    Pending,
    Running,
    Done,
    Skipped,
    Failed,
}

impl PlanStepState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Done => "done",
            Self::Skipped => "skipped",
            Self::Failed => "failed",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "pending" => Some(Self::Pending),
            "running" => Some(Self::Running),
            "done" => Some(Self::Done),
            "skipped" => Some(Self::Skipped),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanStep {
    pub seq: i64,
    pub name: String,
    pub state: PlanStepState,
    /// 最近一次过程摘要（编码任务通常是最近几个动作，多行纯文本）。
    ///
    /// 缺省不序列化：老任务的步骤从来没有进度摘要，多出一个 `"output": null`
    /// 只会让客户端多一条判空分支。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// 该摘要的生成时间（Unix 毫秒）。客户端用它显示"最后更新"与
    /// "多久没有新输出"，所以必须随摘要一起下发，不能靠 `Task.updated_at`
    /// ——后者只由状态转移写，进度刷新不动它（否则会推迟悬空任务回收）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artifact {
    pub id: String,
    pub task_id: String,
    pub kind: String,
    pub size: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
    pub created_at: i64,
}

/// 编码任务的现场：隔离工作树与任务分支。
///
/// 只由服务端按 `task_id` 从磁盘读取，客户端只展示与复制——
/// 不接受客户端传路径，也就不存在"借这个字段删别的目录"。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeInfo {
    /// 隔离工作树目录（`{worktree_dir}/{task_id}/wt`）。
    pub path: String,
    /// 任务分支（`agent/{task_id}`）。合并回原仓库后也会保留。
    pub branch: String,
    /// 工作树目录是否还在（清理过或从未准备成功时为 false）。
    pub exists: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub conversation_id: String,
    /// `skill:<name>` 或能力标识。JSON 字段名沿用契约里的 `type`。
    #[serde(rename = "type")]
    pub task_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skill: Option<String>,
    pub state: TaskState,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub plan: Vec<PlanStep>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_approval: Option<Approval>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifacts: Vec<Artifact>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ApiError>,
    pub retry_count: i64,
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<i64>,
    /// 编码任务的现场；只有详情端点会读盘填充，列表里一律省略。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<WorktreeInfo>,
    /// 创建时的幂等键。客户端据此把"回答里的建议卡"和真实任务对上号：
    /// 同一个建议重复点、重进会话再点，拿到的都是同一条任务。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCreateRequest {
    pub conversation_id: String,
    #[serde(rename = "type")]
    pub task_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skill: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input: Option<serde_json::Value>,
    /// 幂等键。同一个键重复提交返回同一个任务，不重复执行。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

/// 技能当前的可用状态。
///
/// 三态而不是布尔，是因为「装进来了但有风险」和「根本跑不了」是两种处置：
/// 前者该提示、后者该从下拉里消失。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillStatus {
    /// 可装载、可运行。
    Supported,
    /// 可运行，但存在风险（如未声明工具却在正文里指挥跑脚本）。
    Degraded,
    /// 不可运行：依赖本机没有的工具。不装载、不进下拉、不进对话建议。
    Unsupported,
}

impl SkillStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Supported => "supported",
            Self::Degraded => "degraded",
            Self::Unsupported => "unsupported",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "supported" => Some(Self::Supported),
            "degraded" => Some(Self::Degraded),
            "unsupported" => Some(Self::Unsupported),
            _ => None,
        }
    }
}

/// 技能（流程模板）的只读描述。真正的加载与校验在 `jarvis-worker`（M4）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Skill {
    pub name: String,
    pub version: String,
    /// `builtin` / `user` / `third_party`
    pub source: String,
    /// `read` / `reversible_write` / `irreversible_write`
    pub risk_level: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub required_tools: Vec<String>,
    /// 所属插件 id；只有 `third_party` 才有。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<String>,
    /// 所属插件的展示名，客户端「来源」一栏用它，比 id 好读。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plugin_name: Option<String>,
    /// 规范里的 `description`：说清"做什么、何时用"，客户端展示。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// 当前可用状态。
    pub status: SkillStatus,
    /// 降级或不支持的可读原因，直接展示给用户。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reasons: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskPage {
    pub items: Vec<Task>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

/// 派任务前的一次参数解析请求。
///
/// 只服务会话里的 `@技能` 入口：用户说的是人话，而任务要的是结构化 `input`。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrepareTaskRequest {
    pub conversation_id: String,
    pub skill: String,
    /// 用户原话。服务端会把它原样保留进 `input.text`，保证技能总能读到用户的表述。
    pub text: String,
}

/// 参数是怎么来的。客户端据此决定要不要提示"没解析出参数"。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrepareSource {
    /// 模型解析成功。
    Model,
    /// 没有模型、超时或输出不可解析：只带原文。
    Fallback,
}

impl PrepareSource {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Model => "model",
            Self::Fallback => "fallback",
        }
    }
}

/// 归一化后的任务参数。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreparedTaskInput {
    pub skill: String,
    /// 一定是 JSON 对象，且一定含 `text`（用户原话）。
    pub input: serde_json::Value,
    pub source: PrepareSource,
    /// 技能声明需要、这次没拿到的字段（如 `["url"]`）。
    ///
    /// 与 `source` 解耦：模型解析成功也可能漏字段，两种情况都要让界面能提示。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing: Vec<String>,
}

impl TaskPage {
    pub fn from_items(items: Vec<Task>, cursor: Option<Cursor>) -> Self {
        Self {
            items,
            next_cursor: cursor.map(|cursor| cursor.encode()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_states_accept_nothing() {
        for state in [TaskState::Succeeded, TaskState::Failed, TaskState::Canceled] {
            assert!(state.is_terminal());
            for next in [TaskState::Queued, TaskState::Running, TaskState::Succeeded] {
                assert!(!state.can_transition(next), "{state:?} 不应能转到 {next:?}");
            }
        }
    }

    #[test]
    fn happy_path_is_legal() {
        assert!(TaskState::Queued.can_transition(TaskState::Running));
        assert!(TaskState::Running.can_transition(TaskState::NeedsApproval));
        assert!(TaskState::NeedsApproval.can_transition(TaskState::Running));
        assert!(TaskState::Running.can_transition(TaskState::Succeeded));
    }

    #[test]
    fn cannot_skip_from_queued_to_success() {
        assert!(!TaskState::Queued.can_transition(TaskState::Succeeded));
        assert!(!TaskState::Queued.can_transition(TaskState::NeedsApproval));
    }

    #[test]
    fn cancel_is_allowed_before_terminal() {
        for state in [
            TaskState::Queued,
            TaskState::Running,
            TaskState::NeedsInput,
            TaskState::NeedsApproval,
        ] {
            assert!(state.is_cancelable());
            assert!(state.can_transition(TaskState::Canceled));
        }
    }

    #[test]
    fn state_roundtrip() {
        for state in [
            TaskState::Queued,
            TaskState::Running,
            TaskState::NeedsInput,
            TaskState::NeedsApproval,
            TaskState::Succeeded,
            TaskState::Failed,
            TaskState::Canceled,
        ] {
            assert_eq!(TaskState::parse(state.as_str()), Some(state));
        }
    }

    #[test]
    fn task_type_serializes_as_type() {
        let task = Task {
            id: "t1".to_string(),
            conversation_id: "c1".to_string(),
            task_type: "skill:trip-plan".to_string(),
            skill: Some("trip-plan".to_string()),
            state: TaskState::Queued,
            plan: Vec::new(),
            pending_approval: None,
            artifacts: Vec::new(),
            error: None,
            retry_count: 0,
            created_at: 1,
            updated_at: 1,
            finished_at: None,
            worktree: None,
            idempotency_key: None,
        };
        let value = serde_json::to_value(&task).expect("序列化失败");
        assert_eq!(value["type"], "skill:trip-plan");
        assert!(value.get("pending_approval").is_none());
    }
}
