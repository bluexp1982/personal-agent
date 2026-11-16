//! 召回：作用域隔离、中文两字命中、来源卡片、空命中诚实回答、预算。

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::http::StatusCode;
use serde_json::{json, Value};
use jarvis_service::chat::{
    self, ChatEvent, ChatLimits, ChatMessage, ChatModel, ChatStream, LocalTool, LocalToolOutcome,
    StopSignal, ToolSpec,
};
use jarvis_service::config::Config;
use jarvis_service::memory::retrieve::{RecallQuery, RecallScope};
use jarvis_service::tool_gateway::{Source, ToolError, ToolFuture, ToolGateway, ToolOutcome};
use tokio::sync::mpsc;

use common::{body_json, setup_with, TestContext};

async fn memory_enabled() -> TestContext {
    setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.recall.enabled = true;
    })
    .await
}

async fn create_memory(
    ctx: &TestContext,
    token: &str,
    kind: &str,
    content: &str,
    project_id: Option<&str>,
) -> String {
    let mut body = json!({
        "kind": kind,
        "content": content,
        "evidence_quote": content,
    });
    if let Some(project_id) = project_id {
        body["scope"] = json!("project");
        body["project_id"] = json!(project_id);
    }

    let response = ctx.post_json("/api/memories", token, &body).await;
    assert_eq!(response.status(), StatusCode::CREATED, "写入记忆失败");
    body_json(response).await["memory"]["id"]
        .as_str()
        .expect("缺少记忆 id")
        .to_string()
}

#[tokio::test]
async fn two_char_chinese_query_hits() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("recall-two-char").await;
    create_memory(&ctx, &token, "preference", "报销走飞书审批", None).await;

    // 两字查询是 FTS5 直索的盲区：这里能命中说明 bigram 预分词生效了。
    let outcome = ctx
        .state
        .memory
        .recall(RecallQuery {
            text: "报销".to_string(),
            scope: RecallScope::for_mode(false, None),
            kinds: Vec::new(),
            limit: 8,
            now: jarvis_service::clock::now_ms(),
            conversation_id: None,
            message_id: None,
        })
        .await;

    assert_eq!(outcome.hits.len(), 1, "两字查询应命中");
    assert!(outcome.hits[0].memory.content.contains("报销"));
}

#[tokio::test]
async fn scope_isolation_blocks_other_project() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("recall-scope").await;
    let project_a = ctx.work_project("ws-a").await;
    let project_b = ctx.work_project("ws-b").await;

    create_memory(
        &ctx,
        &token,
        "project",
        "这个仓库的时间统一用毫秒",
        Some(&project_a),
    )
    .await;

    let now = jarvis_service::clock::now_ms();
    let query = |project: &str| RecallQuery {
        text: "毫秒".to_string(),
        scope: RecallScope::for_mode(false, Some(project.to_string())),
        kinds: Vec::new(),
        limit: 8,
        now,
        conversation_id: None,
        message_id: None,
    };

    let same = ctx.state.memory.recall(query(&project_a)).await;
    assert_eq!(same.hits.len(), 1, "同一仓库应命中");

    let other = ctx.state.memory.recall(query(&project_b)).await;
    assert!(other.hits.is_empty(), "跨仓库不该串味");
}

#[tokio::test]
async fn code_scope_hides_personal_memory() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("recall-code").await;
    create_memory(&ctx, &token, "profile", "常住示例市东城区", None).await;
    create_memory(&ctx, &token, "preference", "回答先给结论", None).await;

    let now = jarvis_service::clock::now_ms();
    let outcome = ctx
        .state
        .memory
        .recall(RecallQuery {
            text: "东城 结论".to_string(),
            scope: RecallScope::for_mode(true, None),
            kinds: Vec::new(),
            limit: 8,
            now,
            conversation_id: None,
            message_id: None,
        })
        .await;

    assert_eq!(outcome.hits.len(), 1, "Git 项目会话只能看到工程偏好");
    assert_eq!(outcome.hits[0].memory.kind.as_str(), "preference");
}

