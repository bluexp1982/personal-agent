//! 编码代理的集成测试：真端口、假上游。
//!
//! 覆盖的是"钱和权限"这条线：令牌、模型白名单、用量记账、预算与上游错误透传。
//! 这些点一旦错了，表现是"任务看着跑完了但账单对不上"，很难事后发现。

use std::net::SocketAddr;

use axum::http::{header, StatusCode};
use axum::routing::post;
use axum::Router;
use jarvis_service::code_proxy::CodeProxy;
use jarvis_service::config::Config;
use jarvis_service::db;

const KEY_ENV: &str = "PERSONAL_AGENT_TEST_CODE_PROXY_KEY";

/// 假上游：正常返回 SSE（带 usage），模型名为 `boom` 时返回 500。
fn upstream_router() -> Router {
    Router::new().route(
        "/v1/chat/completions",
        post(|body: axum::body::Bytes| async move {
            let model = serde_json::from_slice::<serde_json::Value>(&body)
                .ok()
                .and_then(|value| {
                    value
                        .get("model")
                        .and_then(|model| model.as_str())
                        .map(str::to_string)
                })
                .unwrap_or_default();

            if model == "boom" {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    [("content-type", "application/json")],
                    r#"{"error":{"message":"upstream exploded"}}"#.to_string(),
                );
            }

            // 带缓存命中的用量：用来验证预算只算折扣后的部分。
            if model == "cached-model" {
                let frames = concat!(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\n",
                    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":10,",
                    "\"prompt_tokens_details\":{\"cached_tokens\":90}}}\n\n",
                    "data: [DONE]\n\n",
                );
                return (
                    StatusCode::OK,
                    [("content-type", "text/event-stream")],
                    frames.to_string(),
                );
            }

            // 把"代理有没有补 stream_options.include_usage"原样回显给测试。
            if model == "echo-usage" {
                let include_usage = serde_json::from_slice::<serde_json::Value>(&body)
                    .ok()
                    .and_then(|value| {
                        value
                            .get("stream_options")
                            .and_then(|options| options.get("include_usage"))
                            .and_then(serde_json::Value::as_bool)
                    })
                    .unwrap_or(false);
                return (
                    StatusCode::OK,
                    [("content-type", "application/json")],
                    format!(
                        r#"{{"usage":{{"prompt_tokens":1,"completion_tokens":1}},"include_usage":{include_usage}}}"#
                    ),
                );
            }

            let frames = concat!(
                "data: {\"choices\":[{\"delta\":{\"content\":\"收到\"}}]}\n\n",
                "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":31,\"completion_tokens\":7}}\n\n",
                "data: [DONE]\n\n",
            );

            (
                StatusCode::OK,
                [("content-type", "text/event-stream")],
                frames.to_string(),
            )
        }),
    )
}

async fn start_upstream() -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定假上游失败");
    let addr = listener.local_addr().expect("取端口失败");
    tokio::spawn(async move {
        axum::serve(listener, upstream_router()).await.ok();
    });
    addr
}

struct Harness {
    proxy: std::sync::Arc<CodeProxy>,
    url: String,
    pool: sqlx::SqlitePool,
    config: Config,
    _dir: tempfile::TempDir,
}

async fn harness(budget_calls: u32) -> Harness {
    std::env::set_var(KEY_ENV, "real-upstream-key");

    let dir = tempfile::tempdir().expect("创建临时目录失败");
    let pool = db::connect(&dir.path().join("agent.db"))
        .await
        .expect("连接数据库失败");
    db::migrate(&pool).await.expect("迁移失败");

    let upstream = start_upstream().await;

    let mut config = Config::default();
    config.code.enabled = true;
    config.code.allow_roots = vec![dir.path().to_path_buf()];
    config.code.upstream.base_url = Some(format!("http://{upstream}/v1"));
    config.code.upstream.model = Some("test-model".to_string());
    config.code.upstream.allowed_models = vec![
        "test-model".to_string(),
        "echo-usage".to_string(),
        "cached-model".to_string(),
    ];
    config.code.upstream.api_key_env = Some(KEY_ENV.to_string());
    config.code.upstream.timeout_ms = 5_000;
    config.code.worktree_dir = Some(dir.path().join("worktrees"));
    config.code.timeout_ms = Some(30_000);
    // 工具级审批 TTL 必须落在任务墙钟之内（默认 120s 装不进 30s 的任务）。
    config.code.tool_approval.ttl_ms = 10_000;
    config.task_timeout_ms = 60_000;
    config.code.budget.max_model_calls = budget_calls;
    config.code.budget.max_tokens = 10_000;
    config.validate().expect("配置应合法");

    let proxy = CodeProxy::start(&config, pool.clone())
        .await
        .expect("启动代理失败");
    let url = format!("{}/internal/code/v1/chat/completions", proxy.base_url());

    Harness {
        proxy,
        url,
        pool,
        config,
        _dir: dir,
    }
}

