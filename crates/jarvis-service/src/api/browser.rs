//! 浏览器隧道：`/api/browser/tunnel` 的 WebSocket ⇄ 服务端本机回环 TCP。
//!
//! 与 `ssh.rs` 同一套范式：不解析上层协议，二进制帧就是纯字节流，鉴权复用
//! `require_device`，关闭时先发 Close 帧再 shutdown TCP。
//!
//! 唯一的差别（也是整个功能的安全核心）：目标由客户端按需指定。因此这里
//! 必须自己把住三道门——
//! 1. 主机解析结果全部是回环地址；
//! 2. 端口在 `browser.allowed_ports` 内，且不是 SSH / `/api` 自身 / 编码代理；
//! 3. 全局与每设备两级并发上限，按 TCP 连接计。
//!
//! 为什么允许动态端口：面板要打开的是用户自己的 dev server，端口写不死；
//! 白名单把"任意端口"收窄成"用户显式允许的那几个"，而不是让配对等于可以扫本机。

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Extension, Query, State};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures_util::{SinkExt, StreamExt};
use protocol::{BrowserTunnelInfo, ErrorCode};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::api::error::ApiRejection;
use crate::auth::AuthDevice;
use crate::shutdown::ShutdownNotice;
use crate::state::AppState;

/// 单帧上限。与 SSH 隧道同量级：网页资源通常是几十 KB 的分块。
const MAX_FRAME_BYTES: usize = 64 * 1024;

/// TCP 读缓冲。小于帧上限，保证一次读不会产出超限帧。
const READ_BUFFER_BYTES: usize = 16 * 1024;

/// `target` 字符串长度上限。正常是 `host:port`，128 已经非常宽裕。
const MAX_TARGET_LEN: usize = 128;

const _: () = assert!(READ_BUFFER_BYTES < MAX_FRAME_BYTES);
const _: () = assert!(MAX_FRAME_BYTES <= 256 * 1024);

/// `GET /api/browser/info`：连之前先问一句"允许连哪些端口"。
///
/// 客户端据此在用户输入端口前就给出可执行提示，而不是让一次 WebSocket
/// 握手失败后只看到"网络错误"。
pub async fn info(State(state): State<AppState>) -> Json<BrowserTunnelInfo> {
    let config = &state.config.browser;
    Json(BrowserTunnelInfo {
        enabled: config.enabled,
        loopback_only: config.allowed_hosts.is_empty(),
        allowed_ports: config.allowed_ports.clone(),
        max_tunnels: config.max_tunnels,
    })
}

/// `GET /api/browser/tunnel?target=127.0.0.1:3000`：升级后做纯字节透传。
pub async fn tunnel(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if !state.config.browser.enabled {
        return ApiRejection::new(
            ErrorCode::BrowserUnavailable,
            "browser tunnel disabled",
            "服务端没有开启浏览器访问；请在服务端配置里把 browser.enabled 设为 true 后重启",
        )
        .into_response();
    }

    let Some(raw) = query.get("target") else {
        return invalid_target("缺少 target 参数").into_response();
    };

    let target = match resolve_target(raw, &state).await {
        Ok(target) => target,
        Err(rejection) => return rejection.into_response(),
    };

    // 先占名额再连目标：并发统计的是"活着的连接"，不是"正在握手的请求"。
    let Some(device_slot) = state.acquire_browser_device(&device.device_id) else {
        tracing::warn!(
            device_id = %device.device_id,
            per_device_limit = state.config.browser.max_tunnels_per_device,
            "浏览器隧道达到单设备上限，拒绝新连接"
        );
        return ApiRejection::new(
            ErrorCode::RateLimited,
            "too many browser tunnels for this device",
            "同时打开的网页连接数已达上限，请关掉一些页面或稍后再试",
        )
        .into_response();
    };

    let permit = match state.browser_slots.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            tracing::warn!(
                device_id = %device.device_id,
                max_tunnels = state.config.browser.max_tunnels,
                "浏览器隧道达到全局上限，拒绝新连接"
            );
            return ApiRejection::new(
                ErrorCode::RateLimited,
                "too many browser tunnels",
                "服务端同时打开的浏览器连接数已达上限，请稍后再试",
            )
            .into_response();
        }
    };

    let connect_timeout = Duration::from_millis(state.config.browser.connect_timeout_ms.max(1));
    let upstream = match tokio::time::timeout(connect_timeout, TcpStream::connect(target)).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(err)) => {
            tracing::warn!(%target, %err, "浏览器隧道无法连接目标端口");
            return unreachable(target).into_response();
        }
        Err(_) => {
            tracing::warn!(%target, "浏览器隧道连接目标端口超时");
            return unreachable(target).into_response();
        }
    };

    let _ = upstream.set_nodelay(true);

    let shutdown = state.shutdown.clone();
    let device_id = device.device_id.clone();
    let idle = Duration::from_millis(state.config.browser.idle_timeout_ms.max(1_000));

    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| async move {
            // 名额活到隧道结束：统计的是"活着的连接"，不是"进过 handler 的请求"。
            let _permit = permit;
            let _device_slot = device_slot;
            tracing::info!(%device_id, %target, "浏览器隧道已打开");

            let stats = pump(socket, upstream, shutdown, idle).await;

            tracing::info!(
                %device_id,
                %target,
                upstream_bytes = stats.upstream,
                downstream_bytes = stats.downstream,
                reason = stats.reason,
                "浏览器隧道已关闭"
            );
        })
        .into_response()
}

