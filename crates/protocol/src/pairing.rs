//! 配对相关载荷。字段与 `api-spec/openapi.yaml` 一一对应。
//!
//! 时间统一用 Unix 毫秒整数：与数据库一致，避免引入日期库与字符串解析分支。

use serde::{Deserialize, Serialize};

/// 客户端提交配对码与自身信息。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairRequest {
    /// 12 位配对码，大小写不敏感。
    pub code: String,
    pub device_name: String,
    pub platform: String,
    /// Ed25519 公钥，base32（无 padding）。
    pub client_pubkey: String,
}

/// 票据已受理，等待本机确认。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairPending {
    pub request_id: String,
    pub expires_at: i64,
}

/// 确认或拒绝配对。由已配对设备发起时即"信任传递"。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairConfirmRequest {
    pub request_id: String,
    pub approve: bool,
}

/// 配对结果。拒绝时只有 `accepted=false` 与 `reason`。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairResult {
    pub accepted: bool,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_pubkey: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_fingerprint: Option<String>,
}

/// 票据状态，供客户端轮询。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairStatus {
    pub request_id: String,
    /// `pending` / `awaiting_confirmation` / `approved` / `rejected` / `expired` / `locked`
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_pubkey: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_fingerprint: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejection_omits_optional_fields() {
        let result = PairResult {
            accepted: false,
            reason: "user rejected".to_string(),
            device_id: None,
            server_pubkey: None,
            server_fingerprint: None,
        };
        let value = serde_json::to_value(&result).expect("序列化失败");
        assert!(value.get("device_id").is_none());
        assert_eq!(value["accepted"], false);
    }

    #[test]
    fn pending_roundtrip() {
        let payload = PairPending {
            request_id: "pair_abc".to_string(),
            expires_at: 1_700_000_000_000,
        };
        let json = serde_json::to_string(&payload).expect("序列化失败");
        let back: PairPending = serde_json::from_str(&json).expect("反序列化失败");
        assert_eq!(back.request_id, "pair_abc");
        assert_eq!(back.expires_at, 1_700_000_000_000);
    }
}
