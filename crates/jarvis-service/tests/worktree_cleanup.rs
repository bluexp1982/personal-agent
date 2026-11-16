//! 编码任务现场（隔离工作树）的可见性与清理。
//!
//! 现场是"分支去哪了"这个问题的答案：分支只活在 `{worktree_dir}/{task_id}/wt` 里，
//! 批准合并时才被 fetch 进原仓库。因此详情要能看到它，用户也要能安全地把它删掉。

mod common;

use std::path::PathBuf;
use std::sync::Arc;

use axum::http::StatusCode;
use protocol::{ConversationCreate, TaskCreateRequest, TaskState};
use jarvis_service::{conversation, task};

/// 建一个任务，并把 `code.worktree_dir` 指到测试目录。
async fn setup_task(ctx: &mut common::TestContext, tag: &str) -> String {
    sqlx::query(
        "INSERT OR IGNORE INTO devices (id, name, platform, pubkey, paired_at) \
         VALUES ('dev_wt', '现场测试设备', 'test', 'WTPUBKEY', 0)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("创建设备失败");

    let worktrees = ctx.dir.path().join("worktrees");
    let mut config = (*ctx.state.config).clone();
    config.code.worktree_dir = Some(worktrees);
    ctx.state.config = Arc::new(config);

    let project_id = ctx.work_project(tag).await;
    let conversation_id = conversation::create(
        &ctx.state.pool,
        "dev_wt",
        &ConversationCreate {
            project_id: Some(project_id),
            title: Some("现场测试".to_string()),
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
            task_type: "skill:code-task".to_string(),
            skill: Some("code-task".to_string()),
            input: Some(serde_json::json!({ "instruction": "改点东西" })),
            idempotency_key: None,
        },
        "dev_wt",
    )
    .await
    .expect("创建任务失败");

    task.id
}

/// 造一棵假的现场：`{worktree_dir}/{task_id}/wt` + meta.json。
fn fake_worktree(ctx: &common::TestContext, task_id: &str) -> PathBuf {
    let base = ctx.state.config.code_worktree_dir().join(task_id);
    std::fs::create_dir_all(base.join("wt")).expect("创建工作树失败");
    std::fs::write(base.join("wt").join("hello.py"), "print('hi')\n").expect("写文件失败");
    std::fs::write(
        base.join("meta.json"),
        format!(r#"{{"base_branch":"main","branch":"agent/{task_id}"}}"#),
    )
    .expect("写 meta 失败");
    base
}

#[tokio::test]
async fn detail_exposes_worktree_and_cleanup_removes_it() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("wt-detail").await;
    let task_id = setup_task(&mut ctx, "wt").await;
    let base = fake_worktree(&ctx, &task_id);

    // 详情里能看到路径与分支；列表里不该带（不给每个任务读一次磁盘）。
    let detail =
        common::body_json(ctx.get_json(&format!("/api/tasks/{task_id}"), &token).await).await;
    let worktree = detail.get("worktree").expect("详情应包含现场");
    assert_eq!(worktree["branch"], format!("agent/{task_id}"));
    assert_eq!(worktree["exists"], true);
    assert!(
        worktree["path"]
            .as_str()
            .unwrap_or_default()
            .ends_with("/wt"),
        "应指向工作树目录：{worktree}"
    );

    let list = common::body_json(ctx.get_json("/api/tasks", &token).await).await;
    assert!(
        list["items"][0].get("worktree").is_none(),
        "列表不该为每个任务读盘"
    );

    // 未结束的任务不允许清理。
    let response = ctx
        .delete(&format!("/api/tasks/{task_id}/worktree"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("先取消"), "{hint}");

    task::transition(&ctx.state.pool, &task_id, TaskState::Canceled, None)
        .await
        .expect("转为终态失败");

    let response = ctx
        .delete(&format!("/api/tasks/{task_id}/worktree"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(!base.exists(), "现场目录应被删除");

    // 幂等：再删一次仍是 204。
    let response = ctx
        .delete(&format!("/api/tasks/{task_id}/worktree"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 现场没了，详情里也不再出现这个区块。
    let detail =
        common::body_json(ctx.get_json(&format!("/api/tasks/{task_id}"), &token).await).await;
    assert!(
        detail.get("worktree").is_none(),
        "清理后不该再有现场：{detail}"
    );
}

#[tokio::test]
async fn unknown_task_returns_404() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("wt-404").await;

    let response = ctx.delete("/api/tasks/task_nope/worktree", &token).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn cleanup_does_not_touch_the_repository() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("wt-repo").await;
    let task_id = setup_task(&mut ctx, "wt-repo").await;
    let base = fake_worktree(&ctx, &task_id);
    // 模拟"分支已合并进原仓库"：仓库里的 refs 与现场无关，清理不该动它。
    let repo_marker = ctx.dir.path().join("repo-branch.txt");
    std::fs::write(&repo_marker, "agent/task\n").expect("写文件失败");
    task::cancel(&ctx.state.pool, &task_id, "dev_wt")
        .await
        .expect("转为终态失败");

    let response = ctx
        .delete(&format!("/api/tasks/{task_id}/worktree"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(!base.exists());
    assert!(repo_marker.is_file(), "仓库侧的东西一律不碰");
}
