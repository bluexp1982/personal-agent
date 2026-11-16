//! 挑战应答与会话令牌。
//!
//! 设计要点（见「配对与信任 › 后续连接」）：
//! - 挑战一次性使用，取用即删，天然防重放；
//! - 令牌是不透明随机串，数据库只存 `sha256(令牌)`，泄露库不等于能登录；
//! - 令牌 24 小时过期；吊销设备时同事务删掉其全部令牌，做到"立即生效"；
//! - 验签走 `verify_strict`，拒绝弱公钥。

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use sha2::{Digest, Sha256};
use sqlx::SqlitePool;

use crate::clock::now_ms;
use crate::identity::{Identity, B32};

/// 挑战有效期：5 分钟。
pub const CHALLENGE_TTL_MS: i64 = 5 * 60 * 1000;
/// 会话有效期：24 小时。
pub const SESSION_TTL_MS: i64 = 24 * 60 * 60 * 1000;

/// 内存中挑战条目的上限，防止长跑进程内存无界增长。
const MAX_CHALLENGES: usize = 1024;
/// 同一设备每分钟最多换取 10 次挑战。
const CHALLENGE_PER_MINUTE: u32 = 10;

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
    #[error("设备未配对或已吊销")]
    NotAuthorized,
    #[error("挑战无效、已过期或已使用")]
    ChallengeInvalid,
    #[error("签名校验失败")]
    BadSignature,
    #[error("请求过于频繁")]
    RateLimited,
}

/// 通过鉴权后注入请求上下文的设备信息。
#[derive(Debug, Clone)]
pub struct AuthDevice {
    pub device_id: String,
    pub name: String,
}

#[derive(Debug)]
struct ChallengeEntry {
    device_id: String,
    expires_at: i64,
}

/// 挑战表：内存态、单次消费。
#[derive(Debug, Default)]
pub struct ChallengeStore {
    entries: HashMap<String, ChallengeEntry>,
}

impl ChallengeStore {
    /// 生成挑战并登记，返回 `(挑战串, 过期时间)`。
    ///
    /// 挑战串是 32 字节随机的 base32；客户端对**解码后的原始字节**签名。
    pub fn issue(&mut self, device_id: &str) -> (String, i64) {
        let now = now_ms();
        self.entries.retain(|_, entry| entry.expires_at > now);

        if self.entries.len() >= MAX_CHALLENGES {
            // 淘汰最早到期的一条，保证容量恒有上界。
            if let Some(key) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.expires_at)
                .map(|(key, _)| key.clone())
            {
                self.entries.remove(&key);
            }
        }

        let bytes: [u8; 32] = rand::random();
        let challenge = base32::encode(B32, &bytes);
        let expires_at = now + CHALLENGE_TTL_MS;
        self.entries.insert(
            challenge.clone(),
            ChallengeEntry {
                device_id: device_id.to_string(),
                expires_at,
            },
        );
        (challenge, expires_at)
    }

    /// 取出并删除。设备不匹配、已过期或不存在都返回 false——调用方统一按 401 处理。
    pub fn take(&mut self, challenge: &str, device_id: &str) -> bool {
        let Some(entry) = self.entries.remove(challenge) else {
            return false;
        };
        entry.device_id == device_id && entry.expires_at > now_ms()
    }
}

#[derive(Debug)]
struct Bucket {
    window_start: i64,
    count: u32,
}

/// 极简固定窗口限流器。只用于挑战签发这类低频动作，不追求精确。
#[derive(Debug, Default)]
pub struct RateLimiter {
    buckets: HashMap<String, Bucket>,
}

impl RateLimiter {
    pub fn allow(&mut self, key: &str, limit: u32, window_ms: i64) -> bool {
        let now = now_ms();
        let bucket = self.buckets.entry(key.to_string()).or_insert(Bucket {
            window_start: now,
            count: 0,
        });

        if now - bucket.window_start >= window_ms {
            bucket.window_start = now;
            bucket.count = 0;
        }
        if bucket.count >= limit {
            return false;
        }
        bucket.count += 1;
        true
    }
}

/// 加锁辅助：锁中毒时取回内部数据而不是 panic——限流器与挑战表都不承载一致性状态。
pub fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 签发挑战。设备必须存在且未吊销，并按设备限流。
pub async fn issue_challenge(
    pool: &SqlitePool,
    challenges: &Mutex<ChallengeStore>,
    limiter: &Mutex<RateLimiter>,
    device_id: &str,
) -> Result<(String, i64), AuthError> {
    if !lock(limiter).allow(
        &format!("challenge:{device_id}"),
        CHALLENGE_PER_MINUTE,
        60_000,
    ) {
        return Err(AuthError::RateLimited);
    }

    let paired: Option<String> =
        sqlx::query_scalar("SELECT id FROM devices WHERE id = ? AND revoked_at IS NULL")
            .bind(device_id)
            .fetch_optional(pool)
            .await?;
    if paired.is_none() {
        return Err(AuthError::NotAuthorized);
    }

    Ok(lock(challenges).issue(device_id))
}

