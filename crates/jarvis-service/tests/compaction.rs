//! 会话上下文压缩。
//!
//! 覆盖五条主路径：
//! 1. 没压过时详情里根本没有 `compaction` 字段（旧客户端无感）；
//! 2. 手动整理能产出摘要、边界正确，且装配时真的用上了它；
//! 3. 整理失败**不覆盖**旧摘要，只在 `last_failure` 里留证据；
//! 4. 关掉压缩之后装配回到"最近 N 条"，不再注入摘要；
//! 5. 上游报上下文超长时，先压缩再重试一次，用户拿到的是一条正常回答。

mod common;

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use axum::http::StatusCode;
use futures_util::stream;
use http_body_util::BodyExt;
use jarvis_service::chat::{ChatEvent, ChatMessage, ChatModel, ChatStream, ToolSpec};
use jarvis_service::conversation;
use jarvis_service::model::{Completion, CompletionFuture, CompletionModel};
use protocol::MessageRole;

fn completion(text: &str, finish_reason: Option<&str>) -> Completion {
    Completion {
        text: text.to_string(),
        prompt_tokens: 120,
        completion_tokens: 30,
        tokens_estimated: false,
        finish_reason: finish_reason.map(str::to_string),
    }
}

/// 按脚本依次回复的摘要模型，并记录每次调用给的上限。
///
/// 用队列而不是单个回复，是因为"第一次空、第二次成功"这条重试路径需要
/// 两次不同的响应；同时靠 `limits` 断言重试确实抬了输出上限。
#[derive(Debug)]
struct FakeSummary {
    replies: Mutex<VecDeque<Result<Completion, String>>>,
    calls: AtomicUsize,
    limits: Mutex<Vec<u32>>,
}

impl FakeSummary {
    fn script(replies: Vec<Result<Completion, String>>) -> Arc<Self> {
        Arc::new(Self {
            replies: Mutex::new(VecDeque::from(replies)),
            calls: AtomicUsize::new(0),
            limits: Mutex::new(Vec::new()),
        })
    }

    fn ok(text: &str) -> Arc<Self> {
        Self::script(vec![Ok(completion(text, Some("stop")))])
    }

    fn failing(message: &str) -> Arc<Self> {
        Self::script(vec![Err(message.to_string())])
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }

    fn limits(&self) -> Vec<u32> {
        self.limits.lock().expect("锁中毒").clone()
    }
}

impl CompletionModel for FakeSummary {
    fn complete(
        &self,
        _system: &str,
        _prompt: &str,
        max_tokens: Option<u32>,
    ) -> CompletionFuture<'_> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.limits
            .lock()
            .expect("锁中毒")
            .push(max_tokens.unwrap_or(0));
        // 脚本只剩一条时重复用它：绝大多数用例只关心"每次都这样回"。
        let reply = {
            let mut replies = self.replies.lock().expect("锁中毒");
            if replies.len() > 1 {
                replies.pop_front().expect("已判非空")
            } else {
                replies
                    .front()
                    .cloned()
                    .unwrap_or_else(|| Err("脚本已用完".to_string()))
            }
        };
        Box::pin(async move { reply })
    }
}

/// 第一次调用报"上下文超长"，之后正常作答的对话模型。
#[derive(Debug)]
struct OverflowOnce {
    calls: AtomicUsize,
    text: String,
}

impl ChatModel for OverflowOnce {
    fn stream(&self, _messages: Vec<ChatMessage>, _tools: Vec<ToolSpec>) -> ChatStream {
        let call = self.calls.fetch_add(1, Ordering::SeqCst);
        let text = self.text.clone();
        Box::pin(stream::iter(vec![if call == 0 {
            Err("模型返回 400: {\"error\":{\"message\":\"context length exceeded\"}}".to_string())
        } else {
            Ok(ChatEvent::Text(text))
        }]))
    }
}