async fn call(url: &str, token: Option<&str>, model: &str) -> (StatusCode, String) {
    let body = serde_json::json!({
        "model": model,
        "stream": true,
        "messages": [{"role": "user", "content": "hi"}],
    })
    .to_string();

    let mut request = reqwest::Client::new()
        .post(url)
        .header(header::CONTENT_TYPE, "application/json")
        .body(body);
    if let Some(token) = token {
        request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }

    let response = request.send().await.expect("请求代理失败");
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    (status, text)
}

#[tokio::test(flavor = "multi_thread")]
async fn rejects_missing_or_invalid_token() {
    let h = harness(5).await;

    let (status, body) = call(&h.url, None, "test-model").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(body.contains("missing_token"), "{body}");

    let (status, body) = call(&h.url, Some("not-a-token"), "test-model").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(body.contains("invalid_token"), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn rejects_models_outside_the_allowlist() {
    let h = harness(5).await;
    let token = h.proxy.mint("task_1").expect("应有令牌");

    let (status, body) = call(&h.url, Some(&token), "some-other-model").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("model_not_allowed"), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn streams_bytes_verbatim_and_records_real_usage() {
    let h = harness(5).await;
    let token = h.proxy.mint("task_1").expect("应有令牌");

    let (status, body) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"收到\"}}]}\n\n",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":31,\"completion_tokens\":7}}\n\n",
            "data: [DONE]\n\n",
        ),
        "SSE 必须逐字节透传"
    );

    let view = h.proxy.view();
    let (task_id, totals) = view.usage.first().expect("应有用量记录");
    assert_eq!(task_id, "task_1");
    assert_eq!(totals.calls, 1);
    assert_eq!(totals.prompt_tokens, 31);
    assert_eq!(totals.completion_tokens, 7);
    assert!(!totals.estimated, "上游给了 usage 就不该标估算");

    let rows: i64 = sqlx::query_scalar("SELECT count(*) FROM audit_log WHERE action = ?")
        .bind("code.model_call")
        .fetch_one(&h.pool)
        .await
        .expect("查审计失败");
    assert!(rows > 0, "用量必须写审计");
}

async fn call_with_system(url: &str, token: &str, system: &str) -> StatusCode {
    let body = serde_json::json!({
        "model": "test-model",
        "stream": true,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": "hi"},
        ],
    })
    .to_string();

    reqwest::Client::new()
        .post(url)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(body)
        .send()
        .await
        .expect("请求代理失败")
        .status()
}

#[tokio::test(flavor = "multi_thread")]
async fn cached_tokens_are_credited_against_the_budget() {
    let h = harness(5).await;
    let token = h.proxy.mint("task_1").expect("应有令牌");

    let (status, _) = call(&h.url, Some(&token), "cached-model").await;
    assert_eq!(status, StatusCode::OK);

    let view = h.proxy.view();
    let (_, totals) = view.usage.first().expect("应有用量记录");
    assert_eq!(totals.prompt_tokens, 100, "体积照实记");
    assert_eq!(totals.cached_tokens, 90, "命中缓存的部分要单独记");
    assert_eq!(totals.raw_tokens(), 110);
    assert_eq!(totals.tokens(), 20, "预算只算没命中的 10 + 输出 10");
}

#[tokio::test(flavor = "multi_thread")]
async fn prefix_drift_is_audited_once() {
    let h = harness(5).await;
    let token = h.proxy.mint("task_1").expect("应有令牌");

    assert_eq!(
        call_with_system(&h.url, &token, "你是代码助手").await,
        StatusCode::OK
    );
    assert_eq!(
        call_with_system(&h.url, &token, "你是代码助手").await,
        StatusCode::OK
    );

    let rows: i64 = sqlx::query_scalar("SELECT count(*) FROM audit_log WHERE action = ?")
        .bind("code.prefix_changed")
        .fetch_one(&h.pool)
        .await
        .expect("查审计失败");
    assert_eq!(rows, 0, "前缀没变就不该报");

    // 系统提示里塞了时间戳——最常见的缓存杀手。
    assert_eq!(
        call_with_system(&h.url, &token, "你是代码助手，现在是 12:03").await,
        StatusCode::OK
    );
    let rows: i64 = sqlx::query_scalar("SELECT count(*) FROM audit_log WHERE action = ?")
        .bind("code.prefix_changed")
        .fetch_one(&h.pool)
        .await
        .expect("查审计失败");
    assert_eq!(rows, 1, "前缀变了必须留痕");
}

#[tokio::test(flavor = "multi_thread")]
async fn streaming_requests_ask_the_upstream_for_real_usage() {
    let h = harness(5).await;
    let token = h.proxy.mint("task_1").expect("应有令牌");

    let (status, body) = call(&h.url, Some(&token), "echo-usage").await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        body.contains(r#""include_usage":true"#),
        "流式请求必须补 stream_options.include_usage，否则只能按字节估算：{body}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn refuses_further_calls_after_budget_is_spent() {
    let h = harness(1).await;
    let token = h.proxy.mint("task_1").expect("应有令牌");

    let (status, _) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::OK);

    let (status, body) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert!(body.contains("budget_exceeded"), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn retry_starts_with_a_fresh_budget_window() {
    let h = harness(1).await;
    let token = h.proxy.mint("task_1").expect("应有令牌");
    let (status, _) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "这一轮已经超了");

    // 重试：重新发令牌就是新窗口，否则用户点了「重试」还是立刻失败。
    let token = h.proxy.mint("task_1").expect("应有令牌");
    let (status, _) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::OK, "重试不能背着上一轮的用量");
}

