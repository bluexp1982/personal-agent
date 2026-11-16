//! 会话预览站与运行代理：一个回环只读站点，两种用法。
//!
//! 为什么需要它：会话里要打开的 html 在**服务端**机器上，客户端本机没有这些
//! 文件（手机端更是如此）。客户端唯一验证过的到服务通道是 `/api/browser/tunnel`
//! （裸字节流），所以内容必须由服务端托管成一个 http 地址。
//!
//! 两件事共用一个站点，因为它们的边界完全一致：
//!
//! - 只绑 `127.0.0.1` 的**随机**端口，不跟 `api_bind` 一起对外；
//! - 靠 URL 第一段的随机 token 自证身份——隧道是裸字节流，WebView 的请求
//!   带不了 `Authorization` 头；
//! - 都要过项目路径准入（[`ProjectRoot`](crate::local_tools::path_guard::ProjectRoot)）。
//!
//! 路径布局：
//!
//! - `/f/{token}/{project_id}/{相对路径}`：只读文件预览；
//! - `/d/{token}/{conversation_id}/{相对路径}`：**会话草稿**预览。没有绑定项目的
//!   会话把生成的文件放在 `{data_dir}/drafts/{conversation_id}/`，它不是项目，
//!   用 `/f/` 会让"第一段是项目 id"这条语义变浑，因此单开一段；
//! - `/a/{token}/{project_id}/{相对路径}`：运行代理，按 `api_prefix` 分流到前后端。
//!
//! token 每次进程启动重新生成、不落盘：它只活在"服务端生成 URL → 隧道 → WebView"
//! 这一段里，重启后旧地址自然失效。

mod files;
mod mime;
mod proxy;
mod run_config;

use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{header, StatusCode};
use axum::response::Response;
use axum::Router;
use sqlx::SqlitePool;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::local_tools::path_guard::{GuardError, ProjectRoot};

/// token 的字节数。12 字节 = 24 个十六进制字符，与客户端 `LocalStaticServer` 同量级：
/// 足以让同机其它进程猜不到，又不至于让 URL 长得没法看。
const TOKEN_BYTES: usize = 12;

/// 转发到上游的连接超时。回环连接要么立刻成功要么立刻失败。
const UPSTREAM_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// 运行代理的整请求超时。与浏览器隧道的空闲上限同量级。
const UPSTREAM_REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

/// 预览站句柄。
///
/// 进程启动时装配一次，挂在 [`AppState`](crate::state::AppState) 上：
/// 工具要拿它拼地址，隧道要拿它放行端口。
#[derive(Debug)]
pub struct WebPreview {
    port: u16,
    token: String,
    pool: SqlitePool,
    /// 只用来算"哪些端口是服务端自己的"。运行代理要据此拒绝把浏览器
    /// 导到管理面或编码代理上。
    config: Arc<Config>,
    /// 运行代理的上游客户端。**必须 `no_proxy`**：回环请求一旦走环境变量里的
    /// 代理，会表现为"上游明明在跑却 502"。
    client: reqwest::Client,
    shutdown: CancellationToken,
}

impl WebPreview {
    /// 绑定回环随机端口并开始服务。
    ///
    /// 失败由调用方决定是否降级：预览站起不来不该让整个服务起不来，
    /// 只是会话里的文件预览与运行代理会不可用。
    pub async fn start(pool: SqlitePool, config: Arc<Config>) -> std::io::Result<Arc<Self>> {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();

        let client = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(UPSTREAM_CONNECT_TIMEOUT)
            .timeout(UPSTREAM_REQUEST_TIMEOUT)
            .build()
            .map_err(|err| std::io::Error::other(err.to_string()))?;

        let state = Arc::new(Self {
            port,
            token: random_token(),
            pool,
            config,
            client,
            shutdown: CancellationToken::new(),
        });

        // 显式标注 state 类型：`Router::new()` 的 S 由 `.with_state` 推断，
        // 但 `.fallback` 在它之前，不标注会先被定成 `()` 而找不到 Handler。
        let router: Router<Arc<WebPreview>> = Router::new().fallback(dispatch);
        let router = router.with_state(state.clone());
        let shutdown = state.shutdown.clone();
        tokio::spawn(async move {
            let served = axum::serve(listener, router)
                .with_graceful_shutdown(async move { shutdown.cancelled().await });
            if let Err(err) = served.await {
                tracing::error!(%err, "预览站监听退出");
            }
        });

        tracing::info!(port, "会话预览站已启动（仅回环，地址带随机令牌）");
        Ok(state)
    }

