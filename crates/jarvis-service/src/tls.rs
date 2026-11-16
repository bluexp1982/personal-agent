//! 自签 TLS：证书生成、持久化与指纹。
//!
//! 设计要点：
//!
//! - **独立的证书密钥（ECDSA P-256）**：不复用 Ed25519 身份密钥签证书。
//!   实测 macOS 自带 curl（LibreSSL 3.3.6）的 ClientHello 里没有 Ed25519 签名算法候选，
//!   服务端持 Ed25519 证书时会直接回 `NoSignatureSchemesInCommon`——排障用的
//!   `curl --cacert` 首先就用不了。P-256 是所有目标客户端（苹果/Windows/Linux 的
//!   curl、Dart 的 BoringSSL、浏览器）都必然支持的曲线，代价只是多一个私钥文件。
//! - **证书不随重启变化**：首次生成后落盘（证书 DER/PEM + 私钥 DER），之后只读。
//!   客户端固定的是证书的 SHA-256，指纹变化只应发生在"数据目录被删"。
//! - **有效期取 100 年**：自签证书靠指纹固定，不参与公信 CA 体系，没有续期需求；
//!   设成短期反而会在某天突然连不上，把一个安静的问题变成凌晨的故障。
//! - **`Debug` 不打印密钥材料**：私钥只在内存里以 PKCS#8 字节存在，日志只出指纹。

use std::path::Path;
use std::sync::Arc;

use rcgen::{
    date_time_ymd, CertificateParams, DnType, ExtendedKeyUsagePurpose, KeyPair, KeyUsagePurpose,
    PKCS_ECDSA_P256_SHA256,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::ServerConfig;
use sha2::{Digest, Sha256};
use tokio_rustls::TlsAcceptor;

use crate::config::Config;
use crate::identity::format_digest;

/// 证书 SAN 里始终包含的回环名字：本机调试时不必再加 `-k`。
const LOOPBACK_SANS: [&str; 3] = ["localhost", "127.0.0.1", "::1"];

#[derive(Debug, thiserror::Error)]
pub enum TlsError {
    #[error("读写 TLS 证书失败: {0}")]
    Io(#[from] std::io::Error),
    #[error("生成自签证书失败: {0}")]
    Generate(#[from] rcgen::Error),
    #[error("构建 TLS 配置失败: {0}")]
    Rustls(#[from] rustls::Error),
}

/// 进程内共享的 TLS 材料：证书 DER、私钥 DER（内存态）与对外展示的指纹。
pub struct TlsIdentity {
    cert_der: Vec<u8>,
    key_der: Vec<u8>,
    fingerprint: String,
}

impl std::fmt::Debug for TlsIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TlsIdentity")
            .field("fingerprint", &self.fingerprint)
            .finish_non_exhaustive()
    }
}

impl TlsIdentity {
    /// 加载已有证书；证书或私钥任一缺失、不可读时重新生成一对新的。
    ///
    /// 两者必须同生共死：只补一半会得到一个"证书与私钥不配套"的配置，
    /// 症状是所有握手都失败，而日志里看不出原因。
    pub fn load_or_create(config: &Config) -> Result<Self, TlsError> {
        let cert_path = config.tls_cert_path();
        let key_path = config.tls_key_path();

        match (read_file(&cert_path)?, read_file(&key_path)?) {
            (Some(cert_der), Some(key_der)) => {
                let tls = Self::from_parts(cert_der, key_der);
                // PEM 只是排障副本，每次启动按权威的 DER 重写一次，避免两者漂移。
                write_pem(&config.tls_cert_pem_path(), &tls.cert_pem())?;
                Ok(tls)
            }
            (Some(_), None) => {
                tracing::warn!(
                    path = %key_path.display(),
                    "TLS 私钥缺失，重新生成证书；客户端需要重新核对指纹"
                );
                Self::generate_and_store(config)
            }
            (None, Some(_)) => {
                tracing::warn!(
                    path = %cert_path.display(),
                    "TLS 证书缺失，重新生成证书与私钥；客户端需要重新核对指纹"
                );
                Self::generate_and_store(config)
            }
            (None, None) => Self::generate_and_store(config),
        }
    }

    fn generate_and_store(config: &Config) -> Result<Self, TlsError> {
        let tls = Self::generate()?;

        write_private(&config.tls_cert_path(), &tls.cert_der)?;
        write_private(&config.tls_key_path(), &tls.key_der)?;
        write_pem(&config.tls_cert_pem_path(), &tls.cert_pem())?;

        tracing::info!(
            cert = %config.tls_cert_path().display(),
            fingerprint = %tls.fingerprint,
            "已生成自签 TLS 证书（客户端首次连接时核对此指纹）"
        );
        Ok(tls)
    }

    /// 由证书与私钥字节装配（不触碰磁盘）。
    fn from_parts(cert_der: Vec<u8>, key_der: Vec<u8>) -> Self {
        let fingerprint = format_digest(&Sha256::digest(&cert_der));
        Self {
            cert_der,
            key_der,
            fingerprint,
        }
    }

    fn generate() -> Result<Self, TlsError> {
        let key_pair = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)?;

        let mut params = CertificateParams::new(sans())?;
        params
            .distinguished_name
            .push(DnType::CommonName, "personal-agent");
        params
            .distinguished_name
            .push(DnType::OrganizationName, "personal-agent");
        // 起点放在过去，避免设备时钟略慢时被判定"证书尚未生效"。
        params.not_before = date_time_ymd(2020, 1, 1);
        params.not_after = date_time_ymd(2126, 1, 1);
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];

        let cert = params.self_signed(&key_pair)?;
        Ok(Self::from_parts(
            cert.der().as_ref().to_vec(),
            key_pair.serialize_der(),
        ))
    }

    /// 供 `tokio_rustls` 使用；每次启动构建一次，不按连接解析文件。
    pub fn acceptor(&self) -> Result<TlsAcceptor, TlsError> {
        let certs = vec![CertificateDer::from(self.cert_der.clone())];
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.key_der.clone()));

        // 显式指定 ring provider：仓库里 reqwest 也用 ring，两条 TLS 路径只有一种实现。
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut config = ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(certs, key)?;
        // 只声明 HTTP/1.1：SSE 与 hyper 都是 h1 语义，多声明 h2 会让客户端走一条
        // 本项目从未验证过的路径（流式响应的分帧行为完全不同）。
        config.alpn_protocols = vec![b"http/1.1".to_vec()];

        Ok(TlsAcceptor::from(Arc::new(config)))
    }

    /// 供人工核对与 `/admin/identity` 展示的四组短码，形如 `A7K2-9XQP-3MDE-6RTU`。
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    pub fn cert_der(&self) -> &[u8] {
        &self.cert_der
    }

    pub fn cert_pem(&self) -> String {
        pem_encode(&self.cert_der)
    }
}

