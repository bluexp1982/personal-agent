//! 自签 TLS 的端到端验证。
//!
//! 与其它集成测试的区别：这里必须起一个真实监听端口。TLS 握手、SSE 分帧、
//! 连接排空都发生在传输层，直接对 `Router` 调 `oneshot` 根本不会经过它们。
//!
//! 客户端用 `rustls` 只信任服务端证书（等价于客户端"按指纹固定"的行为）：
//! 换一张证书就必须握手失败，这是整个信任模型的底线。

mod common;

use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::{CertificateDer, ServerName};
use rustls::{ClientConfig, RootCertStore};
use jarvis_service::tls::TlsIdentity;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;

use common::{body_json, setup, setup_with};

/// 只信任给定证书的客户端配置。
fn client_config(cert_der: &[u8]) -> Arc<ClientConfig> {
    let mut roots = RootCertStore::empty();
    roots
        .add(CertificateDer::from(cert_der.to_vec()))
        .expect("证书应当可以加入信任库");

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("默认协议版本可用")
        .with_root_certificates(roots)
        .with_no_client_auth();
    Arc::new(config)
}

async fn connect(port: u16, cert_der: &[u8]) -> TlsStream<TcpStream> {
    let stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("连接服务失败");
    let connector = tokio_rustls::TlsConnector::from(client_config(cert_der));
    // 证书 SAN 里有 localhost；客户端实际按指纹而非主机名信任，这里只是走标准校验。
    let name = ServerName::try_from("localhost").expect("非法主机名");
    connector.connect(name, stream).await.expect("TLS 握手失败")
}

/// 发一条完整的 HTTP/1.1 请求并读完响应（靠 `Connection: close` 收尾）。
async fn request(
    stream: &mut TlsStream<TcpStream>,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&str>,
) -> String {
    let payload = body.unwrap_or("");
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {}\r\n",
        payload.len()
    );
    if let Some(token) = token {
        head.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    if body.is_some() {
        head.push_str("Content-Type: application/json\r\n");
    }
    head.push_str("\r\n");
    head.push_str(payload);

    stream.write_all(head.as_bytes()).await.expect("写请求失败");
    stream.flush().await.expect("flush 失败");

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await.expect("读响应失败");
    String::from_utf8_lossy(&raw).into_owned()
}

/// 读取 SSE，直到出现 `message_completed`（或超时）。
async fn read_until_completed(stream: &mut TlsStream<TcpStream>, timeout: Duration) -> String {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 1024];

    let result = tokio::time::timeout(timeout, async {
        loop {
            let read = stream.read(&mut chunk).await.expect("读取事件流失败");
            if read == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..read]);
            if String::from_utf8_lossy(&buffer).contains("message_completed") {
                break;
            }
        }
    })
    .await;

    assert!(
        result.is_ok(),
        "SSE 未在 {timeout:?} 内给出 message_completed，已收到：{}",
        String::from_utf8_lossy(&buffer)
    );
    String::from_utf8_lossy(&buffer).into_owned()
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