fn invalid_target(detail: &str) -> ApiRejection {
    ApiRejection::new(
        ErrorCode::InvalidRequest,
        format!("invalid browser target: {detail}"),
        "目标地址格式应为 host:port，例如 127.0.0.1:3000",
    )
}

fn denied_target(raw: &str, state: &AppState) -> ApiRejection {
    let ports = state
        .config
        .browser
        .allowed_ports
        .iter()
        .map(u16::to_string)
        .collect::<Vec<_>>()
        .join(", ");
    ApiRejection::new(
        ErrorCode::BrowserTargetDenied,
        format!("browser target denied: {raw}"),
        format!(
            "只允许访问服务端本机的回环端口（当前允许：{ports}）；要加端口请改服务端配置的 browser.allowed_ports 后重启"
        ),
    )
}

/// 目标端口可达性失败：与实际网络状况有关，允许重试。
fn unreachable(target: SocketAddr) -> ApiRejection {
    ApiRejection::new(
        ErrorCode::BrowserUnavailable,
        format!("browser target unreachable: {target}"),
        format!("服务端本机的 {target} 连不上：确认该端口的服务已经启动后再试"),
    )
}

/// 解析并校验目标。
///
/// 规则刻意收得很紧：
/// - 只认 `host:port` / `[v6]:port`，裸 IPv6 必须加方括号；
/// - 端口先过保留端口与白名单，再看主机——避免把"端口不允许"误报成"主机解析失败"；
/// - 主机名解析结果必须**全部**是回环，任何一条非回环都拒绝，防止 DNS 轮询绕过。
async fn resolve_target(raw: &str, state: &AppState) -> Result<SocketAddr, ApiRejection> {
    let raw = raw.trim();
    if raw.is_empty() || raw.len() > MAX_TARGET_LEN {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "browser target is empty or too long",
            "目标地址格式应为 host:port，例如 127.0.0.1:3000",
        ));
    }

    let (host, port) = split_host_port(raw).ok_or_else(|| {
        ApiRejection::new(
            ErrorCode::InvalidRequest,
            format!("browser target is not host:port: {raw}"),
            "目标地址格式应为 host:port，例如 127.0.0.1:3000（IPv6 写成 [::1]:3000）",
        )
    })?;

    if port == 0 {
        return Err(invalid_target("端口不能为 0"));
    }
    if state.config.browser_reserved_ports().contains(&port) {
        return Err(denied_target(raw, state));
    }

    // 预览站是服务端自己持有的只读站点：端口随机、只活在本次进程里，
    // 是客户端"看到项目文件与运行中的前端"的唯一入口，所以必须放行。
    //
    // 放行的只有这一个端口，不是"任意回环端口"——用户配置的白名单语义不变，
    // 本机其它服务仍然要靠显式配置才放得进来。
    let preview_port = state.web_preview.as_ref().map(|preview| preview.port());
    if preview_port != Some(port) && !state.config.browser.allowed_ports.contains(&port) {
        return Err(denied_target(raw, state));
    }

    if let Ok(ip) = host.parse::<IpAddr>() {
        if !ip.is_loopback() {
            return Err(denied_target(raw, state));
        }
        return Ok(SocketAddr::new(ip, port));
    }

    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host, port))
        .await
        .map_err(|err| {
            tracing::debug!(host, %err, "浏览器隧道目标主机解析失败");
            ApiRejection::new(
                ErrorCode::BrowserTargetDenied,
                format!("browser target host cannot be resolved: {host}"),
                format!("无法解析主机 {host}：浏览器隧道只允许访问服务端本机的回环地址"),
            )
        })?
        .collect();

    if addrs.is_empty() {
        return Err(denied_target(raw, state));
    }
    if addrs.iter().any(|addr| !addr.ip().is_loopback()) {
        return Err(denied_target(raw, state));
    }

    Ok(addrs[0])
}

