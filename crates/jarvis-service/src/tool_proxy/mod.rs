//! 联网查证工具的回环代理。
//!
//! 存在的理由和 `code_proxy` 一样：**付费密钥只留在 service 进程里**。
//! `jarvis-worker` 是执行体、还会拉起第三方编码 CLI，不该持有能花钱的钥匙；
//! 它拿到的是一枚进程内随机令牌，只有本机回环代理认。
//!
//! 边界：
//! - 只绑回环（`tool.web.proxy_bind` 由 `Config::validate` 强制），不跟着 `/api` 暴露；
//! - 只有两个端点：`/internal/tools/v1/search`、`/internal/tools/v1/fetch`；
//! - **只换 `Authorization`，不改请求体**；上游响应按状态码原样返回，
//!   由 worker 翻译成中文失败原因（402 余额不足 / 429 限流 / 404 无正文）；
//! - 缺密钥时**不启动**：worker 也就拿不到代理地址，自动停留在 Bing + 本机抓取。

pub(crate) mod upstream;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use axum::routing::post;
use axum::Router;
use serde_json::json;
use subtle::ConstantTimeEq;

use crate::config::Config;

use self::upstream::Upstream;

/// worker 侧调用的路径。前缀与 `/internal/code/...` 同一家族，避免和 `/api/*` 混淆。
pub(crate) const SEARCH_PATH: &str = "/internal/tools/v1/search";
pub(crate) const FETCH_PATH: &str = "/internal/tools/v1/fetch";

/// 上游对应的真实路径（DeepSeek 官方端点）。
const UPSTREAM_SEARCH_PATH: &str = "/v1/tools/search";
const UPSTREAM_FETCH_PATH: &str = "/v1/tools/fetch";

/// 请求体上限：只有搜索词与一个 URL，64 KiB 已经非常宽松。
const MAX_REQUEST_BYTES: usize = 64 * 1024;
/// 响应体上限：`need_content` 打开时正文可能很长，按 2 MiB 截断，
/// 既够 worker 截取 2000 字，也不会把内存吃满。
const MAX_RESPONSE_BYTES: usize = 2 * 1024 * 1024;

/// 代持密钥的联网工具代理。
#[derive(Debug)]
pub struct ToolProxy {
    addr: SocketAddr,
    /// 只发给本机 worker 的进程令牌，进程重启即换。
    token: String,
    upstream: Arc<Upstream>,
}

impl ToolProxy {
    /// 按配置启动代理。**不需要上游时不启动**（返回 `None`），不白占端口。
    pub async fn start(config: &Config) -> std::io::Result<Option<Arc<Self>>> {
        if !config.web_tools_proxy_needed() {
            return Ok(None);
        }

        let upstream = match Upstream::from_config(config) {
            Ok(upstream) => Arc::new(upstream),
            Err(err) => {
                // 与编码代理同口径：不拦启动，只是这次没有付费上游可用。
                tracing::warn!(%err, "联网工具代理没有可用上游，本次不启动（搜索仍是 Bing）");
                return Ok(None);
            }
        };

        let addr: SocketAddr = config.tool.web.proxy_bind.parse().map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("tool.web.proxy_bind 非法: {}", config.tool.web.proxy_bind),
            )
        })?;

        let listener = tokio::net::TcpListener::bind(addr).await?;
        let local = listener.local_addr()?;

        let proxy = Arc::new(Self {
            addr: local,
            token: random_token(),
            upstream,
        });

        let router = proxy.router();
        tokio::spawn(async move {
            if let Err(err) = axum::serve(listener, router).await {
                tracing::error!(%err, "联网工具代理监听退出");
            }
        });

        Ok(Some(proxy))
    }

    /// worker 该访问的地址（`http://127.0.0.1:<port>`）。
    pub fn base_url(&self) -> String {
        format!("http://{}", self.addr)
    }

    /// 进程令牌。只在 supervisor 拉起 worker 时下发，不进日志。
    pub fn token(&self) -> &str {
        &self.token
    }

    fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route(SEARCH_PATH, post(handle_search))
            .route(FETCH_PATH, post(handle_fetch))
            .layer(DefaultBodyLimit::max(MAX_REQUEST_BYTES))
            .with_state(self.clone())
    }
}

