//! 客户端写入的模型密钥。
//!
//! 接入第三方模型之后，密钥不能再只靠环境变量：用户在客户端里填一把 Key
//! 就要能立刻用上，没道理再让他 ssh 到服务器改 shell profile。
//!
//! 三条硬规矩：
//! - **单独一个文件**：`{data_dir}/model-secrets.json`，`config.json` 里只放引用，
//!   备份或发给别人一份配置时不会顺手把 Key 带出去；
//! - **0600 + 原子写**：Unix 上先写临时文件、改权限、再 rename。直接覆写时
//!   进程被杀会留下半截 JSON，下次启动所有模型一起失效；
//! - **绝不回显**：对外只给"有没有"、来源与末四位，完整值只在服务端进程内使用。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// 密钥文件名。放在 `data_dir` 下，与 SQLite、身份密钥同级。
pub const SECRETS_FILE: &str = "model-secrets.json";

/// 显示用的密钥尾巴长度。
const HINT_TAIL: usize = 4;

/// 磁盘上的形状。带 `version` 是为了以后换存储方式时能识别老文件。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SecretsFile {
    version: u32,
    /// `配置 id → 密钥`。默认档的 id 是 `default`。
    keys: BTreeMap<String, String>,
}

impl Default for SecretsFile {
    fn default() -> Self {
        Self {
            version: 1,
            keys: BTreeMap::new(),
        }
    }
}

/// 一把密钥的来源。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KeySource {
    /// 客户端写入的密钥文件。
    Secrets,
    /// `api_key_env` 指向的环境变量。
    Env,
    /// 都没有。
    None,
}

impl KeySource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Secrets => "secrets",
            Self::Env => "env",
            Self::None => "none",
        }
    }
}

/// 一把密钥的"可展示信息"：有没有、从哪来、末四位。
///
/// 结构里**没有完整密钥**，所以它可以被安全地塞进日志与 HTTP 响应。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeyState {
    pub present: bool,
    pub source: Option<KeySource>,
    pub hint: Option<String>,
}

impl KeyState {
    pub fn source(&self) -> KeySource {
        self.source.unwrap_or(KeySource::None)
    }
}

/// 密钥文件的读写句柄。克隆廉价（只有一个路径）。
#[derive(Debug, Clone)]
pub struct ModelSecrets {
    path: PathBuf,
}

impl ModelSecrets {
    pub fn new(data_dir: &Path) -> Self {
        Self {
            path: data_dir.join(SECRETS_FILE),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 读取一把密钥。文件缺失/损坏都当"没有"，只记日志。
    ///
    /// 损坏不报错是刻意的：一份被手工改坏的密钥文件不该让整个服务起不来，
    /// 代价只是模型回到"缺少密钥"的降级状态，用户重新保存一次即可。
    pub fn get(&self, id: &str) -> Option<String> {
        self.load()
            .keys
            .get(id)
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    /// 写入/覆盖一把密钥。空串等价于删除。
    pub fn set(&self, id: &str, key: &str) -> Result<(), String> {
        let key = key.trim();
        if key.is_empty() {
            return self.remove(id);
        }

        let mut file = self.load();
        file.keys.insert(id.to_string(), key.to_string());
        self.save(&file)
    }

    /// 删除一把密钥。不存在也算成功。
    pub fn remove(&self, id: &str) -> Result<(), String> {
        let mut file = self.load();
        if file.keys.remove(id).is_none() {
            return Ok(());
        }
        self.save(&file)
    }

    /// 密钥的末四位，用于"已配置（sk-…9f2a）"这类提示。
    pub fn hint_of(key: &str) -> String {
        let chars: Vec<char> = key.trim().chars().collect();
        if chars.len() <= HINT_TAIL {
            return "…".to_string();
        }
        let tail: String = chars[chars.len() - HINT_TAIL..].iter().collect();
        format!("…{tail}")
    }

    fn load(&self) -> SecretsFile {
        let Ok(raw) = std::fs::read_to_string(&self.path) else {
            return SecretsFile::default();
        };
        match serde_json::from_str::<SecretsFile>(&raw) {
            Ok(file) => file,
            Err(err) => {
                tracing::warn!(
                    path = %self.path.display(),
                    %err,
                    "模型密钥文件无法解析，本次按「未配置密钥」处理"
                );
                SecretsFile::default()
            }
        }
    }

    fn save(&self, file: &SecretsFile) -> Result<(), String> {
        let body = serde_json::to_string_pretty(file)
            .map_err(|err| format!("序列化模型密钥失败：{err}"))?;

        if let Some(parent) = self.path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)
                    .map_err(|err| format!("创建数据目录 {} 失败：{err}", parent.display()))?;
            }
        }

        // 临时文件与目标同目录：跨设备 rename 会失败，而且临时文件也不该落到 /tmp。
        let temp = self.path.with_extension("json.tmp");
        std::fs::write(&temp, body)
            .map_err(|err| format!("写入密钥临时文件 {} 失败：{err}", temp.display()))?;

        restrict_permissions(&temp);
        std::fs::rename(&temp, &self.path).map_err(|err| {
            let _ = std::fs::remove_file(&temp);
            format!("保存密钥文件 {} 失败：{err}", self.path.display())
        })?;
        Ok(())
    }
}

