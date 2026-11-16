//! 公网准入。
//!
//! 对话侧已经不再限制"能读哪些域名"，这里就是唯一的网络防线：
//!
//! - 只允许 https，拒绝 URL 内嵌账号密码；
//! - 拒绝回环 / 私网 / 链路本地 / 组播 / 未指定地址，以及 `localhost`、
//!   `.local`、`.internal` 和单标签主机名（局域网里的短名）；
//! - 域名先解析，**任一解析结果**命中禁止网段即拒绝（保守：避免多 A 记录里挑到内网那条）；
//! - 通过校验后把域名固定到那个地址（[`reqwest::ClientBuilder::resolve`]），
//!   让"校验"与"建连"用的是同一个 IP，防 DNS rebinding；
//! - 重定向不自动跟随（见 [`MAX_REDIRECTS`]）：公网地址 302 到 `127.0.0.1`
//!   必须在下一跳重新过一遍准入，否则去掉白名单就等于开了本机所有端口的读权限。
//!
//! 代价：每跳重定向新建一个 client，同域连续跳转会多一次握手。个人场景可接受。

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use reqwest::redirect::Policy;
use reqwest::{Client, Url};

use super::ToolError;

/// 一次抓取允许跟随的最大跳数。
///
/// 不复用 `reqwest` 的自动重定向：它的策略接口拿不到"这一跳的目标地址"，
/// 没法在建连前做准入，DNS 固定也会失效。
pub(crate) const MAX_REDIRECTS: usize = 5;

/// 校验并建好一个"只连这台机器"的 client。
///
/// 调用方拿到 client 后直接 `get(url.clone())`：域名已在内部固定，
/// 建连时不会再解析一次。
pub(crate) async fn admit(url: &Url, timeout: Duration) -> Result<Client, ToolError> {
    check_url(url)?;

    let host = url
        .host_str()
        .ok_or_else(|| ToolError::Denied("URL 缺少主机名".to_string()))?;
    let port = url.port_or_known_default().unwrap_or(443);
    let bare = host.trim_start_matches('[').trim_end_matches(']');

    let mut builder = Client::builder()
        .timeout(timeout)
        .redirect(Policy::none())
        .user_agent(format!("personal-agent/{}", protocol::VERSION));

    match bare.parse::<IpAddr>() {
        Ok(ip) => {
            // IP 字面量不需要解析，也没有 rebinding 的余地。
            check_ip(ip)?;
        }
        Err(_) => {
            let addr = resolve_public(host, port).await?;
            builder = builder.resolve(host, addr);
        }
    }

    builder
        .build()
        .map_err(|err| ToolError::Failed(format!("创建 HTTP 客户端失败: {err}")))
}

/// URL 的静态部分校验（scheme / 凭据 / 主机形态），不做 DNS。
///
/// 单独暴露是为了让重定向处理能在发请求之前就把明显不合法的地址挡掉，
/// 并在测试里离线断言。
pub(crate) fn check_url(url: &Url) -> Result<(), ToolError> {
    if url.scheme() != "https" {
        return Err(ToolError::Denied("只允许 https".to_string()));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(ToolError::Denied("不允许在地址里携带账号密码".to_string()));
    }

    let host = url
        .host_str()
        .ok_or_else(|| ToolError::Denied("URL 缺少主机名".to_string()))?;
    let bare = host.trim_start_matches('[').trim_end_matches(']');

    if let Ok(ip) = bare.parse::<IpAddr>() {
        return check_ip(ip);
    }

    check_domain(host)
}

/// 地址是否落在禁止网段。
pub(crate) fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => blocked_v4(v4),
        IpAddr::V6(v6) => {
            // IPv4-mapped（`::ffff:127.0.0.1`）先还原成 v4 再判，否则能绕过回环检查。
            if let Some(v4) = v6.to_ipv4_mapped() {
                return blocked_v4(v4);
            }
            let first = v6.segments()[0];
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                // fc00::/7 唯一本地地址（IPv6 的内网段）
                || (first & 0xfe00) == 0xfc00
                // fe80::/10 链路本地
                || (first & 0xffc0) == 0xfe80
        }
    }
}

