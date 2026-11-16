//! 浏览器隧道端点的鉴权、白名单、并发上限与真实字节透传。
//!
//! 与 `ssh_tunnel.rs` 同一套测试手法：`oneshot` 拿不到底层 socket，凡是要走过
//! `WebSocketUpgrade` 的用例都起一个真实监听（回环明文），用裸 TCP 发 HTTP/1.1。
//! 这样测的是"真的能升级、真的连到了目标端口"，而不是只断言状态码。

mod common;

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use jarvis_service::api;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

const WS_KEY: &str = "dGhlIHNhbXBsZSBub25jZQ==";

async fn start_server(ctx: &common::TestContext) -> (u16, JoinHandle<std::io::Result<()>>) {
    let router = api::router(ctx.state.clone());
    let state = ctx.state.clone();
    let server = tokio::spawn(async move { api::serve(state, router).await });
    let port = wait_for_port(ctx).await;
    (port, server)
}

/// 从 `api.port` 读实际端口：绑定 `:0` 时只有服务自己知道。
async fn wait_for_port(ctx: &common::TestContext) -> u16 {
    let path = ctx.state.config.api_port_path();
    let deadline = std::time::Instant::now() + Duration::from_millis(common::wait_limit_ms());
    while std::time::Instant::now() < deadline {
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Ok(port) = text.trim().parse::<u16>() {
                tokio::time::sleep(Duration::from_millis(20)).await;
                return port;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("服务未在 {}ms 内写出 api.port", common::wait_limit_ms());
}

/// 发一个带升级头的 `GET /api/browser/tunnel?target=...`。
async fn upgrade_request(
    port: u16,
    target: &str,
    token: Option<&str>,
) -> (TcpStream, String, Vec<u8>) {
    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("连接服务失败");

    let mut head = format!(
        "GET /api/browser/tunnel?target={target} HTTP/1.1\r\n\
         Host: localhost\r\n\
         Connection: Upgrade\r\n\
         Upgrade: websocket\r\n\
         Sec-WebSocket-Version: 13\r\n\
         Sec-WebSocket-Key: {WS_KEY}\r\n\
         Content-Length: 0\r\n"
    );
    if let Some(token) = token {
        head.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    head.push_str("\r\n");

    stream.write_all(head.as_bytes()).await.expect("写请求失败");
    stream.flush().await.expect("flush 失败");

    let (headers, leftover) = read_until_headers(&mut stream).await;
    (stream, headers, leftover)
}

async fn read_until_headers(stream: &mut TcpStream) -> (String, Vec<u8>) {
    let mut raw = Vec::new();
    let mut chunk = [0u8; 512];
    loop {
        let read = tokio::time::timeout(Duration::from_secs(3), stream.read(&mut chunk))
            .await
            .expect("读取响应头超时")
            .expect("读取响应头失败");
        if read == 0 {
            break;
        }
        raw.extend_from_slice(&chunk[..read]);
        if let Some(index) = raw.windows(4).position(|window| window == b"\r\n\r\n") {
            let split = index + 4;
            let body = raw.split_off(split);
            return (String::from_utf8_lossy(&raw).into_owned(), body);
        }
    }
    (String::from_utf8_lossy(&raw).into_owned(), Vec::new())
}

async fn read_some_body(stream: &mut TcpStream, leftover: Vec<u8>) -> String {
    if !leftover.is_empty() {
        return String::from_utf8_lossy(&leftover).into_owned();
    }
    let mut chunk = [0u8; 1024];
    match tokio::time::timeout(Duration::from_secs(2), stream.read(&mut chunk)).await {
        Ok(Ok(n)) => String::from_utf8_lossy(&chunk[..n]).into_owned(),
        _ => String::new(),
    }
}

fn masked_frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
    assert!(payload.len() < 126, "测试只用短帧");
    let mask = [0x37u8, 0x11, 0x5a, 0x01];
    let mut frame = Vec::with_capacity(payload.len() + 6);
    frame.push(0x80 | opcode);
    frame.push(0x80 | payload.len() as u8);
    frame.extend_from_slice(&mask);
    for (index, byte) in payload.iter().enumerate() {
        frame.push(byte ^ mask[index % 4]);
    }
    frame
}

async fn read_binary_frame(stream: &mut TcpStream) -> Vec<u8> {
    let mut header = [0u8; 2];
    tokio::time::timeout(Duration::from_secs(2), stream.read_exact(&mut header))
        .await
        .expect("读取 WS 帧头超时")
        .expect("读取 WS 帧头失败");

    assert_eq!(header[0] & 0x0f, 0x2, "只期望二进制帧");
    let len = (header[1] & 0x7f) as usize;
    assert!(len < 126, "测试只用短帧");
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await.expect("读取负载失败");
    payload
}

#[tokio::test]
async fn tunnel_requires_paired_device() {
    let ctx = common::setup().await;
    let response = ctx
        .call(
            Request::get("/api/browser/tunnel?target=127.0.0.1:3000")
                .body(Body::empty())
                .expect("构造请求失败"),
        )
        .await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "unauthenticated");
}

#[tokio::test]
async fn info_reports_configured_whitelist() {
    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![5173, 3000];
        config.browser.max_tunnels = 32;
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-info").await;

    let response = ctx
        .call(common::authed_get("/api/browser/info", &token))
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    assert_eq!(body["enabled"], true);
    assert_eq!(body["loopback_only"], true);
    assert_eq!(body["max_tunnels"], 32);
    assert_eq!(body["allowed_ports"], serde_json::json!([5173, 3000]));
}

#[tokio::test]
async fn info_reports_disabled() {
    let ctx = common::setup_with(|config| {
        config.browser.enabled = false;
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-info-disabled").await;

    let response = ctx
        .call(common::authed_get("/api/browser/info", &token))
        .await;
    let body = common::body_json(response).await;
    assert_eq!(body["enabled"], false);
}

#[tokio::test]
async fn tunnel_denies_port_outside_allowlist() {
    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![5173];
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-denied-port").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, leftover) =
        upgrade_request(port, "127.0.0.1:3000", Some(&token)).await;
    assert!(headers.contains("403"), "白名单外的端口应当 403：{headers}");

    let body = read_some_body(&mut stream, leftover).await;
    assert!(body.contains("browser_target_denied"), "{body}");
    assert!(body.contains("5173"), "提示要列出允许的端口：{body}");

    server.abort();
}

#[tokio::test]
async fn tunnel_denies_non_loopback_target() {
    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![3000];
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-denied-host").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, leftover) =
        upgrade_request(port, "192.168.1.10:3000", Some(&token)).await;
    assert!(headers.contains("403"), "非回环目标应当 403：{headers}");

    let body = read_some_body(&mut stream, leftover).await;
    assert!(body.contains("browser_target_denied"), "{body}");

    server.abort();
}

#[tokio::test]
async fn tunnel_upgrades_and_pipes_bytes_both_ways() {
    // 假 dev server：收到字节就原样回写，验证两个方向都通。
    let target = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定假目标失败");
    let target_port = target.local_addr().expect("读取端口失败").port();
    let echo = tokio::spawn(async move {
        let (mut socket, _) = target.accept().await.expect("accept 失败");
        let mut buffer = [0u8; 64];
        let n = socket.read(&mut buffer).await.expect("读取上游字节失败");
        socket
            .write_all(&buffer[..n])
            .await
            .expect("回写上游字节失败");
        socket.flush().await.expect("flush 失败");
        tokio::time::sleep(Duration::from_secs(2)).await;
    });

    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![target_port];
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-upgrade").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, _) =
        upgrade_request(port, &format!("127.0.0.1:{target_port}"), Some(&token)).await;
    assert!(
        headers.contains("101"),
        "鉴权通过且目标可达时应当完成升级：{headers}"
    );

    stream
        .write_all(&masked_frame(0x2, b"GET / HTTP/1.1\r\n\r\n"))
        .await
        .expect("写 WS 帧失败");
    stream.flush().await.expect("flush 失败");

    let echoed = read_binary_frame(&mut stream).await;
    assert_eq!(
        echoed, b"GET / HTTP/1.1\r\n\r\n",
        "隧道必须双向透传且不改字节"
    );

    server.abort();
    echo.abort();
}

#[tokio::test]
async fn tunnel_reports_unavailable_when_target_refuses() {
    // 拿一个刚释放的端口：几乎不可能有人在监听它。
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定临时端口失败");
    let target_port = listener.local_addr().expect("读取端口失败").port();
    drop(listener);

    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![target_port];
        config.browser.connect_timeout_ms = 500;
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-down").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, leftover) =
        upgrade_request(port, &format!("127.0.0.1:{target_port}"), Some(&token)).await;
    assert!(headers.contains("503"), "目标拒连应当 503：{headers}");

    let body = read_some_body(&mut stream, leftover).await;
    assert!(body.contains("browser_unavailable"), "{body}");
    assert!(
        body.contains("\"retryable\":true"),
        "端口服务起来后重试就该能连上：{body}"
    );

    server.abort();
}

#[tokio::test]
async fn tunnel_refuses_beyond_global_limit() {
    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![3000];
        config.browser.max_tunnels = 1;
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-limit").await;
    let (port, server) = start_server(&ctx).await;

    // 占掉唯一的名额：模拟"已经有一条连接开着"。
    let _held = ctx
        .state
        .browser_slots
        .clone()
        .try_acquire_owned()
        .expect("应当能拿到名额");

    let (mut stream, headers, leftover) =
        upgrade_request(port, "127.0.0.1:3000", Some(&token)).await;
    assert!(headers.contains("429"), "超出上限应当 429：{headers}");

    let body = read_some_body(&mut stream, leftover).await;
    assert!(body.contains("rate_limited"), "{body}");

    server.abort();
}

#[tokio::test]
async fn tunnel_refuses_beyond_per_device_limit() {
    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![3000];
        config.browser.max_tunnels = 8;
        config.browser.max_tunnels_per_device = 1;
    })
    .await;
    let (device_id, token) = ctx.pair_and_login("browser-device-limit").await;
    let (port, server) = start_server(&ctx).await;

    let _held = ctx
        .state
        .acquire_browser_device(&device_id)
        .expect("应当能拿到设备名额");

    let (mut stream, headers, leftover) =
        upgrade_request(port, "127.0.0.1:3000", Some(&token)).await;
    assert!(headers.contains("429"), "单设备超限应当 429：{headers}");

    let body = read_some_body(&mut stream, leftover).await;
    assert!(body.contains("rate_limited"), "{body}");

    server.abort();
}

#[tokio::test]
async fn text_frames_close_the_tunnel() {
    let target = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定假目标失败");
    let target_port = target.local_addr().expect("读取端口失败").port();
    tokio::spawn(async move {
        let (mut socket, _) = target.accept().await.expect("accept 失败");
        let mut buffer = [0u8; 8];
        let _ = socket.read(&mut buffer).await;
    });

    let ctx = common::setup_with(|config| {
        config.browser.allowed_ports = vec![target_port];
    })
    .await;
    let (_, token) = ctx.pair_and_login("browser-text-frame").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, _) =
        upgrade_request(port, &format!("127.0.0.1:{target_port}"), Some(&token)).await;
    assert!(headers.contains("101"), "{headers}");

    stream
        .write_all(&masked_frame(0x1, b"hello"))
        .await
        .expect("写文本帧失败");

    let mut rest = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), stream.read_to_end(&mut rest))
        .await
        .expect("服务端应当主动关闭连接")
        .expect("读取关闭帧失败");
    assert_eq!(
        rest.first().map(|byte| byte & 0x0f),
        Some(0x8),
        "应当先收到 Close 帧"
    );

    server.abort();
}
