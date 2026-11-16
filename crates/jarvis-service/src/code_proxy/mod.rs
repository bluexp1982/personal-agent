//! 编码任务专用的模型代理。
//!
//! 存在的理由只有一个：**模型请求必须经过服务端，用量才可见**。
//! opencode 能直接用自己的登录态跑，但那样一来花了多少 token 永远是个黑盒。
//!
//! 边界：
//! - 只绑回环（`code.proxy_bind` 由 `Config::validate` 强制），不跟着 `/api` 暴露；
//! - 只服务编码任务：令牌按任务发、按任务吊销，TTL 等于任务超时；
//! - **SSE 按原始字节透传**，只在旁边解析 `usage`：重打包事件流是最容易
//!   把 opencode 的 AI SDK 弄崩的一步；
//! - 真 key 只在这里出现，客户端带来的 `Authorization` 一律被丢弃。

pub(crate) mod anthropic;
pub(crate) mod prefix;
pub(crate) mod responses;
pub(crate) mod tokens;
pub(crate) mod translate;
pub(crate) mod upstream;
pub(crate) mod usage;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use axum::routing::post;
use axum::Router;
use futures_util::StreamExt;
use serde_json::json;
use sqlx::SqlitePool;
use tokio::sync::mpsc;

use protocol::{ApiError, ErrorCode, TaskState};

use crate::audit::{self, AuditEntry};
use crate::config::{CodeBudgetConfig, Config};
use crate::task;

use self::tokens::{TaskToken, TokenStore};
use self::upstream::Upstream;
use self::usage::{estimate_tokens, UsageParser, UsageSample, UsageTable, UsageTotals};

/// 代理路径。opencode 会在 `baseURL` 后面自己拼 `/chat/completions`。
const PROXY_PATH: &str = "/internal/code/v1/chat/completions";
/// Codex 在 `base_url` 后面自己拼 `/responses`（`wire_api = "responses"`）。
const RESPONSES_PATH: &str = "/internal/code/v1/responses";
/// Claude Code 在 `ANTHROPIC_BASE_URL` 后面自己拼 `/v1/messages`。
const MESSAGES_PATH: &str = "/internal/code/v1/messages";
/// Claude Code 启动时会探一下 token 计数；上游没有对应能力，我们本地估算。
const COUNT_TOKENS_PATH: &str = "/internal/code/v1/count_tokens";

/// 请求体上限。编码任务的上下文可以很大，但仍要有硬顶。
const MAX_REQUEST_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug)]
pub struct CodeProxy {
    addr: SocketAddr,
    tokens: Arc<Mutex<TokenStore>>,
    usage: Arc<Mutex<UsageTable>>,
    /// 缺密钥时为 `None`：此时启动不失败，但每个请求都回 `code_unavailable`。
    upstream: Option<Arc<Upstream>>,
    budget: CodeBudgetConfig,
    pool: SqlitePool,
    provider: String,
    model: String,
    /// 令牌 TTL，与任务超时对齐：任务被判悬空时令牌也会随之失效。
    token_ttl_ms: i64,
    /// 预算命中时的额外动作（终止 CLI）。装配阶段注入：执行器本身持有代理句柄，
    /// 构造时互相引用会成环。
    budget_hook: Mutex<Option<BudgetHook>>,
    /// 每个任务上一次见过的请求前缀指纹，用来发现"缓存杀手"。
    prefixes: Mutex<prefix::PrefixWatch>,
}

/// 预算钩子的薄包装：`dyn Fn` 没有 `Debug`，而 `CodeProxy` 派生了 `Debug`。
#[derive(Clone)]
struct BudgetHook(Arc<dyn Fn(String) + Send + Sync>);

impl std::fmt::Debug for BudgetHook {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BudgetHook")
    }
}

/// 管理面展示用的快照。
#[derive(Debug, Clone)]
pub struct ProxyView {
    pub addr: String,
    pub provider: String,
    pub model: String,
    pub has_upstream: bool,
    pub active_tasks: Vec<String>,
    pub usage: Vec<(String, UsageTotals)>,
}

impl ProxyView {
    /// 仍持有令牌的任务数。
    pub fn active_tokens(&self) -> usize {
        self.active_tasks.len()
    }
}

