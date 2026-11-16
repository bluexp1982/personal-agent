//! 项目与目录浏览的集成测试。
//!
//! 覆盖：CRUD、模式过滤、目录白名单、Git 项目的 git 前置条件、
//! 软删后会话/任务不可见、未结束任务阻止删除、历史会话回填、技能按模式过滤。

mod common;

use std::path::Path;
use std::sync::Arc;

use axum::http::StatusCode;
use protocol::ProjectMode;
use jarvis_service::config::Config;
use jarvis_service::project;

/// 造一个「有提交、在分支上」的仓库，Git 项目的最低要求。
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

/// 把 `code.allow_roots` 指向测试目录：Git 项目必须在白名单内。
fn allow_code_roots(ctx: &mut common::TestContext, root: &Path) {
    let mut config: Config = (*ctx.state.config).clone();
    config.code.enabled = true;
    config.code.allow_roots = vec![root.to_path_buf()];
    ctx.state.config = Arc::new(config);
}

async fn create_project(
    ctx: &common::TestContext,
    token: &str,
    mode: &str,
    path: &Path,
) -> axum::response::Response {
    ctx.post_json(
        "/api/projects",
        token,
        &serde_json::json!({ "mode": mode, "path": path.to_string_lossy() }),
    )
    .await
}

async fn create_conversation(ctx: &common::TestContext, token: &str, project_id: &str) -> String {
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "创建会话失败");
    common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string()
}

#[tokio::test]
async fn creates_lists_and_renames_project() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-crud").await;

    let dir = ctx.dir.path().join("docs");
    std::fs::create_dir_all(&dir).expect("创建目录失败");

    let response = create_project(&ctx, &token, "work", &dir).await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let created = common::body_json(response).await;
    assert_eq!(created["mode"], "work");
    assert_eq!(created["name"], "docs", "名字缺省时取目录名");
    assert_eq!(created["conversation_count"], 0);
    let id = created["id"].as_str().expect("缺少 id").to_string();

    let response = ctx.get_json("/api/projects?mode=work", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let listed = common::body_json(response).await;
    assert_eq!(listed.as_array().map(Vec::len), Some(1));

    // 模式是过滤条件：普通项目不会出现在 Git 项目列表里。
    let response = ctx.get_json("/api/projects?mode=code", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        common::body_json(response).await.as_array().map(Vec::len),
        Some(0)
    );

    // 界面已不再区分模式：省略 mode 时一次返回全部项目。
    let response = ctx.get_json("/api/projects", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let listed = common::body_json(response).await;
    assert_eq!(listed.as_array().map(Vec::len), Some(1));
    assert_eq!(listed[0]["id"], id);

    let response = ctx
        .patch_json(
            &format!("/api/projects/{id}"),
            &token,
            &serde_json::json!({ "name": "工作资料" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(common::body_json(response).await["name"], "工作资料");

    let response = ctx.delete(&format!("/api/projects/{id}"), &token).await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 软删：详情与列表都不再出现。
    let response = ctx.get_json(&format!("/api/projects/{id}"), &token).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let response = ctx.get_json("/api/projects?mode=work", &token).await;
    assert_eq!(
        common::body_json(response).await.as_array().map(Vec::len),
        Some(0)
    );
}

#[tokio::test]
async fn duplicate_directory_is_rejected() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-dup").await;
    let dir = ctx.dir.path().join("same");
    std::fs::create_dir_all(&dir).expect("创建目录失败");

    assert_eq!(
        create_project(&ctx, &token, "work", &dir).await.status(),
        StatusCode::CREATED
    );

    let response = create_project(&ctx, &token, "work", &dir).await;
    assert_eq!(
        response.status(),
        StatusCode::CONFLICT,
        "同一目录不能建两个活动项目"
    );
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "conflict");
}

#[tokio::test]
async fn directory_outside_allowed_roots_is_denied() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-outside").await;

    let response = create_project(&ctx, &token, "work", Path::new("/")).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "code_project_denied");
    assert!(
        body["hint"]
            .as_str()
            .unwrap_or_default()
            .contains("不在允许的目录范围内"),
        "hint 要说清原因：{body}"
    );
}

#[tokio::test]
async fn code_project_requires_allow_roots() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-noroot").await;
    let dir = ctx.dir.path().join("repo");
    init_repo(&dir);

    let response = create_project(&ctx, &token, "code", &dir).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "code_project_denied");
    assert!(
        body["hint"]
            .as_str()
            .unwrap_or_default()
            .contains("code.allow_roots"),
        "hint 要指出配置项：{body}"
    );
}

