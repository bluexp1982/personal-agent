//! SSH 隧道端点的鉴权、预检、拒绝与真实升级路径。
//!
//! `oneshot` 拿不到底层 socket，axum 会以 426 拒绝升级请求；因此凡是要走过
//! `WebSocketUpgrade` 的用例都起一个真实监听（回环明文），用裸 TCP 发 HTTP/1.1。
//! 这样测的是"真的能升级、真的连到了 sshd"，而不是只断言状态码。

mod common;

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use jarvis_service::api;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// 裸请求里固定用的 WS key（RFC 6455 的示例值，服务端只做 base64+sha1 派生）。
const WS_KEY: &str = "dGhlIHNhbXBsZSBub25jZQ==";

/// 起一个真实监听，返回端口与任务句柄。
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
                // 端口文件先于 accept 循环写入，给它一点时间进入 accept。
                tokio::time::sleep(Duration::from_millis(20)).await;
                return port;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("服务未在 {}ms 内写出 api.port", common::wait_limit_ms());
}

/// 发一个带升级头的 `GET /api/ssh`，返回连接、响应头与可能已经读到的正文。
async fn upgrade_request(port: u16, token: Option<&str>) -> (TcpStream, String, Vec<u8>) {
    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("连接服务失败");

    let mut head = format!(
        "GET /api/ssh HTTP/1.1\r\n\
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

/// 读到响应头结束，并把"同一段里已经跟过来的正文"一起返回。
///
/// 错误响应很小，头与体常常在同一个 TCP 段里到达；丢掉这段剩余字节，
/// 后续再怎么读都只能读到空串。
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

/// 读一小段响应体：先看头后面已经跟过来的字节，不够再补一次读。
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

/// 构造一个客户端 → 服务端的掩码二进制帧。
fn masked_binary_frame(payload: &[u8]) -> Vec<u8> {
    assert!(payload.len() < 126, "测试只用短帧");
    let mask = [0x37u8, 0x11, 0x5a, 0x01];
    let mut frame = Vec::with_capacity(payload.len() + 6);
    frame.push(0x82); // FIN + Binary
    frame.push(0x80 | payload.len() as u8);
    frame.extend_from_slice(&mask);
    for (index, byte) in payload.iter().enumerate() {
        frame.push(byte ^ mask[index % 4]);
    }
    frame
}

/// 解析一帧服务端 → 客户端的二进制消息（服务端不加掩码）。
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
            Request::get("/api/ssh")
                .body(Body::empty())
                .expect("构造请求失败"),
        )
        .await;

    // 没有升级头时 axum 会先拒绝升级；这里只关心"未带令牌一定拿不到隧道"。
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "unauthenticated");
}

#[tokio::test]
async fn info_reports_disabled_without_probing() {
    let ctx = common::setup_with(|config| {
        config.ssh.enabled = false;
        // 故意指向一个必然连不上的端口：没启用时它不该被碰。
        config.ssh.target = "127.0.0.1:1".to_string();
    })
    .await;
    let (_, token) = ctx.pair_and_login("ssh-info-disabled").await;

    let response = ctx.call(common::authed_get("/api/ssh/info", &token)).await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    assert_eq!(body["enabled"], false);
    assert_eq!(body["sshd_reachable"], false);
    assert_eq!(body["target"], "127.0.0.1:1");
}

#[tokio::test]
async fn info_reflects_reachable_target() {
    // 只起一个 TCP 监听，不实现 SSH：预检只判断"能不能连上"。
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定临时端口失败");
    let target = listener.local_addr().expect("读取端口失败").to_string();

    let ctx = common::setup_with(|config| {
        config.ssh.target = target.clone();
    })
    .await;
    let (_, token) = ctx.pair_and_login("ssh-info-reachable").await;

    let accept = tokio::spawn(async move {
        let _ = listener.accept().await;
    });

    let response = ctx.call(common::authed_get("/api/ssh/info", &token)).await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    assert_eq!(body["enabled"], true);
    assert_eq!(body["target"], target.as_str());
    assert_eq!(body["sshd_reachable"], true);

    accept.abort();
}

