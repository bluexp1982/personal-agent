//! 产物落盘与下载的集成测试。
//!
//! 覆盖：正文真的写到数据目录、下载返回原始字节与正确头部、文件被清理后给 404、
//! 未授权一律 401。产物是最容易被"看起来有记录"骗过的地方，所以这里断言的是
//! 文件系统上的字节，而不是数据库里的元信息。

mod common;

use axum::http::StatusCode;
use jarvis_service::artifact_store::ArtifactStore;

async fn create_conversation(ctx: &common::TestContext, token: &str) -> String {
    let project_id = ctx.work_project("artifacts").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "产物会话", "project_id": project_id }),
        )
        .await;
    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

/// 走完整链路（创建 → 审批 → 成功）拿到一个真实产物。
async fn artifact_from_finished_task(ctx: &common::TestContext, token: &str) -> serde_json::Value {
    let conversation_id = create_conversation(ctx, token).await;
    let response = ctx
        .post_json(
            "/api/tasks",
            token,
            &serde_json::json!({
                "conversation_id": conversation_id,
                "type": "skill:trip-plan",
                "skill": "trip-plan",
            }),
        )
        .await;
    let task = common::body_json(response).await;
    let task_id = task["id"].as_str().expect("缺少任务 id").to_string();

    let waiting = common::wait_for_state(ctx, token, &task_id, "needs_approval").await;
    let approval_id = waiting["pending_approval"]["id"]
        .as_str()
        .expect("应有待批审批")
        .to_string();

    let response = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/approve"),
            token,
            &serde_json::json!({ "approval_id": approval_id, "decision": "approve" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    let done = common::wait_for_state(ctx, token, &task_id, "succeeded").await;
    done["artifacts"]
        .as_array()
        .and_then(|items| items.first().cloned())
        .expect("成功任务应有产物")
}

#[tokio::test]
async fn artifact_content_is_downloadable() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("artifact").await;

    let artifact = artifact_from_finished_task(&ctx, &token).await;
    let artifact_id = artifact["id"].as_str().expect("缺少产物 id");
    let size = artifact["size"].as_i64().expect("缺少 size");
    assert!(size > 0, "产物正文不应为空");

    let response = ctx
        .call(common::authed_get(
            &format!("/api/artifacts/{artifact_id}/content"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let headers = response.headers().clone();
    assert_eq!(
        headers["content-type"].to_str().expect("头部非法"),
        "text/plain"
    );
    assert_eq!(
        headers["x-content-type-options"]
            .to_str()
            .expect("头部非法"),
        "nosniff"
    );
    let disposition = headers["content-disposition"]
        .to_str()
        .expect("头部非法")
        .to_string();
    assert!(disposition.starts_with("attachment;"), "{disposition}");
    assert!(disposition.ends_with(".txt\""), "{disposition}");

    let body = http_body_util_body_string(response).await;
    assert!(!body.is_empty(), "下载内容不应为空");
    assert_eq!(body.len() as i64, size, "下载字节数应与元信息一致");
    assert!(body.contains("步骤"), "产物应包含步骤说明：{body}");
}

#[tokio::test]
async fn missing_file_reports_not_found() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("artifact-missing").await;

    let artifact = artifact_from_finished_task(&ctx, &token).await;
    let artifact_id = artifact["id"].as_str().expect("缺少产物 id");
    let task_id = artifact["task_id"].as_str().expect("缺少任务 id");

    // 模拟"文件被清理"：删掉数据目录里的产物，记录留着
    let dir = ctx.state.config.artifacts_dir().join(task_id);
    let mut entries = std::fs::read_dir(&dir).expect("产物目录应存在");
    let file = entries
        .next()
        .expect("目录里应有产物文件")
        .expect("读取目录项失败");
    std::fs::remove_file(file.path()).expect("删除产物失败");

    let response = ctx
        .call(common::authed_get(
            &format!("/api/artifacts/{artifact_id}/content"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    let body = common::body_json(response).await;
    assert_eq!(body["code"], "not_found");
    assert!(
        body["hint"]
            .as_str()
            .is_some_and(|hint| hint.contains("清理")),
        "提示应说明文件已被清理：{body}"
    );
}

#[tokio::test]
async fn download_requires_token() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("artifact-auth").await;
    let artifact = artifact_from_finished_task(&ctx, &token).await;
    let artifact_id = artifact["id"].as_str().expect("缺少产物 id");

    let response = ctx
        .call(common::get(&format!(
            "/api/artifacts/{artifact_id}/content"
        )))
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn artifact_record_points_at_real_file() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("artifact-path").await;
    let artifact = artifact_from_finished_task(&ctx, &token).await;

    // path 必须是相对路径且真实存在：一旦写回绝对路径，数据目录搬迁就会失效
    let path: String = sqlx::query_scalar("SELECT path FROM artifacts WHERE id = ?")
        .bind(artifact["id"].as_str().expect("缺少产物 id"))
        .fetch_one(&ctx.state.pool)
        .await
        .expect("读取产物路径失败");
    assert!(!path.starts_with('/'), "path 应为相对路径：{path}");
    assert!(!path.starts_with("inline://"), "不应再写占位路径：{path}");

    let store = ArtifactStore::new(ctx.state.config.artifacts_dir());
    let bytes = store.read(&path).await.expect("产物应可读取");
    assert!(!bytes.is_empty());
}

async fn http_body_util_body_string(response: axum::response::Response) -> String {
    let bytes = http_body_util::BodyExt::collect(response.into_body())
        .await
        .expect("读取响应体失败")
        .to_bytes();
    String::from_utf8(bytes.to_vec()).expect("产物应为 UTF-8")
}