#[tokio::test]
async fn code_project_accepts_repository_root() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-code").await;

    let root = ctx.dir.path().join("code");
    let repo = root.join("project");
    init_repo(&repo);
    allow_code_roots(&mut ctx, &root);

    let response = create_project(&ctx, &token, "code", &repo).await;
    assert_eq!(
        response.status(),
        StatusCode::CREATED,
        "{:?}",
        response.status()
    );
    let body = common::body_json(response).await;
    assert_eq!(body["mode"], "code");
    assert_eq!(body["name"], "project");
}

#[tokio::test]
async fn code_project_rejects_non_repository() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-plain").await;

    let root = ctx.dir.path().join("code");
    let plain = root.join("plain");
    std::fs::create_dir_all(&plain).expect("创建目录失败");
    allow_code_roots(&mut ctx, &root);

    let response = create_project(&ctx, &token, "code", &plain).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("还不是 Git 仓库"), "{hint}");
    // 拒绝的同时要指出出路：这条路客户端会用来弹"要不要初始化"的确认框。
    assert!(hint.contains("初始化"), "{hint}");
}

#[tokio::test]
async fn code_project_rejects_subdirectory_of_repository() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-subdir").await;

    let root = ctx.dir.path().join("code");
    let repo = root.join("project");
    init_repo(&repo);
    let sub = repo.join("src");
    std::fs::create_dir_all(&sub).expect("创建子目录失败");
    allow_code_roots(&mut ctx, &root);

    let response = create_project(&ctx, &token, "code", &sub).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("但本身不是仓库根"), "{hint}");
    assert!(hint.contains("初始化后它会成为独立仓库"), "{hint}");
}

#[tokio::test]
async fn code_project_rejects_repository_without_commits() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-empty").await;

    let root = ctx.dir.path().join("code");
    let repo = root.join("empty");
    std::fs::create_dir_all(&repo).expect("创建目录失败");
    run_git(&repo, &["init", "-q"]);
    allow_code_roots(&mut ctx, &root);

    let response = create_project(&ctx, &token, "code", &repo).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("还没有任何提交"), "{hint}");
}

#[tokio::test]
async fn code_project_rejects_detached_head() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-detached").await;

    let root = ctx.dir.path().join("code");
    let repo = root.join("project");
    init_repo(&repo);
    let head = std::process::Command::new("git")
        .current_dir(&repo)
        .args(["rev-parse", "HEAD"])
        .output()
        .expect("读取 HEAD 失败");
    let head = String::from_utf8_lossy(&head.stdout).trim().to_string();
    run_git(&repo, &["checkout", "-q", &head]);
    allow_code_roots(&mut ctx, &root);

    let response = create_project(&ctx, &token, "code", &repo).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("游离"), "{hint}");
}

