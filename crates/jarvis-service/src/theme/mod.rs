//! 主题包（个性化主题）的安装、校验与生命周期。
//!
//! 分三层，每层只做一件事：
//!
//! - [`manifest`]：`theme.json` 长什么样、哪些字段必填、id 与颜色怎么校验。
//! - [`install`]：把 zip 安全地落成目录（安全规则由 [`crate::archive`] 统一提供）。
//! - [`store`]：落库、列表、删除。
//!
//! 与技能包的关键差异：
//!
//! - **没有启停**：主题是"选中即用"的二选一，`enabled` 没有语义。
//! - **没有版本目录**：`themes/<id>/` 直接覆盖，主题之间不可能并存同一 id 的两个版本。
//! - **不让服务端渲染**：服务端只校验与保存稀疏色表，`ThemeData` 由客户端装配。
//!   这样 Flutter 侧的色表保持唯一真源，服务端加一个 token 不需要跟着改。

pub(crate) mod install;
pub(crate) mod manifest;
pub(crate) mod store;

use protocol::ErrorCode;

/// 主题包根目录名（位于数据目录下）。
pub(crate) const THEMES_DIR: &str = "themes";

/// 安装过程中的临时目录名（位于 `themes/` 下）。
pub(crate) const THEME_TMP_DIR: &str = ".tmp";

/// 必填清单文件名。
pub(crate) const THEME_MANIFEST: &str = "theme.json";

/// 本项目认识的主题清单版本。
pub(crate) const THEME_API: u32 = 1;

/// 安装包体积上限。主题包是纯文本，2 MiB 已经非常宽（壁纸不进包）。
pub(crate) const MAX_ARCHIVE_BYTES: usize = 2 * 1024 * 1024;
/// 文件数上限。
pub(crate) const MAX_ENTRIES: usize = 64;
/// 单个文件解压后上限。
pub(crate) const MAX_ENTRY_BYTES: u64 = 512 * 1024;
/// 解压总量上限。
pub(crate) const MAX_TOTAL_BYTES: u64 = 4 * 1024 * 1024;

/// 解包上限。与技能包共用同一份安全实现，只是额度更紧。
pub(crate) const THEME_ARCHIVE_LIMITS: crate::archive::ArchiveLimits =
    crate::archive::ArchiveLimits {
        archive: MAX_ARCHIVE_BYTES,
        entries: MAX_ENTRIES,
        entry: MAX_ENTRY_BYTES,
        total: MAX_TOTAL_BYTES,
    };

/// 客户端已经占用的主题 id。
///
/// 覆盖安装同名主题是允许的（同 id 即同主题的新版本），但这些名字不能当包 id：
/// 客户端把它们当作"内置主题"的代号，撞上会让选择持久化产生歧义。
pub(crate) const RESERVED_IDS: &[&str] = &["light", "dark", "system", "custom"];

/// 安装与管理链路里的错误。
///
/// 只有三类：包不对、不存在、本机 IO。比技能包少了 `Conflict`——
/// 同 id 重装是覆盖，不是冲突。
#[derive(Debug, thiserror::Error)]
pub(crate) enum ThemeError {
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Io(String),
}

impl ThemeError {
    /// 映射成对外错误码。IO 失败归到 `internal_error`：那是本机的磁盘问题，
    /// 不是用户装错了包，提示里应让他去看日志而不是改包。
    pub(crate) const fn code(&self) -> ErrorCode {
        match self {
            Self::Invalid(_) => ErrorCode::ThemeInvalid,
            Self::NotFound(_) => ErrorCode::ThemeNotFound,
            Self::Io(_) => ErrorCode::InternalError,
        }
    }

    /// 面向用户的一句话。装错包时他知道下一步该做什么。
    pub(crate) const fn hint(&self) -> &'static str {
        match self {
            Self::Invalid(_) => {
                "这个包不是可识别的主题包：确认 zip 里含 theme.json，且 brightness 为 light 或 dark"
            }
            Self::NotFound(_) => "主题包不存在或已删除",
            Self::Io(_) => "主题包装载失败，请查看服务端日志",
        }
    }
}

impl From<crate::archive::ArchiveError> for ThemeError {
    fn from(error: crate::archive::ArchiveError) -> Self {
        match error {
            crate::archive::ArchiveError::Invalid(message) => Self::Invalid(message),
            crate::archive::ArchiveError::Io(message) => Self::Io(message),
        }
    }
}

/// 时间戳（Unix 毫秒），与项目其它地方统一。
pub(crate) fn now_ms() -> i64 {
    crate::clock::now_ms()
}

/// 生成一个临时目录名。只想避免并发冲突，没必要为此多一个依赖。
pub(crate) fn random_token() -> String {
    format!("{:016x}", rand::random::<u64>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes_map_to_stable_strings() {
        assert_eq!(
            ThemeError::Invalid("x".into()).code().as_str(),
            "theme_invalid"
        );
        assert_eq!(
            ThemeError::NotFound("x".into()).code().as_str(),
            "theme_not_found"
        );
        assert_eq!(ThemeError::Io("x".into()).code().as_str(), "internal_error");
    }

    #[test]
    fn archive_limits_fit_inside_body_limit() {
        // 端点放宽到上限 + 1MB，handler 才能自己返回可读错误而不是 axum 的纯文本 413。
        assert!(MAX_ARCHIVE_BYTES >= 1024 * 1024);
        assert!(THEME_ARCHIVE_LIMITS.archive == MAX_ARCHIVE_BYTES);
    }
}
