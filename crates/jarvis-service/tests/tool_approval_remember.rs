//! 工具级审批的「本任务内不再询问」链路。
//!
//! 覆盖两件事：
//! 1. service 按任务审批模式与规则集合计算 `rememberable`；
//! 2. HTTP 的 `remember` 原样透传给执行器（worker 据此把规则记进本任务）。
//!
//! 不启动真实 worker：执行器换成记录型实现，只验证"服务端有没有把意愿传对"。

mod common;

use std::sync::Mutex;

use protocol::{ConversationCreate, IpcMessage, TaskCreateRequest, TaskState, ToolDecisionKind};
use jarvis_service::runner::{TaskContext, TaskExecutor};
use jarvis_service::worker::events;
use jarvis_service::{conversation, task};
use tower::ServiceExt;

#[derive(Debug, Default)]
struct RecordingExecutor {
    decisions: Mutex<Vec<(String, bool, bool)>>,
}

impl RecordingExecutor {
    fn decisions(&self) -> Vec<(String, bool, bool)> {
        self.decisions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

impl TaskExecutor for RecordingExecutor {
    fn spawn(&self, _context: TaskContext) {}

    fn resume(&self, _context: TaskContext) {}

    fn cancel(&self, _context: TaskContext) {}

    fn tool_decision(
        &self,
        _context: TaskContext,
        call_id: &str,
        decision: ToolDecisionKind,
        remember: bool,
    ) {
        self.decisions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push((
                call_id.to_string(),
                decision == ToolDecisionKind::Approve,
                remember,
            ));
    }
}

/// 造一个 running 任务，并给它挂一条工具级审批。
async fn task_with_tool_approval(
    ctx: &common::TestContext,
    tag: &str,
    approval: &str,
    rules: &[&str],
) -> (String, String, String) {
    let (device_id, token) = ctx.pair_and_login(tag).await;
    let project_id = ctx.work_project(tag).await;
    let conversation_id = conversation::create(
        &ctx.state.pool,
        &device_id,
        &ConversationCreate {
            project_id: Some(project_id),
            title: Some("审批记忆测试".to_string()),
            mode: None,
        },
    )
    .await
    .expect("创建会话失败")
    .id;

    let (task, _) = task::create(
        &ctx.state.pool,
        &TaskCreateRequest {
            conversation_id: conversation_id.clone(),
            task_type: "code-task".to_string(),
            skill: None,
            input: Some(serde_json::json!({ "approval": approval })),
            idempotency_key: None,
        },
        &device_id,
    )
    .await
    .expect("创建任务失败");

    task::transition(&ctx.state.pool, &task.id, TaskState::Running, None)
        .await
        .expect("任务应能进入 running");

    events::apply(
        &ctx.state,
        IpcMessage::ToolApprovalRequired {
            task_id: task.id.clone(),
            call_id: "call_1".to_string(),
            provider: "codebuddy".to_string(),
            tool: "Bash".to_string(),
            risk: "irreversible_write".to_string(),
            digest: "python3 -c 'import os; os.system(1)'".to_string(),
            rules: rules.iter().map(|rule| (*rule).to_string()).collect(),
        },
    )
    .await;

    (task.id, conversation_id, token)
}

async fn rememberable_of(
    ctx: &common::TestContext,
    tag: &str,
    approval: &str,
    rules: &[&str],
) -> bool {
    let (task_id, _, _) = task_with_tool_approval(ctx, tag, approval, rules).await;
    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在");
    task.pending_approval
        .expect("应挂起工具审批")
        .tool
        .expect("工具审批应带 tool 字段")
        .rememberable
}

#[tokio::test]
async fn auto_mode_offers_remember_for_rememberable_rules() {
    let ctx = common::setup().await;
    assert!(
        rememberable_of(&ctx, "remember-auto", "auto", &["dangerous_script"]).await,
        "自动档下危险脚本应允许本任务内记住"
    );
}

#[tokio::test]
async fn request_mode_never_offers_remember() {
    let ctx = common::setup().await;
    assert!(
        !rememberable_of(&ctx, "remember-request", "request", &["dangerous_script"]).await,
        "请求审批档必须逐条询问"
    );
}

#[tokio::test]
async fn sensitive_rules_never_offer_remember() {
    let ctx = common::setup().await;
    assert!(
        !rememberable_of(&ctx, "remember-sensitive", "auto", &["sensitive_path"]).await,
        "凭证类规则不允许本任务内记住"
    );
}

#[tokio::test]
async fn approve_passes_remember_to_the_executor() {
    let ctx = common::setup().await;
    let (task_id, _, token) =
        task_with_tool_approval(&ctx, "remember-approve", "auto", &["dangerous_script"]).await;

    let recorder = std::sync::Arc::new(RecordingExecutor::default());
    let mut state = ctx.state.clone();
    state.executor = recorder.clone();

    let approval = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在")
        .pending_approval
        .expect("应挂起工具审批");

    let response = jarvis_service::api::router(state.clone())
        .oneshot(common::authed_json_post(
            &format!("/api/tasks/{task_id}/approve"),
            &token,
            &serde_json::json!({
                "approval_id": approval.id,
                "decision": "approve",
                "remember": true,
            }),
        ))
        .await
        .expect("审批请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::ACCEPTED);

    assert_eq!(
        recorder.decisions(),
        vec![("call_1".to_string(), true, true)],
        "勾选后执行器必须收到 remember=true"
    );
}

#[tokio::test]
async fn approve_without_remember_keeps_the_old_behavior() {
    let ctx = common::setup().await;
    let (task_id, _, token) =
        task_with_tool_approval(&ctx, "remember-plain", "auto", &["dangerous_script"]).await;

    let recorder = std::sync::Arc::new(RecordingExecutor::default());
    let mut state = ctx.state.clone();
    state.executor = recorder.clone();

    let approval = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在")
        .pending_approval
        .expect("应挂起工具审批");

    let response = jarvis_service::api::router(state)
        .oneshot(common::authed_json_post(
            &format!("/api/tasks/{task_id}/approve"),
            &token,
            &serde_json::json!({
                "approval_id": approval.id,
                "decision": "approve",
            }),
        ))
        .await
        .expect("审批请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::ACCEPTED);

    assert_eq!(
        recorder.decisions(),
        vec![("call_1".to_string(), true, false)],
        "未勾选时 remember 必须是 false"
    );
}
