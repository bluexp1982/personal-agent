//! 编码任务的端到端测试：真实 worker 进程 + 假 CLI。
//!
//! 真 CLI 不进测试：它要网络、要密钥、要分钟级时间。但**编排逻辑必须用真进程验**——
//! worktree 创建、进程组、事件解析、产物、审批、合并，这些出错时症状都很像
//! "任务卡住了"。
//!
//! 依赖 `target/debug/jarvis-worker`；未构建时跳过（与 `worker_process.rs` 一致）。

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use protocol::{ApprovalDecision, ApproveAction, Task, TaskCreateRequest, TaskState};
use jarvis_service::code_proxy::CodeProxy;
use jarvis_service::runner::{TaskContext, TaskExecutor};
use jarvis_service::worker::{self, WorkerExecutor};
use jarvis_service::{approval, conversation, task};

const KEY_ENV: &str = "PERSONAL_AGENT_TEST_CODE_TASK_KEY";

fn worker_binary() -> Option<PathBuf> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/debug/jarvis-worker")
        .canonicalize()
        .ok()?;
    path.is_file().then_some(path)
}

/// 假 CLI：在 cwd 里造一个改动，然后按 opencode 的事件格式说一遍。
fn fake_cli(dir: &Path) -> PathBuf {
    let path = dir.join("fake-opencode");
    let script = r#"#!/bin/sh
set -eu
printf 'hello from agent\n' > hello.txt
printf '%s\n' '{"type":"step_start","timestamp":1,"sessionID":"ses_test","part":{}}'
printf '%s\n' '{"type":"tool_use","timestamp":2,"sessionID":"ses_test","part":{"tool":"write","state":{"title":"write","input":{"path":"hello.txt"}}}}'
printf '%s\n' '{"type":"step_finish","timestamp":3,"sessionID":"ses_test","part":{"tokens":{"input":10,"output":5}}}'
printf '%s\n' '{"type":"text","timestamp":4,"sessionID":"ses_test","part":{"text":"已创建 hello.txt"}}'
exit 0
"#;
    std::fs::write(&path, script).expect("写假 CLI 失败");
    let mut perms = std::fs::metadata(&path).expect("取权限失败").permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&path, perms).expect("设置权限失败");
    path
}

fn init_repo(dir: &Path) {
    std::fs::create_dir_all(dir).expect("创建仓库目录失败");
    run_git(dir, &["init", "-q"]);
    std::fs::write(dir.join("README.md"), "init\n").expect("写文件失败");
    run_git(dir, &["add", "-A"]);
    run_git(
        dir,
        &[
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@local",
            "commit",
            "-q",
            "-m",
            "init",
        ],
    );
}

