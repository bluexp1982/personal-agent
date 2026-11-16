//! SSH 隧道的对外契约。
//!
//! 隧道本身是纯字节透传（WebSocket 二进制帧 ⇄ `ssh.target` 的 TCP 流），
//! 这里只定义"连之前先问一句能不能连"的探测结果——客户端据此在用户输密码前
//! 就提示"服务端没开远程登录"，而不是让人反复试密码。

use serde::{Deserialize, Serialize};

/// `GET /api/ssh/info` 的响应。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshTunnelInfo {
    /// 服务端是否开启了 SSH 隧道（`ssh.enabled`）。
    pub enabled: bool,
    /// 隧道终点，形如 `127.0.0.1:22`。只可能是回环地址。
    pub target: String,
    /// 终点当前是否可连。`enabled=false` 时恒为 false。
    pub sshd_reachable: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn info_round_trips_through_json() {
        let info = SshTunnelInfo {
            enabled: true,
            target: "127.0.0.1:22".to_string(),
            sshd_reachable: false,
        };
        let raw = serde_json::to_string(&info).expect("序列化失败");
        let back: SshTunnelInfo = serde_json::from_str(&raw).expect("反序列化失败");
        assert_eq!(back, info);
    }
}
