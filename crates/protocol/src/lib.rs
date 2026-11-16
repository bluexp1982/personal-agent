//! 共享契约类型。
//!
//! 本 crate 是 `api-spec/openapi.yaml` 在 Rust 侧的落地：只放数据结构与错误定义，
//! 不含业务逻辑、不含 IO。`jarvis-service`、`jarvis-worker`、`jarvis-gui`、
//! `jarvis-tui` 共用它，避免各自手写一份 DTO。

pub mod approval;
pub mod auth;
pub mod browser;
pub mod code_event;
pub mod conversation;
pub mod cursor;
pub mod error;
pub mod event;
pub mod git;
pub mod health;
pub mod ipc;
pub mod memory;
pub mod pairing;
pub mod plugin;
pub mod recording;
pub mod skill;
pub mod ssh;
pub mod task;
pub mod theme;
pub mod version;
pub mod project;

pub use approval::{
    asking_rule_names, rememberable_for, rule_is_rememberable, Approval, ApprovalDecision,
    ApprovalScope, ApprovalTool, ApproveAction, ApproveRequest, NON_REMEMBERABLE_RULES,
    SAFE_RULE_NAMES,
};
pub use auth::{ChallengeRequest, ChallengeResponse, DeviceInfo, SessionResponse, VerifyRequest};
pub use browser::BrowserTunnelInfo;
pub use code_event::{
    provider_capabilities, ApprovalSupport, Capabilities, CodeEvent, CodeEventKind, RiskLevel,
    RiskRule, SUPPORTED_CODE_PROVIDERS,
};
pub use conversation::{
    Attachment, Compaction, CompactionFailure, CompactionTokens, Conversation, ConversationCreate,
    ConversationDetail, ConversationMode, ConversationPage, ConversationUpdate, FileWrite,
    FileWriteDecision, MediaAsset, MediaSaveResult, Message, MessagePage, MessageRole,
    MessageSource, MessageStep, SendMessageRequest, SourceKind, TaskSuggestion, TokenUsage,
    FINISH_ERROR, FINISH_STOP, FINISH_STOPPED,
};
pub use cursor::Cursor;
pub use error::{ApiError, ErrorCode};
pub use event::StreamEvent;
pub use git::{
    GitCommitRequest, GitCommitResult, GitCommitSummary, GitCommitsPage, GitDiffReport,
    GitFileChange, GitFileState, GitOperation, GitPathsRequest, GitStatusReport,
    DEFAULT_LOG_LIMIT, MAX_COMMIT_MESSAGE_CHARS, MAX_DIFF_BYTES, MAX_GIT_PATHS, MAX_LOG_LIMIT,
};
pub use health::HealthResponse;
pub use ipc::{
    clip_artifact_content, Envelope, IpcError, IpcMessage, SkillManifest, StepSpec,
    ToolDecisionKind, IPC_VERSION, LOCAL_TOOL_WHITELIST, MAX_ARTIFACT_BYTES, MAX_LINE_BYTES,
};
pub use memory::{
    BatchRevokeRequest, BatchRevokeResult, CandidateDecision, CandidateDecisionRequest,
    CandidateDecisionResult, DigestListItem, DigestSummary, DigestView, Entity, EntityBrief,
    EntityDetail, EntityMergeRequest, EntityPage, EntitySnapshot, EntitySplitRequest, EntityStatus,
    EntityType, EntityUpdateRequest, Evidence, EvidenceSource, ExportApplyRequest,
    ExportApplyResult, ExportPreview, ExtractQuota, ForgetFilter, ForgetRequest, ForgetResult,
    Grant, GrantPage, GrantScope, HeartbeatView, MaintenanceReportView, MaintenanceView, Memory,
    MemoryCounts, MemoryCreateRequest, MemoryDetail, MemoryFeedbackRequest, MemoryKind, MemoryPage,
    MemoryPipeline, MemoryScope, MemorySensitivity, MemorySettings, MemorySource, MemoryStateView,
    MemoryStatus, MemoryUpdateRequest, NotificationCategory, OrganizeAck, PurgeArchivedRequest,
    PurgeArchivedResult, TimeScope,
};
pub use pairing::{PairConfirmRequest, PairPending, PairRequest, PairResult, PairStatus};
pub use plugin::{Plugin, PluginPage, PluginStateUpdate};
pub use recording::{
    Recording, RecordingComplete, RecordingCreate, RecordingDetail, RecordingInfo, RecordingMode,
    RecordingPage, RecordingSegment, RecordingStatus, RecordingSummary, RecordingSummaryGenerate,
    RecordingSummaryStyleUpdate, RecordingUpdate, SegmentState, SummaryAudioPeaks,
    SummaryAudioStatus, SummaryStatus, SummaryStyle,
};
pub use skill::{
    parse_builtin, FetchSource, FetchTool, Frontmatter, SkillError, SkillFetch, BUILTIN_SOURCE,
};
pub use ssh::SshTunnelInfo;
pub use task::{
    Artifact, PlanStep, PlanStepState, PrepareSource, PrepareTaskRequest, PreparedTaskInput, Skill,
    SkillStatus, Task, TaskCreateRequest, TaskPage, TaskState, WorktreeInfo,
};
pub use theme::{
    ThemeAccentColors, ThemeBrightness, ThemeColor, ThemeColors, ThemeMessageColors, ThemePage,
    ThemeSchemeColors, ThemeSpec, ThemeStatusColors, ThemeSurfaceColors, ThemeSyntaxColors,
    ThemeTerminalColors, ThemeTextColors,
};
pub use version::{API_VERSION, IPC_CONTRACT_VERSION, VERSION};
pub use project::{
    DirEntry, DirKind, DirListing, GitState, PreviewTarget, Project, ProjectCreate, ProjectEntry,
    ProjectEntryKind, ProjectFileContent, ProjectListing, ProjectMode, ProjectPreflight,
    ProjectUpdate,
};
