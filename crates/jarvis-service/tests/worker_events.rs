//! worker 事件应用的服务端测试。
//!
//! 不启动真实子进程：直接对 `AppState` 调 `worker::events::apply`，验证
//! "事件 → 状态/审批/产物/审计" 的映射，以及完成校验不采信 worker 自称。

mod common;

use protocol::{IpcMessage, PlanStepState, SkillManifest, StepSpec, TaskCreateRequest, TaskState};
use jarvis_service::worker::events;
use jarvis_service::{approval, task};

fn trip_plan_manifest() -> SkillManifest {
    SkillManifest {
        name: "trip-plan".to_string(),
        version: "0.1.0".to_string(),
        risk_level: "read".to_string(),
        triggers: vec!["出行".to_string()],
        required_tools: vec!["web.fetch".to_string()],
        outputs: vec!["plan_table".to_string()],
        stop_before: Some("提交前确认".to_string()),
        steps: vec![
            "解析出行需求".to_string(),
            "查询参考信息".to_string(),
            "生成方案".to_string(),
            "提交前确认".to_string(),
        ],
        source: protocol::BUILTIN_SOURCE.to_string(),
        plugin_id: None,
        fetch: None,
    }
}

async fn setup_task(ctx: &common::TestContext, skill: &str) -> String {
    *ctx.state
        .skills
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = vec![trip_plan_manifest()];

    // conversations.device_id 有外键约束，先造一台测试设备。
    sqlx::query(
        "INSERT OR IGNORE INTO devices (id, name, platform, pubkey, paired_at) \
         VALUES ('dev_test', '测试设备', 'test', 'TESTPUBKEY', 0)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("创建设备失败");

    let project_id = ctx.work_project("events").await;
    let conversation_id = jarvis_service::conversation::create(
        &ctx.state.pool,
        "dev_test",
        &protocol::ConversationCreate {
            project_id: Some(project_id),
            title: Some("事件测试".to_string()),
            mode: None,
        },
    )
    .await
    .expect("创建会话失败")
    .id;

    let request = TaskCreateRequest {
        conversation_id,
        task_type: format!("skill:{skill}"),
        skill: Some(skill.to_string()),
        input: Some(serde_json::json!({ "submit": true })),
        idempotency_key: None,
    };

    let (task, _) = task::create(&ctx.state.pool, &request, "dev_test")
        .await
        .expect("创建任务失败");
    task.id
}

#[tokio::test]
async fn plan_and_artifact_events_update_task() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("任务应能进入 running");

    events::apply(
        &ctx.state,
        IpcMessage::PlanCreated {
            task_id: task_id.clone(),
            steps: vec![
                StepSpec {
                    seq: 0,
                    name: "解析出行需求".to_string(),
                },
                StepSpec {
                    seq: 1,
                    name: "查询参考信息".to_string(),
                },
            ],
        },
    )
    .await;

    let after_plan = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after_plan.plan.len(), 2);
    assert_eq!(after_plan.plan[0].state, PlanStepState::Pending);

    events::apply(
        &ctx.state,
        IpcMessage::StepStarted {
            task_id: task_id.clone(),
            seq: 0,
            name: "解析出行需求".to_string(),
        },
    )
    .await;

    let after_step = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after_step.plan[0].state, PlanStepState::Running);
}

#[tokio::test]
async fn approval_required_suspends_task() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;

    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("转入 running 失败");

    events::apply(
        &ctx.state,
        IpcMessage::ApprovalRequired {
            task_id: task_id.clone(),
            action: "submit_form".to_string(),
            target: Some("skill:trip-plan".to_string()),
            impact: Some("不可撤销".to_string()),
        },
    )
    .await;

    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::NeedsApproval);

    let pending = approval::latest_for_task(&ctx.state.pool, &task_id)
        .await
        .expect("读取审批失败")
        .expect("应有一条审批");
    assert_eq!(pending.action, "submit_form");
    assert_eq!(pending.decision, protocol::ApprovalDecision::Pending);
}

