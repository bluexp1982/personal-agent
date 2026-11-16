//! 真实 worker 进程的端到端测试。
//!
//! 依赖 `target/debug/jarvis-worker`。未构建时跳过（CI 里可能没有）——这不是
//! 遗漏：进程级验证由本机冒烟负责，逻辑层面的映射已由 `worker_events.rs` 覆盖。

mod common;

use std::path::PathBuf;
use std::time::Duration;

use protocol::{TaskCreateRequest, TaskState};
use jarvis_service::runner::{TaskContext, TaskExecutor};
use jarvis_service::worker::{self, WorkerExecutor};

fn worker_binary() -> Option<PathBuf> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/debug/jarvis-worker")
        .canonicalize()
        .ok()?;
    path.is_file().then_some(path)
}

async fn wait_connected(handle: &worker::WorkerHandle, budget: Duration) -> bool {
    let deadline = std::time::Instant::now() + budget;
    while std::time::Instant::now() < deadline {
        if handle.is_connected() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

async fn wait_state(
    pool: &sqlx::SqlitePool,
    task_id: &str,
    expected: TaskState,
    budget: Duration,
) -> Option<TaskState> {
    let deadline = std::time::Instant::now() + budget;
    while std::time::Instant::now() < deadline {
        if let Ok(Some(task)) = jarvis_service::task::get(pool, task_id).await {
            if task.state == expected {
                return Some(task.state);
            }
            if task.state.is_terminal() {
                return Some(task.state);
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    None
}

async fn create_task(ctx: &common::TestContext, submit: bool) -> String {
    sqlx::query(
        "INSERT OR IGNORE INTO devices (id, name, platform, pubkey, paired_at) \
         VALUES ('dev_e2e', 'E2E 设备', 'test', 'E2EPUBKEY', 0)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("创建设备失败");

    let project_id = ctx.work_project("e2e").await;
    let conversation = jarvis_service::conversation::create(
        &ctx.state.pool,
        "dev_e2e",
        &protocol::ConversationCreate {
            project_id: Some(project_id),
            title: Some("E2E".to_string()),
            mode: None,
        },
    )
    .await
    .expect("创建会话失败");

    let (task, _) = jarvis_service::task::create(
        &ctx.state.pool,
        &TaskCreateRequest {
            conversation_id: conversation.id,
            task_type: "skill:trip-plan".to_string(),
            skill: Some("trip-plan".to_string()),
            input: Some(serde_json::json!({ "submit": submit, "url": "https://example.com" })),
            idempotency_key: None,
        },
        "dev_e2e",
    )
    .await
    .expect("创建任务失败");

    task.id
}

#[tokio::test]
async fn worker_runs_task_and_waits_for_approval() {
    let Some(binary) = worker_binary() else {
        eprintln!("跳过：未找到 target/debug/jarvis-worker，先执行 cargo build");
        return;
    };

    let ctx = common::setup_with(|config| {
        config.worker_enabled = true;
        config.worker_path = Some(binary);
        config.worker_heartbeat_timeout_ms = 5_000;
    })
    .await;

    let handle = worker::spawn(ctx.state.clone());
    assert!(
        wait_connected(&handle, Duration::from_secs(10)).await,
        "worker 未在 10 秒内连接：{:?}",
        handle.view()
    );

    // hello 上报技能后，服务端应能拿到 trip-plan
    let skills = {
        let registry = ctx
            .state
            .skills
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.clone()
    };
    assert!(
        skills.iter().any(|skill| skill.name == "trip-plan"),
        "worker 应上报 trip-plan，实际 {skills:?}"
    );

    let task_id = create_task(&ctx, true).await;
    let executor = WorkerExecutor::new(
        handle.clone(),
        None,
        std::sync::Arc::new(std::sync::RwLock::new(Vec::new())),
        ctx.state.config.clone(),
    );
    executor.spawn(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: task_id.clone(),
    });

    let state = wait_state(
        &ctx.state.pool,
        &task_id,
        TaskState::NeedsApproval,
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(state, Some(TaskState::NeedsApproval), "任务应停在审批");

    let pending = jarvis_service::approval::latest_for_task(&ctx.state.pool, &task_id)
        .await
        .expect("读取审批失败")
        .expect("应有待批审批");
    assert_eq!(pending.action, "submit_form");

    // 模拟审批端点：先决定，再转 running 并恢复执行
    jarvis_service::approval::decide(
        &ctx.state.pool,
        &pending.id,
        protocol::ApproveAction::Approve,
    )
    .await
    .expect("审批失败");
    jarvis_service::task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("转 running 失败");
    executor.resume(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: task_id.clone(),
    });

    let state = wait_state(
        &ctx.state.pool,
        &task_id,
        TaskState::Succeeded,
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(state, Some(TaskState::Succeeded), "批准后任务应成功");

    let task = jarvis_service::task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在");
    let artifact = task
        .artifacts
        .iter()
        .find(|artifact| artifact.kind == "plan_table")
        .expect("应有 plan_table 产物");

    // 正文必须由 worker 经 IPC 送上来并落盘：这条断言把"事件收到了"和"文件真的有了"分开
    let store =
        jarvis_service::artifact_store::ArtifactStore::new(ctx.state.config.artifacts_dir());
    let path: String = sqlx::query_scalar("SELECT path FROM artifacts WHERE id = ?")
        .bind(&artifact.id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("读取产物路径失败");
    let bytes = store.read(&path).await.expect("产物文件应存在");
    let text = String::from_utf8(bytes).expect("产物应为 UTF-8");
    assert!(text.contains("产物：plan_table"), "产物正文异常：{text}");
    assert_eq!(text.len() as i64, artifact.size, "落盘字节数应与元信息一致");

    handle.shutdown().await;
}

#[tokio::test]
async fn worker_is_restarted_after_kill() {
    use std::process::Command;

    let Some(binary) = worker_binary() else {
        eprintln!("跳过：未找到 target/debug/jarvis-worker");
        return;
    };

    let ctx = common::setup_with(|config| {
        config.worker_enabled = true;
        config.worker_path = Some(binary);
        config.worker_max_restarts = 5;
    })
    .await;

    let handle = worker::spawn(ctx.state.clone());
    assert!(wait_connected(&handle, Duration::from_secs(10)).await);

    let first_pid = handle.view().pid.expect("应有 pid");
    let status = Command::new("kill")
        .args(["-9", &first_pid.to_string()])
        .status()
        .expect("kill 失败");
    assert!(status.success());

    // 退避首档 1 秒 + 拉起与握手时间，留 15 秒余量
    let restart_deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut restarted = false;
    while std::time::Instant::now() < restart_deadline {
        if handle.is_connected() {
            if let Some(pid) = handle.view().pid {
                if pid != first_pid {
                    restarted = true;
                    break;
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    assert!(
        restarted,
        "worker 未在 15 秒内以新 pid 重新连接：{:?}",
        handle.view()
    );

    handle.shutdown().await;
}