#[tokio::test]
async fn tunnel_reports_ssh_unavailable_when_sshd_is_down() {
    // 拿一个刚释放的端口：几乎不可能有人在监听它。
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定临时端口失败");
    let target = listener.local_addr().expect("读取端口失败").to_string();
    drop(listener);

    let ctx = common::setup_with(|config| {
        config.ssh.target = target;
    })
    .await;
    let (_, token) = ctx.pair_and_login("ssh-down").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, leftover) = upgrade_request(port, Some(&token)).await;
    assert!(headers.contains("503"), "sshd 不可达应当 503：{headers}");

    let body = read_some_body(&mut stream, leftover).await;
    assert!(
        body.contains("ssh_unavailable"),
        "应当返回统一错误体：{body}"
    );
    assert!(
        body.contains("\"retryable\":true"),
        "打开 sshd 之后重试就该能连上：{body}"
    );

    server.abort();
}

#[tokio::test]
async fn tunnel_refuses_beyond_max_sessions() {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定临时端口失败");
    let target = listener.local_addr().expect("读取端口失败").to_string();

    let ctx = common::setup_with(|config| {
        config.ssh.target = target;
        config.ssh.max_sessions = 1;
    })
    .await;
    let (_, token) = ctx.pair_and_login("ssh-limit").await;
    let (port, server) = start_server(&ctx).await;

    // 占掉唯一的名额：模拟"已经有一个终端开着"。
    let _held = ctx
        .state
        .ssh_slots
        .clone()
        .try_acquire_owned()
        .expect("应当能拿到名额");

    let (mut stream, headers, leftover) = upgrade_request(port, Some(&token)).await;
    assert!(headers.contains("429"), "超出上限应当 429：{headers}");

    let body = read_some_body(&mut stream, leftover).await;
    assert!(body.contains("rate_limited"), "{body}");

    server.abort();
}

#[tokio::test]
async fn tunnel_upgrades_and_pipes_bytes_both_ways() {
    // 假 sshd：收到字节就原样回写，用来验证两条方向都通了。
    let sshd = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定假 sshd 失败");
    let target = sshd.local_addr().expect("读取端口失败").to_string();
    let echo = tokio::spawn(async move {
        let (mut socket, _) = sshd.accept().await.expect("accept 失败");
        let mut buffer = [0u8; 64];
        let n = socket.read(&mut buffer).await.expect("读取上游字节失败");
        socket
            .write_all(&buffer[..n])
            .await
            .expect("回写上游字节失败");
        socket.flush().await.expect("flush 失败");
        // 保持连接，直到测试断言完。
        tokio::time::sleep(Duration::from_secs(2)).await;
    });

    let ctx = common::setup_with(|config| {
        config.ssh.target = target;
    })
    .await;
    let (_, token) = ctx.pair_and_login("ssh-upgrade").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, _) = upgrade_request(port, Some(&token)).await;
    assert!(
        headers.contains("101"),
        "鉴权通过且 sshd 可达时应当完成升级：{headers}"
    );

    // 客户端 → sshd：掩码二进制帧里的负载必须原样到达上游。
    stream
        .write_all(&masked_binary_frame(b"whoami\n"))
        .await
        .expect("写 WS 帧失败");
    stream.flush().await.expect("flush 失败");

    // sshd → 客户端：上游回写的字节必须包成一帧二进制回来。
    let echoed = read_binary_frame(&mut stream).await;
    assert_eq!(echoed, b"whoami\n", "隧道必须双向透传且不改写字节");

    server.abort();
    echo.abort();
}

#[tokio::test]
async fn text_frames_close_the_tunnel() {
    let sshd = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定假 sshd 失败");
    let target = sshd.local_addr().expect("读取端口失败").to_string();
    tokio::spawn(async move {
        let (mut socket, _) = sshd.accept().await.expect("accept 失败");
        // 上游什么也不做，等隧道被客户端踢掉后自动断开。
        let mut buffer = [0u8; 8];
        let _ = socket.read(&mut buffer).await;
    });

    let ctx = common::setup_with(|config| {
        config.ssh.target = target;
    })
    .await;
    let (_, token) = ctx.pair_and_login("ssh-text-frame").await;
    let (port, server) = start_server(&ctx).await;

    let (mut stream, headers, _) = upgrade_request(port, Some(&token)).await;
    assert!(headers.contains("101"), "{headers}");

    // 文本帧不是本协议的合法输入：服务端应主动收尾（Close 帧随后连接断开）。
    let mask = [0x01u8, 0x02, 0x03, 0x04];
    let payload = b"hello";
    let mut frame = vec![0x81u8, 0x80 | payload.len() as u8];
    frame.extend_from_slice(&mask);
    for (index, byte) in payload.iter().enumerate() {
        frame.push(byte ^ mask[index % 4]);
    }
    stream.write_all(&frame).await.expect("写文本帧失败");

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
