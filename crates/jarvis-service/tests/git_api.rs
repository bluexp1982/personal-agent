//! Git 面板端点的集成测试。
//!
//! 用真实临时仓库跑：面板的价值全在"命令与命令行一致"，mock 掉的 git 只能证明
//! 我们自说自话。边界相关的细枝末节（porcelain 解析、路径校验）在
//! `jarvis-service::git` 的单元测试里覆盖，这里只确保 HTTP 层接对了、
//! 真实仓库上的读/写/拒绝行为符合契约。

mod common;

use std::path::{Path, PathBuf};

use axum::http::StatusCode;

fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .current_dir(dir)
        .args(["-c", "user.name=测试", "-c", "user.email=test@example.com"])
        .args(args)
        .output()
        .expect("git 未安装：Git 面板的测试需要服务端有 git");
    assert!(
        output.status.success(),
        "git {:?} 失败：{}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
}

async fn project_dir(ctx: &common::TestContext, id: &str) -> PathBuf {
    let project = jarvis_service::project::get(&ctx.state.pool, id)
        .await
        .expect("查询项目失败")
        .expect("项目不存在");
    PathBuf::from(project.path)
}

/// 建一个已提交的仓库：main 分支、一个 tracked.txt。
async fn init_repo(ctx: &common::TestContext, tag: &str) -> (String, PathBuf) {
    let id = ctx.work_project(tag).await;
    let dir = project_dir(ctx, &id).await;
    git(&dir, &["init", "-b", "main"]);
    std::fs::write(dir.join("tracked.txt"), "第一行\n").expect("写文件失败");
    git(&dir, &["add", "--", "tracked.txt"]);
    git(&dir, &["commit", "-q", "-m", "chore: 初始提交"]);
    (id, dir)
}

fn paths(values: &[&str]) -> serde_json::Value {
    serde_json::json!({ "paths": values })
}

#[tokio::test]
async fn non_repo_is_a_state_not_an_error() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-norepo").await;
    let id = ctx.work_project("git-norepo").await;

    let response = ctx
        .get_json(&format!("/api/projects/{id}/git/status"), &token)
        .await;
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "不是仓库要能画空态，不能变成红色报错"
    );
    let body = common::body_json(response).await;
    assert_eq!(body["repo"], false);
    assert!(body["reason"]
        .as_str()
        .expect("缺 reason")
        .contains("不是 Git 仓库"));

    // 写操作与 diff 没有空态可言：必须拒绝。
    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/stage"),
            &token,
            &paths(&["a.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "code_project_denied");
}

#[tokio::test]
async fn status_reports_branch_and_three_groups() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-status").await;
    let (id, dir) = init_repo(&ctx, "git-status").await;

    std::fs::write(dir.join("tracked.txt"), "第二行\n").expect("写文件失败");
    std::fs::write(dir.join("fresh.txt"), "新文件\n").expect("写文件失败");
    std::fs::write(dir.join("staged.txt"), "已暂存\n").expect("写文件失败");
    git(&dir, &["add", "--", "staged.txt"]);

    let response = ctx
        .get_json(&format!("/api/projects/{id}/git/status"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;

    assert_eq!(body["repo"], true);
    assert_eq!(body["branch"], "main");
    assert_eq!(body["detached"], false);
    assert_eq!(body["head"]["subject"], "chore: 初始提交");

    assert_eq!(body["staged"][0]["path"], "staged.txt");
    assert_eq!(body["staged"][0]["state"], "added");
    assert_eq!(body["unstaged"][0]["path"], "tracked.txt");
    assert_eq!(body["unstaged"][0]["state"], "modified");
    assert_eq!(body["untracked"][0]["path"], "fresh.txt");
    assert_eq!(body["untracked"][0]["state"], "untracked");
    assert!(body.get("operation").is_none(), "正常状态不该带中间态");
}

#[tokio::test]
async fn diff_covers_worktree_staged_and_untracked() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-diff").await;
    let (id, dir) = init_repo(&ctx, "git-diff").await;

    std::fs::write(dir.join("tracked.txt"), "第一行\n第二行\n").expect("写文件失败");
    std::fs::write(dir.join("fresh.txt"), "全新的\n").expect("写文件失败");

    // 工作区 diff
    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/git/diff?path=tracked.txt"),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["additions"], 1);
    assert_eq!(body["deletions"], 0);
    assert!(
        body["text"].as_str().expect("缺 text").contains("+第二行"),
        "diff 正文要能看出加了哪一行：{}",
        body["text"]
    );

    // 未跟踪文件：`git diff` 本身没有任何输出，服务端要现拼一份
    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/git/diff?path=fresh.txt"),
            &token,
        )
        .await;
    let body = common::body_json(response).await;
    assert_eq!(body["additions"], 1);
    assert!(body["text"].as_str().expect("缺 text").contains("+全新的"));

    // 暂存后再看暂存区
    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/stage"),
            &token,
            &paths(&["tracked.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/git/diff?path=tracked.txt&staged=true"),
            &token,
        )
        .await;
    let body = common::body_json(response).await;
    assert_eq!(body["staged"], true);
    assert!(body["text"].as_str().expect("缺 text").contains("+第二行"));
}

