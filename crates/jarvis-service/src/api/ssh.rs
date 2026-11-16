//! SSH 隧道：`/api/ssh` 的 WebSocket ⇄ 服务端本机 sshd 的 TCP。
//!
//! 这里**不解析 SSH 协议**：WebSocket 二进制帧就是一个纯字节流，SSH 自己的握手、
//! 密码认证、加密与主机密钥校验全部由客户端（`dartssh2`）完成。服务端只负责
//! "谁在连、连到哪、还能连几条"，因此不需要引入任何 SSH 库，也不会碰到用户密码。
//!
//! 为什么值得加这条隧道而不是让客户端直连 22 端口：
//! - 可达性与 `/api/*` 完全一致，手机在外网或防火墙只放行 8787 时也能用；
//! - 鉴权复用 `require_device`，不必为 SSH 再造一套令牌校验；
//! - 22 端口不必对局域网/公网暴露。
//!
//! 代价是终点必须锁死在回环地址（见 `Config::validate_ssh`）：否则这个端点会变成
//! 一个"任何已配对设备都能用的内网跳板"。

use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Extension, State};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures_util::{SinkExt, StreamExt};
use protocol::{ErrorCode, SshTunnelInfo};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::api::error::ApiRejection;
use crate::auth::AuthDevice;
use crate::shutdown::ShutdownNotice;
use crate::state::AppState;

/// 单帧上限。SSH 的包通常只有几百字节到几十 KB；64 KiB 足够覆盖大段输出，
/// 又不至于让一条隧道靠单个大帧把内存顶起来。
const MAX_FRAME_BYTES: usize = 64 * 1024;

/// TCP 读缓冲。与上面的帧上限同量级，避免一次读直接产出超大帧。
const READ_BUFFER_BYTES: usize = 16 * 1024;

/// 连 sshd 的超时。回环连接要么立刻成功要么立刻失败，5 秒已经非常宽裕。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// 探测超时。客户端在输密码前会调 `/api/ssh/info`，这里不能让一个卡住的
/// 回环连接把界面拖到转圈。
const PROBE_TIMEOUT: Duration = Duration::from_millis(800);

// 编译期约束：读缓冲必须小于帧上限，否则一次读就产出超限帧，服务端会踢掉自己；
// 帧上限也不该无限放大，否则一条隧道能靠单个大帧吃掉内存。
const _: () = assert!(READ_BUFFER_BYTES < MAX_FRAME_BYTES);
const _: () = assert!(MAX_FRAME_BYTES <= 256 * 1024);

/// `GET /api/ssh/info`：连之前先问一句"能不能连"。
///
/// 没有它，用户只能靠"输完密码再失败"来判断服务端没开远程登录——
/// 而这个失败在界面上和"密码错了"长得几乎一样。
pub async fn info(State(state): State<AppState>) -> Json<SshTunnelInfo> {
    let enabled = state.config.ssh.enabled;
    let target = state.config.ssh.target.clone();
    let sshd_reachable = enabled && probe(&target).await;

    Json(SshTunnelInfo {
        enabled,
        target,
        sshd_reachable,
    })
}

/// `GET /api/ssh`：升级为 WebSocket 后做纯字节透传。
pub async fn tunnel(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
) -> Response {
    if !state.config.ssh.enabled {
        return ApiRejection::new(
            ErrorCode::SshUnavailable,
            "ssh tunnel disabled",
            "服务端没有开启 SSH 隧道；请在服务端配置里把 ssh.enabled 设为 true 后重启",
        )
        .into_response();
    }

    // 先占坑再连：并发上限的意义是"最多几条 shell"，不是"最多几次握手"。
    // 拿不到名额时直接拒绝，避免排队的请求在后台悄悄开出一堆连接。
    let permit = match state.ssh_slots.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            tracing::warn!(
                device_id = %device.device_id,
                max_sessions = state.config.ssh.max_sessions,
                "SSH 隧道达到并发上限，拒绝新会话"
            );
            return ApiRejection::new(
                ErrorCode::RateLimited,
                "too many ssh sessions",
                "同时打开的终端数已达上限，请先关闭其它终端再试",
            )
            .into_response();
        }
    };

    let target = state.config.ssh.target.clone();
    let upstream = match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(&target)).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(err)) => {
            tracing::warn!(%target, %err, "SSH 隧道无法连接本机 sshd");
            return sshd_unreachable().into_response();
        }
        Err(_) => {
            tracing::warn!(%target, "SSH 隧道连接本机 sshd 超时");
            return sshd_unreachable().into_response();
        }
    };

    // TCP 已经连上但还没升级：这条连接不该被后续的握手失败泄漏掉。
    let _ = upstream.set_nodelay(true);

    let shutdown = state.shutdown.clone();
    let device_id = device.device_id.clone();
    let log_target = target.clone();

    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| async move {
            // permit 活到隧道结束：这样并发上限统计的是"活着的终端"，而不是"进过 handler 的请求"。
            let _permit = permit;
            tracing::info!(%device_id, %log_target, "SSH 隧道已打开");

            let stats = pump(socket, upstream, shutdown).await;

            tracing::info!(
                %device_id,
                %log_target,
                upstream_bytes = stats.upstream,
                downstream_bytes = stats.downstream,
                reason = stats.reason,
                "SSH 隧道已关闭"
            );
        })
        .into_response()
}