/// 证书 SAN：回环名字 + 生成时探测到的本机地址。
///
/// 客户端按指纹而不是主机名信任，SAN 只影响 `curl --cacert` 这类走标准校验的工具；
/// 但让它们在局域网地址上也能直接用，排障会少一步。
fn sans() -> Vec<String> {
    let mut names: Vec<String> = LOOPBACK_SANS.iter().map(|s| (*s).to_string()).collect();
    if let Some(ip) = detect_lan_ip() {
        names.push(ip.to_string());
    }
    names
}

/// 取本机默认出口地址。UDP `connect` 只设置对端，不发包。
pub fn detect_lan_ip() -> Option<std::net::IpAddr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    match socket.local_addr().ok()?.ip() {
        ip if ip.is_loopback() || ip.is_unspecified() => None,
        ip => Some(ip),
    }
}

fn read_file(path: &Path) -> Result<Option<Vec<u8>>, TlsError> {
    match std::fs::read(path) {
        Ok(bytes) if !bytes.is_empty() => Ok(Some(bytes)),
        Ok(_) => Ok(None),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err.into()),
    }
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<(), TlsError> {
    write_file(path, bytes)?;
    restrict(path)?;
    Ok(())
}

fn write_pem(path: &Path, pem: &str) -> Result<(), TlsError> {
    write_file(path, pem.as_bytes())
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), TlsError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, bytes)?;
    Ok(())
}

fn pem_encode(der: &[u8]) -> String {
    use base64_like::encode;
    let body = encode(der);
    let mut out = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        out.push_str(&String::from_utf8_lossy(chunk));
        out.push('\n');
    }
    out.push_str("-----END CERTIFICATE-----\n");
    out
}

#[cfg(unix)]
fn restrict(path: &Path) -> Result<(), TlsError> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn restrict(_path: &Path) -> Result<(), TlsError> {
    Ok(())
}

