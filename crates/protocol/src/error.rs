//! 统一错误体：`{ code, message, retryable, hint }`。
//!
//! 约束（来自「业务范围 › 资源与端点轮廓」）：
//! - `code` 是稳定枚举，发布后只允许新增，不允许改变既有语义；
//! - `message` 面向开发者，不包含用户数据；
//! - `retryable` 决定客户端是否呈现"重试"；
//! - `hint` 是可直接展示给用户的一句话。

use serde::{Deserialize, Serialize};

/// 稳定错误码。序列化为 `snake_case` 字符串。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ErrorCode {
    /// 参数缺失、类型错误或校验失败。
    InvalidRequest,
    /// 未配对，或签名/challenge 校验失败。
    Unauthenticated,
    /// 已认证但该设备无权执行此动作（如未获 L2 审批）。
    Forbidden,
    /// 资源不存在。
    NotFound,
    /// 状态冲突（如任务已在运行中被取消）。
    Conflict,
    /// 触发限流。
    RateLimited,
    /// 审批已过期，需重新发起。
    ApprovalExpired,
    /// 幂等键冲突：同一次写操作被重复提交。
    IdempotencyConflict,
    /// 依赖不可用（模型服务商、目标站点等）。
    DependencyUnavailable,
    /// 执行进程不可用或已退出。
    WorkerUnavailable,
    /// 技能未知或已被禁用。
    SkillUnknown,
    /// 产物未覆盖技能声明的 outputs。
    OutputMissing,
    /// 单任务的模型调用次数或 token 用量超过配置上限。
    BudgetExceeded,
    /// 编码能力不可用：未启用、CLI 二进制缺失、代理未就绪或上游密钥缺失。
    CodeUnavailable,
    /// 目标仓库不可用：不在白名单、不是 git 仓库或 HEAD 处于游离状态。
    CodeProjectDenied,
    /// 编码 CLI 执行失败：非零退出、超时或内部错误。
    CodeFailed,
    /// 合并回目标分支时冲突；worktree 与分支会保留。
    CodeMergeConflict,
    /// SSH 隧道不可用：服务端未开启，或本机 sshd 连不上。
    SshUnavailable,
    /// 浏览器隧道不可用：服务端未开启，或目标端口连不上。
    BrowserUnavailable,
    /// 浏览器隧道目标被拒绝：不是回环地址，或端口不在白名单内。
    BrowserTargetDenied,
    /// 录音不存在或已被删除。
    RecordingNotFound,
    /// 音频格式不合法：不是 WAV、不是 16kHz 单声道 PCM16，或分段时长与声明不符。
    InvalidAudio,
    /// 转写能力不可用：服务端未开启、缺少密钥或 provider 未就绪。
    AsrUnavailable,
    /// 转写调用失败：上游错误、超时或返回无法解析。
    AsrFailed,
    /// 请求体超过该端点允许的大小。
    PayloadTooLarge,
    /// 录音时长或总字节数超过 `recording` 配置上限。
    RecordingQuotaExceeded,
    /// 总结能力不可用：未启用总结或模型未配置。
    SummaryUnavailable,
    /// 当前录音还不能生成总结（未结束或还有分段未转写完成）。
    SummaryNotReady,
    /// TTS 能力不可用：未启用、缺少密钥或 provider 未就绪。
    TtsUnavailable,
    /// 总结语音还在合成或合成失败，暂时不能下载。
    SummaryAudioNotReady,
    /// 记忆功能未启用，或启用但缺少可用的模型配置。
    MemoryUnavailable,
    /// 技能包不合法：结构不可识别、清单校验失败、压缩包损坏或超出限额。
    PluginInvalid,
    /// 技能包冲突：插件 id 或技能名与已存在的重复。
    PluginConflict,
    /// 技能包不存在或已被卸载。
    PluginNotFound,
    /// 主题包不合法：缺 `theme.json`、字段校验失败、压缩包损坏或超出限额。
    ThemeInvalid,
    /// 主题包不存在或已被删除。
    ThemeNotFound,
    /// 服务内部错误，需看日志。
    InternalError,
}

