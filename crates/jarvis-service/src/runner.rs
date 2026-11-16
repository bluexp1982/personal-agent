//! 任务执行器。
//!
//! M3 用 `SimulatedExecutor`：按固定三步推进，在"提交"前挂起等审批。
//! 它的存在是为了让状态机与审批链路可端到端验证；M4 会用 `jarvis-worker`
//! 的 IPC 实现替换它，`TaskExecutor` 接口保持不变。

use std::fmt::Debug;

use protocol::{ApprovalDecision, PlanStepState, TaskState, ToolDecisionKind};
use sqlx::SqlitePool;

use crate::approval;
use crate::task;

/// 执行一次任务所需的上下文。
#[derive(Debug, Clone)]
pub struct TaskContext {
    pub pool: SqlitePool,
    pub task_id: String,
}

/// 执行器抽象。实现方决定"怎么跑"，服务端只管状态权威。
pub trait TaskExecutor: Debug + Send + Sync {
    /// 开始执行一个排队中的任务。
    fn spawn(&self, context: TaskContext);

    /// 审批通过后继续执行。
    fn resume(&self, context: TaskContext);

    /// 下发一次工具级裁决（放行/驳回某一次工具调用）。
    ///
    /// `remember` 表示用户勾了「本任务内不再询问这类操作」，只有工具级放行才有意义。
    /// 默认空实现：模拟执行器没有 CLI 进程，不需要通知任何人；
    /// 只有 `WorkerExecutor` 会把它转成 `IpcMessage::Resume{call_id, decision, remember}`。
    fn tool_decision(
        &self,
        _context: TaskContext,
        _call_id: &str,
        _decision: ToolDecisionKind,
        _remember: bool,
    ) {
    }

    /// 让执行侧停手（取消、审批拒绝、审批过期、悬空回收）。
    ///
    /// **不是**状态转移：调用方必须先把任务落成终态，这里只负责通知执行进程。
    /// 通知失败不能回滚状态——任务已经不该继续跑了，worker 侧由重启/超时兜底。
    fn cancel(&self, context: TaskContext);
}

/// 模拟执行器：无外部依赖、确定性强，用于验证状态机与审批。
#[derive(Debug, Clone)]
pub struct SimulatedExecutor {
    approval_ttl_ms: i64,
    /// 产物目录在构造时注入：执行器不持有 `AppState`，只需要知道往哪里写。
    artifacts_dir: std::path::PathBuf,
}

impl SimulatedExecutor {
    pub fn new(approval_ttl_ms: i64, artifacts_dir: impl Into<std::path::PathBuf>) -> Self {
        Self {
            approval_ttl_ms,
            artifacts_dir: artifacts_dir.into(),
        }
    }
}

impl TaskExecutor for SimulatedExecutor {
    fn spawn(&self, context: TaskContext) {
        let ttl = self.approval_ttl_ms;
        tokio::spawn(async move {
            run(context, ttl).await;
        });
    }

    fn resume(&self, context: TaskContext) {
        let artifacts_dir = self.artifacts_dir.clone();
        tokio::spawn(async move {
            continue_after_approval(context, artifacts_dir).await;
        });
    }

    fn cancel(&self, _context: TaskContext) {
        // 模拟执行器没有外部进程：任务状态已经由调用方落库，这里无事可做。
    }
}