/// 校验签名并签发会话令牌，返回 `(明文令牌, 过期时间)`。
pub async fn verify_and_issue(
    pool: &SqlitePool,
    challenges: &Mutex<ChallengeStore>,
    device_id: &str,
    challenge: &str,
    signature_b32: &str,
) -> Result<(String, i64), AuthError> {
    // 先消费挑战：无论后续校验成功与否，同一个挑战都不能再用第二次。
    if !lock(challenges).take(challenge, device_id) {
        return Err(AuthError::ChallengeInvalid);
    }

    let pubkey_b32: Option<String> =
        sqlx::query_scalar("SELECT pubkey FROM devices WHERE id = ? AND revoked_at IS NULL")
            .bind(device_id)
            .fetch_optional(pool)
            .await?;
    let pubkey_b32 = pubkey_b32.ok_or(AuthError::NotAuthorized)?;

    let pubkey = base32::decode(B32, &pubkey_b32).ok_or(AuthError::NotAuthorized)?;
    let message = base32::decode(B32, challenge).ok_or(AuthError::ChallengeInvalid)?;
    let signature = base32::decode(B32, signature_b32).ok_or(AuthError::BadSignature)?;

    if !Identity::verify(&pubkey, &message, &signature) {
        return Err(AuthError::BadSignature);
    }

    issue_session(pool, device_id).await
}

/// 生成会话令牌并落库（只存哈希）。
pub async fn issue_session(pool: &SqlitePool, device_id: &str) -> Result<(String, i64), AuthError> {
    let bytes: [u8; 32] = rand::random();
    let token = base32::encode(B32, &bytes);
    let token_hash = hash_token(&token);
    let created_at = now_ms();
    let expires_at = created_at + SESSION_TTL_MS;

    sqlx::query(
        "INSERT INTO sessions (token_hash, device_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
    )
    .bind(token_hash)
    .bind(device_id)
    .bind(created_at)
    .bind(expires_at)
    .execute(pool)
    .await?;

    Ok((token, expires_at))
}

/// 校验令牌并返回设备信息。任一条件不满足都视为未授权。
pub async fn authenticate(pool: &SqlitePool, token: &str) -> Result<AuthDevice, AuthError> {
    let token_hash = hash_token(token);
    let row = sqlx::query_as::<_, (String, String)>(
        "SELECT d.id, d.name FROM sessions s \
         JOIN devices d ON d.id = s.device_id \
         WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > ? AND d.revoked_at IS NULL",
    )
    .bind(token_hash)
    .bind(now_ms())
    .fetch_optional(pool)
    .await?;

    row.map(|(device_id, name)| AuthDevice { device_id, name })
        .ok_or(AuthError::NotAuthorized)
}

/// 吊销设备：置 `revoked_at` 并作废其全部令牌（同事务）。
pub async fn revoke_device(pool: &SqlitePool, device_id: &str) -> Result<(), AuthError> {
    let now = now_ms();
    let mut tx = pool.begin().await?;

    let updated =
        sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
            .bind(now)
            .bind(device_id)
            .execute(&mut *tx)
            .await?;
    sqlx::query("UPDATE sessions SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL")
        .bind(now)
        .bind(device_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;

    if updated.rows_affected() == 0 {
        // 设备不存在或已吊销，对外统一按未授权处理，避免泄露设备是否存在。
        return Err(AuthError::NotAuthorized);
    }
    Ok(())
}

/// 吊销全部设备：所有 `devices` 与 `sessions` 在同一事务里置 `revoked_at`，返回吊销的设备数。
///
/// 语义是"所有人重新配对"，服务端身份（`identity.key`）不动——那是 `rotate-key` 的事。
/// 与 [`revoke_device`] 的差别只是不带设备过滤；两条 UPDATE 共用同一时间戳，
/// 否则审计里"设备被吊销"和"令牌被吊销"会差几毫秒，排查时对不上。
pub async fn revoke_all_devices(pool: &SqlitePool) -> Result<u64, AuthError> {
    let now = now_ms();
    let mut tx = pool.begin().await?;

    let updated = sqlx::query("UPDATE devices SET revoked_at = ? WHERE revoked_at IS NULL")
        .bind(now)
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE sessions SET revoked_at = ? WHERE revoked_at IS NULL")
        .bind(now)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;

    Ok(updated.rows_affected())
}

/// 令牌哈希：sha256 小写十六进制。
pub fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_is_single_use() {
        let mut store = ChallengeStore::default();
        let (challenge, _) = store.issue("dev_1");

        assert!(store.take(&challenge, "dev_1"));
        assert!(!store.take(&challenge, "dev_1"), "同一挑战不能消费两次");
    }

    #[test]
    fn challenge_bound_to_device() {
        let mut store = ChallengeStore::default();
        let (challenge, _) = store.issue("dev_1");

        assert!(!store.take(&challenge, "dev_2"));
        assert!(!store.take(&challenge, "dev_1"), "错设备尝试也应消耗挑战");
    }

    #[test]
    fn challenge_store_is_bounded() {
        let mut store = ChallengeStore::default();
        for index in 0..(MAX_CHALLENGES + 10) {
            store.issue(&format!("dev_{index}"));
        }
        assert!(store.entries.len() <= MAX_CHALLENGES);
    }

    #[test]
    fn rate_limiter_blocks_after_limit() {
        let mut limiter = RateLimiter::default();
        for _ in 0..CHALLENGE_PER_MINUTE {
            assert!(limiter.allow("k", CHALLENGE_PER_MINUTE, 60_000));
        }
        assert!(!limiter.allow("k", CHALLENGE_PER_MINUTE, 60_000));
    }

    #[test]
    fn token_hash_is_sha256_hex() {
        let hash = hash_token("token");
        assert_eq!(hash.len(), 64);
        assert_ne!(hash, hash_token("token2"));
        assert_eq!(hash, hash_token("token"));
    }
}
