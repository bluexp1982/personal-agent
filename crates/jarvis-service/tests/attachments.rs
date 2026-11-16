//! 输入框附件的集成测试。
//!
//! 覆盖：上传 → 发送绑定 → 历史回看 → 正文下载的整条链路、只发附件不写文字、
//! 体积上限、跨设备拒绝、重复绑定、未发送附件的删除与孤儿清理。

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;

async fn create_conversation(ctx: &common::TestContext, token: &str) -> String {
    let project_id = ctx.work_project("attach").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "附件会话", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

async fn upload(
    ctx: &common::TestContext,
    token: &str,
    name: &str,
    mime: &str,
    bytes: &[u8],
) -> serde_json::Value {
    let response = ctx
        .call(
            Request::post(format!("/api/attachments?name={name}"))
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", mime)
                .body(Body::from(bytes.to_vec()))
                .expect("构造上传请求失败"),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "上传应当成功");
    common::body_json(response).await
}

async fn send(
    ctx: &common::TestContext,
    token: &str,
    id: &str,
    payload: serde_json::Value,
) -> String {
    let response = ctx
        .post_json(&format!("/api/conversations/{id}/messages"), token, &payload)
        .await;
    assert_eq!(response.status(), StatusCode::OK, "发送消息应当返回 SSE 流");

    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("读取 SSE 失败")
        .to_bytes();
    String::from_utf8_lossy(&bytes).into_owned()
}

#[tokio::test]
async fn upload_send_and_read_back() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("attach").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let uploaded = upload(&ctx, &token, "api.md", "text/markdown", b"# API\n").await;
    let attachment_id = uploaded["id"].as_str().expect("缺少附件 id").to_string();
    assert_eq!(uploaded["kind"], "file");
    assert_eq!(uploaded["name"], "api.md");
    assert_eq!(uploaded["bytes"], 6);

    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        serde_json::json!({
            "content": "看看这个",
            "client_msg_id": "c-att-1",
            "attachments": [attachment_id],
        }),
    )
    .await;
    assert!(stream.contains("message_completed"), "应有完成事件: {stream}");

    // 历史回看：附件元信息随消息一起下发，气泡才有芯片可画。
    let response = ctx
        .get_json(
            &format!("/api/conversations/{conversation_id}/messages"),
            &token,
        )
        .await;
    let body = common::body_json(response).await;
    let items = body["items"].as_array().expect("应有消息列表");
    let user = items
        .iter()
        .find(|item| item["role"] == "user")
        .expect("应有一条用户消息");
    let attachments = user["attachments"].as_array().expect("用户消息应带附件");
    assert_eq!(attachments.len(), 1);
    assert_eq!(attachments[0]["name"], "api.md");
    assert_eq!(attachments[0]["kind"], "file");

    // 上下文注入靠 `id + mime` 反推路径（`attachment::relative_path`），
    // 落盘规则必须与它一致——两条路径一旦分叉，模型就永远读不到附件正文。
    let injected = ctx
        .state
        .config
        .attachments_dir()
        .join("upload")
        .join(format!("{attachment_id}.md"));
    assert!(
        injected.exists(),
        "注入上下文读的文件必须就是上传落的那一份：{}",
        injected.display()
    );

    // 正文仍按 id 单独取，且字节与上传时一致。
    let response = ctx
        .get_json(&format!("/api/attachments/{attachment_id}/content"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("读取附件正文失败")
        .to_bytes();
    assert_eq!(&bytes[..], b"# API\n");
}

#[tokio::test]
async fn attachment_only_message_is_allowed() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("attach").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let uploaded = upload(&ctx, &token, "shot.png", "image/png", &png_bytes()).await;

    // 只有附件、没有一句正文：这也是完整意图，不能被"content 不能为空"挡掉。
    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        serde_json::json!({
            "content": "",
            "client_msg_id": "c-att-only",
            "attachments": [uploaded["id"]],
        }),
    )
    .await;
    assert!(stream.contains("message_completed"), "应有完成事件: {stream}");
}

