//! 任务过程摘要的端到端：`StepOutput` → `task_steps.output_json` → 详情端点。
//!
//! 覆盖三件容易退化的事：
//! 1. 过程摘要必须出现在 `GET /api/tasks/{id}` 的 `plan[].output` 里；
//! 2. 进度刷新**不能**动 `tasks.updated_at`（悬空任务回收靠它判断"多久没动"）；
//! 3. 任务进入终态后迟到的进度不得覆盖展示，也不得把摘要写回去。

mod common;

use axum::http::StatusCode;
use protocol::{IpcMessage, StepSpec, TaskCreateRequest, TaskState};
use jarvis_service::task;
use jarvis_service::worker::events;

/// 造一个 `running` 的任务。设备是 `conversations.device_id` 外键要求的。
async fn setup_running_task(ctx: &common::TestContext) -> String {
    sqlx::query(
        "INSERT OR IGNORE INTO devices (id, name, platform, pubkey, paired_at) \
         VALUES ('dev_progress', '测试设备', 'test', 'PROGRESSPUBKEY', 0)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("创建设备失败");

    let project_id = ctx.work_project("progress").await;
    let conversation_id = jarvis_service::conversation::create(
        &ctx.state.pool,
        "dev_progress",
        &protocol::ConversationCreate {
            project_id: Some(project_id),
            title: Some("过程摘要测试".to_string()),
            mode: None,
        },
    )
    .await
    .expect("创建会话失败")
    .id;

    let request = TaskCreateRequest {
        conversation_id,
        task_type: "skill:code-task".to_string(),
        skill: Some("code-task".to_string()),
        input: Some(serde_json::json!({ "instruction": "改个 bug" })),
        idempotency_key: None,
    };
    let (task, _) = task::create(&ctx.state.pool, &request, "dev_progress")
        .await
        .expect("创建任务失败");

    task::transition(&ctx.state.pool, &task.id, TaskState::Running, None)
        .await
        .expect("任务应能进入 running");
    task.id
}

fn code_plan(task_id: &str) -> IpcMessage {
    IpcMessage::PlanCreated {
        task_id: task_id.to_string(),
        steps: vec![
            StepSpec {
                seq: 0,
                name: "准备隔离项目".to_string(),
            },
            StepSpec {
                seq: 1,
                name: "执行编码".to_string(),
            },
        ],
    }
}

#[tokio::test]
async fn step_output_is_exposed_in_task_detail() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("progress").await;
    let task_id = setup_running_task(&ctx).await;

    events::apply(&ctx.state, code_plan(&task_id)).await;
    let before = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");

    let summary = "工具：Bash（只读）git status\n完成：clean\n工具：Edit（可回滚写）src/main.rs";
    events::apply(
        &ctx.state,
        IpcMessage::StepOutput {
            task_id: task_id.clone(),
            seq: 1,
            summary: summary.to_string(),
        },
    )
    .await;

    // 详情端点：客户端真正读的那条路。
    let response = ctx
        .call(common::authed_get(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;

    let plan = body["plan"].as_array().expect("缺少 plan");
    assert_eq!(plan.len(), 2);
    assert_eq!(plan[1]["output"], summary, "过程摘要要随详情下发");
    assert!(
        plan[1]["updated_at"].as_i64().unwrap_or_default() > 0,
        "必须带生成时间：客户端要显示'多久没更新'"
    );
    assert!(
        plan[0].get("output").is_none(),
        "没有进度的步骤不该出现空字符串字段"
    );

    // 进度不写 `tasks.updated_at`：那个字段是悬空任务回收的判据。
    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(
        after.updated_at, before.updated_at,
        "进度刷新不得修改任务级 updated_at"
    );
}

#[tokio::test]
async fn late_step_output_is_ignored_after_terminal_state() {
    let ctx = common::setup().await;
    let task_id = setup_running_task(&ctx).await;

    events::apply(&ctx.state, code_plan(&task_id)).await;
    events::apply(
        &ctx.state,
        IpcMessage::StepOutput {
            task_id: task_id.clone(),
            seq: 1,
            summary: "工具：Bash（只读）cargo test".to_string(),
        },
    )
    .await;

    // 取消之后 worker 收尾仍可能再发一条进度：不得覆盖、不得把任务"写回运行中"。
    task::cancel(&ctx.state.pool, &task_id, "dev_progress")
        .await
        .expect("取消失败");

    let wrote = task::set_step_output(&ctx.state.pool, &task_id, 1, "迟到的进度")
        .await
        .expect("写入过程摘要失败");
    assert!(!wrote, "终态任务的进度必须被拒绝");

    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(task.state, TaskState::Canceled);
    assert_eq!(
        task.plan[1].output.as_deref(),
        Some("工具：Bash（只读）cargo test"),
        "取消前的摘要要保留下来给用户回看"
    );
}

/// 计划重建（重试/重新派发）会 `DELETE` + 重建步骤：旧摘要不能挂在新步骤上。
#[tokio::test]
async fn rebuilt_plan_drops_previous_output() {
    let ctx = common::setup().await;
    let task_id = setup_running_task(&ctx).await;

    events::apply(&ctx.state, code_plan(&task_id)).await;
    events::apply(
        &ctx.state,
        IpcMessage::StepOutput {
            task_id: task_id.clone(),
            seq: 1,
            summary: "上一轮的进度".to_string(),
        },
    )
    .await;

    events::apply(&ctx.state, code_plan(&task_id)).await;

    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert!(
        task.plan.iter().all(|step| step.output.is_none()),
        "重建后的步骤不该继承上一轮的摘要：{:?}",
        task.plan
    );
}
