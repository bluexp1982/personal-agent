//! 配对票据的生命周期。
//!
//! 流程（见「配对与信任 › 首次配对流程」）：
//! 本机 `pair` 生成 12 位配对码 → 客户端提交码与公钥 → 票据转 `awaiting_confirmation`
//! → 本机或已配对设备确认 → 写入 `devices` 并置 `approved`。
//!
//! 安全要点：
//! - 数据库只存 `sha256(码)`，比较走恒定时间；
//! - 同一时刻只允许一个活跃票据（由 `0002` 的生成列 + 唯一索引保证）；
//! - 码错 5 次即 `locked`，必须重新生成。

use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use subtle::ConstantTimeEq;

use crate::clock::now_ms;
use crate::identity::B32;

/// 配对码长度。
pub const CODE_LEN: usize = 12;
/// 配对码有效期：5 分钟。
pub const CODE_TTL_MS: i64 = 5 * 60 * 1000;
/// 允许的最大错误尝试次数。
pub const MAX_ATTEMPTS: i64 = 5;

/// 去掉 `0 / O / 1 / I` 等易混字符后的 32 字符表。
const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

#[derive(Debug, thiserror::Error)]
pub enum PairingError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
    #[error("当前没有待确认的配对请求")]
    NoActiveRequest,
    #[error("配对码错误或已失效")]
    InvalidCode,
    #[error("配对请求已被锁定，请在本机重新生成")]
    Locked,
    #[error("配对请求不存在")]
    NotFound,
    #[error("配对请求状态不允许该操作: {0}")]
    Conflict(&'static str),
    #[error("该公钥已配对过")]
    DuplicateDevice,
}

/// 待确认票据的摘要信息，用于管理面列表。
#[derive(Debug, Clone)]
pub struct PendingRequest {
    pub id: String,
    pub device_name: Option<String>,
    pub platform: Option<String>,
    pub status: String,
    pub created_at: i64,
    pub expires_at: i64,
}

/// 票据对外状态（客户端轮询用）。
#[derive(Debug, Clone)]
pub struct RequestStatus {
    pub id: String,
    pub status: String,
    pub device_id: Option<String>,
}

/// 配对成功后的结果。
#[derive(Debug, Clone)]
pub struct ApprovedDevice {
    pub device_id: String,
    pub device_name: String,
}

/// 生成随机配对码（`CODE_LEN` 位，字符取自 `CODE_ALPHABET`）。
pub fn generate_code() -> String {
    let mut out = String::with_capacity(CODE_LEN);
    for _ in 0..CODE_LEN {
        let index = rand::random::<u8>() as usize % CODE_ALPHABET.len();
        out.push(CODE_ALPHABET[index] as char);
    }
    out
}

/// 配对码哈希：统一大写、去空白后做 sha256，输出小写十六进制。
pub fn hash_code(code: &str) -> String {
    let normalized = code.trim().to_ascii_uppercase();
    let digest = Sha256::digest(normalized.as_bytes());
    to_hex(&digest)
}

fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// 新建一个配对票据，返回 `(request_id, 明文配对码)`。
///
/// 明文只在此处返回一次：调用方打印给本机用户，之后不可再取回。
pub async fn start(pool: &SqlitePool) -> Result<(String, String), PairingError> {
    expire_stale(pool).await?;

    let code = generate_code();
    let request_id = random_id("pair");
    let created_at = now_ms();
    let expires_at = created_at + CODE_TTL_MS;

    let insert = sqlx::query(
        "INSERT INTO pairing_requests (id, code_hash, status, attempts, created_at, expires_at) \
         VALUES (?, ?, 'pending', 0, ?, ?)",
    )
    .bind(&request_id)
    .bind(hash_code(&code))
    .bind(created_at)
    .bind(expires_at)
    .execute(pool)
    .await;

    if let Err(err) = insert {
        // 唯一索引 idx_pairing_active 保证同一时刻只有一个活跃票据；
        // 命中约束说明已有票据仍在有效期内。
        if err.to_string().contains("UNIQUE") {
            return Err(PairingError::Conflict(
                "已有待确认的配对请求，先处理或等待其过期",
            ));
        }
        return Err(PairingError::Db(err));
    }

    Ok((request_id, code))
}

