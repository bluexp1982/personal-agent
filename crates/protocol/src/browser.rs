//! 浏览器隧道：可用性预检结果。
//!
//! 面板里的「浏览器」要访问服务端本机的某个端口时，会先问一句"能不能连、
//! 允许连哪些端口"。把这些信息放在契约里而不是让客户端猜，是为了让
//! "端口没开 / 不在白名单"在界面上是一句可执行的提示，而不是一个转圈。

use serde::{Deserialize, Serialize};

/// 浏览器隧道可用性预检结果。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrowserTunnelInfo {
    /// 服务端是否开启浏览器隧道（`browser.enabled`）。
    pub enabled: bool,
    /// 是否只允许回环目标。本期恒为 true；字段留在这里是为了将来放开
    /// 域名白名单时客户端不用改协议。
    pub loopback_only: bool,
    /// 允许访问的回环端口白名单。
    pub allowed_ports: Vec<u16>,
    /// 全局并发隧道上限（按 TCP 连接计，不是按页面计）。
    pub max_tunnels: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tunnel_info_round_trips() {
        let info = BrowserTunnelInfo {
            enabled: true,
            loopback_only: true,
            allowed_ports: vec![3000, 5173],
            max_tunnels: 64,
        };

        let raw = serde_json::to_string(&info).expect("序列化失败");
        let back: BrowserTunnelInfo = serde_json::from_str(&raw).expect("反序列化失败");
        assert_eq!(back, info);
    }
}
