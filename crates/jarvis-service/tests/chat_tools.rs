//! 对话工具调用的集成测试。
//!
//! 用假模型 + 假网关打真实 Router，验证三件事：
//! 1. 模型请求工具 → 文本分片仍能实时推出 → 回答落库时带 `sources`；
//! 2. 工具失败 → 没有来源、审计记录失败，回答可以是"未核实"；
//! 3. 工具调用写审计，且不落网页正文。

mod common;

use futures_util::stream;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use jarvis_service::chat::{ChatEvent, ChatMessage, ChatModel, ChatStream, ChatToolCall, ToolSpec};
use jarvis_service::tool_gateway::{Source, ToolError, ToolFuture, ToolGateway, ToolOutcome};

#[derive(Debug)]
struct ScriptedModel {
    rounds: Mutex<Vec<Vec<ChatEvent>>>,
}

impl ScriptedModel {
    fn new(rounds: Vec<Vec<ChatEvent>>) -> Self {
        Self {
            rounds: Mutex::new(rounds),
        }
    }
}

impl ChatModel for ScriptedModel {
    fn stream(&self, _messages: Vec<ChatMessage>, _tools: Vec<ToolSpec>) -> ChatStream {
        let next = self
            .rounds
            .lock()
            .expect("锁中毒")
            .pop()
            .unwrap_or_else(|| vec![ChatEvent::Text("（无脚本）".to_string())]);
        // pop 从尾部取，构造时按"最后一轮在前"顺序传。
        Box::pin(stream::iter(next.into_iter().map(Ok)))
    }
}

#[derive(Debug)]
struct FakeGateway {
    calls: AtomicUsize,
    outcome: Result<ToolOutcome, ToolError>,
}

impl ToolGateway for FakeGateway {
    fn call(
        &self,
        _tool: &str,
        _args: serde_json::Value,
    ) -> ToolFuture<'_, Result<ToolOutcome, ToolError>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let outcome = self.outcome.clone();
        Box::pin(async move { outcome })
    }
}

fn call(url: &str) -> ChatToolCall {
    ChatToolCall {
        id: "call_test_1".to_string(),
        name: "web_fetch".to_string(),
        arguments: serde_json::json!({ "url": url }).to_string(),
    }
}

async fn create_conversation(ctx: &common::TestContext, token: &str) -> String {
    let project_id = ctx.work_project("tools").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "工具测试", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::CREATED);
    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

#[tokio::test]
async fn answer_carries_sources_and_audit() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-tools").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    // 覆盖装配：假模型两轮（先请求工具，再给结论），假网关成功。
    // 正文按新约定不再内联来源——来源由 `sources` 单独承载。
    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("标题是 Example Domain。".to_string())],
        vec![ChatEvent::ToolCalls(vec![call("https://example.com")])],
    ])));
    state.tool_gateway = std::sync::Arc::new(FakeGateway {
        calls: AtomicUsize::new(0),
        outcome: Ok(ToolOutcome {
            summary: "Example Domain".to_string(),
            source: Some(Source::web("https://example.com", 1_700_000_000_000)),
            size: 1256,
        }),
    });

    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "example.com 的标题是什么", "client_msg_id": "m-1" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
    let body = String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8");

    assert!(
        body.contains("Example Domain"),
        "SSE 应包含回答文本：{body}"
    );
    assert!(body.contains("message_completed"));

    // 完成事件自带来源：客户端不必再拉一次历史就能渲染卡片
    let completed = body
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter_map(|payload| serde_json::from_str::<serde_json::Value>(payload).ok())
        .find(|event| event["type"] == "message_completed")
        .expect("SSE 应包含完成事件");
    assert_eq!(
        completed["sources"][0]["url"], "https://example.com",
        "完成事件应带来源：{completed}"
    );
    assert_eq!(
        completed["sources"][0]["fetched_at"], 1_700_000_000_000_i64,
        "完成事件应带采集时间：{completed}"
    );

    // 历史接口同样下发来源，且正文里不再重复地址
    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}/messages"),
            &token,
        ))
        .await;
    let page = common::body_json(response).await;
    let assistant = page["items"]
        .as_array()
        .expect("消息列表应为数组")
        .iter()
        .find(|item| item["role"] == "assistant")
        .expect("应有 assistant 消息")
        .clone();
    assert_eq!(
        assistant["sources"][0]["url"], "https://example.com",
        "消息接口应下发来源：{assistant}"
    );
    assert!(
        !assistant["content"]
            .as_str()
            .unwrap_or_default()
            .contains("采集于"),
        "正文不应再内联来源：{assistant}"
    );

    // 落库检查：assistant 消息的 content_json 必须带 sources
    let raw: String = sqlx::query_scalar(
        "SELECT content_json FROM messages WHERE conversation_id = ? AND role = 'assistant'",
    )
    .bind(&conversation_id)
    .fetch_one(&state.pool)
    .await
    .expect("没有 assistant 消息");

    let value: serde_json::Value = serde_json::from_str(&raw).expect("content_json 不是 JSON");
    assert_eq!(value["sources"][0]["url"], "https://example.com");
    assert_eq!(value["sources"][0]["fetched_at"], 1_700_000_000_000_i64);

    // 审计：有一次成功工具调用，且不含正文
    let records = jarvis_service::audit::list_by_trace(&state.pool, &conversation_id)
        .await
        .expect("读取审计失败");
    let tool_calls: Vec<_> = records
        .iter()
        .filter(|record| record.action == "tool.called")
        .collect();
    assert_eq!(tool_calls.len(), 1);
    assert_eq!(tool_calls[0].result, "ok");
    assert!(!tool_calls[0].detail_json.contains("Example Domain"));
}