/// 客户端提交配对码与设备信息。
///
/// 命中则回填设备信息并转入 `awaiting_confirmation`，返回票据 id；
/// 未命中按失败计数处理，达上限即锁定。
pub async fn submit(
    pool: &SqlitePool,
    code: &str,
    device_name: &str,
    platform: &str,
    client_pubkey: &str,
) -> Result<(String, i64), PairingError> {
    expire_stale(pool).await?;

    let active = sqlx::query_as::<_, (String, String, i64, i64)>(
        "SELECT id, code_hash, attempts, expires_at FROM pairing_requests \
         WHERE status IN ('pending', 'awaiting_confirmation') LIMIT 1",
    )
    .fetch_optional(pool)
    .await?
    .ok_or(PairingError::NoActiveRequest)?;

    let (request_id, code_hash, attempts, expires_at) = active;
    if expires_at <= now_ms() {
        expire_stale(pool).await?;
        return Err(PairingError::InvalidCode);
    }
    if attempts >= MAX_ATTEMPTS {
        return Err(PairingError::Locked);
    }

    let provided = hash_code(code);
    if !bool::from(provided.as_bytes().ct_eq(code_hash.as_bytes())) {
        let next = attempts + 1;
        let status = if next >= MAX_ATTEMPTS {
            "locked"
        } else {
            "pending"
        };
        sqlx::query("UPDATE pairing_requests SET attempts = ?, status = ? WHERE id = ?")
            .bind(next)
            .bind(status)
            .bind(&request_id)
            .execute(pool)
            .await?;

        return Err(if next >= MAX_ATTEMPTS {
            PairingError::Locked
        } else {
            PairingError::InvalidCode
        });
    }

    sqlx::query(
        "UPDATE pairing_requests \
         SET device_name = ?, platform = ?, client_pubkey = ?, status = 'awaiting_confirmation' \
         WHERE id = ?",
    )
    .bind(device_name)
    .bind(platform)
    .bind(client_pubkey)
    .bind(&request_id)
    .execute(pool)
    .await?;

    Ok((request_id, expires_at))
}