#[tokio::test]
async fn oversized_upload_is_rejected() {
    let ctx = common::setup_with(|config| {
        config.attachment.max_bytes = 16;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("attach").await;

    let response = ctx
        .call(
            Request::post("/api/attachments?name=big.bin")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/octet-stream")
                .body(Body::from(vec![7u8; 64]))
                .expect("构造上传请求失败"),
        )
        .await;
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "payload_too_large");
}

#[tokio::test]
async fn empty_upload_is_rejected() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("attach").await;

    let response = ctx
        .call(
            Request::post("/api/attachments?name=empty.txt")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "text/plain")
                .body(Body::empty())
                .expect("构造上传请求失败"),
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn another_device_cannot_bind_the_attachment() {
    let ctx = common::setup().await;
    let (_first, first_token) = ctx.pair_and_login("attach-a").await;
    let (_second, second_token) = ctx.pair_and_login("attach-b").await;
    let conversation_id = create_conversation(&ctx, &second_token).await;

    let uploaded = upload(&ctx, &first_token, "secret.txt", "text/plain", b"hi").await;

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/messages"),
            &second_token,
            &serde_json::json!({
                "content": "偷看一下",
                "client_msg_id": "c-other",
                "attachments": [uploaded["id"]],
            }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "forbidden");
}

#[tokio::test]
async fn a_bound_attachment_cannot_be_sent_twice() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("attach").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let uploaded = upload(&ctx, &token, "a.txt", "text/plain", b"one").await;
    let attachment_id = uploaded["id"].as_str().expect("缺少附件 id").to_string();

    send(
        &ctx,
        &token,
        &conversation_id,
        serde_json::json!({
            "content": "第一次",
            "client_msg_id": "c-first",
            "attachments": [attachment_id],
        }),
    )
    .await;

    // 同一枚附件再发一次：它已经属于上一条消息，不能"一物两卖"。
    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/messages"),
            &token,
            &serde_json::json!({
                "content": "第二次",
                "client_msg_id": "c-second",
                "attachments": [attachment_id],
            }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn bound_attachment_cannot_be_deleted() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("attach").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let uploaded = upload(&ctx, &token, "keep.txt", "text/plain", b"keep").await;
    let attachment_id = uploaded["id"].as_str().expect("缺少附件 id").to_string();

    // 未发送时删除应当成功（用户撤掉 chip 的动作）。
    let spare = upload(&ctx, &token, "spare.txt", "text/plain", b"spare").await;
    let response = ctx
        .delete(
            &format!("/api/attachments/{}", spare["id"].as_str().unwrap_or_default()),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    send(
        &ctx,
        &token,
        &conversation_id,
        serde_json::json!({
            "content": "带附件",
            "client_msg_id": "c-keep",
            "attachments": [attachment_id],
        }),
    )
    .await;

    // 已绑定：历史气泡里那枚芯片还要能点开，不能删。
    let response = ctx
        .delete(&format!("/api/attachments/{attachment_id}"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn orphan_attachments_are_purged() {
    let ctx = common::setup_with(|config| {
        config.attachment.orphan_ttl_hours = 0;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("attach").await;

    let uploaded = upload(&ctx, &token, "draft.txt", "text/plain", b"draft").await;
    let attachment_id = uploaded["id"].as_str().expect("缺少附件 id").to_string();

    // TTL 是 0 小时：`created_at < cutoff` 需要一个严格早于现在的时刻。
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    let removed = jarvis_service::attachment::purge_orphans(&ctx.state)
        .await
        .expect("清理孤儿附件失败");
    assert_eq!(removed, 1, "这条附件既没发送也该被清掉");

    let response = ctx
        .get_json(&format!("/api/attachments/{attachment_id}/content"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// 一张最小的 PNG 头 + 少量填充字节：够判定 `kind=image`，也能被原样读回。
fn png_bytes() -> Vec<u8> {
    vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01]
}
