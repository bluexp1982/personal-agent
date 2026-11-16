//! 健康检查响应。管理面 `/admin/health` 与 worker IPC `/internal/v1/health` 共用。

use serde::{Deserialize, Serialize};

use crate::version::VERSION;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthResponse {
    /// 固定为 `ok`；异常时由调用方改用错误体返回。
    pub status: String,
    /// 进程版本，便于确认升级是否生效。
    pub version: String,
}

impl HealthResponse {
    pub fn ok() -> Self {
        Self {
            status: "ok".to_string(),
            version: VERSION.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serializes_status_and_version() {
        let value = serde_json::to_value(HealthResponse::ok()).expect("序列化失败");
        assert_eq!(value["status"], "ok");
        assert_eq!(value["version"], VERSION);
    }
}