impl ErrorCode {
    /// 线缆上的字符串形式，与 `api-spec/errors.md` 一一对应。
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::Unauthenticated => "unauthenticated",
            Self::Forbidden => "forbidden",
            Self::NotFound => "not_found",
            Self::Conflict => "conflict",
            Self::RateLimited => "rate_limited",
            Self::ApprovalExpired => "approval_expired",
            Self::IdempotencyConflict => "idempotency_conflict",
            Self::DependencyUnavailable => "dependency_unavailable",
            Self::WorkerUnavailable => "worker_unavailable",
            Self::SkillUnknown => "skill_unknown",
            Self::OutputMissing => "output_missing",
            Self::BudgetExceeded => "budget_exceeded",
            Self::CodeUnavailable => "code_unavailable",
            Self::CodeProjectDenied => "code_project_denied",
            Self::CodeFailed => "code_failed",
            Self::CodeMergeConflict => "code_merge_conflict",
            Self::SshUnavailable => "ssh_unavailable",
            Self::BrowserUnavailable => "browser_unavailable",
            Self::BrowserTargetDenied => "browser_target_denied",
            Self::RecordingNotFound => "recording_not_found",
            Self::InvalidAudio => "invalid_audio",
            Self::AsrUnavailable => "asr_unavailable",
            Self::AsrFailed => "asr_failed",
            Self::PayloadTooLarge => "payload_too_large",
            Self::RecordingQuotaExceeded => "recording_quota_exceeded",
            Self::SummaryUnavailable => "summary_unavailable",
            Self::SummaryNotReady => "summary_not_ready",
            Self::TtsUnavailable => "tts_unavailable",
            Self::SummaryAudioNotReady => "summary_audio_not_ready",
            Self::MemoryUnavailable => "memory_unavailable",
            Self::PluginInvalid => "plugin_invalid",
            Self::PluginConflict => "plugin_conflict",
            Self::PluginNotFound => "plugin_not_found",
            Self::ThemeInvalid => "theme_invalid",
            Self::ThemeNotFound => "theme_not_found",
            Self::InternalError => "internal_error",
        }
    }

    /// 从线缆字符串解析。未知值返回 `None`，调用方应保守按 `internal_error` 处理。
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "invalid_request" => Some(Self::InvalidRequest),
            "unauthenticated" => Some(Self::Unauthenticated),
            "forbidden" => Some(Self::Forbidden),
            "not_found" => Some(Self::NotFound),
            "conflict" => Some(Self::Conflict),
            "rate_limited" => Some(Self::RateLimited),
            "approval_expired" => Some(Self::ApprovalExpired),
            "idempotency_conflict" => Some(Self::IdempotencyConflict),
            "dependency_unavailable" => Some(Self::DependencyUnavailable),
            "worker_unavailable" => Some(Self::WorkerUnavailable),
            "skill_unknown" => Some(Self::SkillUnknown),
            "output_missing" => Some(Self::OutputMissing),
            "budget_exceeded" => Some(Self::BudgetExceeded),
            "code_unavailable" => Some(Self::CodeUnavailable),
            "code_project_denied" => Some(Self::CodeProjectDenied),
            "code_failed" => Some(Self::CodeFailed),
            "code_merge_conflict" => Some(Self::CodeMergeConflict),
            "ssh_unavailable" => Some(Self::SshUnavailable),
            "browser_unavailable" => Some(Self::BrowserUnavailable),
            "browser_target_denied" => Some(Self::BrowserTargetDenied),
            "recording_not_found" => Some(Self::RecordingNotFound),
            "invalid_audio" => Some(Self::InvalidAudio),
            "asr_unavailable" => Some(Self::AsrUnavailable),
            "asr_failed" => Some(Self::AsrFailed),
            "payload_too_large" => Some(Self::PayloadTooLarge),
            "recording_quota_exceeded" => Some(Self::RecordingQuotaExceeded),
            "summary_unavailable" => Some(Self::SummaryUnavailable),
            "summary_not_ready" => Some(Self::SummaryNotReady),
            "tts_unavailable" => Some(Self::TtsUnavailable),
            "summary_audio_not_ready" => Some(Self::SummaryAudioNotReady),
            "memory_unavailable" => Some(Self::MemoryUnavailable),
            "plugin_invalid" => Some(Self::PluginInvalid),
            "plugin_conflict" => Some(Self::PluginConflict),
            "plugin_not_found" => Some(Self::PluginNotFound),
            "theme_invalid" => Some(Self::ThemeInvalid),
            "theme_not_found" => Some(Self::ThemeNotFound),
            "internal_error" => Some(Self::InternalError),
            _ => None,
        }
    }

    /// 客户端能否通过重试获益。`false` 时客户端不应呈现重试按钮。
    pub const fn retryable(self) -> bool {
        matches!(
            self,
            Self::RateLimited
                | Self::DependencyUnavailable
                | Self::WorkerUnavailable
                | Self::CodeFailed
                | Self::SshUnavailable
                | Self::BrowserUnavailable
                | Self::AsrFailed
                | Self::SummaryUnavailable
                | Self::SummaryNotReady
                | Self::TtsUnavailable
                | Self::SummaryAudioNotReady
                | Self::InternalError
        )
    }
}

impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// 统一错误响应体。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
    pub retryable: bool,
    pub hint: String,
}

impl ApiError {
    /// 构造错误体，`retryable` 由错误码推导，避免调用方各自判断。
    pub fn new(code: ErrorCode, message: impl Into<String>, hint: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: code.retryable(),
            hint: hint.into(),
        }
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {} ({})", self.code, self.message, self.hint)
    }
}