fn run_git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .current_dir(dir)
        .args(args)
        .output()
        .expect("执行 git 失败");
    assert!(
        output.status.success(),
        "git {args:?} 失败: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

async fn wait_terminal(pool: &sqlx::SqlitePool, task_id: &str, budget: Duration) -> Option<Task> {
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if let Ok(Some(task)) = task::get(pool, task_id).await {
            if task.state.is_terminal() || task.state == TaskState::NeedsApproval {
                return Some(task);
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    None
}

async fn artifact_contents(ctx: &common::TestContext, task_id: &str) -> Vec<(String, String)> {
    let rows: Vec<(String, String)> =
        sqlx::query_as("SELECT kind, path FROM artifacts WHERE task_id = ? ORDER BY kind")
            .bind(task_id)
            .fetch_all(&ctx.state.pool)
            .await
            .expect("查询产物失败");

    let store =
        jarvis_service::artifact_store::ArtifactStore::new(ctx.state.config.artifacts_dir());
    let mut out = Vec::new();
    for (kind, relative) in rows {
        let Ok(bytes) = store.read(&relative).await else {
            continue;
        };
        out.push((kind, String::from_utf8_lossy(&bytes).into_owned()));
    }
    out
}

/// 准备一个已启用的编码环境：临时仓库 + 假 CLI + 真代理（只用来发令牌）。
async fn setup() -> Option<(common::TestContext, PathBuf, PathBuf)> {
    let binary = worker_binary()?;
    std::env::set_var(KEY_ENV, "test-upstream-key");

    let ctx = common::setup_with(|config| {
        config.worker_enabled = true;
        config.worker_path = Some(binary);
        config.worker_heartbeat_timeout_ms = 5_000;
        config.code.enabled = true;
        config.code.provider = "opencode".to_string();
        config.code.upstream.api_key_env = Some(KEY_ENV.to_string());
        // 假 CLI 不会真的发请求，地址只要合法即可。
        config.code.upstream.base_url = Some("http://127.0.0.1:1/v1".to_string());
        config.code.upstream.model = Some("test-model".to_string());
    })
    .await;

    let root = ctx.dir.path().join("repo");
    init_repo(&root);
    let cli = fake_cli(ctx.dir.path());

    Some((ctx, root, cli))
}

async fn create_code_task(ctx: &common::TestContext, repo: &Path) -> String {
    sqlx::query(
        "INSERT OR IGNORE INTO devices (id, name, platform, pubkey, paired_at) \
         VALUES ('dev_code', '编码测试设备', 'test', 'CODEPUBKEY', 0)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("创建设备失败");

    // 编码任务只能挂在 Git 项目下：目录必须就是那个 git 仓库。
    // 同一个测试里可能要建多个任务：目录已被占用时复用那个项目。
    let existing = jarvis_service::project::list(
        &ctx.state.pool,
        Some(protocol::ProjectMode::Code),
    )
    .await
    .expect("列出项目失败");
    let repo_text = repo
        .canonicalize()
        .expect("规范化仓库失败")
        .to_string_lossy()
        .to_string();
    let project = match existing
        .into_iter()
        .find(|project| project.path == repo_text)
    {
        Some(project) => project,
        None => jarvis_service::project::create(
            &ctx.state.pool,
            &ctx.state.config,
            &protocol::ProjectCreate {
                name: Some("编码仓库".to_string()),
                mode: protocol::ProjectMode::Code,
                path: repo.display().to_string(),
                init_git: false,
            },
        )
        .await
        .expect("创建 Git 项目失败"),
    };

    let conversation = conversation::create(
        &ctx.state.pool,
        "dev_code",
        &protocol::ConversationCreate {
            project_id: Some(project.id),
            title: Some("编码任务".to_string()),
            mode: None,
        },
    )
    .await
    .expect("创建会话失败");

    let (task, _) = task::create(
        &ctx.state.pool,
        &TaskCreateRequest {
            conversation_id: conversation.id,
            task_type: "skill:code-task".to_string(),
            skill: Some("code-task".to_string()),
            input: Some(serde_json::json!({
                "repo": repo.display().to_string(),
                "instruction": "创建 hello.txt"
            })),
            idempotency_key: None,
        },
        "dev_code",
    )
    .await
    .expect("创建任务失败");

    task.id
}

#[tokio::test]
async fn runs_in_worktree_then_merges_after_approval() {
    let Some((mut ctx, repo, cli)) = setup().await else {
        eprintln!("跳过：未找到 target/debug/jarvis-worker，先执行 cargo build");
        return;
    };

    ctx.state.config = std::sync::Arc::new({
        let mut config = (*ctx.state.config).clone();
        config.code.allow_roots = vec![repo.clone()];
        config.code.bin = Some(cli);
        config.code.worktree_dir = Some(ctx.dir.path().join("worktrees"));
        config
    });

    let proxy = CodeProxy::start(&ctx.state.config, ctx.state.pool.clone())
        .await
        .expect("启动编码代理失败");
    ctx.state.code_proxy = Some(proxy);

    let handle = worker::spawn(ctx.state.clone());
    assert!(
        wait_connected(&handle, Duration::from_secs(10)).await,
        "worker 未在 10 秒内连接：{:?}",
        handle.view()
    );
    assert!(
        handle
            .view()
            .skills
            .iter()
            .any(|skill| skill == "code-task"),
        "编码能力开启后 worker 应上报 code-task：{:?}",
        handle.view()
    );

    let task_id = create_code_task(&ctx, &repo).await;
    let executor = WorkerExecutor::new(
        handle.clone(),
        ctx.state.code_proxy.clone(),
        ctx.state.skills.clone(),
        ctx.state.config.clone(),
    );
    executor.spawn(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: task_id.clone(),
    });

    // 1) 跑到合并前确认
    let waiting = wait_terminal(&ctx.state.pool, &task_id, Duration::from_secs(30))
        .await
        .expect("任务未在 30 秒内到达确认点");
    assert_eq!(
        waiting.state,
        TaskState::NeedsApproval,
        "有改动时必须停在合并前确认"
    );
    let approval_id = waiting
        .pending_approval
        .as_ref()
        .expect("应挂起审批")
        .id
        .clone();
    assert_eq!(waiting.plan.len(), 4, "计划骨架应为 4 步");

    // 原仓库在确认前必须干净
    assert!(!repo.join("hello.txt").exists(), "确认前原仓库不应出现改动");

    // 2) 批准并恢复
    let (decided_task, decision) =
        approval::decide(&ctx.state.pool, &approval_id, ApproveAction::Approve)
            .await
            .expect("审批失败");
    assert_eq!(decided_task, task_id);
    assert_eq!(decision, ApprovalDecision::Approved);
    task::transition(&ctx.state.pool, &task_id, TaskState::Running, None)
        .await
        .expect("恢复状态失败");
    executor.resume(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: task_id.clone(),
    });

    // 3) 合并后成功
    let finished = wait_terminal(&ctx.state.pool, &task_id, Duration::from_secs(30))
        .await
        .expect("任务未在 30 秒内结束");
    assert_eq!(
        finished.state,
        TaskState::Succeeded,
        "批准后应成功：{:?}",
        finished.error
    );
    assert_eq!(
        std::fs::read_to_string(repo.join("hello.txt")).expect("读合并结果失败"),
        "hello from agent\n",
        "批准后改动应合并回原仓库"
    );

    // 4) 三件产物都在，diff 里能看到改动
    let artifacts = artifact_contents(&ctx, &task_id).await;
    let kinds: Vec<&str> = artifacts.iter().map(|(kind, _)| kind.as_str()).collect();
    assert_eq!(
        kinds,
        vec!["change_summary", "diff", "run_log"],
        "产物种类不对"
    );

    let joined = artifacts
        .iter()
        .map(|(_, text)| text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(joined.contains("hello.txt"), "产物应提到改动文件");
    assert!(joined.contains("已创建 hello.txt"), "产物应包含 CLI 结论");
    assert!(
        joined.contains("以代理侧记账为准"),
        "用量口径必须写明以代理为准"
    );

    handle.shutdown().await;
}

#[tokio::test]
async fn rejection_keeps_the_repository_untouched() {
    let Some((mut ctx, repo, cli)) = setup().await else {
        eprintln!("跳过：未找到 target/debug/jarvis-worker");
        return;
    };

    ctx.state.config = std::sync::Arc::new({
        let mut config = (*ctx.state.config).clone();
        config.code.allow_roots = vec![repo.clone()];
        config.code.bin = Some(cli);
        config.code.worktree_dir = Some(ctx.dir.path().join("worktrees"));
        config
    });

    let proxy = CodeProxy::start(&ctx.state.config, ctx.state.pool.clone())
        .await
        .expect("启动编码代理失败");
    ctx.state.code_proxy = Some(proxy);

    let handle = worker::spawn(ctx.state.clone());
    assert!(wait_connected(&handle, Duration::from_secs(10)).await);

    let task_id = create_code_task(&ctx, &repo).await;
    WorkerExecutor::new(
        handle.clone(),
        ctx.state.code_proxy.clone(),
        ctx.state.skills.clone(),
        ctx.state.config.clone(),
    )
    .spawn(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: task_id.clone(),
    });

    let waiting = wait_terminal(&ctx.state.pool, &task_id, Duration::from_secs(30))
        .await
        .expect("任务未到达确认点");
    assert_eq!(waiting.state, TaskState::NeedsApproval);

    let approval_id = waiting.pending_approval.expect("应挂起审批").id;
    let (_, decision) = approval::decide(&ctx.state.pool, &approval_id, ApproveAction::Reject)
        .await
        .expect("拒绝失败");
    assert_eq!(decision, ApprovalDecision::Rejected);
    task::transition(&ctx.state.pool, &task_id, TaskState::Canceled, None)
        .await
        .expect("取消状态失败");

    let finished = wait_terminal(&ctx.state.pool, &task_id, Duration::from_secs(10))
        .await
        .expect("任务未结束");
    assert_eq!(finished.state, TaskState::Canceled);
    assert!(!repo.join("hello.txt").exists(), "拒绝后原仓库必须保持干净");

    // 现场保留：隔离工作树（独立克隆）连同任务分支都还在，便于人工接管。
    let worktree = ctx.dir.path().join("worktrees").join(&task_id).join("wt");
    assert!(
        worktree.is_dir(),
        "拒绝后应保留工作树：{}",
        worktree.display()
    );
    let branch = std::process::Command::new("git")
        .current_dir(&worktree)
        .args(["branch", "--show-current"])
        .output()
        .expect("查分支失败");
    assert_eq!(
        String::from_utf8_lossy(&branch.stdout).trim(),
        format!("agent/{task_id}"),
        "工作树应停在任务分支上"
    );

    // 反向断言：主仓库不该出现任务分支——隔离成立的表现。
    let branches = std::process::Command::new("git")
        .current_dir(&repo)
        .args(["branch", "--list"])
        .output()
        .expect("查分支失败");
    let branches = String::from_utf8_lossy(&branches.stdout);
    assert!(
        !branches.contains(&format!("agent/{task_id}")),
        "主仓库不该有任务分支（那是上一次 worktree 模式的泄漏症状）：{branches}"
    );

    handle.shutdown().await;
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

/// 取消后并发位必须真的释放。
///
/// 这是「取消只改库、不通知 worker」那次缺陷的直接回归：worker 停在审批等待里
/// 占着 `code.max_concurrent`（默认 1）的信号量，取消之后第二个编码任务会永远排队。
#[tokio::test]
async fn cancelling_at_approval_releases_the_concurrency_slot() {
    let Some((mut ctx, repo, cli)) = setup().await else {
        eprintln!("跳过：未找到 target/debug/jarvis-worker，先执行 cargo build");
        return;
    };

    ctx.state.config = std::sync::Arc::new({
        let mut config = (*ctx.state.config).clone();
        config.code.allow_roots = vec![repo.clone()];
        config.code.bin = Some(cli);
        config.code.worktree_dir = Some(ctx.dir.path().join("worktrees"));
        // 默认就是 1；写出来是为了让这条测试的意图不依赖默认值。
        config.code.max_concurrent = 1;
        config
    });

    let proxy = CodeProxy::start(&ctx.state.config, ctx.state.pool.clone())
        .await
        .expect("启动编码代理失败");
    ctx.state.code_proxy = Some(proxy);

    let handle = worker::spawn(ctx.state.clone());
    assert!(
        wait_connected(&handle, Duration::from_secs(10)).await,
        "worker 未在 10 秒内连接：{:?}",
        handle.view()
    );

    let executor = WorkerExecutor::new(
        handle.clone(),
        ctx.state.code_proxy.clone(),
        ctx.state.skills.clone(),
        ctx.state.config.clone(),
    );

    // 第一个任务：跑到合并前确认，然后取消（模拟客户端点「取消任务」）。
    let first = create_code_task(&ctx, &repo).await;
    executor.spawn(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: first.clone(),
    });
    let waiting = wait_terminal(&ctx.state.pool, &first, Duration::from_secs(30))
        .await
        .expect("第一个任务未到达确认点");
    assert_eq!(waiting.state, TaskState::NeedsApproval);

    task::cancel(&ctx.state.pool, &first, "dev_code")
        .await
        .expect("取消失败");
    executor.cancel(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: first.clone(),
    });

    // 取消立刻生效（状态先落库），执行侧随后退出。
    let cancelled = task::get(&ctx.state.pool, &first)
        .await
        .expect("读取任务失败")
        .expect("任务应存在");
    assert_eq!(cancelled.state, TaskState::Canceled);

    // 第二个任务：必须能真的跑起来并到达确认点，否则说明并发位被第一个占死了。
    let second = create_code_task(&ctx, &repo).await;
    executor.spawn(TaskContext {
        pool: ctx.state.pool.clone(),
        task_id: second.clone(),
    });
    let waiting = wait_terminal(&ctx.state.pool, &second, Duration::from_secs(30))
        .await
        .expect("取消后第二个编码任务仍未开始：并发位可能没释放");
    assert_eq!(
        waiting.state,
        TaskState::NeedsApproval,
        "第二个任务应正常跑到确认点：{:?}",
        waiting.error
    );
}
