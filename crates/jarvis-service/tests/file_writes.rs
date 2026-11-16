//! 会话文件生成：覆盖决策与文件预览端点。
//!
//! 写入工具本身在 lib 单测里跑（它需要 service 内部工具才能构造）；
//! 这里验证 HTTP 层：待确认请求怎么被批准/拒绝、多久失效、预览地址能不能打开。

mod common;

use axum::http::StatusCode;
use jarvis_service::clock::now_ms;

/// 建一个会话。`project_id` 为 `None` 就是无归属直聊（草稿场景）。
async fn create_conversation(
    ctx: &common::TestContext,
    token: &str,
    project_id: Option<&str>,
) -> String {
    let payload = match project_id {
        Some(id) => serde_json::json!({ "title": "文件测试", "project_id": id }),
        None => serde_json::json!({ "title": "草稿测试" }),
    };

    let response = ctx.post_json("/api/conversations", token, &payload).await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

/// 直接插一条待确认记录（工具在 lib 里，集成测试够不到它的私有构造）。
async fn insert_pending(
    ctx: &common::TestContext,
    id: &str,
    conversation_id: &str,
    scope: &str,
    path: &str,
    content: &str,
    existing_bytes: i64,
    expires_at: i64,
) {
    sqlx::query(
        "INSERT INTO file_write_requests \
         (id, conversation_id, message_id, scope, path, content, bytes, existing_bytes, \
          status, created_at, expires_at) \
         VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 'pending', ?, ?)",
    )
    .bind(id)
    .bind(conversation_id)
    .bind(scope)
    .bind(path)
    .bind(content)
    .bind(content.len() as i64)
    .bind(existing_bytes)
    .bind(now_ms())
    .bind(expires_at)
    .execute(&ctx.state.pool)
    .await
    .expect("插入待确认请求失败");
}

async fn project_dir(ctx: &common::TestContext, id: &str) -> std::path::PathBuf {
    let project = jarvis_service::project::get(&ctx.state.pool, id)
        .await
        .expect("查询项目失败")
        .expect("项目不存在");

    std::path::PathBuf::from(project.path)
}

#[tokio::test]
async fn approving_overwrite_writes_file_and_keeps_backup() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("fw-approve").await;
    let project_id = ctx.work_project("fw-approve").await;
    let conversation_id = create_conversation(&ctx, &token, Some(&project_id)).await;

    let root = project_dir(&ctx, &project_id).await;
    std::fs::write(root.join("index.html"), "old").expect("写旧文件失败");

    insert_pending(
        &ctx,
        "fw_approve",
        &conversation_id,
        "project",
        "index.html",
        "<h1>new</h1>",
        3,
        now_ms() + 600_000,
    )
    .await;

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/file-writes/fw_approve"),
            &token,
            &serde_json::json!({ "approve": true }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    assert_eq!(body["status"], "written");
    assert_eq!(body["path"], "index.html");
    assert_eq!(body["scope"], "project");

    assert_eq!(
        std::fs::read_to_string(root.join("index.html")).expect("读新文件失败"),
        "<h1>new</h1>"
    );

    let backup = body["backup_path"].as_str().expect("覆盖后应留备份路径");
    assert_eq!(
        std::fs::read_to_string(backup).expect("读备份失败"),
        "old",
        "备份必须是覆盖前的内容"
    );
}

#[tokio::test]
async fn rejecting_overwrite_leaves_file_untouched() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("fw-reject").await;
    let project_id = ctx.work_project("fw-reject").await;
    let conversation_id = create_conversation(&ctx, &token, Some(&project_id)).await;

    let root = project_dir(&ctx, &project_id).await;
    std::fs::write(root.join("index.html"), "old").expect("写旧文件失败");

    insert_pending(
        &ctx,
        "fw_reject",
        &conversation_id,
        "project",
        "index.html",
        "new",
        3,
        now_ms() + 600_000,
    )
    .await;

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/file-writes/fw_reject"),
            &token,
            &serde_json::json!({ "approve": false }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    assert_eq!(body["status"], "rejected");
    assert_eq!(
        std::fs::read_to_string(root.join("index.html")).expect("读文件失败"),
        "old",
        "取消之后文件必须保持原样"
    );
}

#[tokio::test]
async fn expired_request_is_refused() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("fw-expired").await;
    let project_id = ctx.work_project("fw-expired").await;
    let conversation_id = create_conversation(&ctx, &token, Some(&project_id)).await;

    let root = project_dir(&ctx, &project_id).await;
    std::fs::write(root.join("index.html"), "old").expect("写旧文件失败");

    insert_pending(
        &ctx,
        "fw_expired",
        &conversation_id,
        "project",
        "index.html",
        "new",
        3,
        now_ms() - 1_000,
    )
    .await;

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/file-writes/fw_expired"),
            &token,
            &serde_json::json!({ "approve": true }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);

    let body = common::body_json(response).await;
    assert_eq!(body["code"], "conflict");
    assert_eq!(
        std::fs::read_to_string(root.join("index.html")).expect("读文件失败"),
        "old",
        "过期的请求不能落盘"
    );
}

#[tokio::test]
async fn decision_must_belong_to_the_same_conversation() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("fw-crosstalk").await;
    let project_id = ctx.work_project("fw-crosstalk").await;
    let owner = create_conversation(&ctx, &token, Some(&project_id)).await;
    let other = create_conversation(&ctx, &token, Some(&project_id)).await;

    insert_pending(
        &ctx,
        "fw_owner",
        &owner,
        "project",
        "index.html",
        "new",
        0,
        now_ms() + 600_000,
    )
    .await;

    let response = ctx
        .post_json(
            &format!("/api/conversations/{other}/file-writes/fw_owner"),
            &token,
            &serde_json::json!({ "approve": true }),
        )
        .await;
    assert_eq!(
        response.status(),
        StatusCode::CONFLICT,
        "别的会话不能替这个请求做决定"
    );
}

#[tokio::test]
async fn draft_preview_serves_generated_html() {
    let mut ctx = common::setup().await;
    let preview = ctx.start_preview().await;
    let (_device, token) = ctx.pair_and_login("fw-preview").await;
    let conversation_id = create_conversation(&ctx, &token, None).await;

    let dir = ctx.state.config.drafts_dir().join(&conversation_id);
    std::fs::create_dir_all(&dir).expect("建草稿目录失败");
    std::fs::write(dir.join("calc.html"), "<h1>1+1</h1>").expect("写草稿失败");

    let response = ctx
        .get_json(
            &format!("/api/conversations/{conversation_id}/file-preview?path=calc.html"),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    let url = body["url"].as_str().expect("缺少预览地址");
    assert_eq!(body["display"], "草稿/calc.html");
    assert!(url.contains("/d/"), "草稿必须走 /d/ 而不是 /f/：{url}");

    let page = reqwest::get(url).await.expect("请求预览失败");
    assert_eq!(page.status(), 200);
    assert_eq!(page.text().await.expect("读正文失败"), "<h1>1+1</h1>");

    preview.stop();
}

#[tokio::test]
async fn preview_refuses_paths_outside_the_draft() {
    let mut ctx = common::setup().await;
    let preview = ctx.start_preview().await;
    let (_device, token) = ctx.pair_and_login("fw-preview-deny").await;
    let conversation_id = create_conversation(&ctx, &token, None).await;

    let response = ctx
        .get_json(
            &format!("/api/conversations/{conversation_id}/file-preview?path=../agent.db"),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    preview.stop();
}