/// 确认配对：写入 `devices` 并把票据置为 `approved`。
///
/// `approved_by` 为 `"local"` 表示本机确认，否则是代批设备的 id。
pub async fn approve(
    pool: &SqlitePool,
    request_id: &str,
    approved_by: &str,
) -> Result<ApprovedDevice, PairingError> {
    expire_stale(pool).await?;

    let mut tx = pool.begin().await?;

    let row = sqlx::query_as::<_, (Option<String>, Option<String>, Option<String>, String)>(
        "SELECT device_name, platform, client_pubkey, status FROM pairing_requests WHERE id = ?",
    )
    .bind(request_id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(PairingError::NotFound)?;

    let (device_name, platform, client_pubkey, status) = row;
    if status == "approved" {
        return Err(PairingError::Conflict("已确认过"));
    }
    if status != "awaiting_confirmation" {
        return Err(PairingError::Conflict("尚未提交配对码"));
    }

    let device_name = device_name.unwrap_or_else(|| "未命名设备".to_string());
    let platform = platform.unwrap_or_else(|| "unknown".to_string());
    let client_pubkey = client_pubkey.ok_or(PairingError::Conflict("缺少客户端公钥"))?;

    let pubkey_bytes =
        base32::decode(B32, &client_pubkey).ok_or(PairingError::Conflict("公钥不是 base32"))?;
    let _pubkey_bytes: [u8; 32] = pubkey_bytes
        .try_into()
        .map_err(|_| PairingError::Conflict("公钥长度不是 32 字节"))?;

    let device_id = random_id("dev");
    let paired_at = now_ms();

    let insert = sqlx::query(
        "INSERT INTO devices (id, name, platform, pubkey, approved_by, paired_at) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(&device_id)
    .bind(&device_name)
    .bind(&platform)
    .bind(&client_pubkey)
    .bind(approved_by)
    .bind(paired_at)
    .execute(&mut *tx)
    .await;

    if let Err(err) = insert {
        let message = err.to_string();
        if message.contains("UNIQUE") {
            return Err(PairingError::DuplicateDevice);
        }
        return Err(PairingError::Db(err));
    }

    sqlx::query("UPDATE pairing_requests SET status = 'approved', approved_by = ? WHERE id = ?")
        .bind(approved_by)
        .bind(request_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;

    Ok(ApprovedDevice {
        device_id,
        device_name,
    })
}

/// 拒绝配对。
pub async fn reject(pool: &SqlitePool, request_id: &str) -> Result<(), PairingError> {
    let result = sqlx::query(
        "UPDATE pairing_requests SET status = 'rejected' \
         WHERE id = ? AND status IN ('pending', 'awaiting_confirmation')",
    )
    .bind(request_id)
    .execute(pool)
    .await?;

    if result.rows_affected() == 0 {
        return Err(PairingError::NotFound);
    }
    Ok(())
}

/// 查询票据状态（客户端轮询用）。
pub async fn status(pool: &SqlitePool, request_id: &str) -> Result<RequestStatus, PairingError> {
    let row = sqlx::query_as::<_, (String, String)>(
        "SELECT id, status FROM pairing_requests WHERE id = ?",
    )
    .bind(request_id)
    .fetch_optional(pool)
    .await?
    .ok_or(PairingError::NotFound)?;

    let device_id = sqlx::query_scalar::<_, String>(
        "SELECT id FROM devices WHERE pubkey = (SELECT client_pubkey FROM pairing_requests WHERE id = ?)",
    )
    .bind(request_id)
    .fetch_optional(pool)
    .await?;

    Ok(RequestStatus {
        id: row.0,
        status: row.1,
        device_id,
    })
}

/// 列出当前活跃票据（管理面展示）。
pub async fn pending(pool: &SqlitePool) -> Result<Vec<PendingRequest>, PairingError> {
    expire_stale(pool).await?;

    let rows = sqlx::query_as::<_, (String, Option<String>, Option<String>, String, i64, i64)>(
        "SELECT id, device_name, platform, status, created_at, expires_at \
         FROM pairing_requests WHERE status IN ('pending', 'awaiting_confirmation') \
         ORDER BY created_at DESC",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| PendingRequest {
            id: row.0,
            device_name: row.1,
            platform: row.2,
            status: row.3,
            created_at: row.4,
            expires_at: row.5,
        })
        .collect())
}

/// 把过期票据标记为 `expired`，让活跃唯一索引重新可用。
async fn expire_stale(pool: &SqlitePool) -> Result<(), PairingError> {
    sqlx::query(
        "UPDATE pairing_requests SET status = 'expired' \
         WHERE status IN ('pending', 'awaiting_confirmation') AND expires_at <= ?",
    )
    .bind(now_ms())
    .execute(pool)
    .await?;
    Ok(())
}

/// 生成带前缀的随机 id，便于日志区分对象类型。
pub fn random_id(prefix: &str) -> String {
    let bytes: [u8; 16] = rand::random();
    format!("{prefix}_{}", base32::encode(B32, &bytes).to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_uses_safe_alphabet_and_length() {
        for _ in 0..200 {
            let code = generate_code();
            assert_eq!(code.len(), CODE_LEN);
            assert!(code.chars().all(|c| CODE_ALPHABET.contains(&(c as u8))));
            assert!(code.chars().all(|c| !matches!(c, '0' | 'O' | '1' | 'I')));
        }
    }

    #[test]
    fn hash_is_case_insensitive_and_trimmed() {
        assert_eq!(hash_code(" abcd1234efgh "), hash_code("ABCD1234EFGH"));
        assert_ne!(hash_code("ABCD1234EFGH"), hash_code("ABCD1234EFGX"));
    }

    #[test]
    fn hash_is_sha256_hex() {
        let hash = hash_code("ABC");
        assert_eq!(hash.len(), 64);
        assert!(hash
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
