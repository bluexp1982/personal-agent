//! 停止生成：显式取消，而不是"客户端断开"。
//!
//! 三个断言点：
//! 1. `POST /stop` 之后 SSE 由服务端自己收尾（不必断流），并带 `finish_reason=stopped`；
//! 2. 已生成的部分落库，历史接口读回来也是 `stopped`；
//! 3. 对已经结束的轮次再发一次 stop 仍是 204：连点与网络重试都不该看到失败。

mod common;

use std::sync::Mutex;

use axum::http::StatusCode;
use futures_util::stream;
use http_body_util::BodyExt;
use jarvis_service::chat::{ChatEvent, ChatMessage, ChatModel, ChatStream, ToolSpec};
use tokio::sync::mpsc;

/// 由用例逐片驱动的模型：什么时候吐字、什么时候结束，全在测试手里。
///
/// 用它才能稳定地"停在一句话中间"，而不是跟真实模型的时序赛跑。
#[derive(Debug)]
struct ManualModel {
    rx: Mutex<Option<mpsc::Receiver<ChatEvent>>>,
}

impl ChatModel for ManualModel {
    fn stream(&self, _messages: Vec<ChatMessage>, _tools: Vec<ToolSpec>) -> ChatStream {
        let rx = self
            .rx
            .lock()
            .expect("锁中毒")
            .take()
            .expect("这一轮只应调用一次模型");
        Box::pin(stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (Ok(event), rx))
        }))
    }
}

async fn create_conversation(ctx: &common::TestContext, token: &str, tag: &str) -> String {
    let project_id = ctx.work_project(tag).await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "停止测试", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

/// 一帧一帧往下读，直到 `until` 出现。
///
/// 不用"读完整段再断言"：停止请求必须在流还没结束时发出去，
/// 否则测的就成了"事后补一刀"。
async fn read_until(body: &mut axum::body::Body, received: &mut String, until: &str) {
    while !received.contains(until) {
        let frame = body
            .frame()
            .await
            .expect("读取 SSE 帧失败")
            .expect("SSE 在命中目标之前就结束了");
        if let Some(data) = frame.data_ref() {
            received.push_str(&String::from_utf8_lossy(data));
        }
    }
}

/// 把剩余帧读完，拼进同一份文本。
async fn drain(body: &mut axum::body::Body, received: &mut String) {
    while let Some(frame) = body.frame().await {
        let frame = frame.expect("读取 SSE 帧失败");
        if let Some(data) = frame.data_ref() {
            received.push_str(&String::from_utf8_lossy(data));
        }
    }
}

#[tokio::test]
async fn stop_persists_partial_answer() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-stop").await;
    let conversation_id = create_conversation(&ctx, &token, "chat-stop").await;

    let (delta_tx, delta_rx) = mpsc::channel::<ChatEvent>(8);
    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(ManualModel {
        rx: Mutex::new(Some(delta_rx)),
    }));
    let router = jarvis_service::api::router(state);

    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "写点什么", "client_msg_id": "stop-1" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), StatusCode::OK);

    let mut body = response.into_body();
    let mut received = String::new();

    // 先喂一句、确认它已经出现在流里再喊停：断言的是"停在半截"，
    // 而不是"停在还没开始"那种另一种分支（那个分支不落库）。
    delta_tx
        .send(ChatEvent::Text("第一句。".to_string()))
        .await
        .expect("喂分片失败");
    read_until(&mut body, &mut received, "第一句。").await;

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/stop"),
            &token,
            &serde_json::json!({ "client_msg_id": "stop-1" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 流应当由服务端收尾，而不是等客户端断开。
    drain(&mut body, &mut received).await;
    assert!(
        received.contains(r#""finish_reason":"stopped""#),
        "收尾事件应标明被停止：{received}"
    );

    let (content_json, finish_reason): (String, Option<String>) = sqlx::query_as(
        "SELECT content_json, finish_reason FROM messages \
         WHERE conversation_id = ? AND role = 'assistant'",
    )
    .bind(&conversation_id)
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查不到回答");

    assert!(
        content_json.contains("第一句。"),
        "已生成的部分应落库：{content_json}"
    );
    assert_eq!(
        finish_reason.as_deref(),
        Some("stopped"),
        "终态应记成 stopped，否则历史里会显示成已完成"
    );

    // 历史接口与实时事件同源：重进会话也要看到同一个终态。
    let page = common::body_json(
        ctx.get_json(
            &format!("/api/conversations/{conversation_id}/messages"),
            &token,
        )
        .await,
    )
    .await;
    assert_eq!(page["items"][0]["finish_reason"], "stopped");
}

#[tokio::test]
async fn stop_unknown_turn_is_idempotent() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-stop-miss").await;
    let conversation_id = create_conversation(&ctx, &token, "chat-stop-miss").await;

    // 从没发送过这个 client_msg_id：既不该 404 也不该 500，
    // 客户端连点两下或网络重试时会走到这里。
    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/stop"),
            &token,
            &serde_json::json!({ "client_msg_id": "never-sent" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}
