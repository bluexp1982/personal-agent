//! 任务执行接模型的端到端测试。
//!
//! 走真实 worker 进程 + 假模型：验证的是"worker → IPC → service → 模型"这条链，
//! 以及预算在真实事件流里的落点。真实网关不进测试——那会让用例依赖网络与密钥。
//!
//! 依赖 `target/debug/jarvis-worker`；未构建时跳过（与 `worker_process.rs` 一致）。

mod common;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use protocol::{ErrorCode, TaskCreateRequest, TaskState};
use jarvis_service::artifact_store::ArtifactStore;
use jarvis_service::model::{Completion, CompletionFuture, CompletionModel};
use jarvis_service::runner::{TaskContext, TaskExecutor};
use jarvis_service::worker::{self, WorkerExecutor};

const MODEL_MARKER: &str = "【模型生成】";
const ARTIFACT_MARKER: &str = "【模型归纳的产物】";

fn worker_binary() -> Option<PathBuf> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/debug/jarvis-worker")
        .canonicalize()
        .ok()?;
    path.is_file().then_some(path)
}

/// 固定回复的假模型。按 `step` / `synthesis` 给不同文本，便于分辨走的是哪条分支。
#[derive(Debug)]
struct FixedModel;

impl CompletionModel for FixedModel {
    fn complete(
        &self,
        _system: &str,
        prompt: &str,
        _max_tokens: Option<u32>,
    ) -> CompletionFuture<'_> {
        let text = if prompt.contains("各步骤结果") {
            format!("{ARTIFACT_MARKER}\n建议坐高铁，天气多云。")
        } else {
            format!("{MODEL_MARKER}这一步的结论")
        };

        Box::pin(async move {
            Ok(Completion {
                text,
                prompt_tokens: 50,
                completion_tokens: 20,
                tokens_estimated: false,
                finish_reason: None,
            })
        })
    }
}

async fn wait_connected(handle: &worker::WorkerHandle, budget: Duration) -> bool {
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if handle.is_connected() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

async fn wait_terminal(
    pool: &sqlx::SqlitePool,
    task_id: &str,
    budget: Duration,
) -> Option<TaskState> {
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if let Ok(Some(task)) = jarvis_service::task::get(pool, task_id).await {
            if task.state.is_terminal() {
                return Some(task.state);
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    None
}

async fn create_task(ctx: &common::TestContext) -> String {
    sqlx::query(
        "INSERT OR IGNORE INTO devices (id, name, platform, pubkey, paired_at) \
         VALUES ('dev_model', '模型测试设备', 'test', 'MODELPUBKEY', 0)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("创建设备失败");

    let project_id = ctx.work_project("model").await;
    let conversation = jarvis_service::conversation::create(
        &ctx.state.pool,
        "dev_model",
        &protocol::ConversationCreate {
            project_id: Some(project_id),
            title: Some("模型任务".to_string()),
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
            input: Some(serde_json::json!({ "submit": false, "city": "上海" })),
            idempotency_key: None,
        },
        "dev_model",
    )
    .await
    .expect("创建任务失败");

    task.id
}

async fn artifact_text(ctx: &common::TestContext, task_id: &str) -> String {
    let path: Option<String> =
        sqlx::query_scalar("SELECT path FROM artifacts WHERE task_id = ? LIMIT 1")
            .bind(task_id)
            .fetch_optional(&ctx.state.pool)
            .await
            .expect("查询产物失败");

    let path = path.expect("任务应产出至少一个产物");
    let store = ArtifactStore::new(ctx.state.config.artifacts_dir());
    let bytes = store.read(&path).await.expect("读取产物失败");
    String::from_utf8_lossy(&bytes).into_owned()
}

async fn model_call_count(ctx: &common::TestContext, task_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM audit_log WHERE action = 'task.model_call' AND trace_id = ?",
    )
    .bind(task_id)
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查询审计失败")
}

async fn model_call_count_with_result(
    ctx: &common::TestContext,
    task_id: &str,
    result: &str,
) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM audit_log \
         WHERE action = 'task.model_call' AND trace_id = ? AND result = ?",
    )
    .bind(task_id)
    .bind(result)
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查询审计失败")
}

#[tokio::test]
async fn steps_and_artifact_come_from_model() {
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

    ctx.state.model_bridge.set_model(Some(Arc::new(FixedModel)));

    let handle = worker::spawn(ctx.state.clone());
    assert!(
        wait_connected(&handle, Duration::from_secs(10)).await,
        "worker 未在 10 秒内连接：{:?}",
        handle.view()
    );

    let task_id = create_task(&ctx).await;
    WorkerExecutor::new(
        handle.clone(),
        None,
        std::sync::Arc::new(std::sync::RwLock::new(Vec::new())),
        ctx.state.config.clone(),
    )
    .spawn(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: task_id.clone(),
    });

    let state = wait_terminal(&ctx.state.pool, &task_id, Duration::from_secs(30)).await;
    assert_eq!(state, Some(TaskState::Succeeded), "任务应当成功");

    let artifact = artifact_text(&ctx, &task_id).await;
    assert!(
        artifact.contains(ARTIFACT_MARKER),
        "产物应由模型归纳，实际：{artifact}"
    );

    // 4 步 + 1 次归纳：每一步都真的问过模型，而不是模板回显。
    assert!(
        model_call_count(&ctx, &task_id).await >= 4,
        "模型调用次数偏少，说明有步骤走了模板"
    );

    handle.shutdown().await;
}

#[tokio::test]
async fn budget_exceeded_fails_task_with_stable_code() {
    let Some(binary) = worker_binary() else {
        eprintln!("跳过：未找到 target/debug/jarvis-worker");
        return;
    };

    let ctx = common::setup_with(|config| {
        config.worker_enabled = true;
        config.worker_path = Some(binary);
        config.worker_heartbeat_timeout_ms = 5_000;
        // 只给一次调用：第一步之后必须撞上限，走失败分支而不是继续烧。
        config.task.max_model_calls = 1;
    })
    .await;

    ctx.state.model_bridge.set_model(Some(Arc::new(FixedModel)));

    let handle = worker::spawn(ctx.state.clone());
    assert!(
        wait_connected(&handle, Duration::from_secs(10)).await,
        "worker 未在 10 秒内连接：{:?}",
        handle.view()
    );

    let task_id = create_task(&ctx).await;
    WorkerExecutor::new(
        handle.clone(),
        None,
        std::sync::Arc::new(std::sync::RwLock::new(Vec::new())),
        ctx.state.config.clone(),
    )
    .spawn(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: task_id.clone(),
    });

    let state = wait_terminal(&ctx.state.pool, &task_id, Duration::from_secs(30)).await;
    assert_eq!(state, Some(TaskState::Failed), "超预算应当失败");

    let task = jarvis_service::task::get(&ctx.state.pool, &task_id)
        .await
        .expect("读取任务失败")
        .expect("任务应存在");
    let error = task.error.expect("失败任务必须带错误码");
    assert_eq!(error.code, ErrorCode::BudgetExceeded);

    // 只有第一次真的问了模型；第二次在预算检查处就被拒，
    // 但拒绝本身也要留审计（否则"为什么停下"无处可查）。
    assert_eq!(
        model_call_count_with_result(&ctx, &task_id, "ok").await,
        1,
        "超预算后不应再发起成功调用"
    );
    assert_eq!(
        model_call_count_with_result(&ctx, &task_id, "error").await,
        1,
        "被拒绝的那次也应留一条审计"
    );

    handle.shutdown().await;
}