async fn handle_search(
    State(proxy): State<Arc<ToolProxy>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    forward(&proxy, SEARCH_PATH, UPSTREAM_SEARCH_PATH, &headers, body).await
}

async fn handle_fetch(
    State(proxy): State<Arc<ToolProxy>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    forward(&proxy, FETCH_PATH, UPSTREAM_FETCH_PATH, &headers, body).await
}

/// 鉴权后把请求原样转给上游，并把上游的状态码与响应体原样带回去。
async fn forward(
    proxy: &ToolProxy,
    path: &str,
    upstream_path: &str,
    headers: &HeaderMap,
    body: Bytes,
) -> Response {
    if !authorized(headers, &proxy.token) {
        // 只有本机 worker 该拿到令牌；这里也不透露"令牌对不对"以外的信息。
        return json_response(
            StatusCode::UNAUTHORIZED,
            &json!({"error": {"message": "unauthorized"}}).to_string(),
        );
    }

    let started = Instant::now();
    let response = match proxy.upstream.post(upstream_path, body).await {
        Ok(response) => response,
        Err(err) => {
            tracing::warn!(path, %err, "联网工具上游请求失败");
            return json_response(
                StatusCode::BAD_GATEWAY,
                &json!({"error": {"message": err}}).to_string(),
            );
        }
    };

    let status = response.status();
    let bytes = match read_capped(response).await {
        Ok(bytes) => bytes,
        Err(err) => {
            tracing::warn!(path, %err, "联网工具上游响应读取失败");
            return json_response(
                StatusCode::BAD_GATEWAY,
                &json!({"error": {"message": err}}).to_string(),
            );
        }
    };

    // 只记端点、状态与耗时：查询词与目标 URL 属于用户内容，不进服务日志
    // （它们仍会按截断规则进审计，那是另一条通道）。
    tracing::info!(
        path,
        status = status.as_u16(),
        elapsed_ms = started.elapsed().as_millis() as u64,
        bytes = bytes.len(),
        "联网工具调用"
    );

    let status = StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(bytes))
        .unwrap_or_else(|_| json_response(StatusCode::BAD_GATEWAY, "{\"error\":{}}"))
}

fn authorized(headers: &HeaderMap, token: &str) -> bool {
    let Some(raw) = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
    else {
        return false;
    };
    let Some(candidate) = raw.strip_prefix("Bearer ") else {
        return false;
    };
    // 逐字节定时比较：回环也不是"可以随便比"的理由。
    candidate.as_bytes().ct_eq(token.as_bytes()).into()
}

fn json_response(status: StatusCode, body: &str) -> Response {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

/// 边读边截断：上游给 100 MB 正文时不能整段读进内存。
async fn read_capped(mut response: reqwest::Response) -> Result<Vec<u8>, String> {
    let mut collected: Vec<u8> = Vec::new();

    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|err| format!("读取响应失败：{err}"))?
    {
        collected.extend_from_slice(&chunk);
        if collected.len() >= MAX_RESPONSE_BYTES {
            collected.truncate(MAX_RESPONSE_BYTES);
            break;
        }
    }

    Ok(collected)
}