impl CodeProxy {
    /// 绑定回环端口并开始服务。
    pub async fn start(config: &Config, pool: SqlitePool) -> std::io::Result<Arc<Self>> {
        let upstream = match Upstream::from_config(config) {
            Ok(upstream) => Some(Arc::new(upstream)),
            Err(err) => {
                // 启动不失败：让服务先把管理面跑起来，用户在 /admin/code 就能看到原因。
                tracing::warn!(
                    %err,
                    "编码代理没有可用上游，编码任务会返回 code_unavailable"
                );
                None
            }
        };

        let addr: SocketAddr = config.code.proxy_bind.parse().map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("code.proxy_bind 非法: {}", config.code.proxy_bind),
            )
        })?;

        let listener = tokio::net::TcpListener::bind(addr).await?;
        let local = listener.local_addr()?;

        let proxy = Arc::new(Self {
            addr: local,
            tokens: Arc::new(Mutex::new(TokenStore::default())),
            usage: Arc::new(Mutex::new(UsageTable::default())),
            budget_hook: Mutex::new(None),
            prefixes: Mutex::new(prefix::PrefixWatch::default()),
            upstream,
            budget: config.code.budget.clone(),
            pool,
            provider: config.code.provider.clone(),
            model: config.code_upstream_model().to_string(),
            token_ttl_ms: config.task_timeout_ms,
        });

        let router = proxy.router();
        tokio::spawn(async move {
            if let Err(err) = axum::serve(listener, router).await {
                tracing::error!(%err, "编码代理监听退出");
            }
        });

        Ok(proxy)
    }

    fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route(PROXY_PATH, post(handle))
            .route(RESPONSES_PATH, post(handle_responses))
            .route(MESSAGES_PATH, post(handle_messages))
            .route(COUNT_TOKENS_PATH, post(handle_count_tokens))
            .layer(DefaultBodyLimit::max(MAX_REQUEST_BYTES))
            .with_state(self.clone())
    }

    /// worker 用的基地址（不含 `/internal/code/v1`，那是 provider 拼的）。
    pub fn base_url(&self) -> String {
        format!("http://{}", self.addr)
    }

    pub fn has_upstream(&self) -> bool {
        self.upstream.is_some()
    }

    /// 给任务发一枚令牌。没有上游时返回 `None`，调用方据此拒绝创建任务。
    pub fn mint(&self, task_id: &str) -> Option<String> {
        self.upstream.as_ref()?;
        // 新一轮执行 = 新的预算窗口。重试同一个任务时不能背着上一轮的用量，
        // 否则"重试"会在第一次请求就被判超预算。历史用量在审计表里，不丢。
        if let Ok(mut usage) = self.usage.lock() {
            usage.forget(task_id);
        }
        if let Ok(mut prefixes) = self.prefixes.lock() {
            prefixes.forget(task_id);
        }
        let mut store = self.tokens.lock().ok()?;
        Some(store.mint(task_id, self.token_ttl_ms))
    }

    /// 预算命中时通知执行器停手。
    ///
    /// 由装配层注入而不是构造时传入：执行器持有代理句柄，双向强引用会成环。
    pub fn on_budget_exceeded(&self, hook: Arc<dyn Fn(String) + Send + Sync>) {
        if let Ok(mut slot) = self.budget_hook.lock() {
            *slot = Some(BudgetHook(hook));
        }
    }

    /// 任务终态后吊销令牌并清掉内存里的用量。
    ///
    /// 用量明细已经在审计表（`code.model_call`）里，这里只是一份"活跃任务"的缓存，
    /// 不清就会随任务数一直长。
    pub fn forget(&self, task_id: &str) {
        if let Ok(mut store) = self.tokens.lock() {
            store.revoke_task(task_id);
        }
        if let Ok(mut usage) = self.usage.lock() {
            usage.forget(task_id);
        }
        if let Ok(mut prefixes) = self.prefixes.lock() {
            prefixes.forget(task_id);
        }
    }

    pub fn view(&self) -> ProxyView {
        let mut tokens = self
            .tokens
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let usage = self
            .usage
            .lock()
            .map(|table| table.snapshot())
            .unwrap_or_default();

        ProxyView {
            addr: self.base_url(),
            provider: self.provider.clone(),
            model: self.model.clone(),
            has_upstream: self.has_upstream(),
            active_tasks: tokens.active_tasks(),
            usage,
        }
    }

    async fn record(
        &self,
        task_id: &str,
        usage: Option<UsageSample>,
        prompt_fallback_chars: u64,
        completion_fallback_chars: u64,
    ) -> UsageTotals {
        let totals = {
            let mut table = self
                .usage
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            table.record(
                task_id,
                usage,
                prompt_fallback_chars,
                completion_fallback_chars,
            )
        };

        // 不记 prompt 与正文，只记计数——与 `task.model_call` 的既有口径一致。
        audit::record(
            &self.pool,
            &AuditEntry::new(task_id, "worker", "code.model_call", "ok")
                .target(task_id)
                .detail(json!({
                    "prompt_tokens": totals.prompt_tokens,
                    "completion_tokens": totals.completion_tokens,
                    // 命中前缀缓存的部分：仍算在 prompt_tokens 里，但不按全价计入预算。
                    "cached_tokens": totals.cached_tokens,
                    "tokens_estimated": totals.estimated,
                    "calls": totals.calls,
                })),
        )
        .await;

        totals
    }

    fn budget_hit(&self, totals: UsageTotals) -> bool {
        totals.calls >= self.budget.max_model_calls as u64
            || totals.tokens() >= self.budget.max_tokens
    }

    /// 预算命中时把任务落成 `budget_exceeded`。
    ///
    /// 由代理来落而不是等 CLI 报错：超预算必须立刻停，否则"可控成本"是空话。
    async fn mark_budget_exceeded(&self, task_id: &str, totals: UsageTotals) {
        let error = ApiError::new(
            ErrorCode::BudgetExceeded,
            format!(
                "code budget exceeded: {} tokens / {} calls",
                totals.tokens(),
                totals.calls
            ),
            format!(
                "编码任务已超出预算（{} tokens / {} 次调用），可调整 code.budget 后重试",
                totals.tokens(),
                totals.calls
            ),
        );

        tracing::warn!(
            task_id,
            tokens = totals.tokens(),
            "编码任务超预算，标记失败"
        );
        if let Err(err) =
            task::transition(&self.pool, task_id, TaskState::Failed, Some(&error)).await
        {
            tracing::warn!(%err, task_id, "超预算后无法转为 failed（可能已终态）");
        }

        // 走的是"代理自己判失败"，绕过了 worker 的失败路径；不在这里收尾，
        // 半路停下的步骤会一直挂在「进行中」，用户看不出任务是为什么停的。
        crate::worker::events::settle_steps(&self.pool, task_id, false).await;

        // 让 CLI 立刻停手：否则它还会继续发请求（每次都 429），并发位一直被占着。
        let hook = self.budget_hook.lock().ok().and_then(|slot| slot.clone());
        if let Some(hook) = hook {
            (hook.0)(task_id.to_string());
        }
    }
}

