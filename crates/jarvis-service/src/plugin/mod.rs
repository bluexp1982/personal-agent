//! 技能包（外部技能）的安装、兼容与生命周期。
//!
//! 分四层，每层只做一件事：
//!
//! - [`manifest`]：包是什么形状（Claude 插件 / 本项目原生 / 无清单 / 单技能），
//!   以及 `plugin.json` 里那几个字段。
//! - [`install`]：把 zip 安全地落成目录。路径穿越、zip 炸弹、超限都在这里挡住。
//! - [`compat`]：把「符合 Agent Skills 规范的技能」翻译成「本项目能跑的技能」。
//!   补缺省字段、映射工具、判三态。**这是唯一懂规范的地方**，worker 只读结果。
//! - [`store`]：落库、列表、启停、卸载、审计。
//!
//! 为什么兼容层在 service 而不在 worker：装包时就要知道「这条技能能不能跑」，
//! 管理页要显示原因；而 worker 只该消费归一化后的结果（`sidecar`），
//! 不该懂 `allowed-tools`、更不该懂包形态。

pub mod cli;
pub(crate) mod compat;
pub(crate) mod install;
pub(crate) mod manifest;
/// 集成测试也要走同一套播种（测试不经过 `app::run`），所以对外可见。
pub mod seed;
pub(crate) mod store;

use protocol::ErrorCode;

/// 插件安装根目录名（位于数据目录下）。
pub(crate) const PLUGINS_DIR: &str = "plugins";

/// 安装过程中的临时目录名（位于 `plugins/` 下）。
pub(crate) const PLUGIN_TMP_DIR: &str = ".tmp";

/// 本项目认识的清单版本。缺省视为 1：Claude/Codex 的 `plugin.json` 没有这个字段。
pub(crate) const PLUGIN_API: u32 = 1;

/// 安装包体积上限。技能包是文本，8 MiB 已经非常宽。
pub(crate) const MAX_ARCHIVE_BYTES: usize = 8 * 1024 * 1024;
/// 文件数上限，防「几万个小文件」把 inode 吃光。
pub(crate) const MAX_ENTRIES: usize = 256;
/// 单个文件解压后上限。
pub(crate) const MAX_ENTRY_BYTES: u64 = 2 * 1024 * 1024;
/// 解压总量上限，防 zip 炸弹。
pub(crate) const MAX_TOTAL_BYTES: u64 = 32 * 1024 * 1024;

/// 技能正文（`SKILL.md` + 合并的 `references/*.md`）上限。
///
/// 规范建议正文 <500 行；个人场景下 16 KiB 足够，超出的部分截断并记 warn——
/// 我们没有给 worker「按需读配套文件」的能力，全量塞进提示词只会白烧上下文。
pub(crate) const MAX_SKILL_BODY_BYTES: usize = 16 * 1024;

/// 安装与管理链路里的错误。
///
/// 分四类而不是一个字符串：`ErrorCode` 是给客户端分支用的，
/// 「包不对」和「重名了」的下一步动作完全不同。
#[derive(Debug, thiserror::Error)]
pub(crate) enum PluginError {
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Io(String),
}

impl PluginError {
    /// 映射成对外错误码。IO 失败归到 `internal_error`：那是本机的磁盘问题，
    /// 不是用户装错了包，提示里应让他去看日志而不是改包。
    pub(crate) const fn code(&self) -> ErrorCode {
        match self {
            Self::Invalid(_) => ErrorCode::PluginInvalid,
            Self::Conflict(_) => ErrorCode::PluginConflict,
            Self::NotFound(_) => ErrorCode::PluginNotFound,
            Self::Io(_) => ErrorCode::InternalError,
        }
    }

    /// 面向用户的一句话。装错包时他知道下一步该做什么。
    pub(crate) const fn hint(&self) -> &'static str {
        match self {
            Self::Invalid(_) => {
                "这个包不是可识别的技能包：确认 zip 里含 SKILL.md 或 skills/*/SKILL.md"
            }
            Self::Conflict(_) => "同名技能已存在，先卸载旧版本或改名后重装",
            Self::NotFound(_) => "插件不存在或已卸载",
            Self::Io(_) => "安装失败，请查看服务端日志",
        }
    }
}

/// 时间戳（Unix 毫秒），与项目其它地方统一。
pub(crate) fn now_ms() -> i64 {
    crate::clock::now_ms()
}

/// 生成一个临时目录名。用随机数而不是 uuid crate：只想避免并发冲突，
/// 没必要为此多一个依赖。
pub(crate) fn random_token() -> String {
    format!("{:016x}", rand::random::<u64>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes_map_to_stable_strings() {
        assert_eq!(
            PluginError::Invalid("x".into()).code().as_str(),
            "plugin_invalid"
        );
        assert_eq!(
            PluginError::Conflict("x".into()).code().as_str(),
            "plugin_conflict"
        );
        assert_eq!(
            PluginError::NotFound("x".into()).code().as_str(),
            "plugin_not_found"
        );
        assert_eq!(
            PluginError::Io("x".into()).code().as_str(),
            "internal_error"
        );
    }
}