    /// 预览站监听端口。隧道据此放行，不要在别处硬编码。
    pub fn port(&self) -> u16 {
        self.port
    }

    /// 文件预览地址。
    ///
    /// `relative` 是**项目相对路径**：绝对路径会把用户名与目录结构写进会话记录。
    pub fn file_url(&self, project_id: &str, relative: &str) -> String {
        format!(
            "http://127.0.0.1:{}/f/{}/{}/{}",
            self.port,
            self.token,
            project_id,
            encode_path(relative)
        )
    }

    /// 草稿文件预览地址。
    ///
    /// 草稿不是项目，因此单独一段路径：`/d/{token}/{conversation_id}/{相对路径}`。
    pub fn draft_url(&self, conversation_id: &str, relative: &str) -> String {
        format!(
            "http://127.0.0.1:{}/d/{}/{}/{}",
            self.port,
            self.token,
            conversation_id,
            encode_path(relative)
        )
    }

    /// 运行代理根地址。路径以 `/` 结尾，页面里的相对引用才会落在同一个根下。
    pub fn run_url(&self, project_id: &str) -> String {
        format!(
            "http://127.0.0.1:{}/a/{}/{}/",
            self.port, self.token, project_id
        )
    }

    /// 停止监听。测试用；进程退出时由运行时统一回收。
    pub fn stop(&self) {
        self.shutdown.cancel();
    }

    /// 校验 URL 第一段的 token。定长比较，避免按字符差异泄露前缀。
    fn token_matches(&self, provided: &str) -> bool {
        use subtle::ConstantTimeEq;

        provided.len() == self.token.len()
            && bool::from(provided.as_bytes().ct_eq(self.token.as_bytes()))
    }
}

/// 按路径第一段分发。
///
/// 用 `fallback` 而不是 `route("/f/{token}/{*path}")`：axum 的通配段不匹配空路径，
/// 而运行代理的根（`/a/{token}/{project}/`）恰恰是一个空尾段。手动拆分只有一处
/// 解析、两条分支共用同一套 token 校验。
async fn dispatch(State(state): State<Arc<WebPreview>>, request: Request) -> Response {
    // 先拷成 owned：下面要把 `request` 整体交给代理去读 body，
    // 借用着 path 的话 move 不出去。
    let path = request.uri().path().trim_start_matches('/').to_string();
    let mut parts = path.splitn(4, '/');
    let kind = parts.next().unwrap_or_default();
    let token = parts.next().unwrap_or_default();
    // 第二段：`/f` 与 `/a` 下是项目 id，`/d` 下是会话 id。名字取中性一点，
    // 免得在草稿分支里读到 `project_id` 又去查项目表。
    let ticket = parts.next().unwrap_or_default();
    let tail = parts.next().unwrap_or_default();

    if !state.token_matches(token) {
        // 不区分"没有这段""猜错了"：一律 404，别给探测者任何反馈。
        return not_found();
    }
    if ticket.is_empty() {
        return not_found();
    }

    match kind {
        // 文件预览只借一个 method：把整个 `Request` 借进 async 块会让
        // future 需要 `Request: Sync`，而 `Body` 不满足，handler 就注册不上。
        "f" => {
            let method = request.method().clone();
            files::serve(&state, ticket, tail, &method).await
        }
        "d" => {
            let method = request.method().clone();
            files::serve_draft(&state, ticket, tail, &method).await
        }
        "a" => proxy::serve(&state, ticket, tail, request).await,
        _ => not_found(),
    }
}