// ---- 文件工具（read_file / preview_url）----

/// 建一个绑定到指定 tag 项目的会话，返回（会话 id，项目目录）。
async fn conversation_in(
    ctx: &common::TestContext,
    token: &str,
    tag: &str,
) -> (String, std::path::PathBuf) {
    let project_id = ctx.work_project(tag).await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "文件工具", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::CREATED);
    let body = common::body_json(response).await;
    let id = body["id"].as_str().expect("缺少会话 id").to_string();
    (id, ctx.dir.path().join(format!("ws-{tag}")))
}

fn tool_call(name: &str, args: serde_json::Value) -> ChatToolCall {
    ChatToolCall {
        id: format!("call_{name}"),
        name: name.to_string(),
        arguments: args.to_string(),
    }
}

/// 用给定脚本跑一轮对话，返回完整 SSE 正文。
async fn stream_script(
    ctx: &common::TestContext,
    token: &str,
    conversation_id: &str,
    rounds: Vec<Vec<ChatEvent>>,
) -> String {
    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel::new(rounds)));
    let router = jarvis_service::api::router(state);
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        token,
        &serde_json::json!({ "content": "看看这个项目", "client_msg_id": "m-file" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
    String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8")
}

fn completed_event(body: &str) -> serde_json::Value {
    body.lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter_map(|payload| serde_json::from_str::<serde_json::Value>(payload).ok())
        .find(|event| event["type"] == "message_completed")
        .expect("SSE 应包含完成事件")
}

#[tokio::test]
async fn read_file_tool_carries_doc_source() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-file-tool").await;
    let (conversation_id, project) = conversation_in(&ctx, &token, "files").await;
    std::fs::write(project.join("notes.md"), "# 笔记\n内容\n").expect("写文件失败");

    let body = stream_script(
        &ctx,
        &token,
        &conversation_id,
        vec![
            vec![ChatEvent::Text("已经看过笔记。".to_string())],
            vec![ChatEvent::ToolCalls(vec![tool_call(
                "read_file",
                serde_json::json!({ "path": "notes.md" }),
            )])],
        ],
    )
    .await;

    let completed = completed_event(&body);
    assert_eq!(
        completed["sources"][0]["kind"], "doc",
        "本地文件来源应按 doc 下发：{completed}"
    );
    assert_eq!(
        completed["sources"][0]["url"], "file://notes.md",
        "来源用项目相对路径：{completed}"
    );
    assert!(
        completed["sources"][0]["fetched_at"].as_i64().is_some(),
        "来源必须带采集时间：{completed}"
    );
}