fn check_ip(ip: IpAddr) -> Result<(), ToolError> {
    if is_blocked_ip(ip) {
        return Err(ToolError::Denied(format!(
            "地址指向本机或内网，已拒绝: {ip}"
        )));
    }
    Ok(())
}

fn check_domain(host: &str) -> Result<(), ToolError> {
    let name = host.to_ascii_lowercase();

    if name == "localhost"
        || name.ends_with(".localhost")
        || name.ends_with(".local")
        || name.ends_with(".internal")
    {
        return Err(ToolError::Denied(format!(
            "地址指向本机或内网，已拒绝: {host}"
        )));
    }

    // 单标签主机名（`nas`、`router`）只可能来自局域网搜索域。
    if !name.contains('.') {
        return Err(ToolError::Denied(format!("只允许公网域名: {host}")));
    }

    Ok(())
}

/// 解析域名，返回第一个可用地址；任一结果命中禁止网段即整体拒绝。
async fn resolve_public(host: &str, port: u16) -> Result<SocketAddr, ToolError> {
    let addrs = tokio::net::lookup_host((host, port))
        .await
        .map_err(|err| ToolError::Failed(format!("域名解析失败: {err}")))?;

    let mut chosen: Option<SocketAddr> = None;
    for addr in addrs {
        if is_blocked_ip(addr.ip()) {
            return Err(ToolError::Denied(format!(
                "域名解析到内网地址，已拒绝: {host} → {}",
                addr.ip()
            )));
        }
        if chosen.is_none() {
            chosen = Some(addr);
        }
    }

    chosen.ok_or_else(|| ToolError::Failed(format!("域名没有可用地址: {host}")))
}

fn blocked_v4(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_documentation()
        || ip.is_unspecified()
        || ip.is_multicast()
        // 100.64.0.0/10：运营商级 NAT，不是公网可路由地址。
        || (octets[0] == 100 && (octets[1] & 0xc0) == 64)
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use super::*;

    fn url(input: &str) -> Url {
        Url::parse(input).expect("测试地址应合法")
    }

    fn ip(input: &str) -> IpAddr {
        IpAddr::from_str(input).expect("测试地址应是 IP")
    }

    #[test]
    fn rejects_non_https_and_credentials() {
        assert!(check_url(&url("http://example.com")).is_err());
        assert!(check_url(&url("https://user:pass@example.com")).is_err());
        assert!(check_url(&url("https://example.com/path")).is_ok());
    }

    #[test]
    fn rejects_local_names() {
        for host in [
            "https://localhost",
            "https://foo.localhost",
            "https://printer.local",
            "https://nas",
            "https://metadata.internal",
        ] {
            assert!(
                check_url(&url(host)).is_err(),
                "应拒绝本机/内网域名: {host}"
            );
        }
    }

    #[test]
    fn rejects_loopback_and_private_literals() {
        for host in [
            "https://127.0.0.1",
            "https://10.0.0.5",
            "https://172.16.3.4",
            "https://192.168.1.1",
            "https://169.254.169.254",
            "https://100.64.1.1",
            "https://0.0.0.0",
            "https://[::1]",
            "https://[fe80::1]",
            "https://[fc00::1]",
            "https://[::ffff:127.0.0.1]",
        ] {
            assert!(
                check_url(&url(host)).is_err(),
                "应拒绝内网/回环地址: {host}"
            );
        }
    }

    #[test]
    fn allows_public_literals() {
        assert!(check_url(&url("https://1.1.1.1")).is_ok());
        assert!(check_url(&url("https://[2606:4700:4700::1111]")).is_ok());
    }

    #[test]
    fn ip_classification_covers_edge_cases() {
        assert!(is_blocked_ip(ip("192.168.0.1")));
        assert!(is_blocked_ip(ip("224.0.0.1")));
        assert!(!is_blocked_ip(ip("8.8.8.8")));
        assert!(!is_blocked_ip(ip("2606:4700:4700::1111")));
    }
}