async fn create_conversation(ctx: &common::TestContext, token: &str, title: &str) -> String {
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": title }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

/// 直接往会话里塞 `count` 条一问一答，返回消息 id（按插入顺序）。
async fn seed_messages(
    ctx: &common::TestContext,
    conversation_id: &str,
    count: usize,
) -> Vec<String> {
    let mut ids = Vec::with_capacity(count);
    for index in 0..count {
        let (role, text) = if index % 2 == 0 {
            (MessageRole::User, format!("第 {index} 个问题"))
        } else {
            (MessageRole::Assistant, format!("第 {index} 个回答"))
        };
        let message =
            conversation::append_message(&ctx.state.pool, conversation_id, role, &text, None, None)
                .await
                .expect("追加消息失败");
        ids.push(message.id);
    }
    ids
}

/// 等摘要就绪。压缩是后台任务，不能假定 POST 返回时已经写完。
async fn wait_ready(ctx: &common::TestContext, conversation_id: &str) -> protocol::Compaction {
    let deadline =
        std::time::Instant::now() + std::time::Duration::from_millis(common::wait_limit_ms());
    while std::time::Instant::now() < deadline {
        let view = jarvis_service::compaction::view(&ctx.state.pool, conversation_id)
            .await
            .expect("读取压缩状态失败");
        if let Some(view) = view {
            if view.status == "ready" && view.summary.is_some() {
                return view;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("压缩未在 {}ms 内就绪", common::wait_limit_ms());
}

#[tokio::test]
async fn fresh_conversation_has_no_compaction() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("compaction-fresh").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-空").await;
    seed_messages(&ctx, &conversation_id, 2).await;

    let response = ctx
        .get_json(&format!("/api/conversations/{conversation_id}"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert!(
        body.get("compaction").is_none(),
        "没压过的会话不该下发 compaction：{body}"
    );
}

#[tokio::test]
async fn manual_compaction_produces_summary_and_assembly_uses_it() {
    // keep=2 + 8 条消息：边界落在第 6 条，留下最后 2 条不压。
    let ctx = common::setup_with(|config| {
        config.compaction.keep_messages = 2;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-manual").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-手动").await;
    let ids = seed_messages(&ctx, &conversation_id, 8).await;

    ctx.state.compaction.set_model(
        Some(FakeSummary::ok("- 用户在问一系列问题")),
        "fake-summary",
    );

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/compaction"),
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    let view = wait_ready(&ctx, &conversation_id).await;
    assert_eq!(view.source_messages, 6, "8 条里应折叠 6 条");
    assert_eq!(
        view.anchor_message_id.as_deref(),
        Some(ids[6].as_str()),
        "锚点应当是第一条没被折叠的消息"
    );
    assert_eq!(view.status, "ready");
    assert_eq!(view.model.as_deref(), Some("fake-summary"));

    // 装配：摘要前置，折叠范围内的消息不再进入。
    let active = jarvis_service::compaction::load_active(&ctx.state.pool, &conversation_id)
        .await
        .expect("读取摘要失败")
        .expect("摘要应可用");
    let messages = conversation::build_chat_messages_with(
        &ctx.state.pool,
        &conversation_id,
        20,
        Some(&active),
    )
    .await
    .expect("装配失败");
    assert_eq!(messages.len(), 3, "1 条摘要 + 2 条未折叠消息");
    let first = format!("{:?}", messages[0]);
    assert!(first.contains("摘要"), "首条应是摘要：{first}");

    // 详情接口能读到同一份摘要。
    let response = ctx
        .get_json(&format!("/api/conversations/{conversation_id}"), &token)
        .await;
    let body = common::body_json(response).await;
    assert_eq!(body["compaction"]["status"], "ready");
    assert!(body["compaction"]["summary"]
        .as_str()
        .unwrap_or("")
        .contains("问题"));
}

#[tokio::test]
async fn failed_attempt_keeps_previous_summary() {
    let ctx = common::setup_with(|config| {
        config.compaction.keep_messages = 2;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-fail").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-失败").await;
    seed_messages(&ctx, &conversation_id, 6).await;

    ctx.state
        .compaction
        .set_model(Some(FakeSummary::ok("- 第一版摘要")), "fake-summary");
    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/compaction"),
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);
    let first = wait_ready(&ctx, &conversation_id).await;

    // 再压一次，这次模型报错。先补两条新消息：上一次已经把能压的压完了，
    // 没有新增内容时"没东西可压"是对的，不该产生一条失败记录。
    seed_messages(&ctx, &conversation_id, 2).await;
    ctx.state.compaction.set_model(
        Some(FakeSummary::failing("模型返回 500: boom")),
        "fake-summary",
    );
    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/compaction"),
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    let deadline =
        std::time::Instant::now() + std::time::Duration::from_millis(common::wait_limit_ms());
    let mut view = None;
    while std::time::Instant::now() < deadline {
        if let Ok(Some(current)) =
            jarvis_service::compaction::view(&ctx.state.pool, &conversation_id).await
        {
            if current.last_failure.is_some() {
                view = Some(current);
                break;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let view = view.expect("失败记录应在时限内出现");

    // 旧摘要照旧生效，失败只是多了一行证据。
    assert_eq!(view.status, "ready");
    assert_eq!(view.summary.as_deref(), Some("- 第一版摘要"));
    assert_eq!(view.anchor_message_id, first.anchor_message_id);
    let failure = view.last_failure.expect("应有失败记录");
    assert!(
        failure.error.contains("上游报错"),
        "失败原因应分档：{}",
        failure.error
    );
}

#[tokio::test]
async fn disabling_stops_using_the_summary() {
    let ctx = common::setup_with(|config| {
        config.compaction.keep_messages = 2;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-disable").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-关闭").await;
    seed_messages(&ctx, &conversation_id, 6).await;

    ctx.state
        .compaction
        .set_model(Some(FakeSummary::ok("- 会被关掉的摘要")), "fake-summary");
    ctx.post_json(
        &format!("/api/conversations/{conversation_id}/compaction"),
        &token,
        &serde_json::json!({}),
    )
    .await;
    wait_ready(&ctx, &conversation_id).await;

    let response = ctx
        .delete(
            &format!("/api/conversations/{conversation_id}/compaction"),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 摘要记录还在库里，但不再下发、也不再注入。
    assert!(
        jarvis_service::compaction::load_active(&ctx.state.pool, &conversation_id)
            .await
            .expect("读取摘要失败")
            .is_none(),
        "关掉之后不该还有可用摘要"
    );
    let messages = conversation::build_chat_messages(&ctx.state.pool, &conversation_id, 20)
        .await
        .expect("装配失败");
    for message in &messages {
        let text = format!("{message:?}");
        assert!(
            !text.contains("会被关掉的摘要"),
            "关掉后不该再注入摘要：{text}"
        );
    }
}

#[tokio::test]
async fn overflow_compacts_then_retries_once() {
    let ctx = common::setup_with(|config| {
        config.compaction.keep_messages = 2;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-overflow").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-溢出").await;
    seed_messages(&ctx, &conversation_id, 6).await;

    ctx.state.compaction.set_model(
        Some(FakeSummary::ok("- 溢出时压出来的摘要")),
        "fake-summary",
    );
    let mut state = ctx.state.clone();
    state.chat_model = Some(Arc::new(OverflowOnce {
        calls: AtomicUsize::new(0),
        text: "压完之后的回答。".to_string(),
    }));

    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "继续", "client_msg_id": "overflow-1" }),
    );
    let response = tower::ServiceExt::oneshot(jarvis_service::api::router(state), request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), StatusCode::OK);

    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("读取响应失败")
        .to_bytes();
    let text = String::from_utf8_lossy(&bytes).to_string();

    assert!(
        text.contains("压完之后的回答。"),
        "重试后的回答应出现在流里：{text}"
    );
    assert!(
        text.contains("message_completed"),
        "应以完成事件收尾：{text}"
    );
    assert!(
        !text.contains("context length exceeded"),
        "不该把溢出错误推给用户"
    );

    let view = jarvis_service::compaction::view(&ctx.state.pool, &conversation_id)
        .await
        .expect("读取压缩状态失败")
        .expect("重试前应当已经写入摘要");
    assert_eq!(view.status, "ready");
}

#[tokio::test]
async fn manual_compaction_without_model_is_unavailable() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("compaction-nomodel").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-无模型").await;
    seed_messages(&ctx, &conversation_id, 4).await;

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/compaction"),
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "dependency_unavailable");
}

/// 等到出现一条失败记录；等不到就 panic。
async fn wait_failure(ctx: &common::TestContext, conversation_id: &str) -> protocol::Compaction {
    let deadline =
        std::time::Instant::now() + std::time::Duration::from_millis(common::wait_limit_ms());
    while std::time::Instant::now() < deadline {
        if let Ok(Some(view)) =
            jarvis_service::compaction::view(&ctx.state.pool, conversation_id).await
        {
            if view.last_failure.is_some() {
                return view;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("失败记录未在时限内出现");
}

/// 等到模型被调用到 `expected` 次；用于断言"后台任务到底有没有发请求"。
async fn wait_calls(model: &FakeSummary, expected: usize) {
    let deadline =
        std::time::Instant::now() + std::time::Duration::from_millis(common::wait_limit_ms());
    while std::time::Instant::now() < deadline {
        if model.calls() >= expected {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("模型调用次数没到 {expected}，实际 {}", model.calls());
}

#[tokio::test]
async fn empty_output_is_retried_with_bigger_budget() {
    let ctx = common::setup_with(|config| {
        config.compaction.keep_messages = 2;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-retry").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-重试").await;
    seed_messages(&ctx, &conversation_id, 6).await;

    // 第一次空（思考吃光额度的典型形态），第二次正常。
    let model = FakeSummary::script(vec![
        Ok(completion("", None)),
        Ok(completion("- 重试后的摘要", Some("stop"))),
    ]);
    ctx.state
        .compaction
        .set_model(Some(model.clone()), "fake-summary");

    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/compaction"),
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    let view = wait_ready(&ctx, &conversation_id).await;
    assert_eq!(view.summary.as_deref(), Some("- 重试后的摘要"));
    assert_eq!(model.calls(), 2, "空内容应当自动重试一次");
    assert_eq!(model.limits(), vec![1_200, 2_400], "第二次要把输出上限翻倍");
}

#[tokio::test]
async fn truncated_output_fails_with_a_specific_reason() {
    let ctx = common::setup_with(|config| {
        config.compaction.keep_messages = 2;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-truncated").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-截断").await;
    seed_messages(&ctx, &conversation_id, 6).await;

    // 两次都停在上限：半截摘要不能当背景，必须判失败并说清原因。
    let model = FakeSummary::script(vec![
        Ok(completion("半截摘要", Some("length"))),
        Ok(completion("还是半截", Some("length"))),
    ]);
    ctx.state
        .compaction
        .set_model(Some(model.clone()), "fake-summary");

    ctx.post_json(
        &format!("/api/conversations/{conversation_id}/compaction"),
        &token,
        &serde_json::json!({}),
    )
    .await;

    let view = wait_failure(&ctx, &conversation_id).await;
    assert!(view.summary.is_none(), "半截摘要不该落成可用摘要");
    let failure = view.last_failure.expect("应有失败记录");
    assert!(
        failure.error.contains("截断"),
        "失败原因要指向输出上限：{}",
        failure.error
    );
    assert_eq!(model.calls(), 2, "截断也要重试一次");
}

#[tokio::test]
async fn failure_cooldown_skips_automatic_retries() {
    let ctx = common::setup_with(|config| {
        config.context_messages = 4;
        config.compaction.keep_messages = 2;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-cooldown").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-冷却").await;
    seed_messages(&ctx, &conversation_id, 6).await;

    let model = FakeSummary::failing("模型返回 500: boom");
    ctx.state
        .compaction
        .set_model(Some(model.clone()), "fake-summary");

    ctx.post_json(
        &format!("/api/conversations/{conversation_id}/compaction"),
        &token,
        &serde_json::json!({}),
    )
    .await;
    wait_failure(&ctx, &conversation_id).await;
    assert_eq!(model.calls(), 1);

    // 冷却期内：即使条数与窗口都满足，也不该再花一次模型调用。
    ctx.state
        .compaction
        .maybe_spawn(&conversation_id, 0, 128_000)
        .await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(model.calls(), 1, "冷却期内不该再自动整理");
}

#[tokio::test]
async fn zero_cooldown_allows_automatic_retry() {
    let ctx = common::setup_with(|config| {
        config.context_messages = 4;
        config.compaction.keep_messages = 2;
        config.compaction.failure_cooldown_ms = 0;
    })
    .await;
    let (_, token) = ctx.pair_and_login("compaction-nocooldown").await;
    let conversation_id = create_conversation(&ctx, &token, "压缩-无冷却").await;
    seed_messages(&ctx, &conversation_id, 6).await;

    let model = FakeSummary::failing("模型返回 500: boom");
    ctx.state
        .compaction
        .set_model(Some(model.clone()), "fake-summary");

    ctx.post_json(
        &format!("/api/conversations/{conversation_id}/compaction"),
        &token,
        &serde_json::json!({}),
    )
    .await;
    wait_failure(&ctx, &conversation_id).await;
    assert_eq!(model.calls(), 1);

    ctx.state
        .compaction
        .maybe_spawn(&conversation_id, 0, 128_000)
        .await;
    wait_calls(&model, 2).await;
}