#[tokio::test]
async fn no_hit_returns_honest_empty() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("recall-empty").await;
    create_memory(&ctx, &token, "preference", "不吃香菜", None).await;

    let outcome = ctx
        .state
        .memory
        .recall(RecallQuery {
            text: "量子计算".to_string(),
            scope: RecallScope::for_mode(false, None),
            kinds: Vec::new(),
            limit: 8,
            now: jarvis_service::clock::now_ms(),
            conversation_id: None,
            message_id: None,
        })
        .await;

    assert!(outcome.hits.is_empty());
}

// ---------------------------------------------------------------------------
// 工具层：预算与来源
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct ScriptedModel {
    /// 依次返回的工具调用脚本：每轮一个 (name, arguments)。
    script: std::sync::Mutex<Vec<(String, String)>>,
}

impl ChatModel for ScriptedModel {
    fn stream(&self, _messages: Vec<ChatMessage>, _tools: Vec<ToolSpec>) -> ChatStream {
        let next = self.script.lock().expect("锁失效").pop();
        let events = match next {
            Some((name, arguments)) => vec![
                Ok(ChatEvent::ToolCalls(vec![chat::ChatToolCall {
                    id: "call_1".to_string(),
                    name,
                    arguments,
                }])),
                Ok(ChatEvent::Usage(Default::default())),
            ],
            None => vec![
                Ok(ChatEvent::Text("回答".to_string())),
                Ok(ChatEvent::Usage(Default::default())),
            ],
        };
        Box::pin(futures_util::stream::iter(events))
    }
}

#[derive(Debug)]
struct NoopGateway;

impl ToolGateway for NoopGateway {
    fn call(&self, _tool: &str, _args: Value) -> ToolFuture<'_, Result<ToolOutcome, ToolError>> {
        // 本用例不该走到外部工具：走到了说明分发顺序错了。
        Box::pin(async move { Err(ToolError::Unavailable("不该调用".to_string())) })
    }
}

#[derive(Debug)]
struct CountingLocal {
    calls: Arc<AtomicUsize>,
}

#[async_trait::async_trait]
impl LocalTool for CountingLocal {
    fn spec(&self) -> ToolSpec {
        ToolSpec::memory_recall()
    }

    async fn call(&self, _arguments: &str) -> LocalToolOutcome {
        let count = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        LocalToolOutcome {
            content: format!("第 {count} 次命中"),
            sources: vec![Source::memory("mem_1", 0)],
            ok: true,
            target: "memory:hits=1".to_string(),
            ui: Vec::new(),
        }
    }
}

async fn run_with_local(
    local: &dyn LocalTool,
    max_calls_per_turn: usize,
) -> (chat::ChatOutcome, String) {
    let model = ScriptedModel {
        script: std::sync::Mutex::new(vec![
            (
                "memory_recall".to_string(),
                json!({"query": "报销"}).to_string(),
            ),
            (
                "memory_recall".to_string(),
                json!({"query": "报销"}).to_string(),
            ),
            (
                "memory_recall".to_string(),
                json!({"query": "报销"}).to_string(),
            ),
        ]),
    };
    let gateway = NoopGateway;
    let (tx, _rx) = mpsc::channel::<chat::ChatPush>(16);
    let stop = StopSignal::default();
    let local_tools = chat::LocalToolRegistry::new().with(local);
    let outcome = chat::run(
        &model,
        &gateway,
        &local_tools,
        vec![ChatMessage::user("我上次说报销走哪个系统")],
        vec![ToolSpec::memory_recall()],
        &[],
        ChatLimits::without_media(
            max_calls_per_turn,
            8,
            4,
            std::time::Duration::from_secs(30),
        ),
        &tx,
        &stop,
    )
    .await
    .expect("引擎不应失败");

    (outcome, String::new())
}