/// 预览入口白名单：只允许网页本身。资源白名单在 [`mime`] 里另有一份。
pub(crate) fn is_preview_entry(path: &std::path::Path) -> bool {
    mime::is_entry(path)
}

/// 运行配置相对项目根的路径。错误文案与文档共用这一句。
pub(crate) fn run_config_path() -> &'static str {
    run_config::CONFIG_RELATIVE
}

/// 一次"把项目文件变成可加载地址"的结果。
#[derive(Debug, Clone)]
pub(crate) struct FileTarget {
    pub(crate) url: String,
    /// 地址栏显示值：`项目目录名/相对路径`。
    pub(crate) display: String,
    /// 归一化后的项目相对路径（已去掉模型常写的项目名前缀）。
    pub(crate) relative: String,
}

/// 为什么打不开这个文件。
///
/// 与 [`GuardError`] 分开：那个只说"路径不行"，这里还要表达
/// "路径可以，但不是网页"——两者对用户的下一步建议完全不同。
#[derive(Debug, thiserror::Error)]
pub(crate) enum TargetError {
    #[error("{0}")]
    Denied(String),
    #[error("{0}")]
    Invalid(String),
}

/// 把项目文件变成一个可加载的预览地址。
///
/// 准入、入口白名单、地址拼接**只有这一份**：会话工具（`preview_url(path)`）
/// 与会话外的右键菜单都调它。两处各写一遍的话，规则迟早分叉。
pub(crate) fn file_target(
    preview: &WebPreview,
    root: &ProjectRoot,
    project_id: &str,
    path: &str,
) -> Result<FileTarget, TargetError> {
    let abs = root.file(path).map_err(|err| match err {
        GuardError::Denied(reason) => TargetError::Denied(reason),
        GuardError::Invalid(reason) => TargetError::Invalid(reason),
    })?;

    if !is_preview_entry(&abs) {
        return Err(TargetError::Invalid(format!(
            "只能预览项目里的 html/htm 文件，{path} 不在白名单里"
        )));
    }

    let relative = root.relative(&abs);
    Ok(FileTarget {
        url: preview.file_url(project_id, &relative),
        display: format!("{}/{}", root.root_label(), relative),
        relative,
    })
}

/// 把会话草稿文件变成一个可加载的预览地址。
///
/// 与 [`file_target`] 的区别只在根从哪来：这里固定是 `{data_dir}/drafts/{conversation_id}`。
/// 入口白名单、路径准入（`ProjectRoot::file`）完全一样——草稿目录同样是"一个根"。
pub(crate) fn draft_target(
    preview: &WebPreview,
    config: &Config,
    conversation_id: &str,
    path: &str,
) -> Result<FileTarget, TargetError> {
    if crate::write_store::check_segment(conversation_id).is_err() {
        return Err(TargetError::Denied("会话标识非法".to_string()));
    }

    let dir = config.drafts_dir().join(conversation_id);
    let root = ProjectRoot::new(&dir.to_string_lossy()).map_err(|err| match err {
        GuardError::Denied(reason) => TargetError::Denied(reason),
        GuardError::Invalid(reason) => {
            TargetError::Invalid(format!("这个会话还没有生成过文件（{reason}）"))
        }
    })?;

    let abs = root.file(path).map_err(|err| match err {
        GuardError::Denied(reason) => TargetError::Denied(reason),
        GuardError::Invalid(reason) => TargetError::Invalid(reason),
    })?;

    if !is_preview_entry(&abs) {
        return Err(TargetError::Invalid(format!(
            "只能预览草稿里的 html/htm 文件，{path} 不在白名单里"
        )));
    }

    let relative = root.relative(&abs);
    Ok(FileTarget {
        url: preview.draft_url(conversation_id, &relative),
        display: format!("草稿/{relative}"),
        relative,
    })
}