#[tokio::test(flavor = "multi_thread")]
async fn budget_failure_notifies_the_executor() {
    let h = harness(1).await;
    let notified = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let sink = notified.clone();
    h.proxy
        .on_budget_exceeded(std::sync::Arc::new(move |task_id: String| {
            sink.lock().expect("锁").push(task_id);
        }));

    let token = h.proxy.mint("task_9").expect("应有令牌");
    let (status, _) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(&h.url, Some(&token), "test-model").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);

    let seen = notified.lock().expect("锁").clone();
    assert!(!seen.is_empty(), "超预算必须让执行器停手");
    // 每条到达预算的请求都会通知一次（cancel 本身幂等），但只能指向本任务。
    assert!(seen.iter().all(|task| task == "task_9"), "{seen:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn passes_upstream_errors_through() {
    let h = harness(5).await;

    // 让白名单接受 boom，才能走到"上游报错"这条分支。
    let mut config = h.config.clone();
    config.code.upstream.allowed_models = vec!["test-model".to_string(), "boom".to_string()];
    let proxy = CodeProxy::start(&config, h.pool.clone())
        .await
        .expect("重启代理失败");
    let url = format!("{}/internal/code/v1/chat/completions", proxy.base_url());
    let token = proxy.mint("task_1").expect("应有令牌");

    let (status, body) = call(&url, Some(&token), "boom").await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert!(
        body.contains("upstream exploded"),
        "上游错误应原样透传: {body}"
    );
}

/// 通用 POST：按目标协议的路径发一次请求，返回状态与正文。
async fn post_json(
    url: &str,
    token: Option<&str>,
    body: serde_json::Value,
) -> (StatusCode, String) {
    let mut request = reqwest::Client::new()
        .post(url)
        .header(header::CONTENT_TYPE, "application/json")
        .body(body.to_string());
    if let Some(token) = token {
        request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    let response = request.send().await.expect("请求代理失败");
    let status = response.status();
    (status, response.text().await.unwrap_or_default())
}

#[tokio::test(flavor = "multi_thread")]
async fn responses_route_translates_both_directions() {
    // Codex 只讲 Responses API：请求要被映射成 chat，响应要再映射回去。
    let h = harness(5).await;
    let url = format!("{}/internal/code/v1/responses", h.proxy.base_url());
    let token = h.proxy.mint("task_resp").expect("应有令牌");

    let (status, body) = post_json(
        &url,
        Some(&token),
        serde_json::json!({
            "model": "test-model",
            "stream": true,
            "input": [
                {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "你是编码 agent"}]},
                {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "打个招呼"}]}
            ],
            "tools": [{"type": "function", "name": "exec_command", "parameters": {"type": "object"}}]
        }),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "{body}");
    for event in [
        "response.created",
        "response.output_text.delta",
        "response.completed",
    ] {
        assert!(body.contains(event), "缺事件 {event}: {body}");
    }
    // 用量仍由代理记账：上游回的 31/7 要出现在末帧里。
    assert!(body.contains("\"input_tokens\":31"), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn responses_route_shares_the_same_guards() {
    let h = harness(5).await;
    let url = format!("{}/internal/code/v1/responses", h.proxy.base_url());

    // 没有令牌
    let (status, body) = post_json(
        &url,
        None,
        serde_json::json!({"model": "test-model", "input": "hi"}),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(body.contains("missing_token"), "{body}");

    // 模型越界：新协议不能绕过白名单
    let token = h.proxy.mint("task_guard").expect("应有令牌");
    let (status, body) = post_json(
        &url,
        Some(&token),
        serde_json::json!({"model": "gpt-5", "input": "hi"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("model_not_allowed"), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn messages_route_and_count_tokens_work() {
    // Claude Code 讲 Anthropic 协议；count_tokens 是它启动时的一次探测。
    let h = harness(5).await;
    let base = h.proxy.base_url();
    let token = h.proxy.mint("task_msg").expect("应有令牌");

    let (status, body) = post_json(
        &format!("{base}/internal/code/v1/messages"),
        Some(&token),
        serde_json::json!({
            "model": "test-model",
            "max_tokens": 256,
            "stream": true,
            "system": [{"type": "text", "text": "你是编码 agent"}],
            "messages": [{"role": "user", "content": "打个招呼"}]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    for event in ["message_start", "content_block_delta", "message_stop"] {
        assert!(body.contains(event), "缺事件 {event}: {body}");
    }

    let (status, body) = post_json(
        &format!("{base}/internal/code/v1/count_tokens"),
        Some(&token),
        serde_json::json!({"model": "test-model", "messages": [{"role": "user", "content": "hi"}]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("input_tokens"), "{body}");
}
