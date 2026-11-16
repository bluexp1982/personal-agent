//! 会话标题生成：首条提问 → 标题（短则直接取，长则模型概括）。
//!
//! 覆盖四件事：
//! 1. 长提问交给模型，标题清洗掉引号与句号后落库；
//! 2. 没配模型时退回截断，短提问原样使用；
//! 3. 用户自己起过名的会话不被覆盖，也不浪费一次模型调用；
//! 4. 历史「新会话」能被回填。

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::http::StatusCode;
use jarvis_service::model::{Completion, CompletionFuture, CompletionModel};
use jarvis_service::state::AppState;

/// 直接把「模型输出」定死的假实现：标题生成的断言只关心清洗与落库。
#[derive(Debug)]
struct FakeCompletion {
    title: String,
    calls: AtomicUsize,
}

impl FakeCompletion {
    fn new(title: &str) -> Self {
        Self {
            title: title.to_string(),
            calls: AtomicUsize::new(0),
        }
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl CompletionModel for FakeCompletion {
    fn complete(
        &self,
        _system: &str,
        _prompt: &str,
        _max_tokens: Option<u32>,
    ) -> CompletionFuture<'_> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let title = self.title.clone();
        Box::pin(async move {
            Ok(Completion {
                text: title,
                ..Completion::default()
            })
        })
    }
}

/// 带模型的上下文：只替换 `completion_model`，对话仍走确定性回答。
fn state_with_model(ctx: &common::TestContext, model: Arc<FakeCompletion>) -> AppState {
    let mut state = ctx.state.clone();
    state.completion_model = Some(model);
    state
}

async fn create_conversation(
    ctx: &common::TestContext,
    token: &str,
    title: Option<&str>,
) -> String {
    let project_id = ctx.work_project("titles").await;
    let payload = match title {
        Some(title) => serde_json::json!({ "title": title, "project_id": project_id }),
        None => serde_json::json!({ "project_id": project_id }),
    };
    let response = ctx.post_json("/api/conversations", token, &payload).await;
    assert_eq!(response.status(), StatusCode::CREATED);
    common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string()
}

async fn send_message(state: &AppState, token: &str, id: &str, content: &str) {
    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{id}/messages"),
        token,
        &serde_json::json!({ "content": content }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), StatusCode::OK);
    axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
}

async fn wait_for_title(ctx: &common::TestContext, token: &str, id: &str, expected: &str) {
    let deadline = Instant::now() + Duration::from_millis(common::wait_limit_ms());
    let mut last = String::new();

    while Instant::now() < deadline {
        let response = ctx
            .call(common::authed_get(
                &format!("/api/conversations/{id}"),
                token,
            ))
            .await;
        if response.status() == StatusCode::OK {
            let body = common::body_json(response).await;
            last = body["title"].as_str().unwrap_or_default().to_string();
            if last == expected {
                return;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    panic!(
        "标题未在 {}ms 内变为「{expected}」，最后一次是「{last}」",
        common::wait_limit_ms()
    );
}

#[tokio::test]
async fn long_first_question_is_summarized_by_model() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("title-model").await;
    let conversation_id = create_conversation(&ctx, &token, None).await;

    let model = Arc::new(FakeCompletion::new("“上海出差穿搭建议”。"));
    let state = state_with_model(&ctx, model.clone());

    send_message(
        &state,
        &token,
        &conversation_id,
        "下周三去上海出差三天，帮我看看该带什么衣服，顺便看看会不会下雨",
    )
    .await;

    wait_for_title(&ctx, &token, &conversation_id, "上海出差穿搭建议").await;
    assert_eq!(model.calls(), 1, "长提问应当只问一次模型");
}

#[tokio::test]
async fn short_question_becomes_title_without_model() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("title-short").await;
    let conversation_id = create_conversation(&ctx, &token, None).await;

    // 没有模型：标题直接取提问本身。
    send_message(&ctx.state, &token, &conversation_id, "明天上海天气").await;

    wait_for_title(&ctx, &token, &conversation_id, "明天上海天气").await;
}

#[tokio::test]
async fn custom_title_is_never_overwritten() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("title-custom").await;
    let conversation_id = create_conversation(&ctx, &token, Some("我的会话")).await;

    let model = Arc::new(FakeCompletion::new("不该出现的标题"));
    let state = state_with_model(&ctx, model.clone());

    send_message(
        &state,
        &token,
        &conversation_id,
        "这是一个很长很长的提问，长到足够触发模型概括，但用户已经自己命名了",
    )
    .await;

    // 给后台任务一点时间：它应该在看标题时就放弃，不调用模型。
    tokio::time::sleep(Duration::from_millis(200)).await;

    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    let body = common::body_json(response).await;
    assert_eq!(body["title"], "我的会话");
    assert_eq!(model.calls(), 0, "用户命名的会话不该消耗模型调用");
}

#[tokio::test]
async fn backfill_fills_existing_default_titles() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("title-backfill").await;
    let conversation_id = create_conversation(&ctx, &token, None).await;

    // 绕开 send_message 直接落一条用户消息，模拟"标题机制上线前"的历史数据。
    jarvis_service::conversation::append_message(
        &ctx.state.pool,
        &conversation_id,
        protocol::MessageRole::User,
        "帮我整理这周的工作记录并写一份周报，周五之前要交给主管",
        None,
        None,
    )
    .await
    .expect("写入历史消息失败");

    let model = Arc::new(FakeCompletion::new("周报整理"));
    let updated = jarvis_service::title::backfill(&ctx.state.pool, Some(model.as_ref()))
        .await
        .expect("回填应当成功");

    assert_eq!(updated, 1, "只有一条占位标题的会话需要回填");

    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    let body = common::body_json(response).await;
    assert_eq!(body["title"], "周报整理");
}
