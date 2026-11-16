//! 运行时设置：用户可以在界面上改的那几项。
//!
//! 为什么放在 `memory` 而不是 `heartbeat`：`heartbeat` 已经依赖 `memory`
//! （`model()` / `submit_extract`），而 `digest()` 又必须读这里——放在心跳里
//! 会绕成一个环。设置是"记忆模块的运行时状态"，心跳只是它的一个读方。
//!
//! 存储仍复用 `memory_heartbeat_state` 的 `settings` 键，**不新增迁移**：
//! 表名带 heartbeat 是历史原因，它的实际语义是"记忆运行态的 key/value"。

use serde_json::json;
use sqlx::SqlitePool;

use crate::clock::now_ms;

/// 运行态 key。当前只有这一个键，直接内联，不做枚举。
const KEY: &str = "settings";

/// 用户可改的记忆设置。
#[derive(Debug, Clone, PartialEq)]
pub struct RuntimeSettings {
    /// 静音的类别线缆值：心跳据此"记录但不投递"。
    pub mute: Vec<String>,
    /// 每日打扰上限。
    pub daily_limit: u32,
    /// 常驻摘要开关。缺省 `true`：读不到设置时按开启处理。
    pub digest_enabled: bool,
}

impl Default for RuntimeSettings {
    fn default() -> Self {
        Self {
            mute: Vec::new(),
            daily_limit: 2,
            digest_enabled: true,
        }
    }
}

/// 读设置。**任何失败都退回默认值**：读不到设置不该让摘要凭空消失，
/// 也不该让心跳停摆。
pub async fn load(pool: &SqlitePool) -> RuntimeSettings {
    let raw: Option<(String,)> =
        sqlx::query_as("SELECT value_json FROM memory_heartbeat_state WHERE key = ?")
            .bind(KEY)
            .fetch_optional(pool)
            .await
            .ok()
            .flatten();

    let Some((raw,)) = raw else {
        return RuntimeSettings::default();
    };

    let value: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(value) => value,
        Err(err) => {
            tracing::warn!(%err, "记忆设置无法解析，按默认值处理");
            return RuntimeSettings::default();
        }
    };

    RuntimeSettings {
        mute: value["mute"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default(),
        daily_limit: value["daily_limit"].as_u64().unwrap_or(2).min(10) as u32,
        digest_enabled: value["digest_enabled"].as_bool().unwrap_or(true),
    }
}

/// 写设置。整份覆盖：设置项少，合并写反而会让"清空静音列表"这种操作做不到。
pub async fn save(pool: &SqlitePool, settings: &RuntimeSettings) -> Result<(), sqlx::Error> {
    let value = json!({
        "mute": settings.mute,
        "daily_limit": settings.daily_limit,
        "digest_enabled": settings.digest_enabled,
    });

    sqlx::query(
        "INSERT INTO memory_heartbeat_state (key, value_json, updated_at) VALUES (?, ?, ?) \
         ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, \
           updated_at = excluded.updated_at",
    )
    .bind(KEY)
    .bind(value.to_string())
    .bind(now_ms())
    .execute(pool)
    .await?;

    Ok(())
}

/// 常驻摘要是否开启。`digest()` 每轮调用一次，单主键查询 <0.1ms。
pub async fn digest_enabled(pool: &SqlitePool) -> bool {
    load(pool).await.digest_enabled
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_keeps_digest_on() {
        let settings = RuntimeSettings::default();
        assert!(
            settings.digest_enabled,
            "缺省必须开启：读不到设置不该关掉摘要"
        );
        assert_eq!(settings.daily_limit, 2);
        assert!(settings.mute.is_empty());
    }
}
