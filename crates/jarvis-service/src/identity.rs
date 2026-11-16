//! 服务端身份：一对 Ed25519 长期密钥。
//!
//! 约束（见「配对与信任 › 身份概念」）：
//! - 私钥只存在本机，文件权限 0600，不进日志、不进任何响应；
//! - 公钥以 base32 展示，指纹为 `base32(sha256(公钥))` 取前 16 字符、每 4 字符分组，
//!   供客户端人工核对；
//! - 签名校验用 `verify_strict`，拒绝弱公钥与可延展签名。
//!
//! 注意：这里**不使用** `SigningKey::generate(&mut OsRng)`——它会把 `rand_core`
//! 版本绑死在 `ed25519-dalek` 上；改为自取 32 字节种子后 `from_bytes`。

use std::path::Path;

use base32::Alphabet;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

/// base32 字母表，不带 padding（对外展示与文件存储都更紧凑）。
pub const B32: Alphabet = Alphabet::Rfc4648 { padding: false };

const KEY_LEN: usize = 32;

#[derive(Debug)]
pub struct Identity {
    signing: SigningKey,
}

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("读写身份密钥失败: {0}")]
    Io(#[from] std::io::Error),
    #[error("身份密钥格式非法（期望 32 字节的 base32 编码）")]
    Malformed,
}

impl Identity {
    /// 加载已有身份；文件不存在时生成并落盘。
    pub fn load_or_create(path: &Path) -> Result<Self, IdentityError> {
        if path.exists() {
            return Self::load(path);
        }

        let seed: [u8; KEY_LEN] = rand::random();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, base32::encode(B32, &seed))?;
        restrict_permissions(path)?;

        Ok(Self {
            signing: SigningKey::from_bytes(&seed),
        })
    }

    fn load(path: &Path) -> Result<Self, IdentityError> {
        let raw = std::fs::read_to_string(path)?;
        let bytes = base32::decode(B32, raw.trim()).ok_or(IdentityError::Malformed)?;
        let seed: [u8; KEY_LEN] = bytes.try_into().map_err(|_| IdentityError::Malformed)?;

        // 历史文件可能权限过宽，每次加载都纠正一次。
        restrict_permissions(path)?;

        Ok(Self {
            signing: SigningKey::from_bytes(&seed),
        })
    }

    pub fn public_key(&self) -> [u8; KEY_LEN] {
        self.signing.verifying_key().to_bytes()
    }

    pub fn public_key_b32(&self) -> String {
        base32::encode(B32, &self.public_key())
    }

    /// 供人工核对的分组指纹，形如 `A7K2-9XQP-3MDE-6RTU`。
    pub fn fingerprint(&self) -> String {
        fingerprint_of(&self.public_key())
    }

    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        self.signing.sign(message).to_bytes()
    }

    /// 校验任意公钥对消息的签名。公钥或签名字节长度不对时直接返回 false。
    pub fn verify(public_key: &[u8], message: &[u8], signature: &[u8]) -> bool {
        let Ok(key_bytes) = <[u8; KEY_LEN]>::try_from(public_key) else {
            return false;
        };
        let Ok(sig_bytes) = <[u8; 64]>::try_from(signature) else {
            return false;
        };
        let Ok(verifying_key) = VerifyingKey::from_bytes(&key_bytes) else {
            return false;
        };
        let signature = Signature::from_bytes(&sig_bytes);
        verifying_key.verify_strict(message, &signature).is_ok()
    }
}

/// 由公钥计算指纹：`base32(sha256(pubkey))` 取前 16 字符，每 4 字符一组。
pub fn fingerprint_of(public_key: &[u8]) -> String {
    format_digest(&Sha256::digest(public_key))
}

/// 把任意摘要按对外统一的四组短码格式展示。
///
/// TLS 证书指纹同样走这里：客户端与终端上的观感只有一种，
/// 用户不需要分辨"这次看到的是身份指纹还是证书指纹"。
pub fn format_digest(digest: &[u8]) -> String {
    let encoded = base32::encode(B32, digest);
    let head: String = encoded.chars().take(16).collect();

    head.as_bytes()
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

#[cfg(unix)]
fn restrict_permissions(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &Path) -> std::io::Result<()> {
    // Windows 上依靠目录 ACL；显式改权限需要平台特定 API，留到打包阶段处理。
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_key_path(tag: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("系统时间异常")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "personal-agent-identity-{tag}-{}-{nanos}.key",
            std::process::id()
        ))
    }

    #[test]
    fn creates_and_reloads_same_key() {
        let path = temp_key_path("reload");
        let first = Identity::load_or_create(&path).expect("创建身份失败");
        let second = Identity::load_or_create(&path).expect("加载身份失败");

        assert_eq!(first.public_key(), second.public_key());
        let _ = std::fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn key_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let path = temp_key_path("perm");
        let _identity = Identity::load_or_create(&path).expect("创建身份失败");
        let mode = std::fs::metadata(&path)
            .expect("读取元数据失败")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn signature_roundtrip_and_tamper_detection() {
        let path = temp_key_path("sign");
        let identity = Identity::load_or_create(&path).expect("创建身份失败");
        let message = b"challenge-bytes";
        let signature = identity.sign(message);

        assert!(Identity::verify(
            &identity.public_key(),
            message,
            &signature
        ));
        assert!(!Identity::verify(
            &identity.public_key(),
            b"other",
            &signature
        ));
        assert!(!Identity::verify(&[0u8; 32], message, &signature));
        assert!(!Identity::verify(
            &identity.public_key(),
            message,
            &[0u8; 63]
        ));

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn fingerprint_has_four_groups() {
        let path = temp_key_path("fingerprint");
        let identity = Identity::load_or_create(&path).expect("创建身份失败");
        let fingerprint = identity.fingerprint();
        let groups: Vec<&str> = fingerprint.split('-').collect();

        assert_eq!(groups.len(), 4);
        assert!(groups.iter().all(|group| group.len() == 4));

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn malformed_key_file_is_rejected() {
        let path = temp_key_path("malformed");
        std::fs::write(&path, "not-base32!!").expect("写测试文件失败");

        let result = Identity::load_or_create(&path);
        assert!(matches!(result, Err(IdentityError::Malformed)));

        let _ = std::fs::remove_file(path);
    }
}