#[tokio::test]
async fn deleting_project_hides_its_conversations() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-hide").await;

    let dir = ctx.dir.path().join("docs");
    std::fs::create_dir_all(&dir).expect("创建目录失败");
    let project_id = common::body_json(create_project(&ctx, &token, "work", &dir).await).await
        ["id"]
        .as_str()
        .expect("缺少 id")
        .to_string();
    let conversation_id = create_conversation(&ctx, &token, &project_id).await;

    let response = ctx
        .get_json(
            &format!("/api/conversations?project_id={project_id}"),
            &token,
        )
        .await;
    assert_eq!(
        common::body_json(response).await["items"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );

    assert_eq!(
        ctx.delete(&format!("/api/projects/{project_id}"), &token)
            .await
            .status(),
        StatusCode::NO_CONTENT
    );

    // 全局列表里也不该再出现：项目没了，它下面的会话就该一起退出视图。
    let response = ctx.get_json("/api/conversations", &token).await;
    assert_eq!(
        common::body_json(response).await["items"]
            .as_array()
            .map(Vec::len),
        Some(0)
    );

    // 数据保留：按 id 仍然能取到（只是没有入口了）。
    let response = ctx
        .get_json(&format!("/api/conversations/{conversation_id}"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn deleting_project_is_blocked_by_unfinished_task() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-busy").await;

    let dir = ctx.dir.path().join("docs");
    std::fs::create_dir_all(&dir).expect("创建目录失败");
    let project_id = common::body_json(create_project(&ctx, &token, "work", &dir).await).await
        ["id"]
        .as_str()
        .expect("缺少 id")
        .to_string();
    let conversation_id = create_conversation(&ctx, &token, &project_id).await;

    sqlx::query(
        "INSERT INTO tasks (id, conversation_id, type, state, retry_count, created_at, updated_at) \
         VALUES ('task_running', ?, 'skill:trip-plan', 'running', 0, 0, 0)",
    )
    .bind(&conversation_id)
    .execute(&ctx.state.pool)
    .await
    .expect("插入任务失败");

    let response = ctx
        .delete(&format!("/api/projects/{project_id}"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = common::body_json(response).await;
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("未结束"),
        "{body}"
    );
}

#[tokio::test]
async fn default_project_backfills_history() {
    let ctx = common::setup().await;

    // 模拟升级前的数据：会话没有项目归属。
    sqlx::query(
        "INSERT INTO conversations (id, title, mode, archived, created_at, updated_at) \
         VALUES ('conv_legacy', '历史会话', 'text', 0, 1, 1)",
    )
    .execute(&ctx.state.pool)
    .await
    .expect("插入历史会话失败");

    let created = project::ensure_default(&ctx.state.pool, &ctx.state.config)
        .await
        .expect("回填失败")
        .expect("应创建默认项目");
    assert_eq!(created.mode, ProjectMode::Work);
    assert_eq!(created.conversation_count, 1);
    assert!(
        Path::new(&created.path).is_dir(),
        "默认项目目录必须真的建出来：{}",
        created.path
    );

    let backfilled: Option<String> =
        sqlx::query_scalar("SELECT project_id FROM conversations WHERE id = 'conv_legacy'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(backfilled.as_deref(), Some(created.id.as_str()));

    // 幂等：没有待回填的会话时不再动手。
    assert!(
        project::ensure_default(&ctx.state.pool, &ctx.state.config)
            .await
            .expect("第二次回填失败")
            .is_none()
    );
}

#[tokio::test]
async fn skills_are_filtered_by_mode() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-skills").await;

    let mut config: Config = (*ctx.state.config).clone();
    config.code.enabled = true;
    ctx.state.config = Arc::new(config);

    let all = common::body_json(ctx.get_json("/api/skills", &token).await).await;
    assert!(
        has_skill(&all, "code-task"),
        "不带 mode 时编码技能应可见：{all}"
    );

    let work = common::body_json(ctx.get_json("/api/skills?mode=work", &token).await).await;
    assert!(!has_skill(&work, "code-task"), "普通模式不该出现编码技能");
    assert!(has_skill(&work, "trip-plan"), "普通技能两种模式都可用");

    let code = common::body_json(ctx.get_json("/api/skills?mode=code", &token).await).await;
    assert!(has_skill(&code, "code-task"), "Git 模式应包含编码技能");

    let invalid = ctx.get_json("/api/skills?mode=nope", &token).await;
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
}

fn has_skill(skills: &serde_json::Value, name: &str) -> bool {
    skills
        .as_array()
        .map(|items| items.iter().any(|skill| skill["name"] == name))
        .unwrap_or(false)
}

#[tokio::test]
async fn work_project_rejects_code_task() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-codetask").await;

    let project_id = ctx.work_project("office").await;
    let conversation_id = create_conversation(&ctx, &token, &project_id).await;

    let response = ctx
        .post_json(
            "/api/tasks",
            &token,
            &serde_json::json!({
                "conversation_id": conversation_id,
                "type": "skill:code-task",
                "skill": "code-task",
                "input": { "instruction": "改个东西" },
            }),
        )
        .await;

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    assert!(
        body["hint"]
            .as_str()
            .unwrap_or_default()
            .contains("Git 项目"),
        "提示要说明能力边界：{body}"
    );
}

#[tokio::test]
async fn browses_directories_and_marks_repositories() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-browse").await;

    let root = ctx.dir.path().join("home");
    std::fs::create_dir_all(root.join("docs")).expect("创建目录失败");
    std::fs::create_dir_all(root.join(".hidden")).expect("创建隐藏目录失败");
    init_repo(&root.join("project"));
    std::fs::write(root.join("note.txt"), "x").expect("写文件失败");

    let mut config: Config = (*ctx.state.config).clone();
    config.project.browse_roots = vec![root.clone()];
    ctx.state.config = Arc::new(config);

    let response = ctx.get_json("/api/fs/dirs?mode=work", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let listing = common::body_json(response).await;
    let entries = listing["entries"].as_array().expect("缺少 entries");
    let names: Vec<&str> = entries
        .iter()
        .filter_map(|entry| entry["name"].as_str())
        .collect();
    assert_eq!(names, vec!["docs", "project"], "只列目录、跳过隐藏目录");
    assert_eq!(entries[1]["kind"], "repo", "git 仓库要能识别出来");
    assert!(listing.get("parent").is_none(), "根目录不该有上一级");

    let child = root.join("docs");
    let response = ctx
        .get_json(
            &format!("/api/fs/dirs?mode=work&path={}", child.to_string_lossy()),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let listing = common::body_json(response).await;
    // 服务端返回的是规范化路径（macOS 上 /var 会变成 /private/var），断言也要用规范化的根。
    let canonical_root = root.canonicalize().expect("规范化根目录失败");
    assert_eq!(
        listing["parent"].as_str(),
        Some(canonical_root.to_string_lossy().as_ref()),
        "子目录应能回到上一级"
    );

    let response = ctx.get_json("/api/fs/dirs?mode=work&path=/", &token).await;
    assert_eq!(
        response.status(),
        StatusCode::BAD_REQUEST,
        "越界目录必须拒绝"
    );
    assert_eq!(
        common::body_json(response).await["code"],
        "code_project_denied"
    );
}

#[tokio::test]
async fn fs_browse_in_code_mode_requires_allow_roots() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-fscode").await;

    let response = ctx.get_json("/api/fs/dirs?mode=code", &token).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("code.allow_roots"), "{hint}");
}

// ---------------------------------------------------------------- 预检与初始化

async fn preflight(
    ctx: &common::TestContext,
    token: &str,
    mode: &str,
    path: &Path,
) -> axum::response::Response {
    ctx.get_json(
        &format!(
            "/api/projects/preflight?mode={mode}&path={}",
            path.to_string_lossy()
        ),
        token,
    )
    .await
}

async fn git_stdout(dir: &Path, args: &[&str]) -> String {
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
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

#[tokio::test]
async fn preflight_reports_each_git_state() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-preflight").await;

    let root = ctx.dir.path().join("code");
    let plain = root.join("plain");
    std::fs::create_dir_all(&plain).expect("创建目录失败");
    let repo = root.join("project");
    init_repo(&repo);
    let nested = repo.join("src");
    std::fs::create_dir_all(&nested).expect("创建子目录失败");
    let empty = root.join("empty");
    std::fs::create_dir_all(&empty).expect("创建目录失败");
    run_git(&empty, &["init", "-q"]);
    allow_code_roots(&mut ctx, &root);

    let body = common::body_json(preflight(&ctx, &token, "code", &plain).await).await;
    assert_eq!(body["git"], "missing");
    assert_eq!(body["ready"], false);
    assert_eq!(body["can_init"], true);
    assert!(body["reason"]
        .as_str()
        .unwrap_or_default()
        .contains("还不是 Git 仓库"));

    let body = common::body_json(preflight(&ctx, &token, "code", &repo).await).await;
    assert_eq!(body["git"], "ready");
    assert_eq!(body["ready"], true);
    assert_eq!(body["can_init"], false);
    assert!(
        !body["git_detail"].as_str().unwrap_or_default().is_empty(),
        "ready 时要给出当前分支：{body}"
    );

    let body = common::body_json(preflight(&ctx, &token, "code", &nested).await).await;
    assert_eq!(body["git"], "nested");
    assert_eq!(body["can_init"], true);
    assert!(
        body["git_detail"]
            .as_str()
            .unwrap_or_default()
            .ends_with("project"),
        "nested 要告诉用户父仓库在哪：{body}"
    );

    let body = common::body_json(preflight(&ctx, &token, "code", &empty).await).await;
    assert_eq!(body["git"], "no_commits");
    assert_eq!(body["can_init"], true);

    // 普通模式与 git 无关：不该让客户端以为要初始化一个仓库。
    let body = common::body_json(preflight(&ctx, &token, "work", &plain).await).await;
    assert_eq!(body["git"], "not_applicable");
    assert_eq!(body["ready"], true);
    assert_eq!(body["can_init"], false);
}

#[tokio::test]
async fn preflight_rejects_path_outside_roots() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-preflight-denied").await;

    let response = preflight(&ctx, &token, "work", Path::new("/")).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        common::body_json(response).await["code"],
        "code_project_denied"
    );
}