#[tokio::test]
async fn read_file_outside_project_is_refused_without_source() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-file-escape").await;
    let (conversation_id, _project) = conversation_in(&ctx, &token, "escape").await;
    // 项目外确实存在这个文件：拒绝的理由必须是"越界"，不是"不存在"。
    std::fs::write(ctx.dir.path().join("outside.txt"), "secret").expect("写文件失败");

    let body = stream_script(
        &ctx,
        &token,
        &conversation_id,
        vec![
            vec![ChatEvent::Text("读不到。".to_string())],
            vec![ChatEvent::ToolCalls(vec![tool_call(
                "read_file",
                serde_json::json!({ "path": "../outside.txt" }),
            )])],
        ],
    )
    .await;

    assert!(
        !body.contains(r#""kind":"doc""#),
        "越界不应产出来源：{body}"
    );

    let records = jarvis_service::audit::list_by_trace(&ctx.state.pool, &conversation_id)
        .await
        .expect("读取审计失败");
    let failed = records
        .iter()
        .find(|record| record.action == "tool.called")
        .expect("应有工具审计");
    assert_eq!(failed.result, "error", "越界必须记失败");
    assert!(
        !failed.detail_json.contains("secret"),
        "审计不应记录文件内容：{}",
        failed.detail_json
    );
}

#[tokio::test]
async fn preview_url_emits_open_url_event() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-preview").await;
    let (conversation_id, _project) = conversation_in(&ctx, &token, "preview").await;

    let body = stream_script(
        &ctx,
        &token,
        &conversation_id,
        vec![
            vec![ChatEvent::Text("已经在浏览器里打开了。".to_string())],
            vec![ChatEvent::ToolCalls(vec![tool_call(
                "preview_url",
                serde_json::json!({ "url": "http://localhost:3000", "title": "本地预览" }),
            )])],
        ],
    )
    .await;

    assert!(
        body.contains(r#""type":"open_url""#),
        "SSE 应推 open_url：{body}"
    );
    // 地址会先被 `reqwest::Url` 规范化（补上根路径的斜杠）：客户端拿到的是可解析的完整 URL。
    assert!(
        body.contains(r#""url":"http://localhost:3000/""#),
        "事件应带目标地址：{body}"
    );
    assert!(
        body.contains(r#""title":"本地预览""#),
        "事件应带标题：{body}"
    );
}

#[tokio::test]
async fn preview_url_rejects_non_http_scheme() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-preview-deny").await;
    let (conversation_id, _project) = conversation_in(&ctx, &token, "preview-deny").await;

    let body = stream_script(
        &ctx,
        &token,
        &conversation_id,
        vec![
            vec![ChatEvent::Text("不能打开。".to_string())],
            vec![ChatEvent::ToolCalls(vec![tool_call(
                "preview_url",
                serde_json::json!({ "url": "file:///etc/passwd" }),
            )])],
        ],
    )
    .await;

    assert!(
        !body.contains(r#""type":"open_url""#),
        "非 http(s) 不应产生打开动作：{body}"
    );
}

/// 按工具名返回不同结果的网关：一次搜索、一次抓取要拿到两份不同的来源。
#[derive(Debug)]
struct RoutingGateway {
    calls: Mutex<Vec<(String, serde_json::Value)>>,
}

impl ToolGateway for RoutingGateway {
    fn call(
        &self,
        tool: &str,
        args: serde_json::Value,
    ) -> ToolFuture<'_, Result<ToolOutcome, ToolError>> {
        self.calls
            .lock()
            .expect("锁中毒")
            .push((tool.to_string(), args));

        let outcome = if tool == "web.search" {
            Ok(ToolOutcome {
                summary: "1. 候选一\n   https://example.com/a".to_string(),
                // 搜索不产出来源：候选页还没被读过。
                source: None,
                size: 40,
            })
        } else {
            Ok(ToolOutcome {
                summary: "候选一的正文".to_string(),
                source: Some(Source::web("https://example.com/a", 1_700_000_001_000)),
                size: 12,
            })
        };

        Box::pin(async move { outcome })
    }
}

#[tokio::test]
async fn search_produces_no_source_and_fetch_does() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-search").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    // pop 从尾部取：脚本按"最后一轮在前"排列 → 先搜索、再抓取、最后作答。
    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("答案是候选一的正文。".to_string())],
        vec![ChatEvent::ToolCalls(vec![ChatToolCall {
            id: "call_fetch".to_string(),
            name: "web_fetch".to_string(),
            arguments: serde_json::json!({ "url": "https://example.com/a" }).to_string(),
        }])],
        vec![ChatEvent::ToolCalls(vec![ChatToolCall {
            id: "call_search".to_string(),
            name: "web_search".to_string(),
            arguments: serde_json::json!({ "query": "热点", "limit": 3 }).to_string(),
        }])],
    ])));

    let gateway = std::sync::Arc::new(RoutingGateway {
        calls: Mutex::new(Vec::new()),
    });
    state.tool_gateway = gateway.clone();

    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "最近的热点是什么", "client_msg_id": "m-search" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::OK);

    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
    let body = String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8");
    let completed = body
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter_map(|payload| serde_json::from_str::<serde_json::Value>(payload).ok())
        .find(|event| event["type"] == "message_completed")
        .expect("SSE 应包含完成事件");

    // 只有一条来源：被真正读过的候选页。搜索不再把结果页当来源，
    // 否则客户端会多出一张"点开是搜索引擎"的卡片。
    let sources = completed["sources"].as_array().expect("应带来源");
    assert_eq!(sources.len(), 1, "只有读过的页面才算来源：{completed}");
    assert_eq!(sources[0]["url"], "https://example.com/a");

    // 参数归一：搜索的 limit 被夹到上限以内，未展开成字符串以外的形态。
    let calls = gateway.calls.lock().expect("锁中毒").clone();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].0, "web.search");
    assert_eq!(calls[0].1["limit"], 3);
    assert_eq!(calls[1].0, "web.fetch");

    // 审计：搜索记 `search:关键词`，抓取记 URL，两者都不含正文。
    let records = jarvis_service::audit::list_by_trace(&state.pool, &conversation_id)
        .await
        .expect("读取审计失败");
    let tool_calls: Vec<_> = records
        .iter()
        .filter(|record| record.action == "tool.called")
        .collect();
    assert_eq!(tool_calls.len(), 2);
    assert!(tool_calls[0].detail_json.contains("search:热点"));
    assert!(tool_calls[0].detail_json.contains("web.search"));
    assert!(!tool_calls[0].detail_json.contains("候选一"));
}