/// 给流式请求补 `stream_options.include_usage=true`。
///
/// 不补这一格，OpenAI 兼容上游的流式末帧不带 `usage`，代理只能按字节估算用量——
/// 实测会把一次正常编码任务放大 3~4 倍、提前撞上预算。这里**只增字段**：
/// 不删、不改任何上下文；body 不是 JSON、不是流式、或已经写了这一格时原样返回。
fn ensure_stream_usage(body: Bytes) -> Bytes {
    let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return body;
    };
    if !value
        .get("stream")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
    {
        return body;
    }
    let Some(object) = value.as_object_mut() else {
        return body;
    };
    let options = object
        .entry("stream_options")
        .or_insert_with(|| serde_json::json!({}));
    let Some(options) = options.as_object_mut() else {
        // 形状不认识就不擅自改，原样过去。
        return body;
    };
    if options.contains_key("include_usage") {
        return body;
    }
    options.insert("include_usage".into(), serde_json::Value::Bool(true));
    serde_json::to_vec(&value).map(Bytes::from).unwrap_or(body)
}

/// 一次请求走的是哪条协议。
///
/// `Chat` 是原样透传（opencode / codebuddy）；另外两个是把上游 chat 流按目标协议
/// 重新渲染。渲染只影响响应方向，请求方向在进入这里之前已经统一成 chat。
enum RouteKind {
    Chat,
    Responses {
        model: String,
        response_id: String,
        created_at: i64,
    },
    Anthropic {
        model: String,
        message_id: String,
    },
}