#[tokio::test]
async fn init_git_turns_plain_directory_into_project_repo() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-init-plain").await;

    let root = ctx.dir.path().join("code");
    let dir = root.join("demo");
    std::fs::create_dir_all(&dir).expect("创建目录失败");
    // 目录里已经有用户的东西：初始化不能把它提交进去，也不能改它。
    std::fs::write(dir.join("notes.md"), "原有内容\n").expect("写文件失败");
    allow_code_roots(&mut ctx, &root);

    // 不带 init_git：拒绝，并说清可以初始化。
    let response = create_project(&ctx, &token, "code", &dir).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("初始化"), "hint 要指出可以初始化：{hint}");

    // 带 init_git：建成功，目录变成有提交的仓库。
    let response = ctx
        .post_json(
            "/api/projects",
            &token,
            &serde_json::json!({ "mode": "code", "path": dir.to_string_lossy(), "init_git": true }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    assert_eq!(
        git_stdout(&dir, &["rev-parse", "--abbrev-ref", "HEAD"]).await,
        "main",
        "初始分支应为 main，不依赖用户的 init.defaultBranch"
    );
    assert!(
        !git_stdout(&dir, &["rev-parse", "--verify", "HEAD"])
            .await
            .is_empty(),
        "必须留下一个提交，否则建不出任务分支"
    );

    // 只做初始化：原有文件仍是未跟踪状态，没有被顺手提交。
    let status = git_stdout(&dir, &["status", "--porcelain"]).await;
    assert!(
        status.contains("notes.md"),
        "不该把已有文件提交进去：{status}"
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("notes.md")).expect("读文件失败"),
        "原有内容\n",
        "初始化不得改动已有文件"
    );
}

