//! 登录与设备信息载荷。
//!
//! 签名对象是**挑战串 base32 解码后的 32 字节原始值**，不是字符串本身——
//! 这一条必须两端一致，否则签名永远校验不过。

use serde::{Deserialize, Serialize};

/// 换取挑战。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChallengeRequest {
    pub device_id: String,
}

/// 一次性挑战。客户端对其原始字节签名。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChallengeResponse {
    /// 32 字节随机的 base32 编码。
    pub challenge: String,
    pub expires_at: i64,
}

/// 提交签名换取会话令牌。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyRequest {
    pub device_id: String,
    pub challenge: String,
    /// Edwards25519 签名的 base32 编码（64 字节）。
    pub signature: String,
}

/// 不透明会话令牌，仅在此响应中出现一次。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionResponse {
    pub token: String,
    pub expires_at: i64,
}

/// 当前设备信息（`GET /api/auth/me`）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub device_id: String,
    pub name: String,
    pub platform: String,
    pub paired_at: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_response_roundtrip() {
        let payload = SessionResponse {
            token: "ABCDEF".to_string(),
            expires_at: 1_700_000_000_000,
        };
        let json = serde_json::to_string(&payload).expect("序列化失败");
        let back: SessionResponse = serde_json::from_str(&json).expect("反序列化失败");
        assert_eq!(back.token, "ABCDEF");
    }

    #[test]
    fn device_info_is_serializable() {
        let info = DeviceInfo {
            device_id: "dev_1".to_string(),
            name: "iPhone".to_string(),
            platform: "ios".to_string(),
            paired_at: 1,
        };
        let value = serde_json::to_value(&info).expect("序列化失败");
        assert_eq!(value["device_id"], "dev_1");
        assert_eq!(value["platform"], "ios");
    }
}
