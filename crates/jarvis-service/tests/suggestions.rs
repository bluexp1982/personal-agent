//! 对话内派活：建议工具 → 落库 → SSE 下发 → 历史回读。
//!
//! 重点不是"模型会不会用工具"，而是**服务端有没有守住边界**：
//! 建议必须真实落库（历史可见）、必须经过技能校验、且不能凭空变成任务。

mod common;

use std::sync::Mutex;

use futures_util::stream;
use http_body_util::BodyExt;
use protocol::MessageRole;
use jarvis_service::chat::{ChatEvent, ChatMessage, ChatModel, ChatStream, ChatToolCall, ToolSpec};

#[derive(Debug)]
struct ScriptedModel {
    /// 从尾部取：构造时按"最后一轮在前"的顺序传（与 `chat_tools.rs` 一致）。
    rounds: Mutex<Vec<Vec<ChatEvent>>>,
}

impl ChatModel for ScriptedModel {
    fn stream(&self, _messages: Vec<ChatMessage>, _tools: Vec<ToolSpec>) -> ChatStream {
        let next = self
            .rounds
            .lock()
            .expect("锁中毒")
            .pop()
            .unwrap_or_else(|| vec![ChatEvent::Text("（无脚本）".to_string())]);
        Box::pin(stream::iter(next.into_iter().map(Ok)))
    }
}

fn suggest(skill: &str, reason: &str, input: serde_json::Value) -> ChatToolCall {
    ChatToolCall {
        id: "call_suggest_1".to_string(),
        name: "suggest_task".to_string(),
        arguments: serde_json::json!({
            "skill": skill,
            "reason": reason,
            "input": input,
        })
        .to_string(),
    }
}

async fn create_conversation(ctx: &common::TestContext, token: &str) -> String {
    let project_id = ctx.work_project("suggest").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "派活", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::CREATED);
    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

#[tokio::test]
async fn suggestion_is_streamed_and_persisted() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("suggest").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    // 覆盖装配：模型先请求建议工具，再给一句收尾文本。
    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel {
        rounds: Mutex::new(vec![
            vec![ChatEvent::Text("要不要我直接排一下？".to_string())],
            vec![ChatEvent::ToolCalls(vec![suggest(
                "trip-plan",
                "你提到下周三去上海",
                serde_json::json!({ "city": "上海", "date": "2026-10-28" }),
            )])],
        ]),
    }));

    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "下周三去上海，帮我安排下", "client_msg_id": "m-1" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("发送消息失败");
    assert_eq!(response.status(), axum::http::StatusCode::OK);

    let body = response
        .into_body()
        .collect()
        .await
        .expect("读取 SSE 失败")
        .to_bytes();
    let body = String::from_utf8_lossy(&body);

    // 完成事件里带建议：客户端不必再拉一次历史就能渲染卡片。
    assert!(
        body.contains("\"type\":\"message_completed\""),
        "缺少完成事件：{body}"
    );
    assert!(
        body.contains("\"task_suggestions\""),
        "完成事件缺少建议：{body}"
    );
    assert!(body.contains("\"skill\":\"trip-plan\""));
    assert!(body.contains("下周三去上海"));

    // 历史回读：建议已经落库，重进会话仍然看得到。
    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}/messages?limit=10"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let page = common::body_json(response).await;
    let items = page["items"].as_array().expect("items 应为数组");

    let assistant = items
        .iter()
        .find(|item| item["role"] == serde_json::json!(MessageRole::Assistant.as_str()))
        .expect("应有 assistant 消息");
    let suggestions = assistant["task_suggestions"]
        .as_array()
        .expect("assistant 消息应带建议");
    assert_eq!(suggestions.len(), 1);
    assert_eq!(suggestions[0]["skill"], "trip-plan");
    assert_eq!(suggestions[0]["input"]["city"], "上海");
}

#[tokio::test]
async fn unknown_skill_suggestion_is_not_persisted() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("suggest-bad").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel {
        rounds: Mutex::new(vec![
            vec![ChatEvent::Text("这个我办不了。".to_string())],
            vec![ChatEvent::ToolCalls(vec![suggest(
                "make-coffee",
                "编出来的技能",
                serde_json::json!({}),
            )])],
        ]),
    }));

    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "帮我煮杯咖啡" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("发送消息失败");
    let body = response
        .into_body()
        .collect()
        .await
        .expect("读取 SSE 失败")
        .to_bytes();
    let body = String::from_utf8_lossy(&body);

    assert!(
        !body.contains("make-coffee"),
        "不存在的技能不该出现在下发数据里：{body}"
    );
    assert!(
        !body.contains("\"task_suggestions\""),
        "被拒绝的建议不该下发：{body}"
    );

    // 也不该悄悄建出任务。
    let response = ctx.call(common::authed_get("/api/tasks", &token)).await;
    let page = common::body_json(response).await;
    assert_eq!(
        page["items"].as_array().map(Vec::len),
        Some(0),
        "对话不应自动创建任务"
    );
}