/// Unix 上把文件收成 0600；其它平台维持默认 ACL。
///
/// 失败只告警不阻断：Windows 上根本没有 POSIX 权限位，为了让这条路径
/// "也能跑通"而整体失败，等于让 Windows 用户完全用不了模型配置。
fn restrict_permissions(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(err) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
            tracing::warn!(
                path = %path.display(),
                %err,
                "模型密钥文件权限收紧为 0600 失败，请检查数据目录权限"
            );
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secrets() -> (tempfile::TempDir, ModelSecrets) {
        let dir = tempfile::tempdir().expect("创建临时目录失败");
        let secrets = ModelSecrets::new(dir.path());
        (dir, secrets)
    }

    #[test]
    fn missing_file_means_no_key() {
        let (_dir, secrets) = secrets();
        assert_eq!(secrets.get("default"), None);
        assert!(!secrets.path().exists(), "读不存在的文件不该顺手创建它");
    }

    #[test]
    fn set_then_get_round_trip() {
        let (_dir, secrets) = secrets();
        secrets.set("default", "sk-abc123").expect("写入失败");
        assert_eq!(secrets.get("default").as_deref(), Some("sk-abc123"));
    }

    #[test]
    fn empty_value_removes_the_key() {
        let (_dir, secrets) = secrets();
        secrets.set("default", "sk-abc123").expect("写入失败");
        secrets.set("default", "   ").expect("清空失败");
        assert_eq!(secrets.get("default"), None);
    }

    #[test]
    fn keys_are_scoped_per_profile() {
        let (_dir, secrets) = secrets();
        secrets.set("default", "sk-one").expect("写入失败");
        secrets.set("deepseek", "sk-two").expect("写入失败");
        assert_eq!(secrets.get("default").as_deref(), Some("sk-one"));
        assert_eq!(secrets.get("deepseek").as_deref(), Some("sk-two"));
        assert_eq!(secrets.get("other"), None);
    }

    #[test]
    fn broken_file_falls_back_to_no_key() {
        let (dir, secrets) = secrets();
        std::fs::write(dir.path().join(SECRETS_FILE), "{ not json").expect("写入失败");
        assert_eq!(secrets.get("default"), None);
    }

    #[test]
    fn hint_keeps_only_the_tail() {
        assert_eq!(ModelSecrets::hint_of("sk-abcdef9f2a"), "…9f2a");
        assert_eq!(ModelSecrets::hint_of("ab"), "…", "太短的密钥不能整段回显");
    }

    #[cfg(unix)]
    #[test]
    fn saved_file_is_not_world_readable() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, secrets) = secrets();
        secrets.set("default", "sk-abc123").expect("写入失败");
        let mode = std::fs::metadata(secrets.path())
            .expect("读取元数据失败")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "密钥文件必须只有属主可读写");
    }
}