#[tokio::test]
async fn init_git_turns_nested_directory_into_its_own_repo() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-init-nested").await;

    let root = ctx.dir.path().join("code");
    let parent = root.join("mono");
    init_repo(&parent);
    let child = parent.join("app");
    std::fs::create_dir_all(&child).expect("创建子目录失败");
    allow_code_roots(&mut ctx, &root);

    let response = ctx
        .post_json(
            "/api/projects",
            &token,
            &serde_json::json!({ "mode": "code", "path": child.to_string_lossy(), "init_git": true }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let toplevel = git_stdout(&child, &["rev-parse", "--show-toplevel"]).await;
    assert_eq!(
        Path::new(&toplevel),
        child.canonicalize().expect("规范化失败").as_path(),
        "初始化后它应当是自己仓库的根"
    );
    assert!(
        parent.join(".git").is_dir(),
        "父仓库必须保持原样，不能被搬走或替换"
    );
}

#[tokio::test]
async fn init_git_adds_missing_first_commit() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-init-commit").await;

    let root = ctx.dir.path().join("code");
    let dir = root.join("empty");
    std::fs::create_dir_all(&dir).expect("创建目录失败");
    run_git(&dir, &["init", "-q"]);
    allow_code_roots(&mut ctx, &root);

    let response = ctx
        .post_json(
            "/api/projects",
            &token,
            &serde_json::json!({ "mode": "code", "path": dir.to_string_lossy(), "init_git": true }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    assert!(
        !git_stdout(&dir, &["rev-parse", "--verify", "HEAD"])
            .await
            .is_empty(),
        "空仓库补完提交后应能读到 HEAD"
    );
}

#[tokio::test]
async fn detached_head_cannot_be_fixed_by_init() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-init-detached").await;

    let root = ctx.dir.path().join("code");
    let repo = root.join("project");
    init_repo(&repo);
    let head = git_stdout(&repo, &["rev-parse", "HEAD"]).await;
    run_git(&repo, &["checkout", "-q", &head]);
    allow_code_roots(&mut ctx, &root);

    let body = common::body_json(preflight(&ctx, &token, "code", &repo).await).await;
    assert_eq!(body["git"], "detached");
    assert_eq!(body["can_init"], false, "游离 HEAD 初始化修不了");

    let response = ctx
        .post_json(
            "/api/projects",
            &token,
            &serde_json::json!({ "mode": "code", "path": repo.to_string_lossy(), "init_git": true }),
        )
        .await;
    assert_eq!(
        response.status(),
        StatusCode::BAD_REQUEST,
        "带着 init_git 也不能硬做"
    );
    let hint = common::body_json(response).await["hint"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(hint.contains("游离"), "{hint}");
}

#[tokio::test]
async fn ready_repository_ignores_init_flag() {
    let mut ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-init-noop").await;

    let root = ctx.dir.path().join("code");
    let repo = root.join("project");
    init_repo(&repo);
    let before = git_stdout(&repo, &["rev-list", "--count", "HEAD"]).await;
    allow_code_roots(&mut ctx, &root);

    let response = ctx
        .post_json(
            "/api/projects",
            &token,
            &serde_json::json!({ "mode": "code", "path": repo.to_string_lossy(), "init_git": true }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    assert_eq!(
        git_stdout(&repo, &["rev-list", "--count", "HEAD"]).await,
        before,
        "已就绪的仓库不该被塞进一个空提交"
    );
}