#[tokio::test]
async fn recall_counts_against_tool_budget() {
    let calls = Arc::new(AtomicUsize::new(0));
    let local = CountingLocal {
        calls: calls.clone(),
    };

    let (_outcome, _) = run_with_local(&local, 2).await;

    // 模型脚本里有三次调用，预算只给两次：第三次必须被预算拦住。
    assert_eq!(
        calls.load(Ordering::SeqCst),
        2,
        "本地工具必须与外部工具共用同一份调用预算"
    );
}

#[tokio::test]
async fn recall_result_carries_memory_source() {
    let calls = Arc::new(AtomicUsize::new(0));
    let local = CountingLocal { calls };

    let (outcome, _) = run_with_local(&local, 1).await;

    assert_eq!(outcome.sources.len(), 1);
    assert_eq!(outcome.sources[0].kind, protocol::SourceKind::Memory);
    assert_eq!(outcome.sources[0].memory_id.as_deref(), Some("mem_1"));
    assert_eq!(outcome.calls.len(), 1);
    assert!(outcome.calls[0].tool == "memory_recall");
}

#[tokio::test]
async fn answer_marks_memory_used() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("recall-used").await;
    let id = create_memory(&ctx, &token, "preference", "回答先给结论再给依据", None).await;

    let query = RecallQuery {
        text: "回答风格".to_string(),
        scope: RecallScope::for_mode(false, None),
        kinds: Vec::new(),
        limit: 8,
        now: jarvis_service::clock::now_ms(),
        conversation_id: Some("conv_1".to_string()),
        message_id: None,
    };

    let outcome = ctx.state.memory.recall(query.clone()).await;
    assert_eq!(outcome.hits.len(), 1, "先要有命中");
    jarvis_service::memory::retrieve::log_hits(ctx.state.memory.pool(), &query, &outcome.hits)
        .await
        .expect("写召回日志失败");

    let answer = "按你之前的要求，先给结论再给依据：结论是可以。";
    let marked = ctx
        .state
        .memory
        .touch_used(std::slice::from_ref(&id), answer)
        .await;
    assert_eq!(marked, 1, "回答里出现了记忆正文的连续片段");

    let used: (i64,) = sqlx::query_as("SELECT used FROM memory_recall_log WHERE memory_id = ?")
        .bind(&id)
        .fetch_one(ctx.state.memory.pool())
        .await
        .expect("查询失败");
    assert_eq!(used.0, 1);

    let use_count: (i64,) = sqlx::query_as("SELECT use_count FROM memories WHERE id = ?")
        .bind(&id)
        .fetch_one(ctx.state.memory.pool())
        .await
        .expect("查询失败");
    assert_eq!(use_count.0, 1);

    // 幂等：没有新的未标记日志时不再加一。
    let again = ctx
        .state
        .memory
        .touch_used(std::slice::from_ref(&id), answer)
        .await;
    assert_eq!(again, 0);
    let use_count: (i64,) = sqlx::query_as("SELECT use_count FROM memories WHERE id = ?")
        .bind(&id)
        .fetch_one(ctx.state.memory.pool())
        .await
        .expect("查询失败");
    assert_eq!(use_count.0, 1, "重复回填不该刷高使用次数");
}

#[tokio::test]
async fn short_answer_does_not_mark_used() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("recall-not-used").await;
    let id = create_memory(&ctx, &token, "preference", "不吃香菜", None).await;

    let query = RecallQuery {
        text: "香菜".to_string(),
        scope: RecallScope::for_mode(false, None),
        kinds: Vec::new(),
        limit: 8,
        now: jarvis_service::clock::now_ms(),
        conversation_id: Some("conv_2".to_string()),
        message_id: None,
    };
    let outcome = ctx.state.memory.recall(query.clone()).await;
    jarvis_service::memory::retrieve::log_hits(ctx.state.memory.pool(), &query, &outcome.hits)
        .await
        .expect("写召回日志失败");

    // 回答里没有出现这条记忆：不该算"用过"。
    let marked = ctx
        .state
        .memory
        .touch_used(&[id], "好的，我知道了，下次注意。")
        .await;
    assert_eq!(marked, 0);
}
