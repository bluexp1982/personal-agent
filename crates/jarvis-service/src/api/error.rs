//! 把领域错误映射成统一错误体与状态码。
//!
//! 所有 `/api/*` 的非 2xx 响应都必须走这里，保证客户端只需处理一种错误形状：
//! `{ code, message, retryable, hint }`。

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use protocol::{ApiError, ErrorCode};

use crate::auth::AuthError;
use crate::pairing::PairingError;

/// 包装 `ApiError`，让 handler 可以直接 `?` 或 `return Err(...)`。
#[derive(Debug)]
pub struct ApiRejection(pub ApiError);

impl ApiRejection {
    pub fn new(code: ErrorCode, message: impl Into<String>, hint: impl Into<String>) -> Self {
        Self(ApiError::new(code, message, hint))
    }
}

impl IntoResponse for ApiRejection {
    fn into_response(self) -> Response {
        let status = status_for(self.0.code);
        (status, Json(self.0)).into_response()
    }
}

/// 错误码到 HTTP 状态码的唯一映射表。
pub fn status_for(code: ErrorCode) -> StatusCode {
    match code {
        ErrorCode::InvalidRequest => StatusCode::BAD_REQUEST,
        ErrorCode::Unauthenticated => StatusCode::UNAUTHORIZED,
        ErrorCode::Forbidden => StatusCode::FORBIDDEN,
        ErrorCode::NotFound => StatusCode::NOT_FOUND,
        ErrorCode::Conflict | ErrorCode::ApprovalExpired | ErrorCode::IdempotencyConflict => {
            StatusCode::CONFLICT
        }
        ErrorCode::RateLimited => StatusCode::TOO_MANY_REQUESTS,
        // `ssh_unavailable` 与它们同类：不是请求写错了，是服务端缺了 sshd 这个依赖，
        // 打开之后重试就能连上（所以 `retryable=true`）。
        ErrorCode::DependencyUnavailable
        | ErrorCode::WorkerUnavailable
        | ErrorCode::SshUnavailable
        | ErrorCode::BrowserUnavailable
        // 记忆没启用属于"配置没打开"而不是"请求写错了"，503 + retryable=false
        // 让客户端据 hint 引导用户去配置，而不是把提示写成"参数错误"。
        | ErrorCode::MemoryUnavailable => StatusCode::SERVICE_UNAVAILABLE,
        // 目标不在白名单 / 不是回环：重试不会改变结果，属于"配置问题"。
        ErrorCode::BrowserTargetDenied => StatusCode::FORBIDDEN,
        // 与 errors.md 的码表逐项对齐：这些码以前落进下面的兜底分支变成 500，
        // 客户端于是把一个"目录选错了"当成服务内部错误。
        ErrorCode::SkillUnknown | ErrorCode::OutputMissing | ErrorCode::BudgetExceeded => {
            StatusCode::CONFLICT
        }
        ErrorCode::CodeProjectDenied => StatusCode::BAD_REQUEST,
        ErrorCode::CodeFailed => StatusCode::BAD_GATEWAY,
        ErrorCode::CodeMergeConflict => StatusCode::CONFLICT,
        ErrorCode::RecordingNotFound => StatusCode::NOT_FOUND,
        // 技能包：包不对是 400（用户换一个包即可），重名是 409（要先卸旧的），
        // 找不到是 404。三者处置完全不同，不能都落进 500。
        ErrorCode::PluginInvalid => StatusCode::BAD_REQUEST,
        ErrorCode::PluginConflict => StatusCode::CONFLICT,
        ErrorCode::PluginNotFound => StatusCode::NOT_FOUND,
        // 主题包同理：包不对 400、找不到 404。没有"冲突"——同 id 重装是覆盖。
        ErrorCode::ThemeInvalid => StatusCode::BAD_REQUEST,
        ErrorCode::ThemeNotFound => StatusCode::NOT_FOUND,
        ErrorCode::SummaryUnavailable | ErrorCode::TtsUnavailable => {
            StatusCode::SERVICE_UNAVAILABLE
        }
        ErrorCode::SummaryNotReady | ErrorCode::SummaryAudioNotReady => StatusCode::CONFLICT,
        ErrorCode::InvalidAudio => StatusCode::BAD_REQUEST,
        ErrorCode::AsrUnavailable => StatusCode::SERVICE_UNAVAILABLE,
        ErrorCode::AsrFailed => StatusCode::BAD_GATEWAY,
        ErrorCode::PayloadTooLarge => StatusCode::PAYLOAD_TOO_LARGE,
        ErrorCode::RecordingQuotaExceeded => StatusCode::CONFLICT,
        ErrorCode::InternalError => StatusCode::INTERNAL_SERVER_ERROR,
        // `ErrorCode` 是 non_exhaustive：新增错误码忘记映射时保守返回 500，
        // 而不是让请求线程 panic。
        _ => {
            tracing::warn!(?code, "错误码缺少状态码映射，回退为 500");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

impl From<AuthError> for ApiRejection {
    fn from(err: AuthError) -> Self {
        match err {
            AuthError::Db(source) => {
                tracing::error!(%source, "鉴权查询失败");
                Self::new(
                    ErrorCode::InternalError,
                    "auth query failed",
                    "服务内部错误，请查看日志",
                )
            }
            AuthError::NotAuthorized => Self::new(
                ErrorCode::Unauthenticated,
                "device not paired or revoked",
                "设备未授权，请重新配对",
            ),
            AuthError::ChallengeInvalid => Self::new(
                ErrorCode::Unauthenticated,
                "challenge invalid or already used",
                "登录挑战已失效，请重新获取",
            ),
            AuthError::BadSignature => Self::new(
                ErrorCode::Unauthenticated,
                "signature verification failed",
                "签名校验失败，请重新登录",
            ),
            AuthError::RateLimited => Self::new(
                ErrorCode::RateLimited,
                "too many requests",
                "操作过于频繁，请稍后再试",
            ),
        }
    }
}

impl From<PairingError> for ApiRejection {
    fn from(err: PairingError) -> Self {
        match err {
            PairingError::Db(source) => {
                tracing::error!(%source, "配对流程数据库失败");
                Self::new(
                    ErrorCode::InternalError,
                    "pairing storage failed",
                    "服务内部错误，请查看日志",
                )
            }
            PairingError::NoActiveRequest => Self::new(
                ErrorCode::Unauthenticated,
                "no active pairing request",
                "本机没有待配对请求，请在服务终端运行 pair",
            ),
            PairingError::InvalidCode => Self::new(
                ErrorCode::Unauthenticated,
                "pairing code mismatch",
                "配对码不正确或已过期",
            ),
            PairingError::Locked => Self::new(
                ErrorCode::Unauthenticated,
                "pairing request locked",
                "尝试次数过多，请在本机重新生成配对码",
            ),
            PairingError::NotFound => Self::new(
                ErrorCode::NotFound,
                "pairing request not found",
                "配对请求不存在",
            ),
            PairingError::Conflict(reason) => Self::new(
                ErrorCode::Conflict,
                format!("pairing conflict: {reason}"),
                "该配对请求当前状态不允许此操作",
            ),
            PairingError::DuplicateDevice => Self::new(
                ErrorCode::Conflict,
                "public key already paired",
                "这台设备已经配对过了",
            ),
        }
    }
}

impl From<crate::conversation::ConversationError> for ApiRejection {
    fn from(err: crate::conversation::ConversationError) -> Self {
        use crate::conversation::ConversationError;
        match err {
            ConversationError::Db(source) => {
                tracing::error!(%source, "会话数据库操作失败");
                Self::new(
                    ErrorCode::InternalError,
                    "conversation storage failed",
                    "服务内部错误，请查看日志",
                )
            }
            ConversationError::NotFound => Self::new(
                ErrorCode::NotFound,
                "conversation not found",
                "会话不存在或已被删除",
            ),
            ConversationError::ProjectNotFound => Self::new(
                ErrorCode::NotFound,
                "project not found",
                "项目不存在或已被删除：请先选一个项目再建会话",
            ),
            ConversationError::Conflict(reason) => Self::new(
                ErrorCode::Conflict,
                format!("conversation conflict: {reason}"),
                reason,
            ),
            ConversationError::Invalid(reason) => Self::new(
                ErrorCode::InvalidRequest,
                format!("invalid conversation request: {reason}"),
                "请求参数不正确",
            ),
        }
    }
}

impl From<crate::task::TaskError> for ApiRejection {
    fn from(err: crate::task::TaskError) -> Self {
        use crate::task::TaskError;
        match err {
            TaskError::Db(source) => {
                tracing::error!(%source, "任务数据库操作失败");
                Self::new(
                    ErrorCode::InternalError,
                    "task storage failed",
                    "服务内部错误，请查看日志",
                )
            }
            TaskError::NotFound => Self::new(
                ErrorCode::NotFound,
                "task not found",
                "任务不存在或已被删除",
            ),
            TaskError::ConversationNotFound => Self::new(
                ErrorCode::NotFound,
                "conversation not found",
                "会话不存在，无法创建任务",
            ),
            TaskError::InvalidTransition { from, to } => Self::new(
                ErrorCode::Conflict,
                format!("invalid task transition: {from} -> {to}"),
                "当前任务状态不允许该操作",
            ),
            TaskError::Conflict(reason) => Self::new(
                ErrorCode::Conflict,
                format!("task conflict: {reason}"),
                "任务状态已变化，请刷新后重试",
            ),
            TaskError::Invalid(reason) => Self::new(
                ErrorCode::InvalidRequest,
                format!("invalid task request: {reason}"),
                "请求参数不正确",
            ),
            TaskError::Artifact(source) => {
                tracing::error!(%source, "产物落盘失败");
                Self::new(
                    ErrorCode::InternalError,
                    "artifact storage failed",
                    "产物保存失败，请重试任务",
                )
            }
        }
    }
}

impl From<crate::approval::ApprovalError> for ApiRejection {
    fn from(err: crate::approval::ApprovalError) -> Self {
        use crate::approval::ApprovalError;
        match err {
            ApprovalError::Db(source) => {
                tracing::error!(%source, "审批数据库操作失败");
                Self::new(
                    ErrorCode::InternalError,
                    "approval storage failed",
                    "服务内部错误，请查看日志",
                )
            }
            ApprovalError::NotFound => Self::new(
                ErrorCode::NotFound,
                "approval not found",
                "该审批不存在或已被清理",
            ),
            ApprovalError::AlreadyDecided => Self::new(
                ErrorCode::Conflict,
                "approval already decided",
                "该操作已处理过，请刷新任务状态",
            ),
            ApprovalError::Expired => Self::new(
                ErrorCode::ApprovalExpired,
                "approval expired",
                "确认已超时，任务已停止；可重试任务重新发起",
            ),
        }
    }
}

impl From<crate::project::ProjectError> for ApiRejection {
    fn from(err: crate::project::ProjectError) -> Self {
        use crate::project::ProjectError;
        match err {
            ProjectError::Db(source) => {
                tracing::error!(%source, "项目数据库操作失败");
                Self::new(
                    ErrorCode::InternalError,
                    "project storage failed",
                    "服务内部错误，请查看日志",
                )
            }
            ProjectError::NotFound => Self::new(
                ErrorCode::NotFound,
                "project not found",
                "项目不存在或已被删除",
            ),
            ProjectError::Conflict(hint) => {
                Self::new(ErrorCode::Conflict, "project conflict", hint)
            }
            ProjectError::Invalid(hint) => {
                Self::new(ErrorCode::InvalidRequest, "invalid project request", hint)
            }
            // 目录越界、不可访问、不是 git 仓库：与编码任务的仓库拒绝共用同一个码，
            // 客户端只需要认"目录不能用"这一类，不必区分是建项目还是派任务时撞上的。
            ProjectError::Denied(hint) => Self::new(
                ErrorCode::CodeProjectDenied,
                "project directory is not allowed",
                hint,
            ),
        }
    }
}

impl From<crate::git::GitError> for ApiRejection {
    fn from(err: crate::git::GitError) -> Self {
        use crate::git::GitError;
        match &err {
            // 不是仓库、路径越界、参数非法：与"目录不能用"共用一个码，
            // 客户端只需要认"这次请求改输入才能继续"。
            GitError::Denied(_) => Self::new(
                ErrorCode::CodeProjectDenied,
                "git request denied",
                err.hint(),
            ),
            // 中间态、索引锁、没有可暂存/可提交的内容：都是"现在不行，等会儿或换个做法"。
            GitError::Blocked(_) => Self::new(ErrorCode::Conflict, "git operation blocked", err.hint()),
            // git 本身失败或超时：这是服务端环境问题，不是用户的错。
            GitError::Failed(_) => {
                tracing::warn!(%err, "git 命令失败");
                Self::new(ErrorCode::CodeFailed, "git command failed", err.hint())
            }
        }
    }
}

impl From<crate::worktree::WorktreeError> for ApiRejection {
    fn from(err: crate::worktree::WorktreeError) -> Self {
        use crate::worktree::WorktreeError;
        match err {
            WorktreeError::InvalidId => Self::new(
                ErrorCode::InvalidRequest,
                "invalid task id",
                "任务标识非法，无法定位现场",
            ),
            // 与项目越界共用一个码：客户端只需要认"这个路径不能用"。
            WorktreeError::Escape(path) => Self::new(
                ErrorCode::CodeProjectDenied,
                "worktree path is outside the expected root",
                format!("{path} 不在工作树根目录下，拒绝删除"),
            ),
            WorktreeError::Io(reason) => {
                tracing::error!(%reason, "清理编码任务现场失败");
                Self::new(ErrorCode::InternalError, "worktree cleanup failed", reason)
            }
        }
    }
}

impl From<crate::recording::RecordingError> for ApiRejection {
    fn from(err: crate::recording::RecordingError) -> Self {
        use crate::recording::RecordingError;
        match err {
            RecordingError::Db(source) => {
                tracing::error!(%source, "录音数据库操作失败");
                Self::new(
                    ErrorCode::InternalError,
                    "recording storage failed",
                    "服务内部错误，请查看日志",
                )
            }
            RecordingError::NotFound => Self::new(
                ErrorCode::RecordingNotFound,
                "recording not found",
                "录音不存在或已被删除",
            ),
            RecordingError::Invalid(reason) => Self::new(
                ErrorCode::InvalidRequest,
                format!("invalid recording request: {reason}"),
                "请求参数不正确",
            ),
            // 直接展示"采样率/声道/时长对不上"这类具体原因：用户手里是录音，
            // 一句笼统的"格式错误"没法让人判断是客户端 bug 还是导入的文件不对。
            RecordingError::InvalidAudio(reason) => Self::new(
                ErrorCode::InvalidAudio,
                format!("invalid audio: {reason}"),
                format!("音频格式不支持：{reason}"),
            ),
            RecordingError::TooLarge(reason) => Self::new(
                ErrorCode::PayloadTooLarge,
                format!("recording payload too large: {reason}"),
                "文件超过服务端上限，请缩短单段录音",
            ),
            RecordingError::Quota(reason) => Self::new(
                ErrorCode::RecordingQuotaExceeded,
                format!("recording quota exceeded: {reason}"),
                format!("{reason}；请拆分录音或调高服务端配额"),
            ),
            RecordingError::AsrUnavailable => Self::new(
                ErrorCode::AsrUnavailable,
                "asr not available",
                "服务端未开启转写；音频已保存，开启后可重试",
            ),
            RecordingError::SummaryUnavailable => Self::new(
                ErrorCode::SummaryUnavailable,
                "summary not available",
                "服务端未开启总结或模型未配置",
            ),
            RecordingError::SummaryNotReady(reason) => Self::new(
                ErrorCode::SummaryNotReady,
                format!("summary not ready: {reason}"),
                format!("还不能生成总结：{reason}"),
            ),
            RecordingError::TtsUnavailable => Self::new(
                ErrorCode::TtsUnavailable,
                "tts not available",
                "服务端未开启语音合成",
            ),
            RecordingError::SummaryAudioNotReady(reason) => Self::new(
                ErrorCode::SummaryAudioNotReady,
                format!("summary audio not ready: {reason}"),
                format!("语音还没准备好：{reason}"),
            ),
            RecordingError::Store(reason) => {
                tracing::error!(%reason, "录音音频存储失败");
                Self::new(
                    ErrorCode::InternalError,
                    format!("recording storage failed: {reason}"),
                    "音频保存失败，请重试",
                )
            }
        }
    }
}

impl From<crate::grants::GrantError> for ApiRejection {
    fn from(err: crate::grants::GrantError) -> Self {
        let (code, hint) = match &err {
            crate::grants::GrantError::NotFound => {
                (protocol::ErrorCode::NotFound, "这条授权不存在")
            }
            crate::grants::GrantError::Conflict(reason) => {
                tracing::warn!(%err, "授权状态冲突");
                let hint = if reason.is_empty() {
                    "授权状态已变化，请刷新"
                } else {
                    // 冲突原因本身就是给用户看的（例如"不可逆动作不提供记住"）。
                    reason.as_str()
                };
                (protocol::ErrorCode::Conflict, hint)
            }
            crate::grants::GrantError::Invalid(reason) => {
                tracing::warn!(%err, "授权参数不合法");
                let _ = reason;
                (protocol::ErrorCode::InvalidRequest, "授权参数不合法")
            }
            crate::grants::GrantError::Db(_) => {
                tracing::error!(%err, "授权数据库错误");
                (protocol::ErrorCode::InternalError, "服务内部错误")
            }
        };

        ApiRejection::new(code, err.to_string(), hint)
    }
}

impl From<crate::memory::MemoryError> for ApiRejection {
    fn from(err: crate::memory::MemoryError) -> Self {
        use crate::memory::MemoryError;
        match err {
            // "没开"和"缺模型"对调用方是同一件事：功能不可用，去配置里打开。
            MemoryError::Disabled | MemoryError::ModelUnavailable => Self::new(
                ErrorCode::MemoryUnavailable,
                "memory is not available",
                "记忆功能未启用：在配置里打开 memory.enabled 后重启服务",
            ),
            MemoryError::NotFound => Self::new(
                ErrorCode::NotFound,
                "memory not found",
                "这条记忆不存在或已被删除",
            ),
            MemoryError::Invalid(reason) => Self::new(
                ErrorCode::InvalidRequest,
                format!("invalid memory request: {reason}"),
                reason,
            ),
            MemoryError::Conflict(reason) => {
                Self::new(ErrorCode::Conflict, "memory conflict", reason)
            }
            MemoryError::Corrupt(reason) => {
                tracing::error!(%reason, "记忆数据无法解析");
                Self::new(
                    ErrorCode::InternalError,
                    "memory data is corrupt",
                    "服务内部错误，请查看日志",
                )
            }
            MemoryError::Db(source) => {
                tracing::error!(%source, "记忆数据库操作失败");
                Self::new(
                    ErrorCode::InternalError,
                    "memory storage failed",
                    "服务内部错误，请查看日志",
                )
            }
        }
    }
}

impl From<sqlx::Error> for ApiRejection {
    fn from(err: sqlx::Error) -> Self {
        tracing::error!(%err, "数据库访问失败");
        Self::new(
            ErrorCode::InternalError,
            "database error",
            "服务内部错误，请查看日志",
        )
    }
}