/// 三处入口共用的前置：令牌、上游、模型白名单、预算。
///
/// 抽出来不是为了少写几行，而是为了**保证三条路由的安全属性完全一致**：
/// 任何新协议都不该有机会跳过白名单或预算检查。
///
/// `Err` 直接返回 `Response` 而不是装箱：三处调用点都要立刻 `return Err(..)`，
/// 装箱只会给每条错误路径多一次分配。clippy 的新 lint 会按 128 字节报警。
#[allow(clippy::result_large_err)]
async fn authorize(
    proxy: &Arc<CodeProxy>,
    headers: &HeaderMap,
    model: &str,
) -> Result<(String, Arc<Upstream>), Response> {
    let Some(token) = bearer(headers) else {
        return Err(openai_error(
            StatusCode::UNAUTHORIZED,
            "missing_token",
            "缺少 Authorization: Bearer <token>",
        ));
    };

    let entry: TaskToken = {
        let mut store = proxy
            .tokens
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match store.resolve(&token) {
            Some(entry) => entry,
            None => {
                return Err(openai_error(
                    StatusCode::UNAUTHORIZED,
                    "invalid_token",
                    "任务令牌无效或已过期",
                ));
            }
        }
    };

    let Some(upstream) = proxy.upstream.clone() else {
        return Err(openai_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "upstream_unavailable",
            "服务端未配置模型密钥（见 code.upstream.api_key_env）",
        ));
    };

    if !upstream.allows(model) {
        return Err(openai_error(
            StatusCode::BAD_REQUEST,
            "model_not_allowed",
            &format!(
                "模型 {model:?} 不在允许列表内（允许：{}）",
                upstream.models().join(", ")
            ),
        ));
    }

    // 预算前置检查：已经超了就不再往上游发，省一次钱。
    let current = proxy
        .usage
        .lock()
        .map(|table| table.get(&entry.task_id))
        .unwrap_or_default();
    if proxy.budget_hit(current) {
        proxy.mark_budget_exceeded(&entry.task_id, current).await;
        return Err(openai_error(
            StatusCode::TOO_MANY_REQUESTS,
            "budget_exceeded",
            "编码任务已超出预算，请求被拒绝",
        ));
    }

    Ok((entry.task_id, upstream))
}

fn model_of(body: &[u8]) -> String {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("model")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_default()
}

/// 处理一次模型请求（OpenAI chat/completions，原样透传）。
async fn handle(State(proxy): State<Arc<CodeProxy>>, headers: HeaderMap, body: Bytes) -> Response {
    let model = model_of(&body);
    match authorize(&proxy, &headers, &model).await {
        Ok((task_id, upstream)) => forward(proxy, task_id, upstream, body, RouteKind::Chat).await,
        Err(response) => response,
    }
}

/// Codex 的 Responses 请求：映射成 chat 再发，响应再映射回去。
async fn handle_responses(
    State(proxy): State<Arc<CodeProxy>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let model = model_of(&body);
    let (task_id, upstream) = match authorize(&proxy, &headers, &model).await {
        Ok(pair) => pair,
        Err(response) => return response,
    };

    let chat = match responses::to_chat(&body) {
        Ok(chat) => chat,
        Err(message) => return openai_error(StatusCode::BAD_REQUEST, "invalid_request", &message),
    };

    let kind = RouteKind::Responses {
        model,
        response_id: format!("resp_{}", next_id()),
        created_at: now_seconds(),
    };
    forward(proxy, task_id, upstream, Bytes::from(chat), kind).await
}

/// Claude Code 的 Messages 请求：映射成 chat 再发，响应再映射回去。
async fn handle_messages(
    State(proxy): State<Arc<CodeProxy>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let model = model_of(&body);
    let (task_id, upstream) = match authorize(&proxy, &headers, &model).await {
        Ok(pair) => pair,
        Err(response) => return response,
    };

    let chat = match anthropic::to_chat(&body) {
        Ok(chat) => chat,
        Err(message) => return openai_error(StatusCode::BAD_REQUEST, "invalid_request", &message),
    };

    let kind = RouteKind::Anthropic {
        model,
        message_id: format!("msg_{}", next_id()),
    };
    forward(proxy, task_id, upstream, Bytes::from(chat), kind).await
}