impl std::error::Error for ApiError {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    #[test]
    fn error_body_has_exactly_four_fields() {
        let err = ApiError::new(
            ErrorCode::NotFound,
            "task not found",
            "任务不存在或已被删除",
        );
        let value: Value = serde_json::to_value(&err).expect("序列化失败");
        let obj = value.as_object().expect("应为对象");

        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["code", "hint", "message", "retryable"]);
        assert_eq!(obj["code"], json!("not_found"));
        assert_eq!(obj["retryable"], json!(false));
    }

    #[test]
    fn retryable_is_derived_from_code() {
        let retryable = ApiError::new(ErrorCode::RateLimited, "slow down", "稍后再试");
        let fatal = ApiError::new(ErrorCode::Forbidden, "no approval", "请先批准该操作");

        assert!(retryable.retryable);
        assert!(!fatal.retryable);
    }

    #[test]
    fn code_strings_match_error_dictionary() {
        // 与 api-spec/errors.md 的 code 列保持一致，改了这里就要同步改文档。
        assert_eq!(ErrorCode::InvalidRequest.as_str(), "invalid_request");
        assert_eq!(ErrorCode::Unauthenticated.as_str(), "unauthenticated");
        assert_eq!(ErrorCode::Forbidden.as_str(), "forbidden");
        assert_eq!(ErrorCode::NotFound.as_str(), "not_found");
        assert_eq!(ErrorCode::Conflict.as_str(), "conflict");
        assert_eq!(ErrorCode::RateLimited.as_str(), "rate_limited");
        assert_eq!(ErrorCode::ApprovalExpired.as_str(), "approval_expired");
        assert_eq!(
            ErrorCode::IdempotencyConflict.as_str(),
            "idempotency_conflict"
        );
        assert_eq!(
            ErrorCode::DependencyUnavailable.as_str(),
            "dependency_unavailable"
        );
        assert_eq!(ErrorCode::BudgetExceeded.as_str(), "budget_exceeded");
        assert_eq!(ErrorCode::CodeUnavailable.as_str(), "code_unavailable");
        assert_eq!(ErrorCode::CodeProjectDenied.as_str(), "code_project_denied");
        assert_eq!(ErrorCode::CodeFailed.as_str(), "code_failed");
        assert_eq!(ErrorCode::CodeMergeConflict.as_str(), "code_merge_conflict");
        assert_eq!(ErrorCode::SshUnavailable.as_str(), "ssh_unavailable");
        assert_eq!(
            ErrorCode::BrowserUnavailable.as_str(),
            "browser_unavailable"
        );
        assert_eq!(
            ErrorCode::BrowserTargetDenied.as_str(),
            "browser_target_denied"
        );
        assert_eq!(ErrorCode::RecordingNotFound.as_str(), "recording_not_found");
        assert_eq!(ErrorCode::InvalidAudio.as_str(), "invalid_audio");
        assert_eq!(ErrorCode::AsrUnavailable.as_str(), "asr_unavailable");
        assert_eq!(ErrorCode::AsrFailed.as_str(), "asr_failed");
        assert_eq!(ErrorCode::PayloadTooLarge.as_str(), "payload_too_large");
        assert_eq!(
            ErrorCode::RecordingQuotaExceeded.as_str(),
            "recording_quota_exceeded"
        );
        assert_eq!(ErrorCode::MemoryUnavailable.as_str(), "memory_unavailable");
        assert_eq!(ErrorCode::PluginInvalid.as_str(), "plugin_invalid");
        assert_eq!(ErrorCode::ThemeInvalid.as_str(), "theme_invalid");
        assert_eq!(ErrorCode::ThemeNotFound.as_str(), "theme_not_found");
        assert_eq!(ErrorCode::InternalError.as_str(), "internal_error");
    }

    #[test]
    fn code_failed_is_retryable_but_conflicts_are_not() {
        // CLI 退出码非零多半是外部原因（网络、上游抖动），值得重试一次；
        // 合并冲突是确定性的，重试同一个分支只会再冲突一次。
        assert!(ErrorCode::CodeFailed.retryable());
        assert!(!ErrorCode::CodeMergeConflict.retryable());
        assert!(!ErrorCode::CodeProjectDenied.retryable());
        assert!(!ErrorCode::CodeUnavailable.retryable());
        // sshd 是可以在服务端打开的：打开之后重试就能连上。
        assert!(ErrorCode::SshUnavailable.retryable());
        // 目标端口没起来是外部原因，等 dev server 启动后重试即可；
        // 但"目标不在白名单"是配置问题，重试不会改变结果。
        assert!(ErrorCode::BrowserUnavailable.retryable());
        assert!(!ErrorCode::BrowserTargetDenied.retryable());
    }
}