/// 拆 `host:port`，支持 `[::1]:3000`。裸 IPv6（多个冒号）一律视为非法。
fn split_host_port(raw: &str) -> Option<(&str, u16)> {
    if let Some(rest) = raw.strip_prefix('[') {
        let (host, tail) = rest.split_once(']')?;
        let port = tail.strip_prefix(':')?.parse::<u16>().ok()?;
        return (!host.is_empty()).then_some((host, port));
    }

    let (host, port) = raw.rsplit_once(':')?;
    if host.is_empty() || host.contains(':') {
        return None;
    }
    Some((host, port.parse::<u16>().ok()?))
}

/// 隧道关闭后的统计。与 SSH 隧道同口径：只记字节数与原因，**不记内容**。
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

/// 双向泵送，直到任意一侧结束或空闲超时。
///
/// 空闲超时按"双向任一侧有字节"重置：页面加载完停在原地时，连接可以一直在，
/// 但用户关掉标签、客户端进程被杀之后，服务端不该无限期挂着这条隧道。
async fn pump(
    socket: WebSocket,
    upstream: TcpStream,
    shutdown: std::sync::Arc<ShutdownNotice>,
    idle: Duration,
) -> PumpStats {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let (mut tcp_rx, mut tcp_tx) = upstream.into_split();

    let mut stats = PumpStats::new();
    let mut buffer = vec![0u8; READ_BUFFER_BYTES];
    let sleep = tokio::time::sleep(idle);
    tokio::pin!(sleep);

    loop {
        tokio::select! {
            // 先看关闭信号：服务停的时候不该等另一侧再发一个字节才退出。
            biased;
            _ = shutdown.wait() => {
                stats.reason = "shutdown";
                break;
            }
            _ = &mut sleep => {
                stats.reason = "idle_timeout";
                break;
            }
            incoming = ws_rx.next() => match incoming {
                Some(Ok(Message::Binary(bytes))) => {
                    if tcp_tx.write_all(&bytes).await.is_err() {
                        stats.reason = "target_write_failed";
                        break;
                    }
                    stats.upstream += bytes.len() as u64;
                    sleep.as_mut().reset(tokio::time::Instant::now() + idle);
                }
                Some(Ok(Message::Ping(payload))) => {
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
                    // 协议只有二进制帧：允许文本帧会让"发了没反应"变成要翻日志的谜案。
                    stats.reason = "unexpected_text_frame";
                    break;
                }
                Some(Ok(_)) => {}
                Some(Err(_)) => {
                    stats.reason = "client_error";
                    break;
                }
            },
            read = tcp_rx.read(&mut buffer) => match read {
                Ok(0) => {
                    stats.reason = "target_closed";
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
                    sleep.as_mut().reset(tokio::time::Instant::now() + idle);
                }
                Err(_) => {
                    stats.reason = "target_read_failed";
                    break;
                }
            },
        }
    }

    // 先发 Close 帧再关 TCP：顺序反了客户端看到的是"连接被重置"。
    let _ = ws_tx.send(Message::Close(None)).await;
    let _ = tcp_tx.shutdown().await;
    stats
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_ipv4_and_bracketed_ipv6() {
        assert_eq!(split_host_port("127.0.0.1:3000"), Some(("127.0.0.1", 3000)));
        assert_eq!(split_host_port("[::1]:8080"), Some(("::1", 8080)));
        assert_eq!(split_host_port("localhost:5173"), Some(("localhost", 5173)));
    }

    #[test]
    fn rejects_malformed_targets() {
        assert_eq!(split_host_port("::1:3000"), None, "裸 IPv6 必须加方括号");
        assert_eq!(split_host_port(":3000"), None);
        assert_eq!(split_host_port("127.0.0.1"), None);
        assert_eq!(split_host_port("127.0.0.1:99999"), None);
    }
}