#[tokio::test]
async fn denied_tool_leaves_no_sources() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-denied").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text(
            "未核实：该地址指向内网，读不到".to_string(),
        )],
        vec![ChatEvent::ToolCalls(vec![call("https://127.0.0.1/")])],
    ])));
    state.tool_gateway = std::sync::Arc::new(FakeGateway {
        calls: AtomicUsize::new(0),
        outcome: Err(ToolError::Denied(
            "地址指向本机或内网，已拒绝: 127.0.0.1".to_string(),
        )),
    });

    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "blocked.test 是什么", "client_msg_id": "m-2" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
    let body = String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8");

    assert!(body.contains("未核实"), "回答应标注未核实：{body}");

    let raw: String = sqlx::query_scalar(
        "SELECT content_json FROM messages WHERE conversation_id = ? AND role = 'assistant'",
    )
    .bind(&conversation_id)
    .fetch_one(&state.pool)
    .await
    .expect("没有 assistant 消息");
    let value: serde_json::Value = serde_json::from_str(&raw).expect("content_json 不是 JSON");
    assert!(
        value.get("sources").is_none(),
        "失败时不应写入来源：{value}"
    );

    let records = jarvis_service::audit::list_by_trace(&state.pool, &conversation_id)
        .await
        .expect("读取审计失败");
    let failed: Vec<_> = records
        .iter()
        .filter(|record| record.action == "tool.called" && record.result == "error")
        .collect();
    assert_eq!(failed.len(), 1);
}

#[tokio::test]
async fn model_failure_keeps_user_message() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-fail").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    #[derive(Debug)]
    struct FailingModel;

    impl ChatModel for FailingModel {
        fn stream(&self, _messages: Vec<ChatMessage>, _tools: Vec<ToolSpec>) -> ChatStream {
            Box::pin(stream::iter(vec![Err("网关超时".to_string())]))
        }
    }

    let mut state = ctx.state.clone();
    state.chat_model = Some(std::sync::Arc::new(FailingModel));

    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "在吗", "client_msg_id": "m-3" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
    let body = String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8");

    assert!(
        body.contains("dependency_unavailable"),
        "应返回错误事件：{body}"
    );

    // 用户消息仍在，助手消息没有落库（避免半截回答污染历史）
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM messages WHERE conversation_id = ? AND role = 'assistant'",
    )
    .bind(&conversation_id)
    .fetch_one(&state.pool)
    .await
    .expect("查询失败");
    assert_eq!(count, 0);
}