/// 手写 base64：只为把 DER 转成 PEM 给 `curl --cacert` 用，
/// 为此再加一个依赖不值得（证书只有一千多字节）。
mod base64_like {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub(super) fn encode(input: &[u8]) -> String {
        let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
        for chunk in input.chunks(3) {
            let b0 = chunk[0] as u32;
            let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
            let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
            let triple = (b0 << 16) | (b1 << 8) | b2;

            out.push(ALPHABET[((triple >> 18) & 0x3f) as usize] as char);
            out.push(ALPHABET[((triple >> 12) & 0x3f) as usize] as char);
            if chunk.len() > 1 {
                out.push(ALPHABET[((triple >> 6) & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
            if chunk.len() > 2 {
                out.push(ALPHABET[(triple & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "personal-agent-tls-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn config_in(dir: &Path) -> Config {
        Config {
            data_dir: dir.to_path_buf(),
            ..Config::default()
        }
    }

    #[test]
    fn certificate_is_stable_across_loads() {
        let dir = TempDir::new("stable");
        let config = config_in(&dir.0);

        let first = TlsIdentity::load_or_create(&config).unwrap();
        let second = TlsIdentity::load_or_create(&config).unwrap();

        assert_eq!(
            first.fingerprint(),
            second.fingerprint(),
            "重启不能换指纹，否则客户端每次都要重新核对"
        );
        assert_eq!(first.cert_der(), second.cert_der());
        assert!(config.tls_cert_path().exists());
        assert!(config.tls_key_path().exists());
        assert!(config.tls_cert_pem_path().exists());
    }

    #[test]
    fn losing_the_key_regenerates_certificate_and_key_together() {
        let dir = TempDir::new("key-lost");
        let config = config_in(&dir.0);

        let older = TlsIdentity::load_or_create(&config).unwrap();
        std::fs::remove_file(config.tls_key_path()).unwrap();

        let newer = TlsIdentity::load_or_create(&config).unwrap();
        assert_ne!(
            older.fingerprint(),
            newer.fingerprint(),
            "只剩证书时不能硬撑：宁可换一对新的，也不要留下不配套的组合"
        );
        assert!(config.tls_key_path().exists());
        // 新的一对必须能真正构建出 TLS 配置（证书与私钥配套）。
        newer.acceptor().expect("重新生成的证书与私钥应配套");
    }

    #[test]
    fn fingerprint_has_four_groups_like_identity() {
        let dir = TempDir::new("fingerprint");
        let config = config_in(&dir.0);
        let tls = TlsIdentity::load_or_create(&config).unwrap();

        let groups: Vec<&str> = tls.fingerprint().split('-').collect();
        assert_eq!(groups.len(), 4, "指纹格式应与身份指纹一致");
        assert!(groups.iter().all(|group| group.len() == 4));
    }

    #[test]
    fn pem_roundtrip_matches_der() {
        let dir = TempDir::new("pem");
        let config = config_in(&dir.0);
        let tls = TlsIdentity::load_or_create(&config).unwrap();

        let pem = tls.cert_pem();
        assert!(pem.starts_with("-----BEGIN CERTIFICATE-----\n"));
        assert!(pem.trim_end().ends_with("-----END CERTIFICATE-----"));

        let stored = std::fs::read_to_string(config.tls_cert_pem_path()).unwrap();
        assert_eq!(pem, stored);
        // PEM 是 DER 的 base64；长度必须对得上（含换行）。
        let body: String = pem
            .lines()
            .filter(|line| !line.starts_with("-----"))
            .collect::<Vec<_>>()
            .join("");
        assert_eq!(body.len(), tls.cert_der().len().div_ceil(3) * 4);
    }

    #[test]
    fn base64_matches_rfc4648_vectors() {
        assert_eq!(base64_like::encode(b"Man"), "TWFu");
        assert_eq!(base64_like::encode(b"Ma"), "TWE=");
        assert_eq!(base64_like::encode(b"M"), "TQ==");
        assert_eq!(base64_like::encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64_like::encode(b""), "");
    }

    #[test]
    fn acceptor_builds_with_ecdsa_certificate() {
        let dir = TempDir::new("acceptor");
        let config = config_in(&dir.0);
        let tls = TlsIdentity::load_or_create(&config).unwrap();
        tls.acceptor()
            .expect("rustls 应当接受 ECDSA P-256 自签证书");
    }

    #[test]
    fn certificate_file_is_not_world_readable() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let dir = TempDir::new("perm");
            let config = config_in(&dir.0);
            let _ = TlsIdentity::load_or_create(&config).unwrap();

            let mode = std::fs::metadata(config.tls_cert_path())
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }
}