/// 查项目根。
///
/// 只认没被逻辑删除的项目：项目删掉之后，旧地址不该还能读到磁盘上的内容。
async fn project_root(pool: &SqlitePool, project_id: &str) -> Option<ProjectRoot> {
    let path: Option<String> =
        sqlx::query_scalar("SELECT path FROM projects WHERE id = ? AND deleted_at IS NULL")
            .bind(project_id)
            .fetch_optional(pool)
            .await
            .ok()
            .flatten();

    ProjectRoot::new(&path?).ok()
}

fn not_found() -> Response {
    text(StatusCode::NOT_FOUND, "404 Not Found")
}

/// 纯文本响应。预览站的错误页面不需要 JSON：它的消费者是浏览器。
///
/// Content-Length 交给 hyper 按 `Body` 的精确大小补，不手写——
/// 手写时一旦和实际字节数不一致，浏览器会一直转圈等剩余内容。
fn text(status: StatusCode, body: impl Into<String>) -> Response {
    let mut response = Response::new(Body::from(body.into()));
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    headers.insert(
        header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store"),
    );
    response
}

fn random_token() -> String {
    let bytes: [u8; TOKEN_BYTES] = rand::random();
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// 按路径段做百分号编码，保留 `/` 作为分隔符。
///
/// 不引 `url` crate：这里只需要"把空格与中文编掉"，多一个依赖不值得。
fn encode_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for byte in path.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(*byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// 还原百分号编码。
///
/// 解码失败返回 `None` 而不是静默裁掉：一个坏字节拼出来的路径可能指向别处，
/// 与其猜，不如直接 400。
fn decode_path(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = hex_value(*bytes.get(index + 1)?)?;
            let low = hex_value(*bytes.get(index + 2)?)?;
            out.push(high * 16 + low);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }

    String::from_utf8(out).ok()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// 拒绝一切以 `.` 开头的路径段。
///
/// `.env`、`.git`、`.ssh` 这类名字不该通过浏览器面板暴露，哪怕它们没被
/// [`ProjectRoot`] 的文件名名单命中。静态服务按路径直读，这一道必须自己把住。
fn has_hidden_segment(relative: &str) -> bool {
    relative
        .split('/')
        .any(|segment| segment.starts_with('.') && !segment.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_and_decodes_round_trip() {
        for raw in ["index.html", "a b/c.html", "中文/页面.html", "x+y.txt"] {
            let encoded = encode_path(raw);
            assert!(
                encoded.is_ascii(),
                "编码结果必须是 ASCII: {encoded}（{raw}）"
            );
            assert_eq!(decode_path(&encoded).as_deref(), Some(raw));
        }
    }

    #[test]
    fn keeps_slashes_and_dot_segments_intact() {
        assert_eq!(encode_path("a/b/c.html"), "a/b/c.html");
        assert_eq!(decode_path("a/../b").as_deref(), Some("a/../b"));
    }

    #[test]
    fn rejects_malformed_percent_sequences() {
        assert!(decode_path("%zz").is_none());
        assert!(decode_path("%4").is_none());
        assert!(decode_path("%ff").is_none(), "非法 UTF-8 不能被当成路径");
    }

    #[test]
    fn hides_dot_segments() {
        assert!(has_hidden_segment(".env"));
        assert!(has_hidden_segment("a/.git/config"));
        assert!(!has_hidden_segment("a/b.html"));
        // 文件名中间的点和前导点不是一回事。
        assert!(!has_hidden_segment("a/app.min.js"));
    }

    #[test]
    fn random_token_is_hex_and_unique() {
        let first = random_token();
        let second = random_token();
        assert_eq!(first.len(), TOKEN_BYTES * 2);
        assert!(first.chars().all(|ch| ch.is_ascii_hexdigit()));
        assert_ne!(first, second);
    }
}