/// 模型说"打开 clock.html"之后，客户端必须收到一条可加载的 open_url。
///
/// 这条链路跨了四层（工具 → 预览站 → 事件 → 客户端），任何一层错都表现为
/// "点了没反应"，光靠单测看不出端到端是否通。
#[tokio::test]
async fn preview_file_tool_emits_open_url_with_display() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("preview-file").await;
    let (conversation_id, project) = conversation_in(&ctx, &token, "preview-file").await;
    std::fs::write(project.join("clock.html"), "<h1>时钟</h1>").expect("写文件失败");

    let mut state = ctx.state.clone();
    let preview =
        jarvis_service::web_preview::WebPreview::start(state.pool.clone(), state.config.clone())
            .await
            .expect("预览站启动失败");
    state.web_preview = Some(preview.clone());
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("已经打开 clock.html。".to_string())],
        vec![ChatEvent::ToolCalls(vec![tool_call(
            "preview_url",
            serde_json::json!({ "path": "clock.html", "title": "时钟" }),
        )])],
    ])));

    let router = jarvis_service::api::router(state);
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({
            "content": "在本项目中预览下 clock.html",
            "client_msg_id": "m-preview-file"
        }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
    let body = String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8");

    let event = body
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter_map(|payload| serde_json::from_str::<serde_json::Value>(payload).ok())
        .find(|event| event["type"] == "open_url")
        .expect("应推 open_url 事件");

    let url = event["url"].as_str().expect("缺少 url");
    assert!(
        url.starts_with(&format!("http://127.0.0.1:{}/f/", preview.port())),
        "预览地址应指向预览站：{url}"
    );
    assert!(url.ends_with("/clock.html"), "{url}");
    assert_eq!(
        event["display"], "ws-preview-file/clock.html",
        "地址栏显示的是项目名 + 相对路径：{event}"
    );
    assert_eq!(event["title"], "时钟", "{event}");

    preview.stop();
}

/// 工具成功、但模型这一轮一个字都没说的形态（线上真实出现过的）。
///
/// 这时预览站已经把页面准备好了，UI 动作必须照常推——模型说不说话
/// 是另一回事，用户要的是那个页面。之前这里提前 return，页面就被吞了。
#[tokio::test]
async fn preview_opens_even_when_model_gives_no_text() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("preview-silent").await;
    let (conversation_id, project) = conversation_in(&ctx, &token, "preview-silent").await;
    std::fs::write(project.join("clock.html"), "<h1>时钟</h1>").expect("写文件失败");

    let mut state = ctx.state.clone();
    let preview =
        jarvis_service::web_preview::WebPreview::start(state.pool.clone(), state.config.clone())
            .await
            .expect("预览站启动失败");
    state.web_preview = Some(preview.clone());
    // 第二轮（先被取走）是空流：模型调完工具后就沉默了。
    state.chat_model = Some(std::sync::Arc::new(ScriptedModel::new(vec![
        vec![],
        vec![ChatEvent::ToolCalls(vec![tool_call(
            "preview_url",
            serde_json::json!({ "path": "clock.html" }),
        )])],
    ])));

    let router = jarvis_service::api::router(state);
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        &token,
        &serde_json::json!({ "content": "预览下 clock.html", "client_msg_id": "m-preview-silent" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取 SSE 失败");
    let body = String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8");

    let open = body
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter_map(|payload| serde_json::from_str::<serde_json::Value>(payload).ok())
        .find(|event| event["type"] == "open_url");
    assert!(
        open.is_some(),
        "工具成功时，即使模型没给正文也必须打开页面：{body}"
    );
    assert!(
        body.contains("dependency_unavailable"),
        "同时仍要告诉用户模型没回答：{body}"
    );

    preview.stop();
}
