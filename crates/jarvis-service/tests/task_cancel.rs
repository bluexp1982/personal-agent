//! 「任务结束」必须通知执行侧。
//!
//! 这条链路的缺陷曾经很难发现：状态落库了、界面显示"已取消"，但 worker 里的 CLI
//! 仍在跑（继续烧额度、继续改文件），停在审批等待的任务则永久占着编码并发位。
//!
//! 这里用**记录型执行器**替掉真正的执行器，断言每个"任务结束"的入口都真的调了
//! `cancel`：取消、审批拒绝、审批过期、悬空回收。

mod common;

use std::sync::{Arc, Mutex};

use protocol::{ApprovalDecision, IpcMessage, TaskCreateRequest, TaskState, ToolDecisionKind};
use jarvis_service::runner::{TaskContext, TaskExecutor};
use jarvis_service::worker::events;
use jarvis_service::{approval, task, ticker};

/// 只记下"谁被要求停手"，不做任何实际动作。
#[derive(Debug, Clone, Default)]
struct RecordingExecutor {
    cancelled: Arc<Mutex<Vec<String>>>,
    decided: Arc<Mutex<Vec<(String, bool)>>>,
}

impl RecordingExecutor {
    fn cancelled(&self) -> Vec<String> {
        self.cancelled
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn decided(&self) -> Vec<(String, bool)> {
        self.decided
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

impl TaskExecutor for RecordingExecutor {
    fn spawn(&self, _context: TaskContext) {}

    fn resume(&self, _context: TaskContext) {}

    fn cancel(&self, context: TaskContext) {
        self.cancelled
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(context.task_id);
    }

    fn tool_decision(
        &self,
        _context: TaskContext,
        call_id: &str,
        decision: ToolDecisionKind,
        _remember: bool,
    ) {
        self.decided
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push((call_id.to_string(), decision == ToolDecisionKind::Approve));
    }
}

/// 建一个跑在 running 状态的任务，返回 `(task_id, conversation_id)`。
async fn running_task(ctx: &common::TestContext, tag: &str) -> String {
    let project_id = ctx.work_project(tag).await;

    sqlx::query(
        "INSERT OR IGNORE INTO devices (id, name, platform, pubkey, paired_at) \
         VALUES ('dev_cancel', '取消测试设备', 'test', 'CANCELPUBKEY', 0)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("创建设备失败");

    let conversation_id = jarvis_service::conversation::create(
        &ctx.state.pool,
        "dev_cancel",
        &protocol::ConversationCreate {
            project_id: Some(project_id),
            title: Some("取消测试".to_string()),
            mode: None,
        },
    )
    .await
    .expect("创建会话失败")
    .id;

    let (task, _) = task::create(
        &ctx.state.pool,
        &TaskCreateRequest {
            conversation_id,
            task_type: "skill:trip-plan".to_string(),
            skill: Some("trip-plan".to_string()),
            input: Some(serde_json::json!({ "submit": true })),
            idempotency_key: None,
        },
        "dev_cancel",
    )
    .await
    .expect("创建任务失败");

    task::transition(&ctx.state.pool, &task.id, TaskState::Running, None)
        .await
        .expect("任务应能进入 running");

    task.id
}

/// 把任务挂到审批等待，返回 approval_id。
async fn park_at_approval(ctx: &common::TestContext, task_id: &str) -> String {
    let approval = approval::create(
        &ctx.state.pool,
        approval::NewApproval::task(task_id, "merge_changes", ctx.state.config.approval_ttl_ms)
            .with_target("agent/task_x")
            .with_impact("合并回 main"),
    )
    .await
    .expect("创建审批失败");
    task::transition(&ctx.state.pool, task_id, TaskState::NeedsApproval, None)
        .await
        .expect("任务应能进入 needs_approval");
    approval.id
}

async fn setup_with_recorder() -> (common::TestContext, RecordingExecutor) {
    let mut ctx = common::setup().await;
    let recorder = RecordingExecutor::default();
    ctx.state.executor = Arc::new(recorder.clone());
    (ctx, recorder)
}

#[tokio::test]
async fn cancel_endpoint_notifies_executor() {
    let (ctx, recorder) = setup_with_recorder().await;
    let (_device, token) = ctx.pair_and_login("cancel-api").await;
    let task_id = running_task(&ctx, "cancel").await;

    let response = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/cancel"),
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    assert_eq!(
        common::body_json(response).await["state"],
        "canceled",
        "取消应立即对客户端生效"
    );

    assert_eq!(
        recorder.cancelled(),
        vec![task_id],
        "取消之后必须通知执行侧停手，否则 CLI 会继续跑到超时"
    );
}

#[tokio::test]
async fn rejecting_approval_notifies_executor() {
    let (ctx, recorder) = setup_with_recorder().await;
    let (_device, token) = ctx.pair_and_login("reject-api").await;
    let task_id = running_task(&ctx, "reject").await;
    let approval_id = park_at_approval(&ctx, &task_id).await;

    let response = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/approve"),
            &token,
            &serde_json::json!({ "approval_id": approval_id, "decision": "reject" }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::ACCEPTED);

    let latest = approval::latest_for_task(&ctx.state.pool, &task_id)
        .await
        .expect("读取审批失败")
        .expect("应有审批记录");
    assert_eq!(latest.id, approval_id);
    assert_eq!(latest.decision, ApprovalDecision::Rejected);

    assert_eq!(
        recorder.cancelled(),
        vec![task_id],
        "拒绝之后 worker 还停在等 Resume，必须通知它退出"
    );
}

#[tokio::test]
async fn approving_does_not_cancel() {
    let (ctx, recorder) = setup_with_recorder().await;
    let (_device, token) = ctx.pair_and_login("approve-api").await;
    let task_id = running_task(&ctx, "approve").await;
    let approval_id = park_at_approval(&ctx, &task_id).await;

    let response = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/approve"),
            &token,
            &serde_json::json!({ "approval_id": approval_id, "decision": "approve" }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::ACCEPTED);

    assert!(
        recorder.cancelled().is_empty(),
        "批准是继续执行，不该发取消"
    );
}

#[tokio::test]
async fn expired_approval_notifies_executor() {
    let (ctx, recorder) = setup_with_recorder().await;
    let task_id = running_task(&ctx, "expire").await;
    park_at_approval(&ctx, &task_id).await;

    // 直接把"现在"推到审批过期之后，避免 sleep。
    let now = jarvis_service::clock::now_ms() + ctx.state.config.approval_ttl_ms + 1_000;
    ticker::run_once_at(&ctx.state, now)
        .await
        .expect("扫描应成功");

    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在");
    assert_eq!(task.state, TaskState::Failed, "审批过期应判失败");
    assert_eq!(
        recorder.cancelled(),
        vec![task_id],
        "过期的任务同样停在审批等待，不通知就会一直占着并发位"
    );
}

#[tokio::test]
async fn stale_running_task_is_cancelled_before_requeue() {
    let (ctx, recorder) = setup_with_recorder().await;
    let task_id = running_task(&ctx, "stale").await;

    // 让 updated_at 远早于超时线，模拟"进程没了但状态还是 running"。
    sqlx::query("UPDATE tasks SET updated_at = 0 WHERE id = ?")
        .bind(&task_id)
        .execute(&ctx.state.pool)
        .await
        .expect("更新失败");

    ticker::run_once(&ctx.state).await.expect("扫描应成功");

    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在");
    assert_eq!(task.state, TaskState::Queued, "悬空任务应回到队列");
    assert_eq!(
        recorder.cancelled(),
        vec![task_id],
        "回收前必须先让旧执行实例停手，否则用户重试会跑出两份"
    );
}

#[tokio::test]
async fn worker_failure_after_cancel_is_ignored() {
    let (ctx, _recorder) = setup_with_recorder().await;
    let task_id = running_task(&ctx, "late-fail").await;

    // 模拟"用户已取消、worker 收尾时又报失败"。
    task::cancel(&ctx.state.pool, &task_id, "dev_cancel")
        .await
        .expect("取消失败");
    events::apply(
        &ctx.state,
        protocol::IpcMessage::TaskFailed {
            task_id: task_id.clone(),
            code: "code_failed".to_string(),
            hint: "CLI 被终止".to_string(),
            retryable: true,
        },
    )
    .await;

    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在");
    assert_eq!(
        task.state,
        TaskState::Canceled,
        "迟到的失败上报不能把 canceled 覆盖成 failed"
    );
    assert!(task.error.is_none(), "取消的任务不该带失败原因");
}

/// 把任务挂到"某一次工具调用"的审批等待上，返回 approval_id。
async fn park_at_tool_approval(ctx: &common::TestContext, task_id: &str) -> String {
    // 调用方传进来时任务已经在 running（`running_task` 里转过了）。
    events::apply(
        &ctx.state,
        IpcMessage::ToolApprovalRequired {
            task_id: task_id.to_string(),
            call_id: "call_9".to_string(),
            provider: "codebuddy".to_string(),
            tool: "Bash".to_string(),
            risk: "irreversible_write".to_string(),
            digest: "git push origin main".to_string(),
            rules: vec!["external_command".to_string()],
        },
    )
    .await;

    approval::pending_for_task(&ctx.state.pool, task_id)
        .await
        .expect("读取审批失败")
        .expect("应有一张工具级审批卡")
        .id
}

#[tokio::test]
async fn rejecting_tool_approval_keeps_the_task_running() {
    let (ctx, recorder) = setup_with_recorder().await;
    let (_device, token) = ctx.pair_and_login("tool-reject").await;
    let task_id = running_task(&ctx, "tool-reject").await;
    let approval_id = park_at_tool_approval(&ctx, &task_id).await;

    let response = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/approve"),
            &token,
            &serde_json::json!({ "approval_id": approval_id, "decision": "reject" }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::ACCEPTED);

    // 驳回一次工具调用 ≠ 取消任务：CLI 会看到这一步失败并继续往下跑。
    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::Running);
    assert!(
        recorder.cancelled().is_empty(),
        "工具级驳回不该终止执行进程：{:?}",
        recorder.cancelled()
    );
    assert_eq!(recorder.decided(), vec![("call_9".to_string(), false)]);
}

#[tokio::test]
async fn approving_tool_approval_only_releases_that_call() {
    let (ctx, recorder) = setup_with_recorder().await;
    let (_device, token) = ctx.pair_and_login("tool-approve").await;
    let task_id = running_task(&ctx, "tool-approve").await;
    let approval_id = park_at_tool_approval(&ctx, &task_id).await;

    let response = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/approve"),
            &token,
            &serde_json::json!({ "approval_id": approval_id, "decision": "approve" }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::ACCEPTED);

    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::Running);
    assert!(recorder.cancelled().is_empty());
    assert_eq!(recorder.decided(), vec![("call_9".to_string(), true)]);
}