/// Claude Code 的 token 估算。不转发上游：它只用于上下文管理，不参与计费。
async fn handle_count_tokens(
    State(proxy): State<Arc<CodeProxy>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let model = model_of(&body);
    if let Err(response) = authorize(&proxy, &headers, &model).await {
        return response;
    }
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(anthropic::count_tokens(&body)))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response_stub())
}

/// 统一的上游转发与记账。
async fn forward(
    proxy: Arc<CodeProxy>,
    task_id: String,
    upstream: Arc<Upstream>,
    body: Bytes,
    kind: RouteKind,
) -> Response {
    // 流式请求补一个 `stream_options.include_usage`：没有它，OpenAI 兼容上游的末帧
    // 不带 `usage`，代理只能按字节估算（见 usage.rs）。只增字段、不动上下文。
    let body = ensure_stream_usage(body);

    // 前缀变了，缓存就永远命不中——而这件事从账单上只能看出"钱花多了"。
    // 只观测不改写：真正该稳定前缀的是 CLI 与它的配置，不是代理。
    if let Some(fingerprint) = prefix::fingerprint(&body) {
        let changed = proxy
            .prefixes
            .lock()
            .ok()
            .and_then(|mut watch| watch.observe(&task_id, fingerprint));
        if let Some(previous) = changed {
            tracing::warn!(
                task_id = %task_id,
                previous,
                current = fingerprint,
                "同一任务的请求前缀发生变化：前缀缓存将失效"
            );
            audit::record(
                &proxy.pool,
                &AuditEntry::new(&task_id, "worker", "code.prefix_changed", "warn")
                    .target(&task_id)
                    .detail(json!({ "previous": previous, "current": fingerprint })),
            )
            .await;
        }
    }

    // 上游不给 usage 时，用请求体字节数当 prompt 的估算（偏高，具体口径见 usage.rs）。
    let prompt_bytes = body.len() as u64;

    match upstream.post(body).await {
        Err(message) => openai_error(StatusCode::BAD_GATEWAY, "upstream_error", &message),
        Ok(response) => {
            let status = response.status();
            if !status.is_success() {
                let text = response.text().await.unwrap_or_default();
                proxy.record(&task_id, None, 0, 0).await;
                return passthrough_error(status, &text);
            }

            let streaming = response
                .headers()
                .get(header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .is_some_and(|value| value.contains("text/event-stream"));

            if streaming {
                proxy.stream(task_id, response, prompt_bytes, kind)
            } else {
                let bytes = response.bytes().await.unwrap_or_default();
                let mut parser = UsageParser::default();
                parser.feed(&bytes);
                parser.finish();

                let totals = proxy
                    .record(
                        &task_id,
                        parser.usage(),
                        prompt_bytes,
                        parser.content_chars(),
                    )
                    .await;
                if proxy.budget_hit(totals) {
                    proxy.mark_budget_exceeded(&task_id, totals).await;
                }

                let translated = match &kind {
                    RouteKind::Chat => bytes.to_vec(),
                    RouteKind::Responses {
                        model,
                        response_id,
                        created_at,
                    } => responses::json_response(&bytes, model, response_id, *created_at),
                    RouteKind::Anthropic { model, message_id } => {
                        anthropic::json_response(&bytes, model, message_id)
                    }
                };
                Response::builder()
                    .status(StatusCode::OK)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(translated))
                    .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response_stub())
            }
        }
    }
}

fn now_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|delta| delta.as_secs() as i64)
        .unwrap_or(0)
}

/// 请求级的单调 id 后缀。不追求全局唯一：只在单条响应里用来区分 item。
fn next_id() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

