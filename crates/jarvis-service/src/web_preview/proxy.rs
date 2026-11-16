//! 运行代理 handler：一个入口，按 `api_prefix` 把请求分给前端或后端。
//!
//! 存在的理由：客户端浏览器标签只对应**一条**隧道、一个端口。页面里若写死
//! `http://localhost:8080`，`localhost` 解析到的是客户端自己，必然失败。
//! 所以前后端必须收在同一个源下，"前端调后端"变成同源相对路径。
//!
//! 第一版只做 HTTP，不透传 WebSocket 升级：HMR 会退化成手动刷新。
//! 这是显式取舍——接管升级需要自己处理 `hyper` 连接，收益与风险不成正比。

use axum::body::Body;
use axum::extract::Request;
use axum::http::{HeaderValue, StatusCode};
use axum::response::Response;

use super::run_config::{self, RunConfig, CONFIG_RELATIVE};
use super::{project_root, text, WebPreview};

/// 逐跳头：只对单条连接有意义，转发过去会让上游理解错。
const HOP_BY_HOP: &[&str] = &[
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "trailers",
    "transfer-encoding",
    "upgrade",
];

/// 请求侧额外要丢的头。
///
/// - `host`：reqwest 会按目标 URL 重写，留着会让上游看到客户端的桥接端口；
/// - `content-length`：body 是流式的，长度由 reqwest 自己决定；
/// - `expect`：`100-continue` 我们不做应答，透传只会让请求卡住等一个不会来的响应。
const REQUEST_SKIP: &[&str] = &["host", "content-length", "expect"];

pub(super) async fn serve(
    state: &WebPreview,
    project_id: &str,
    tail: &str,
    request: Request,
) -> Response {
    let Some(root) = project_root(&state.pool, project_id).await else {
        return text(StatusCode::NOT_FOUND, "项目不存在或已删除");
    };

    let config = match run_config::load(root.root()).await {
        Ok(config) => config,
        Err(reason) => return text(StatusCode::BAD_GATEWAY, reason),
    };

    let port = match target_port(state, &config, tail) {
        Ok(port) => port,
        Err(reason) => return text(StatusCode::BAD_GATEWAY, reason),
    };

    forward(state, port, tail, request).await
}

/// 这一条请求该发给谁。
///
/// 命中 `api_prefix` 走 backend，其余走 frontend。配置写错时给出
/// 能直接照做的错误页，而不是一个空白的 502。
///
/// 错误用 `String` 而不是 `Response`：`Response` 有一百多字节，
/// 塞进 `Err` 里会让每个调用点都白扛一份体积（clippy 的
/// `result_large_err` 就是在说这件事）。
fn target_port(state: &WebPreview, config: &RunConfig, tail: &str) -> Result<u16, String> {
    let path = format!("/{tail}");
    let port = if run_config::matches_prefix(&path, &config.api_prefix) {
        match config.backend {
            Some(port) => port,
            None => {
                return Err(format!(
                    "请求命中 {} 但 {CONFIG_RELATIVE} 里没有配置 backend",
                    config.api_prefix
                ))
            }
        }
    } else {
        config.frontend
    };

    check_port(state, port)?;
    Ok(port)
}

/// 上游端口不能是服务端自己的监听。
///
/// 配置是用户写的，但一份手滑的配置会把浏览器导到管理面或编码代理上，
/// 那不是"用户自己的选择"，是配置事故——直接拒绝并说清原因。
fn check_port(state: &WebPreview, port: u16) -> Result<(), String> {
    let mut reserved = state.config.browser_reserved_ports();
    // 预览站自己也在名单里：否则会绕出一个自指的回环。
    reserved.push(state.port);

    if reserved.contains(&port) {
        return Err(format!(
            "端口 {port} 与服务端自身监听冲突（SSH / API / 预览站），不能作为运行目标"
        ));
    }
    Ok(())
}

/// 把请求原样转给上游，再把响应原样转回来。
///
/// 不做内容改写：只支持同源相对路径是产品边界，写死的绝对地址不在这条路里。
async fn forward(state: &WebPreview, port: u16, tail: &str, request: Request) -> Response {
    let (parts, body) = request.into_parts();

    let query = parts
        .uri
        .query()
        .map(|query| format!("?{query}"))
        .unwrap_or_default();
    // `tail` 保持原始编码拼回上游：解码再编码会丢语义，也可能拼出另一条路径。
    let raw = format!("http://127.0.0.1:{port}/{tail}{query}");
    let url = match reqwest::Url::parse(&raw) {
        Ok(url) => url,
        Err(err) => {
            tracing::debug!(%raw, %err, "运行代理上游地址非法");
            return text(StatusCode::BAD_REQUEST, "上游地址非法");
        }
    };

    let method = match reqwest::Method::from_bytes(parts.method.as_str().as_bytes()) {
        Ok(method) => method,
        Err(_) => return text(StatusCode::BAD_REQUEST, "不支持的请求方法"),
    };

    let mut upstream = state.client.request(method.clone(), url);
    for (name, value) in &parts.headers {
        let name = name.as_str();
        if HOP_BY_HOP.contains(&name) || REQUEST_SKIP.contains(&name) {
            continue;
        }
        upstream = upstream.header(name, value.as_bytes());
    }

    // GET / HEAD 不挂 body：挂一个空流会让 reqwest 发 chunked，
    // 某些只认 `Content-Length` 的老服务会直接 400。
    if method != reqwest::Method::GET && method != reqwest::Method::HEAD {
        upstream = upstream.body(reqwest::Body::wrap_stream(body.into_data_stream()));
    }

    let response = match upstream.send().await {
        Ok(response) => response,
        Err(err) => {
            // 这里是最常见的用户侧失败：服务没起、端口写错。给能照做的一句话。
            tracing::debug!(port, %err, "运行代理转发失败");
            return text(
                StatusCode::BAD_GATEWAY,
                format!("连不上 127.0.0.1:{port}：确认该端口的服务已经启动，端口与 {CONFIG_RELATIVE} 一致"),
            );
        }
    };

    let status =
        StatusCode::from_u16(response.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);

    // `bytes_stream` 会吃掉 response，头要先拷出来。
    let upstream_headers = response.headers().clone();
    let mut out = Response::new(Body::from_stream(response.bytes_stream()));
    *out.status_mut() = status;

    let headers = out.headers_mut();
    for (name, value) in &upstream_headers {
        if HOP_BY_HOP.contains(&name.as_str()) {
            continue;
        }
        if let Ok(value) = HeaderValue::from_bytes(value.as_bytes()) {
            // append 而不是 insert：`set-cookie` 这类头本来就允许多条。
            headers.append(name.clone(), value);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hop_by_hop_headers_are_dropped() {
        for name in [
            "connection",
            "keep-alive",
            "transfer-encoding",
            "upgrade",
            "te",
        ] {
            assert!(HOP_BY_HOP.contains(&name), "{name} 应被剥离");
        }
        // 这几个必须透传：丢了浏览器就拿不到编码信息与缓存指令。
        assert!(!HOP_BY_HOP.contains(&"content-encoding"));
        assert!(!HOP_BY_HOP.contains(&"content-type"));
        assert!(!REQUEST_SKIP.contains(&"accept"));
        // Host 必须丢给 reqwest 重写，否则上游看到的是客户端桥接端口。
        assert!(REQUEST_SKIP.contains(&"host"));
    }
}