fn sshd_unreachable() -> ApiRejection {
    ApiRejection::new(
        ErrorCode::SshUnavailable,
        "local sshd is unreachable",
        "服务端本机的 sshd 连不上：请在服务端打开「远程登录 / SSH」，确认 22 端口在监听后重试",
    )
}

/// 只探测 TCP 可连性，不发任何 SSH 字节。
async fn probe(target: &str) -> bool {
    matches!(
        tokio::time::timeout(PROBE_TIMEOUT, TcpStream::connect(target)).await,
        Ok(Ok(_))
    )
}

/// 隧道关闭后的统计。只记字节数与原因，**不记内容**：终端里可能有敏感命令。
struct PumpStats {
    upstream: u64,
    downstream: u64,
    reason: &'static str,
}

impl PumpStats {
    fn new() -> Self {
        Self {
            upstream: 0,
            downstream: 0,
            reason: "unknown",
        }
    }
}

/// 双向泵送，直到任意一侧结束。
///
/// 客户端 → sshd 走 WebSocket 的 Binary 帧；sshd → 客户端同样。文本帧直接断开：
/// 允许第二种帧类型只会让"发了没反应"变成需要翻日志的谜案。
async fn pump(socket: WebSocket, upstream: TcpStream, shutdown: Arc<ShutdownNotice>) -> PumpStats {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let (mut tcp_rx, mut tcp_tx) = upstream.into_split();

    let mut stats = PumpStats::new();
    let mut buffer = vec![0u8; READ_BUFFER_BYTES];

    loop {
        tokio::select! {
            // 先看关闭信号：服务停的时候不该等另一侧再发一个字节才退出。
            biased;
            _ = shutdown.wait() => {
                stats.reason = "shutdown";
                break;
            }
            incoming = ws_rx.next() => match incoming {
                Some(Ok(Message::Binary(bytes))) => {
                    if tcp_tx.write_all(&bytes).await.is_err() {
                        stats.reason = "sshd_write_failed";
                        break;
                    }
                    stats.upstream += bytes.len() as u64;
                }
                Some(Ok(Message::Ping(payload))) => {
                    // 浏览器/客户端都可能发心跳；不回 Pong 会被对端判定为死连接。
                    if ws_tx.send(Message::Pong(payload)).await.is_err() {
                        stats.reason = "client_closed";
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | None => {
                    stats.reason = "client_closed";
                    break;
                }
                Some(Ok(Message::Text(_))) => {
                    stats.reason = "unexpected_text_frame";
                    break;
                }
                // Pong 与未来新增的控制帧：忽略即可，不必因此断开。
                Some(Ok(_)) => {}
                Some(Err(_)) => {
                    stats.reason = "client_error";
                    break;
                }
            },
            read = tcp_rx.read(&mut buffer) => match read {
                Ok(0) => {
                    stats.reason = "sshd_closed";
                    break;
                }
                Ok(n) => {
                    if ws_tx
                        .send(Message::Binary(buffer[..n].to_vec().into()))
                        .await
                        .is_err()
                    {
                        stats.reason = "client_closed";
                        break;
                    }
                    stats.downstream += n as u64;
                }
                Err(_) => {
                    stats.reason = "sshd_read_failed";
                    break;
                }
            },
        }
    }

    // 先发 Close 帧再关 TCP：顺序反了客户端看到的是"连接被重置"，
    // 而不是一次正常的会话结束。
    let _ = ws_tx.send(Message::Close(None)).await;
    let _ = tcp_tx.shutdown().await;
    stats
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn probe_reports_closed_port_as_unreachable() {
        // 绑一个端口再立刻释放：拿到一个几乎必然没人监听的端口号。
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定临时端口失败");
        let addr = listener.local_addr().expect("读取端口失败");
        drop(listener);

        assert!(!probe(&addr.to_string()).await, "没有监听时应当判为不可达");
    }

    #[tokio::test]
    async fn probe_reports_listening_port_as_reachable() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定临时端口失败");
        let addr = listener.local_addr().expect("读取端口失败");

        // 只要有监听就算可达：探测只连不发，不需要真的 sshd。
        let accept = tokio::spawn(async move {
            let _ = listener.accept().await;
        });
        assert!(probe(&addr.to_string()).await);
        accept.abort();
    }
}