impl CodeProxy {
    /// 流式透传：原样转发字节，旁路累积用量。
    fn stream(
        self: Arc<Self>,
        task_id: String,
        response: reqwest::Response,
        prompt_bytes: u64,
        kind: RouteKind,
    ) -> Response {
        let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(32);

        tokio::spawn(async move {
            let mut parser = UsageParser::default();
            let mut stream = response.bytes_stream();
            let mut cut_off = false;
            // 非 chat 协议：上游 chunk 先归一再渲染。chat 走原样透传，
            // 因为重打包 SSE 是最容易把 CLI 的解析器弄崩的一步。
            let mut chat_parser = translate::ChatParser::default();
            let mut renderer: Option<Box<dyn translate::Renderer>> = match &kind {
                RouteKind::Chat => None,
                RouteKind::Responses {
                    model,
                    response_id,
                    created_at,
                } => Some(Box::new(responses::StreamRenderer::new(
                    model,
                    response_id,
                    *created_at,
                ))),
                RouteKind::Anthropic { model, message_id } => {
                    Some(Box::new(anthropic::StreamRenderer::new(model, message_id)))
                }
            };

            while let Some(chunk) = stream.next().await {
                match chunk {
                    Ok(chunk) => {
                        parser.feed(&chunk);
                        let outbound = match renderer.as_mut() {
                            Some(renderer) => {
                                let deltas = chat_parser.feed(&chunk);
                                renderer.push(&deltas)
                            }
                            None => chunk.to_vec(),
                        };
                        if outbound.is_empty() {
                            continue;
                        }
                        // 客户端断开时没人读，继续拉上游只会白烧 token。
                        if tx.send(Ok(Bytes::from(outbound))).await.is_err() {
                            break;
                        }
                        if self.would_exceed(&task_id, &parser, prompt_bytes) {
                            cut_off = true;
                            break;
                        }
                    }
                    Err(err) => {
                        let _ = tx.send(Err(std::io::Error::other(err.to_string()))).await;
                        break;
                    }
                }
            }

            if let Some(renderer) = renderer.as_mut() {
                let tail = renderer.finish();
                if !tail.is_empty() {
                    let _ = tx.send(Ok(Bytes::from(tail))).await;
                }
            }

            parser.finish();
            let totals = self
                .record(
                    &task_id,
                    parser.usage(),
                    prompt_bytes,
                    parser.content_chars(),
                )
                .await;

            if cut_off || self.budget_hit(totals) {
                self.mark_budget_exceeded(&task_id, totals).await;
            }
        });

        let body = Body::from_stream(futures_util::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|item| (item, rx))
        }));

        Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "text/event-stream")
            .header(header::CACHE_CONTROL, "no-cache")
            .body(body)
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response_stub())
    }

    /// 流式过程中的即时预算判断：已记录的量 + 本次已收到的量。
    fn would_exceed(&self, task_id: &str, parser: &UsageParser, prompt_bytes: u64) -> bool {
        let base = self
            .usage
            .lock()
            .map(|table| table.get(task_id))
            .unwrap_or_default();

        let used = base.tokens() + estimate_tokens(prompt_bytes) + parser.content_chars();
        used >= self.budget.max_tokens
    }
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let token = value
        .strip_prefix("Bearer ")
        .or_else(|| value.strip_prefix("bearer "))?;
    let token = token.trim();
    (!token.is_empty()).then(|| token.to_string())
}

/// 给 opencode 看的错误体：必须是 OpenAI 的形状，否则它只会显示"未知错误"。
fn openai_error(status: StatusCode, code: &str, message: &str) -> Response {
    let body = json!({
        "error": {
            "message": message,
            "type": code,
            "code": code,
        }
    });

    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response_stub())
}

/// 上游的非 2xx 原样透传：把上游的话改写成我们的话，排障时就少一半信息。
fn passthrough_error(status: StatusCode, text: &str) -> Response {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(text.to_string()))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response_stub())
}

/// `Response::builder()` 失败在实践里只可能是把头写错了；这里给一个兜底，
/// 避免为了一个不可能的分支到处 `unwrap()`。
trait IntoStub {
    fn into_response_stub(self) -> Response;
}

impl IntoStub for StatusCode {
    fn into_response_stub(self) -> Response {
        let body = json!({"error": {"message": "response build failed", "type": "internal_error"}});
        let mut response = Response::new(Body::from(body.to_string()));
        *response.status_mut() = self;
        response
    }
}
