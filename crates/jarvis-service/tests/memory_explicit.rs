//! 会话里的显式「记住」：确定性写入、可见提示、失败不静默、普通消息不误触发。

mod common;

use axum::http::StatusCode;
use serde_json::{json, Value};
use jarvis_service::config::Config;

use common::{body_json, setup_with, TestContext};

async fn memory_enabled() -> TestContext {
    setup_with(|config: &mut Config| {
        config.memory.enabled = true;
    })
    .await
}

async fn create_conversation(ctx: &TestContext, token: &str) -> String {
    let project_id = ctx.work_project("explicit").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &json!({ "title": "显式记忆", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);

    body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string()
}

/// 发一条消息并读完整个 SSE 流。
async fn send(ctx: &TestContext, token: &str, conversation_id: &str, payload: Value) -> String {
    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/messages"),
            token,
            &payload,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK, "发送消息应当返回 SSE 流");

    let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .expect("读取 SSE 失败");
    String::from_utf8_lossy(&bytes).into_owned()
}

async fn memories(ctx: &TestContext, token: &str) -> Vec<Value> {
    let response = ctx.get_json("/api/memories?status=active", token).await;
    assert_eq!(response.status(), StatusCode::OK);
    body_json(response).await["items"]
        .as_array()
        .expect("缺少 items")
        .clone()
}

async fn messages(ctx: &TestContext, token: &str, conversation_id: &str) -> Vec<Value> {
    let response = ctx
        .get_json(
            &format!("/api/conversations/{conversation_id}/messages"),
            token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    body_json(response).await["items"]
        .as_array()
        .expect("缺少 items")
        .clone()
}

#[tokio::test]
async fn remember_command_writes_memory_and_returns_notice() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("expl-write").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        json!({ "content": "记住：我儿子叫小姚，2007 年出生", "client_msg_id": "c-1" }),
    )
    .await;

    assert!(stream.contains("\"notice\""), "完成事件应带提示：{stream}");
    assert!(stream.contains("已记住"), "提示应说明已保存：{stream}");
    assert!(stream.contains("小姚"), "提示应回显记住的内容：{stream}");

    let items = memories(&ctx, &token).await;
    assert_eq!(items.len(), 1, "显式指令应恰好写入一条记忆");
    assert_eq!(items[0]["content"], "我儿子叫小姚，2007 年出生");
    assert_eq!(items[0]["kind"], "profile", "无关键词时按画像归类");
    assert_eq!(items[0]["status"], "active", "显式写入应直接生效");
}

#[tokio::test]
async fn notice_is_persisted_between_user_and_answer() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("expl-order").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    send(
        &ctx,
        &token,
        &conversation_id,
        json!({ "content": "记住：我讨厌香菜", "client_msg_id": "c-1" }),
    )
    .await;

    // 接口倒序返回：assistant → system → user。
    let items = messages(&ctx, &token, &conversation_id).await;
    assert_eq!(items.len(), 3, "用户 + 提示 + 回答共三条");
    assert_eq!(items[0]["role"], "assistant");
    assert_eq!(items[1]["role"], "system");
    assert_eq!(items[1]["content"], "已记住：我讨厌香菜");
    assert_eq!(items[2]["role"], "user", "提示必须排在用户消息之后");

    let memories = memories(&ctx, &token).await;
    assert_eq!(memories[0]["kind"], "preference", "「讨厌」应归类为偏好");
}

#[tokio::test]
async fn missing_content_gets_hint_without_writing() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("expl-empty").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        json!({ "content": "记住", "client_msg_id": "c-1" }),
    )
    .await;

    assert!(
        stream.contains("要记住什么"),
        "缺内容要给可执行提示：{stream}"
    );
    assert!(!stream.contains("已记住"), "不该假装记住了");
    assert!(memories(&ctx, &token).await.is_empty());
}

#[tokio::test]
async fn secret_is_rejected_with_reason() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("expl-secret").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        json!({
            "content": "记住：我的密钥是 sk-abcdefghijklmnop1234",
            "client_msg_id": "c-1",
        }),
    )
    .await;

    assert!(stream.contains("没有保存"), "被拒也要说话：{stream}");
    assert!(!stream.contains("已记住"), "被拒不能回显已记住");
    assert!(
        memories(&ctx, &token).await.is_empty(),
        "密钥一类的内容绝不能落库"
    );
}

#[tokio::test]
async fn plain_messages_do_not_trigger() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("expl-plain").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    // 前缀不在开头：只是普通叙述。
    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        json!({ "content": "我记住你的建议了", "client_msg_id": "c-1" }),
    )
    .await;
    assert!(
        !stream.contains("\"notice\""),
        "普通消息不该产生提示：{stream}"
    );

    // 以问号结尾：用户在提问，不是下指令。
    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        json!({ "content": "记住我刚才说的了吗？", "client_msg_id": "c-2" }),
    )
    .await;
    assert!(!stream.contains("\"notice\""), "问句不该产生提示：{stream}");

    assert!(memories(&ctx, &token).await.is_empty());
    let items = messages(&ctx, &token, &conversation_id).await;
    assert_eq!(items.len(), 4, "两轮问答，各两条消息，没有额外提示");
}

#[tokio::test]
async fn replayed_message_keeps_single_notice_and_evidence() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("expl-replay").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let payload = json!({ "content": "记住：我不吃香菜", "client_msg_id": "c-1" });
    send(&ctx, &token, &conversation_id, payload.clone()).await;
    // 同一条消息重发（网络重试）：记忆与提示都不该再写一遍。
    send(&ctx, &token, &conversation_id, payload).await;

    let notices: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM messages WHERE role = 'system'")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(notices, 1, "重发不该多出一条提示");

    let evidence: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memory_evidence")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(evidence, 1, "重发不该重复追加证据");
}