#[tokio::test]
async fn tls_handshake_auth_and_sse() {
    let ctx = setup_with(|config| config.tls.mode = jarvis_service::config::TlsMode::On).await;
    let tls = TlsIdentity::load_or_create(&ctx.state.config).expect("生成证书失败");
    let cert_der = tls.cert_der().to_vec();
    let fingerprint = tls.fingerprint().to_string();

    let mut state = ctx.state.clone();
    state.tls = Some(Arc::new(tls));
    let router = jarvis_service::api::router(state.clone());
    let server = tokio::spawn(async move { jarvis_service::api::serve(state, router).await });

    let port = wait_for_port(&ctx).await;
    assert_eq!(fingerprint.len(), 19, "指纹是四组短码");

    // 1. 未授权请求必须能穿过 TLS 到达业务层（而不是握手就断）
    let mut stream = connect(port, &cert_der).await;
    let response = request(&mut stream, "GET", "/api/auth/me", None, None).await;
    assert!(response.contains("401"), "未带令牌应当 401：{response}");
    assert!(
        response.contains("unauthenticated"),
        "应当返回统一错误体：{response}"
    );

    // 2. 走完整配对与登录（这两步在测试里直接打 Router，不重复验证鉴权）
    let (_, token) = ctx.pair_and_login("tls-client").await;

    let mut stream = connect(port, &cert_der).await;
    let response = request(&mut stream, "GET", "/api/auth/me", Some(&token), None).await;
    assert!(response.contains("200"), "带令牌应当 200：{response}");

    // 3. SSE 在 TLS 上必须逐帧可见（流式回答的核心）
    let project_id = ctx.work_project("tls").await;
    let created = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "title": "TLS 冒烟", "project_id": project_id }),
        )
        .await;
    let conversation = body_json(created).await;
    let conversation_id = conversation["id"].as_str().expect("缺少会话 id");

    let mut stream = connect(port, &cert_der).await;
    let payload = serde_json::json!({ "content": "TLS 通道上的流式回答" }).to_string();
    let head = format!(
        "POST /api/conversations/{conversation_id}/messages HTTP/1.1\r\n\
         Host: localhost\r\n\
         Connection: close\r\n\
         Authorization: Bearer {token}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\r\n{payload}",
        payload.len()
    );
    stream.write_all(head.as_bytes()).await.expect("写请求失败");
    stream.flush().await.expect("flush 失败");

    let events =
        read_until_completed(&mut stream, Duration::from_millis(common::wait_limit_ms())).await;
    assert!(
        events.contains("message_delta"),
        "流式回答应当先有增量事件：{events}"
    );

    server.abort();
}

#[tokio::test]
async fn client_trusting_another_certificate_is_rejected() {
    let ctx = setup().await;
    let tls = TlsIdentity::load_or_create(&ctx.state.config).expect("生成证书失败");
    let server_cert = tls.cert_der().to_vec();

    let mut state = ctx.state.clone();
    state.tls = Some(Arc::new(tls));
    let router = jarvis_service::api::router(state.clone());
    let server = tokio::spawn(async move { jarvis_service::api::serve(state, router).await });

    let port = wait_for_port(&ctx).await;

    // 另一台"机器"的证书：用它当信任根，握手必须失败。
    let other_dir = tempfile::tempdir().expect("创建临时目录失败");
    let other_config = jarvis_service::config::Config {
        data_dir: other_dir.path().to_path_buf(),
        ..Default::default()
    };
    let other = TlsIdentity::load_or_create(&other_config).expect("生成另一张证书失败");

    let stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("连接服务失败");
    let connector = tokio_rustls::TlsConnector::from(client_config(other.cert_der()));
    let outcome = connector
        .connect(ServerName::try_from("localhost").unwrap(), stream)
        .await;

    assert!(
        outcome.is_err(),
        "信任另一张证书时必须握手失败；证书有 {} 字节",
        server_cert.len()
    );

    server.abort();
}

#[tokio::test]
async fn plaintext_on_non_loopback_is_refused_at_startup() {
    let dir = tempfile::tempdir().expect("创建临时目录失败");
    let config_path = dir.path().join("config.json");
    let config = serde_json::json!({
        "api_bind": "0.0.0.0:0",
        "data_dir": dir.path().join("data").to_string_lossy(),
        "tls": { "mode": "off" },
        "worker_enabled": false,
    });
    std::fs::write(&config_path, config.to_string()).expect("写配置失败");

    let output = std::process::Command::new(env!("CARGO_BIN_EXE_jarvis-service"))
        .arg("--foreground")
        .arg("--config")
        .arg(&config_path)
        .output()
        .expect("启动二进制失败");

    assert!(!output.status.success(), "非回环 + 明文应当在启动时被拒绝");
    // tracing 的 fmt subscriber 默认写 stdout（daemon-kit 会把两者都收进日志文件），
    // 因此两处都要看。
    let logs = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        logs.contains("allow_insecure_plaintext"),
        "错误信息要给出改法：{logs}"
    );
}