#[tokio::test]
async fn tool_approval_creates_a_tool_scoped_card() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("转入 running 失败");

    events::apply(
        &ctx.state,
        IpcMessage::ToolApprovalRequired {
            task_id: task_id.clone(),
            call_id: "call_1".to_string(),
            provider: "codebuddy".to_string(),
            tool: "Bash".to_string(),
            risk: "irreversible_write".to_string(),
            digest: "rm -rf build".to_string(),
            rules: vec!["delete_command".to_string()],
        },
    )
    .await;

    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::NeedsApproval);
    let pending = after.pending_approval.expect("应带一张待批卡");
    assert_eq!(pending.action, approval::TOOL_ACTION);
    assert_eq!(pending.scope, protocol::ApprovalScope::Tool);
    assert_eq!(pending.target.as_deref(), Some("call_1"));
    assert_eq!(pending.previews, vec!["rm -rf build".to_string()]);
    let tool = pending.tool.expect("工具级审批必须带工具信息");
    assert_eq!(tool.name, "Bash");
    assert_eq!(tool.risk, protocol::RiskLevel::IrreversibleWrite);

    // 串行不变量：同一任务已经有 pending 时，第二次请求不能建第二张卡。
    events::apply(
        &ctx.state,
        IpcMessage::ToolApprovalRequired {
            task_id: task_id.clone(),
            call_id: "call_2".to_string(),
            provider: "codebuddy".to_string(),
            tool: "Write".to_string(),
            risk: "irreversible_write".to_string(),
            digest: "/etc/passwd".to_string(),
            rules: vec!["path_outside_worktree".to_string()],
        },
    )
    .await;

    let pending_after = approval::pending_for_task(&ctx.state.pool, &task_id)
        .await
        .expect("读取审批失败")
        .expect("仍应有 pending");
    assert_eq!(
        pending_after.target.as_deref(),
        Some("call_1"),
        "第二张卡不该覆盖第一张"
    );
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM approvals WHERE task_id = ?")
        .bind(&task_id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("统计失败");
    assert_eq!(total, 1, "同一任务不能同时出现两条审批");
}

#[tokio::test]
async fn finished_requires_declared_outputs() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("转入 running 失败");

    // 没有产物就宣布完成：应被判失败
    events::apply(
        &ctx.state,
        IpcMessage::TaskFinished {
            task_id: task_id.clone(),
            summary: "我说我完成了".to_string(),
        },
    )
    .await;

    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::Failed);
    assert_eq!(
        after.error.map(|error| error.code.as_str().to_string()),
        Some("output_missing".to_string())
    );
}

#[tokio::test]
async fn finished_succeeds_with_artifact() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("转入 running 失败");

    events::apply(
        &ctx.state,
        IpcMessage::ArtifactCreated {
            task_id: task_id.clone(),
            kind: "plan_table".to_string(),
            size: 42,
            mime: Some("text/plain".to_string()),
            content: "行程草案正文".to_string(),
        },
    )
    .await;
    events::apply(
        &ctx.state,
        IpcMessage::TaskFinished {
            task_id: task_id.clone(),
            summary: "方案已生成".to_string(),
        },
    )
    .await;

    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::Succeeded);
    assert_eq!(after.artifacts.len(), 1);
    assert!(after.finished_at.is_some());

    // 正文必须真的落盘：size 以实际写入为准，不是事件里声明的 42
    let artifact = &after.artifacts[0];
    assert_eq!(artifact.size as usize, "行程草案正文".len());
    let store =
        jarvis_service::artifact_store::ArtifactStore::new(ctx.state.config.artifacts_dir());
    let bytes = store
        .read(&format!("{}/{}.txt", task_id, artifact.id))
        .await
        .expect("产物文件应存在");
    assert_eq!(String::from_utf8(bytes).expect("非 UTF-8"), "行程草案正文");

    // 审计能串起来
    let records = jarvis_service::audit::list_by_trace(&ctx.state.pool, &task_id)
        .await
        .expect("读取审计失败");
    let actions: Vec<&str> = records
        .iter()
        .map(|record| record.action.as_str())
        .collect();
    assert!(actions.contains(&"plan.created") || actions.contains(&"task.created"));
    assert!(actions.contains(&"artifact.created"));
    assert!(actions.contains(&"task.finished"));
}

#[tokio::test]
async fn unknown_skill_cannot_complete() {
    let ctx = common::setup().await;
    // 注册表里只有 trip-plan，任务却声明另一个技能
    let task_id = setup_task(&ctx, "missing-skill").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("转入 running 失败");

    events::apply(
        &ctx.state,
        IpcMessage::ArtifactCreated {
            task_id: task_id.clone(),
            kind: "plan_table".to_string(),
            size: 1,
            mime: None,
            content: "x".to_string(),
        },
    )
    .await;
    events::apply(
        &ctx.state,
        IpcMessage::TaskFinished {
            task_id: task_id.clone(),
            summary: "假装完成".to_string(),
        },
    )
    .await;

    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::Failed);
}

#[tokio::test]
async fn disconnect_requeues_running_tasks() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("转入 running 失败");

    let requeued = events::requeue_on_disconnect(&ctx.state, "worker 断开").await;
    assert_eq!(requeued, 1);

    let after = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取失败")
        .expect("任务应存在");
    assert_eq!(after.state, TaskState::Queued);
    assert_eq!(after.retry_count, 1);
}

