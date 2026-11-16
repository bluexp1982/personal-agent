//! 草案文件字节端点的集成测试。
//!
//! 这条端点只服务「另存为」：草案里的 md / png / mp4 在此之前没有任何读取通道
//! （`file-preview` 只换 html 的地址，且白名单只认 html/htm）。覆盖四件事：
//! 1. 成功读回字节，`download=true` 带附件头；
//! 2. 越界路径被拒（不允许读到草案目录之外）；
//! 3. 文件缺失与会话没有草稿目录各自的错误；
//! 4. 未携带令牌一律 401（与其他端点同一套鉴权）。

mod common;

use axum::http::StatusCode;

/// 一段"像 markdown"的最小内容：端点只转发字节，不参与解析。
const NOTE: &[u8] = b"# cat\n\n\xe4\xb8\x80\xe5\x8f\xaa\xe6\xa9\x98\xe7\x8c\xab\n";

/// 建会话并把一份草稿写进草案目录，返回会话 id。
async fn seed(ctx: &common::TestContext, token: &str, _tag: &str) -> String {
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "猫的说明稿" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "建会话失败");
    let conversation_id = common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();

    let dir = ctx.state.config.drafts_dir().join(&conversation_id);
    std::fs::create_dir_all(&dir).expect("建草案目录失败");
    std::fs::write(dir.join("notes.md"), NOTE).expect("写草案文件失败");
    conversation_id
}

async fn get_draft(
    ctx: &common::TestContext,
    token: &str,
    conversation_id: &str,
    path: &str,
    download: bool,
) -> axum::response::Response {
    let suffix = if download { "&download=true" } else { "" };
    ctx.call(common::authed_get(
        &format!("/api/conversations/{conversation_id}/draft-file?path={path}{suffix}"),
        token,
    ))
    .await
}

#[tokio::test]
async fn serves_draft_bytes_with_attachment_header() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("draft-file-ok").await;
    let conversation_id = seed(&ctx, &token, "draft-file-ok").await;

    let response = get_draft(&ctx, &token, &conversation_id, "notes.md", true).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("content-disposition")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default(),
        "attachment; filename=\"notes.md\"",
        "另存时系统保存框要拿到原始文件名"
    );

    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取响应体失败");
    assert_eq!(bytes.to_vec(), NOTE, "转发的是原始字节，不做任何转换");
}

#[tokio::test]
async fn rejects_paths_outside_the_draft_root() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("draft-file-escape").await;
    let conversation_id = seed(&ctx, &token, "draft-file-escape").await;

    // 真实存在、但不在本草稿根里的文件：`../` 能爬到别的会话，必须拒。
    // 用真实文件（而不是不存在的路径）才能证明拒绝来自边界判断，而不是"文件没找到"。
    let sibling = ctx.state.config.drafts_dir().join("someone-else");
    std::fs::create_dir_all(&sibling).expect("建旁路目录失败");
    std::fs::write(sibling.join("secret.md"), b"do not read").expect("写旁路文件失败");

    for bad in ["../someone-else/secret.md", "/etc/hosts"] {
        let response = get_draft(&ctx, &token, &conversation_id, bad, true).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{bad} 应被拒绝");
    }
}

#[tokio::test]
async fn missing_file_and_missing_draft_dir_are_not_found() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("draft-file-404").await;

    // 没有草稿目录的会话：先给可读提示，而不是 500。
    let response = ctx
        .post_json(
            "/api/conversations",
            token.as_str(),
            &serde_json::json!({ "title": "还没写过文件" }),
        )
        .await;
    let empty_id = common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();
    let response = get_draft(&ctx, &token, &empty_id, "notes.md", true).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    // 有目录但文件不在：同样是 404，客户端提示"已被清理"。
    let conversation_id = seed(&ctx, &token, "draft-file-404").await;
    let response = get_draft(&ctx, &token, &conversation_id, "gone.md", true).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn requires_authentication() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("draft-file-auth").await;
    let conversation_id = seed(&ctx, &token, "draft-file-auth").await;

    let response = ctx
        .call(
            axum::http::Request::builder()
                .uri(format!(
                    "/api/conversations/{conversation_id}/draft-file?path=notes.md"
                ))
                .body(axum::body::Body::empty())
                .expect("构造请求失败"),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}