/// 进程令牌：32 字节随机数的十六进制表示。
fn random_token() -> String {
    let bytes: [u8; 32] = rand::random();
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    use serde_json::Value;

    /// 起一个假上游，回显收到的 `Authorization` 与请求体，并返回固定成功体。
    async fn fake_upstream() -> (String, Arc<std::sync::Mutex<Vec<(String, String)>>>) {
        let seen: Arc<std::sync::Mutex<Vec<(String, String)>>> = Arc::default();
        let recorded = seen.clone();

        let app = Router::new()
            .route(
                UPSTREAM_SEARCH_PATH,
                post(move |headers: HeaderMap, body: String| async move {
                    let auth = headers
                        .get(header::AUTHORIZATION)
                        .and_then(|value| value.to_str().ok())
                        .unwrap_or("")
                        .to_string();
                    recorded.lock().unwrap().push((auth, body));
                    axum::Json(json!({ "results": [] }))
                }),
            )
            .route(
                UPSTREAM_FETCH_PATH,
                post(|body: String| async move {
                    (
                        StatusCode::NOT_FOUND,
                        axum::Json(json!({"error": {"message": format!("no body: {body}")}})),
                    )
                }),
            );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定假上游失败");
        let addr = listener.local_addr().expect("取地址失败");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        (format!("http://{addr}"), seen)
    }

    async fn start_proxy(upstream: &str) -> Arc<ToolProxy> {
        std::env::set_var("PERSONAL_AGENT_TEST_TOOL_PROXY_KEY", "real-upstream-key");
        let mut config = Config::default();
        config.tool.web.api_key_env = "PERSONAL_AGENT_TEST_TOOL_PROXY_KEY".to_string();
        config.tool.web.base_url = upstream.to_string();
        // 触发"需要代理"：抓取兜底开关打开即可。
        config.tool.web.fetch_fallback = true;

        ToolProxy::start(&config)
            .await
            .expect("代理应能启动")
            .expect("有密钥时应返回实例")
    }

    #[tokio::test]
    async fn rejects_missing_or_wrong_token() {
        let (upstream, _seen) = fake_upstream().await;
        let proxy = start_proxy(&upstream).await;

        let client = reqwest::Client::new();
        let response = client
            .post(format!("{}{}", proxy.base_url(), SEARCH_PATH))
            .json(&json!({ "query": "x" }))
            .send()
            .await
            .expect("请求应发出");
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        let response = client
            .post(format!("{}{}", proxy.base_url(), SEARCH_PATH))
            .header("authorization", "Bearer wrong")
            .json(&json!({ "query": "x" }))
            .send()
            .await
            .expect("请求应发出");
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn injects_real_key_and_passes_status_through() {
        let (upstream, seen) = fake_upstream().await;
        let proxy = start_proxy(&upstream).await;
        let client = reqwest::Client::new();

        let response = client
            .post(format!("{}{}", proxy.base_url(), SEARCH_PATH))
            .header("authorization", format!("Bearer {}", proxy.token()))
            .json(&json!({ "query": "浙江 高考", "count": 3 }))
            .send()
            .await
            .expect("请求应发出");
        assert_eq!(response.status(), StatusCode::OK);

        // 上游收到的是真密钥，不是 worker 那枚进程令牌；请求体原样转发。
        let (auth, body) = {
            let seen = seen.lock().unwrap();
            seen.first().cloned().expect("上游应收到一次请求")
        };
        assert_eq!(auth, "Bearer real-upstream-key");
        let parsed: Value = serde_json::from_str(&body).expect("请求体应是 JSON");
        assert_eq!(parsed["query"], "浙江 高考");
        assert_eq!(parsed["count"], 3);

        // 上游 404（取不到正文）要原样透传，worker 据此写"未核实"。
        let response = client
            .post(format!("{}{}", proxy.base_url(), FETCH_PATH))
            .header("authorization", format!("Bearer {}", proxy.token()))
            .json(&json!({ "url": "https://example.com" }))
            .send()
            .await
            .expect("请求应发出");
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        let text = response.text().await.expect("读取失败");
        assert!(text.contains("no body"), "{text}");
    }

    #[tokio::test]
    async fn no_key_means_no_proxy() {
        std::env::remove_var("PERSONAL_AGENT_TEST_TOOL_PROXY_ABSENT");
        let mut config = Config::default();
        config.tool.web.api_key_env = "PERSONAL_AGENT_TEST_TOOL_PROXY_ABSENT".to_string();
        config.tool.web.fetch_fallback = true;

        let started = ToolProxy::start(&config).await.expect("不该报错");
        assert!(started.is_none(), "缺密钥时不该启动代理");
    }

    #[test]
    fn token_is_hex_and_never_reused() {
        let first = random_token();
        let second = random_token();
        assert_eq!(first.len(), 64);
        assert!(first.chars().all(|ch| ch.is_ascii_hexdigit()));
        assert_ne!(first, second);
    }
}