async fn run(context: TaskContext, approval_ttl_ms: i64) {
    let pool = &context.pool;
    let task_id = context.task_id.as_str();

    if let Err(err) = task::transition(pool, task_id, TaskState::Running, None).await {
        tracing::warn!(%err, task_id, "任务无法进入 running，执行器退出");
        return;
    }

    if let Err(err) = task::replace_plan(pool, task_id, &["准备参数", "提交前确认", "收尾"]).await
    {
        tracing::warn!(%err, task_id, "写入计划失败");
    }

    let _ = task::set_step_state(pool, task_id, 0, PlanStepState::Running).await;
    let _ = task::set_step_state(pool, task_id, 0, PlanStepState::Done).await;

    // 第二步是不可逆动作：必须挂起等审批。
    if let Err(err) = task::set_step_state(pool, task_id, 1, PlanStepState::Running).await {
        tracing::warn!(%err, task_id, "更新步骤状态失败");
    }

    match approval::create(
        pool,
        approval::NewApproval::task(task_id, "submit_form", approval_ttl_ms)
            .with_target("demo.local")
            .with_impact("模拟动作：确认后不可撤销"),
    )
    .await
    {
        Ok(approval) => {
            tracing::info!(
                task_id,
                approval_id = %approval.id,
                expires_at = approval.expires_at,
                "任务等待审批"
            );
            if let Err(err) = task::transition(pool, task_id, TaskState::NeedsApproval, None).await
            {
                tracing::warn!(%err, task_id, "进入 needs_approval 失败");
            }
        }
        Err(err) => {
            tracing::error!(%err, task_id, "创建审批失败，任务失败");
            let error = protocol::ApiError::new(
                protocol::ErrorCode::InternalError,
                "approval creation failed",
                "任务执行失败，请查看日志",
            );
            let _ = task::transition(pool, task_id, TaskState::Failed, Some(&error)).await;
        }
    }
}

async fn continue_after_approval(context: TaskContext, artifacts_dir: std::path::PathBuf) {
    let pool = &context.pool;
    let task_id = context.task_id.as_str();

    let approval = match approval::latest_for_task(pool, task_id).await {
        Ok(Some(approval)) => approval,
        Ok(None) => {
            tracing::warn!(task_id, "没有审批记录，无法恢复");
            return;
        }
        Err(err) => {
            tracing::error!(%err, task_id, "读取审批失败");
            return;
        }
    };

    match approval.decision {
        ApprovalDecision::Approved => {
            // 审批端点可能已经把任务转为 running（它需要立即给客户端一个准确状态），
            // 因此这里允许"已经是 running"的情况，只在仍是 needs_approval 时补一次转移。
            let current = task::get(pool, task_id)
                .await
                .ok()
                .flatten()
                .map(|task| task.state);
            match current {
                Some(TaskState::NeedsApproval) => {
                    if let Err(err) =
                        task::transition(pool, task_id, TaskState::Running, None).await
                    {
                        tracing::warn!(%err, task_id, "从 needs_approval 恢复失败");
                        return;
                    }
                }
                Some(TaskState::Running) => {}
                other => {
                    tracing::warn!(?other, task_id, "任务不在可恢复状态，执行器退出");
                    return;
                }
            }

            let _ = task::set_step_state(pool, task_id, 1, PlanStepState::Done).await;
            let _ = task::set_step_state(pool, task_id, 2, PlanStepState::Running).await;
            let store = crate::artifact_store::ArtifactStore::new(artifacts_dir);
            let content = demo_artifact_text(task_id);
            if let Err(err) =
                task::add_artifact(pool, &store, task_id, "table", Some("text/plain"), &content)
                    .await
            {
                tracing::warn!(%err, task_id, "写入产物失败");
            }
            let _ = task::set_step_state(pool, task_id, 2, PlanStepState::Done).await;

            if let Err(err) = task::transition(pool, task_id, TaskState::Succeeded, None).await {
                tracing::warn!(%err, task_id, "进入 succeeded 失败");
            }
        }
        ApprovalDecision::Rejected => {
            if let Err(err) = task::transition(pool, task_id, TaskState::Canceled, None).await {
                tracing::warn!(%err, task_id, "审批拒绝后取消任务失败");
            }
        }
        ApprovalDecision::Expired => {
            let error = approval::expired_error();
            if let Err(err) = task::transition(pool, task_id, TaskState::Failed, Some(&error)).await
            {
                tracing::warn!(%err, task_id, "审批过期后标记失败失败");
            }
        }
        ApprovalDecision::Pending => {
            tracing::debug!(task_id, "审批仍未决，等待用户操作");
        }
    }
}

/// 模拟执行器的产物正文。
///
/// 内容本身没有业务价值，但**必须有**：M3 路径不启用 worker，
/// 若这里只写空文件，"产物可查看"在未接 worker 时就是个空壳。
fn demo_artifact_text(task_id: &str) -> String {
    format!(
        "任务：{task_id}\n\
         类型：模拟执行（未启用 jarvis-worker）\n\
         步骤：准备参数 → 提交前确认 → 收尾\n\
         结论：审批已通过，模拟动作已执行。\n"
    )
}
