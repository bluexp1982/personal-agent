//! 管理面客户端，供 `pair` 子命令使用。
//!
//! 为什么 CLI 也要走管理面而不是直接读数据库：
//! 直接写库会绕过配对的不变量（单活跃票据、失败计数、事务），
//! 而且和运行中的服务争用同一个 SQLite 文件。走套接字只有一条写路径。
//!
//! 复用已有的 `hyper` + `hyper-util`，不为一条命令引入 `reqwest`。
//! CLI 的输出就是产品本身，所以本模块允许 `print_stdout`。

#![allow(clippy::print_stdout)]

use std::io::IsTerminal;
use std::path::Path;

use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::{Method, Request};
use hyper_util::rt::TokioIo;
use serde::Deserialize;

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("连接管理面失败（服务是否在运行？）: {0}")]
    Io(#[from] std::io::Error),
    #[error("与管理面通信失败: {0}")]
    Hyper(#[from] hyper::Error),
    #[error("构造请求失败: {0}")]
    Http(#[from] hyper::http::Error),
    #[error("管理面返回 {status}: {body}")]
    Status { status: u16, body: String },
    #[error("解析响应失败: {0}")]
    Decode(#[from] serde_json::Error),
}

#[derive(Debug, Deserialize)]
struct PairStart {
    request_id: String,
    code: String,
    expires_at: i64,
    /// 自签 TLS 证书指纹；明文模式下为 null。
    tls_fingerprint: Option<String>,
}

#[derive(Debug, Deserialize)]
struct IdentityView {
    tls_fingerprint: Option<String>,
}

/// 配对输出里"客户端该填什么地址"的上下文。
///
/// 端口必须取运行中的服务（`api.port`），scheme 与是否对外暴露则来自启动配置——
/// 客户端只看这两样东西就能决定用 http 还是 https。
#[derive(Debug, Clone)]
pub struct PairAddress {
    pub scheme: &'static str,
    pub port: u16,
    /// 绑定非回环时才给出局域网地址；绑回环时别人的机器根本连不上。
    pub lan_ip: Option<std::net::IpAddr>,
}

#[derive(Debug, Deserialize)]
struct PendingItem {
    request_id: String,
    device_name: Option<String>,
    platform: Option<String>,
    status: String,
    expires_at: i64,
}

#[derive(Debug, Deserialize)]
struct PairResultView {
    accepted: bool,
    reason: String,
    device_id: Option<String>,
    server_fingerprint: Option<String>,
}

/// 终端着色的两种颜色。只给"要照着抄走"的内容用：配对码（绿）与地址（红）。
///
/// 为什么只在 TTY 里着色：`dev.sh pair | tee`、脚本里 `$(...)` 捕获都很常见，
/// 把转义序列写进文件/变量会污染下游。TTY 判断放在这一处，调用点不用关心。
fn paint(text: &str, color: &str) -> String {
    if std::io::stdout().is_terminal() {
        format!("\x1b[{color}m{text}\x1b[0m")
    } else {
        text.to_string()
    }
}

fn red(text: &str) -> String {
    paint(text, "31")
}

fn green(text: &str) -> String {
    paint(text, "32")
}

/// 生成配对码并打印（只此一次）。
///
/// `api_port` 是服务**实际**监听的端口：把它直接印出来，用户就不必去配置文件里
/// 推算客户端该填什么地址（`api_bind` 为 `:0` 时更是猜不到）。
pub async fn start_pairing(socket: &Path, address: Option<PairAddress>) -> Result<(), ClientError> {
    let body = call(socket, Method::POST, "/admin/pair/start").await?;
    let parsed: PairStart = serde_json::from_str(&body)?;

    println!("配对码（5 分钟内有效，只显示一次）：");
    println!();
    // 绿色只包住码本身：缩进与前后空行保持中性，复制粘贴时不会把颜色当内容。
    println!("    {}", green(&group_code(&parsed.code)));
    println!();
    if let Some(address) = &address {
        // 与 `dev.sh` 的启动/状态输出统一措辞，用户在两个入口看到的是同一句话。
        println!(
            "{}",
            red(&format!(
                "服务地址：{}://127.0.0.1:{}",
                address.scheme, address.port
            ))
        );
        match address.lan_ip {
            Some(ip) => println!(
                "{}",
                red(&format!(
                    "局域网地址：{}://{}:{}",
                    address.scheme, ip, address.port
                ))
            ),
            // `lan_ip` 为 None 有两种成因（绑定回环 / 探测不到出口地址），
            // 措辞要同时覆盖：只提回环会让"明明绑了 0.0.0.0"的人对不上。
            None => println!(
                "{}",
                red("局域网地址：不可用（服务只监听回环，或探测不到本机局域网地址）")
            ),
        }
    } else {
        println!("客户端服务地址：见数据目录下的 api.port（服务未运行时读不到）");
    }
    if let Some(fingerprint) = &parsed.tls_fingerprint {
        println!("服务端证书指纹：{fingerprint}（客户端首次连接时核对，一致才继续）");
    }
    println!();
    println!("在客户端输入该码，然后在另一台已配对设备上确认，或在本机执行：");
    println!("    jarvis-service pair --approve {}", parsed.request_id);
    println!();
    println!(
        "票据 {} 有效期{}",
        parsed.request_id,
        format_remaining(parsed.expires_at)
    );
    Ok(())
}

/// 列出待确认的配对请求。
pub async fn list_pending(socket: &Path) -> Result<(), ClientError> {
    let body = call(socket, Method::GET, "/admin/pair/pending").await?;
    let items: Vec<PendingItem> = serde_json::from_str(&body)?;

    if items.is_empty() {
        println!("当前没有待确认的配对请求。先执行 `jarvis-service pair` 生成配对码。");
        return Ok(());
    }

    println!("待确认的配对请求：");
    for item in items {
        println!(
            "  {}  状态={}  设备={}  平台={}  {}",
            item.request_id,
            item.status,
            item.device_name.as_deref().unwrap_or("-"),
            item.platform.as_deref().unwrap_or("-"),
            format_remaining(item.expires_at)
        );
    }
    println!();
    println!("批准：jarvis-service pair --approve <request_id>");
    println!("拒绝：jarvis-service pair --reject <request_id>");
    Ok(())
}

/// 批准并打印设备 id 与服务端指纹（供客户端人工核对）。
pub async fn approve(socket: &Path, request_id: &str) -> Result<(), ClientError> {
    let path = format!("/admin/pair/{request_id}/approve");
    let body = call(socket, Method::POST, &path).await?;
    let parsed: PairResultView = serde_json::from_str(&body)?;

    if parsed.accepted {
        println!("已批准配对。");
        println!("  设备 id: {}", parsed.device_id.unwrap_or_default());
        println!(
            "  服务端指纹: {}",
            parsed.server_fingerprint.unwrap_or_default()
        );
        // 证书指纹来自另一条管理面端点：`PairResult` 属于业务契约，
        // 不为了运维展示往里加字段（那会让 openapi 与 protocol 一起漂移）。
        if let Ok(body) = call(socket, Method::GET, "/admin/identity").await {
            if let Ok(identity) = serde_json::from_str::<IdentityView>(&body) {
                if let Some(tls) = identity.tls_fingerprint {
                    println!("  证书指纹: {tls}");
                }
            }
        }
        println!("请让客户端核对指纹一致后再开始使用。");
    } else {
        println!("未批准：{}", parsed.reason);
    }
    Ok(())
}

/// 拒绝配对。
pub async fn reject(socket: &Path, request_id: &str) -> Result<(), ClientError> {
    let path = format!("/admin/pair/{request_id}/reject");
    let body = call(socket, Method::POST, &path).await?;
    let parsed: PairResultView = serde_json::from_str(&body)?;
    println!("已拒绝配对：{}", parsed.reason);
    Ok(())
}

#[derive(Debug, Deserialize)]
struct DeviceItem {
    id: String,
    name: String,
    platform: String,
    revoked_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct RevokeAllResult {
    revoked: u64,
}

/// 吊销全部设备：默认只打印清单（dry-run），`confirmed` 才真的执行。
///
/// 危险等级和 `rotate-key` 同级——执行后包括此刻正在用的客户端在内全部掉线，
/// 手机必须回到机器旁重新配对。所以默认只列清单，必须显式 `--yes`。
pub async fn reset_devices(socket: &Path, confirmed: bool) -> Result<(), ClientError> {
    let body = call(socket, Method::GET, "/admin/devices").await?;
    let devices: Vec<DeviceItem> = serde_json::from_str(&body)?;
    let active: Vec<DeviceItem> = devices
        .into_iter()
        .filter(|device| device.revoked_at.is_none())
        .collect();

    if active.is_empty() {
        println!("当前没有已配对设备，无需重置。");
        return Ok(());
    }

    println!(
        "将吊销 {} 台设备（它们的会话令牌会立即作废）：",
        active.len()
    );
    for device in &active {
        println!(
            "    - {}（{}，id {}）",
            device.name, device.platform, device.id
        );
    }
    println!();

    if !confirmed {
        // 不猜用户意图：这里只给命令，不执行。
        println!("确认后执行：jarvis-service pair --reset --yes");
        println!("开发环境：  ./scripts/dev.sh pair reset --yes");
        return Ok(());
    }

    let body = call(socket, Method::POST, "/admin/devices/revoke-all").await?;
    let parsed: RevokeAllResult = serde_json::from_str(&body)?;
    println!(
        "{}",
        red(&format!(
            "已吊销 {} 台设备：包括你正在用的客户端在内，全部需要重新配对。",
            parsed.revoked
        ))
    );
    println!("桌面端重新启动客户端即可重新配对；手机端需重新生成配对码并在本机确认。");
    Ok(())
}

async fn call(socket: &Path, method: Method, path: &str) -> Result<String, ClientError> {
    let stream = tokio::net::UnixStream::connect(socket).await?;
    let io = TokioIo::new(stream);
    let (mut sender, connection) = hyper::client::conn::http1::handshake(io).await?;

    // 连接任务与请求同寿：请求结束后 abort，避免 CLI 退出前挂住。
    let connection_task = tokio::spawn(async move {
        let _ = connection.await;
    });

    let request = Request::builder()
        .method(method)
        .uri(path)
        .header("host", "localhost")
        .body(Full::new(Bytes::new()))?;

    let response = sender.send_request(request).await?;
    let status = response.status().as_u16();
    let body = response.into_body().collect().await?.to_bytes();
    connection_task.abort();

    let body = String::from_utf8_lossy(&body).into_owned();
    if !(200..300).contains(&status) {
        return Err(ClientError::Status { status, body });
    }
    Ok(body)
}

/// 把 12 位码按 4 位分组，降低口头转述时的错读概率。
fn group_code(code: &str) -> String {
    code.as_bytes()
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

/// 剩余有效期的人话版本。CLI 只需要"还有多久"，不需要绝对时间。
fn format_remaining(expires_at: i64) -> String {
    let remaining = expires_at - crate::clock::now_ms();
    if remaining <= 0 {
        return "已过期".to_string();
    }
    format!("约 {} 分钟后过期", (remaining + 59_999) / 60_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_code_by_four() {
        assert_eq!(group_code("ABCDEFGHJKLM"), "ABCD-EFGH-JKLM");
    }
}