/// 任务成功后，计划步骤必须一起落定。
///
/// 回归用例：IPC 里没有"步骤完成"消息，早先没人收尾，详情页的步骤会永远停在
/// "进行中"——所有技能都受影响，只是没人盯着看。
#[tokio::test]
async fn finishing_settles_plan_steps() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("任务应能进入 running");

    events::apply(
        &ctx.state,
        IpcMessage::PlanCreated {
            task_id: task_id.clone(),
            steps: vec![
                StepSpec {
                    seq: 0,
                    name: "解析出行需求".to_string(),
                },
                StepSpec {
                    seq: 1,
                    name: "查询参考信息".to_string(),
                },
            ],
        },
    )
    .await;
    events::apply(
        &ctx.state,
        IpcMessage::StepStarted {
            task_id: task_id.clone(),
            seq: 0,
            name: "解析出行需求".to_string(),
        },
    )
    .await;
    events::apply(
        &ctx.state,
        IpcMessage::ArtifactCreated {
            task_id: task_id.clone(),
            kind: "plan_table".to_string(),
            size: 6,
            mime: Some("text/plain".to_string()),
            content: "行程草案".to_string(),
        },
    )
    .await;
    events::apply(
        &ctx.state,
        IpcMessage::TaskFinished {
            task_id: task_id.clone(),
            summary: "完成".to_string(),
        },
    )
    .await;

    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("查任务失败")
        .expect("任务应存在");
    assert_eq!(task.state, TaskState::Succeeded);
    assert!(
        task.plan
            .iter()
            .all(|step| step.state == PlanStepState::Done),
        "成功的任务不应留下进行中的步骤：{:?}",
        task.plan
    );
}

#[tokio::test]
async fn failure_marks_the_running_step_and_leaves_the_rest_pending() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("任务应能进入 running");

    events::apply(
        &ctx.state,
        IpcMessage::PlanCreated {
            task_id: task_id.clone(),
            steps: vec![
                StepSpec {
                    seq: 0,
                    name: "解析出行需求".to_string(),
                },
                StepSpec {
                    seq: 1,
                    name: "查询参考信息".to_string(),
                },
            ],
        },
    )
    .await;
    events::apply(
        &ctx.state,
        IpcMessage::StepStarted {
            task_id: task_id.clone(),
            seq: 0,
            name: "解析出行需求".to_string(),
        },
    )
    .await;
    events::apply(
        &ctx.state,
        IpcMessage::TaskFailed {
            task_id: task_id.clone(),
            code: "code_failed".to_string(),
            hint: "编码 CLI 执行失败".to_string(),
            retryable: true,
        },
    )
    .await;

    let task = task::get(&ctx.state.pool, &task_id)
        .await
        .expect("查任务失败")
        .expect("任务应存在");
    assert_eq!(task.state, TaskState::Failed);
    assert_eq!(
        task.plan[0].state,
        PlanStepState::Failed,
        "断在哪一步要看得出来"
    );
    assert_eq!(
        task.plan[1].state,
        PlanStepState::Pending,
        "没开始的步骤不该被标成失败"
    );
}

/// 重试前清产物：行与文件都要消失，否则详情页会夹带上一次的失败日志。
#[tokio::test]
async fn clearing_artifacts_removes_both_row_and_file() {
    let ctx = common::setup().await;
    let task_id = setup_task(&ctx, "trip-plan").await;

    events::apply(
        &ctx.state,
        IpcMessage::ArtifactCreated {
            task_id: task_id.clone(),
            kind: "plan_table".to_string(),
            size: 6,
            mime: Some("text/plain".to_string()),
            content: "行程草案".to_string(),
        },
    )
    .await;

    let path: String = sqlx::query_scalar("SELECT path FROM artifacts WHERE task_id = ?")
        .bind(&task_id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("应有产物记录");

    task::clear_artifacts(&ctx.state.pool, &task_id, &ctx.state.config.artifacts_dir())
        .await
        .expect("清理失败");

    let remaining: i64 = sqlx::query_scalar("SELECT count(*) FROM artifacts WHERE task_id = ?")
        .bind(&task_id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查产物失败");
    assert_eq!(remaining, 0, "产物行应被删除");

    let store =
        jarvis_service::artifact_store::ArtifactStore::new(ctx.state.config.artifacts_dir());
    assert!(
        store.read(&path).await.is_err(),
        "产物文件也应被删除：{path}"
    );
}