#[tokio::test]
async fn stage_commit_and_history_roundtrip() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-commit").await;
    let (id, dir) = init_repo(&ctx, "git-commit").await;

    std::fs::write(dir.join("tracked.txt"), "第二行\n").expect("写文件失败");

    // 没暂存就提交：拒绝，而不是替用户 add -A
    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/commit"),
            &token,
            &serde_json::json!({ "message": "feat: 空提交" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = common::body_json(response).await;
    assert!(body["hint"].as_str().expect("缺 hint").contains("暂存"));

    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/stage"),
            &token,
            &paths(&["tracked.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["staged"][0]["path"], "tracked.txt");
    assert!(body["unstaged"].as_array().expect("缺 unstaged").is_empty());

    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/commit"),
            &token,
            &serde_json::json!({ "message": "feat: 面板提交" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["commit"]["subject"], "feat: 面板提交");
    assert_eq!(
        body["status"]["staged"]
            .as_array()
            .expect("缺 staged")
            .len(),
        0
    );
    assert_eq!(
        body["status"]["untracked"]
            .as_array()
            .expect("缺 untracked")
            .len(),
        0
    );

    let response = ctx
        .get_json(&format!("/api/projects/{id}/git/commits"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    let commits = body["commits"].as_array().expect("缺 commits");
    assert_eq!(commits.len(), 2);
    assert_eq!(commits[0]["subject"], "feat: 面板提交");
    assert_eq!(body["has_more"], false);

    // 单次提交的 diff 也能看（历史里点一条）
    let hash = body["commits"][0]["hash"].as_str().expect("缺 hash");
    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/git/diff?commit={hash}"),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert!(body["text"].as_str().expect("缺 text").contains("+第二行"));
}

#[tokio::test]
async fn unstage_keeps_file_on_disk() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-unstage").await;
    let (id, dir) = init_repo(&ctx, "git-unstage").await;

    std::fs::write(dir.join("tracked.txt"), "改了一笔\n").expect("写文件失败");
    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/stage"),
            &token,
            &paths(&["tracked.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/unstage"),
            &token,
            &paths(&["tracked.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert!(body["staged"].as_array().expect("缺 staged").is_empty());
    assert_eq!(body["unstaged"][0]["path"], "tracked.txt");
    assert!(dir.join("tracked.txt").exists(), "取消暂存不能删文件");
}

#[tokio::test]
async fn discard_restores_tracked_but_keeps_new_files() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-discard").await;
    let (id, dir) = init_repo(&ctx, "git-discard").await;

    std::fs::write(dir.join("tracked.txt"), "弄坏了\n").expect("写文件失败");
    std::fs::write(dir.join("fresh.txt"), "新文件\n").expect("写文件失败");

    // 新文件不在 HEAD 里：撤销请求只含它时拒绝，且不删磁盘文件
    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/discard"),
            &token,
            &paths(&["fresh.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert!(dir.join("fresh.txt").exists(), "未跟踪文件一律不删");

    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/discard"),
            &token,
            &paths(&["tracked.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        std::fs::read_to_string(dir.join("tracked.txt")).expect("读文件失败"),
        "第一行\n",
        "撤销要把工作区恢复到 HEAD"
    );
}

#[tokio::test]
async fn rejects_paths_outside_the_repo() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-escape").await;
    let (id, _dir) = init_repo(&ctx, "git-escape").await;

    for path in ["../outside.txt", "/etc/passwd", ".git/config"] {
        let response = ctx
            .post_json(
                &format!("/api/projects/{id}/git/stage"),
                &token,
                &paths(&[path]),
            )
            .await;
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "{path} 应该被拒绝"
        );
        let body = common::body_json(response).await;
        assert_eq!(body["code"], "code_project_denied");
    }
}

#[tokio::test]
async fn unborn_repo_still_stages_and_unstages() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-unborn").await;
    let id = ctx.work_project("git-unborn").await;
    let dir = project_dir(&ctx, &id).await;
    git(&dir, &["init", "-b", "main"]);
    std::fs::write(dir.join("first.txt"), "第一行\n").expect("写文件失败");

    // 空仓库也要有分支名，但 head 为空：面板据此显示"还没有任何提交"。
    let status = common::body_json(
        ctx.get_json(&format!("/api/projects/{id}/git/status"), &token)
            .await,
    )
    .await;
    assert_eq!(status["repo"], true);
    assert_eq!(status["branch"], "main");
    assert!(status.get("head").is_none(), "空仓库没有 HEAD");
    assert_eq!(status["untracked"][0]["path"], "first.txt");

    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/stage"),
            &token,
            &paths(&["first.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["staged"][0]["state"], "added");

    // 暂存区 diff：没有 HEAD 也要能比（git 拿空树当基线）
    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/git/diff?path=first.txt&staged=true"),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert!(body["text"].as_str().expect("缺 text").contains("+第一行"));

    // 取消暂存：没有 HEAD 时 `reset HEAD` 必然失败，服务端要退回 `rm --cached`
    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/unstage"),
            &token,
            &paths(&["first.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert!(body["staged"].as_array().expect("缺 staged").is_empty());
    assert_eq!(body["untracked"][0]["path"], "first.txt");
    assert!(dir.join("first.txt").exists(), "取消暂存不能删文件");

    // 历史：空仓库返回空页而不是报错
    let response = ctx
        .get_json(&format!("/api/projects/{id}/git/commits"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert!(body["commits"].as_array().expect("缺 commits").is_empty());
    assert_eq!(body["has_more"], false);
}

#[tokio::test]
async fn commit_is_blocked_during_merge() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("git-merge").await;
    let (id, dir) = init_repo(&ctx, "git-merge").await;

    std::fs::write(dir.join("tracked.txt"), "改了一笔\n").expect("写文件失败");
    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/stage"),
            &token,
            &paths(&["tracked.txt"]),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    // 伪造 merge 现场：只要 `.git/MERGE_HEAD` 在，git 自己就认为在合并中。
    let head = std::process::Command::new("git")
        .current_dir(&dir)
        .args(["rev-parse", "HEAD"])
        .output()
        .expect("git 未安装");
    let sha = String::from_utf8_lossy(&head.stdout).trim().to_string();
    std::fs::write(dir.join(".git").join("MERGE_HEAD"), format!("{sha}\n"))
        .expect("写 MERGE_HEAD 失败");

    let status = common::body_json(
        ctx.get_json(&format!("/api/projects/{id}/git/status"), &token)
            .await,
    )
    .await;
    assert_eq!(status["operation"], "merge", "状态里要能看出中间态");

    let response = ctx
        .post_json(
            &format!("/api/projects/{id}/git/commit"),
            &token,
            &serde_json::json!({ "message": "chore: 合并中提交" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = common::body_json(response).await;
    assert!(body["hint"].as_str().expect("缺 hint").contains("merge"));
}
