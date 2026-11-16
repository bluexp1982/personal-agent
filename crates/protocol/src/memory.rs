//! 记忆系统的契约类型（对应 `api-spec/openapi.yaml` 的 `memories` tag）。
//!
//! 只放数据结构与枚举，不含 IO——与 `protocol` crate 的定位一致。
//!
//! 枚举一律 `serde(rename_all = "snake_case")`，并配 `as_str` / `parse`：
//! 库里存字符串，读回来要能解析；新增取值时 `parse` 返回 `None`，调用方按
//! `invalid_request` 处理，而不是 panic。
//!
//! 分期：本文件先落 P1（显式记忆 + digest 注入）需要的类型；实体页、授权页
//! 的类型在 P3 / G 落地时追加，不提前登记未实现的端点。

use serde::{Deserialize, Serialize};

/// 生成 `as_str` / `parse` 的样板：库里存字符串，两侧必须一致。
macro_rules! string_enum {
    ($name:ident { $($variant:ident => $text:literal),+ $(,)? }) => {
        impl $name {
            /// 线缆与库里的字符串形式。
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $text),+
                }
            }

            /// 未知值返回 `None`，由调用方转成 `invalid_request`。
            pub fn parse(raw: &str) -> Option<Self> {
                match raw {
                    $($text => Some(Self::$variant),)+
                    _ => None,
                }
            }
        }
    };
}

/// 记忆类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    /// 稳定身份事实：常住地、家庭成员、职业。
    Profile,
    /// 偏好与习惯：回答风格、工具选择。
    Preference,
    /// 某个时间发生的事。
    Event,
    /// 仓库约定与项目决策。
    Project,
}

string_enum!(MemoryKind {
    Profile => "profile",
    Preference => "preference",
    Event => "event",
    Project => "project",
});

impl MemoryKind {
    /// 用户可见的类型名，客户端筛选用。
    pub const fn label(self) -> &'static str {
        match self {
            Self::Profile => "画像",
            Self::Preference => "偏好",
            Self::Event => "事件",
            Self::Project => "项目",
        }
    }

    pub const ALL: [Self; 4] = [Self::Profile, Self::Preference, Self::Event, Self::Project];
}

/// 写入管道：主观（用户说的）与客观（从记录里推出来的）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryPipeline {
    Subjective,
    Objective,
}

string_enum!(MemoryPipeline {
    Subjective => "subjective",
    Objective => "objective",
});

/// 记忆状态。候选不是独立表，就是 `status='candidate'` 的记忆。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryStatus {
    Candidate,
    Active,
    Stale,
    Archived,
    Deleted,
}

string_enum!(MemoryStatus {
    Candidate => "candidate",
    Active => "active",
    Stale => "stale",
    Archived => "archived",
    Deleted => "deleted",
});

/// 作用域：全局，或绑定某个项目。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryScope {
    Global,
    Project,
}

string_enum!(MemoryScope {
    Global => "global",
    Project => "project",
});

/// 敏感度。`secret` 不出现：命中的内容在写入阶段就被拒绝，不入库。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemorySensitivity {
    #[default]
    Normal,
    /// 入库但永不进常驻摘要，只能在显式召回时按需命中。
    Private,
}

string_enum!(MemorySensitivity {
    Normal => "normal",
    Private => "private",
});

/// 记忆的来源管道。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemorySource {
    /// 用户显式写入。
    Explicit,
    Session,
    Task,
    Recording,
    CodeTask,
    Heartbeat,
    /// 用户改过正文。
    UserCorrected,
}

string_enum!(MemorySource {
    Explicit => "explicit",
    Session => "session",
    Task => "task",
    Recording => "recording",
    CodeTask => "code_task",
    Heartbeat => "heartbeat",
    UserCorrected => "user_corrected",
});

impl MemorySource {
    /// 展示用来源标签（会出现在提示词与来源卡片里）。
    pub const fn label(self) -> &'static str {
        match self {
            Self::Explicit | Self::UserCorrected => "用户设定",
            Self::Session => "来自对话",
            Self::Task => "来自任务",
            Self::Recording => "来自录音",
            Self::CodeTask => "来自编码任务",
            Self::Heartbeat => "服务端巡检",
        }
    }
}

/// 证据指向的源对象类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EvidenceSource {
    Message,
    Task,
    Step,
    Recording,
    CodeTask,
    Explicit,
}

string_enum!(EvidenceSource {
    Message => "message",
    Task => "task",
    Step => "step",
    Recording => "recording",
    CodeTask => "code_task",
    Explicit => "explicit",
});

/// 实体类型。P1 只在记忆详情里用到 `EntityBrief`，实体页在 P3 落地。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityType {
    Person,
    Org,
    Project,
    Device,
    Recurring,
}

string_enum!(EntityType {
    Person => "person",
    Org => "org",
    Project => "project",
    Device => "device",
    Recurring => "recurring",
});

/// 时间范围描述：给人看的标签 + 可选边界，与 `due_at`（给心跳扫描用）分工不同。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimeScope {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

/// 一条证据：源文本里的连续片段。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Evidence {
    pub id: String,
    pub source_kind: EvidenceSource,
    pub source_id: String,
    /// 源文本的连续子串（归一化前）。
    pub quote: String,
    /// 断言依赖 `quote` 里的哪一段；必须也是 `quote` 的子串。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub support_span: Option<String>,
    pub created_at: i64,
}

/// 一条记忆。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Memory {
    pub id: String,
    pub kind: MemoryKind,
    pub pipeline: MemoryPipeline,
    pub status: MemoryStatus,
    pub scope: MemoryScope,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    pub sensitivity: MemorySensitivity,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entity_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub predicate: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_scope: Option<TimeScope>,
    pub confidence: f32,
    pub importance: f32,
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_id: Option<String>,
    pub source: MemorySource,
    pub valid_from: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub valid_to: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub superseded_by: Option<String>,
    pub use_count: u32,
    /// 同一 subject + predicate 下存在多条 active 且内容不同。
    #[serde(default)]
    pub conflicting: bool,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 实体的一句话摘要，用于记忆详情页顶部。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntityBrief {
    pub id: String,
    pub name: String,
    pub entity_type: EntityType,
}

/// 记忆详情：正文 + 证据 + 实体摘要 + 召回次数。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemoryDetail {
    pub memory: Memory,
    pub evidence: Vec<Evidence>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entity: Option<EntityBrief>,
    pub recall_count: u32,
}

/// 一页记忆。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemoryPage {
    pub items: Vec<Memory>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

/// 显式写入请求。`evidence_quote` 是"用户当时说的原话"，没有它就只能进候选。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryCreateRequest {
    pub kind: MemoryKind,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub predicate: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_scope: Option<TimeScope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<MemoryScope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pipeline: Option<MemoryPipeline>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sensitivity: Option<MemorySensitivity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    /// 显式写入也要求一句原话，作为唯一证据。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_quote: Option<String>,
}

/// 局部更新：只传要改的字段。
///
/// `status` 只允许 `active` / `archived`；删除必须走 `DELETE`（要留软删痕迹）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryUpdateRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sensitivity: Option<MemorySensitivity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<MemoryKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<MemoryStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_scope: Option<TimeScope>,
}

/// 按状态分组的条数，客户端分段徽标用。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryCounts {
    pub candidate: u32,
    pub active: u32,
    pub stale: u32,
    pub archived: u32,
}

/// 当前 digest 的概况。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DigestSummary {
    pub chars: usize,
    pub memory_items: usize,
    pub generated_at: i64,
}

/// 今日抽取额度。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtractQuota {
    pub enabled: bool,
    pub daily_limit: u32,
    pub used_today: u32,
}

/// 心跳状态概览（P4 落地前恒为"未启用"）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeartbeatView {
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_scan_at: Option<i64>,
    pub daily_limit: u32,
    pub delivered_today: u32,
}

/// 一次整理的条数概览。只放条数，不放正文、不放录音转写。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MaintenanceReportView {
    /// 重算成功的实体快照数。
    pub recomputed: u32,
    /// 重算失败的实体数（保留旧快照，下次再试）。
    pub failed: u32,
    /// 投递出去抽取的录音 / 编码任务数。
    pub sedimented: u32,
    /// 衰减归档的记忆条数。
    pub decayed: u32,
    /// 归并掉的记忆条数。
    pub consolidated: u32,
    /// 有没有可用模型。没有时快照重算会被跳过，其余三步照常。
    #[serde(default)]
    pub model_available: bool,
}

/// 记忆整理的状态：手动「整理」按钮靠它做忙碌态与结果提示。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MaintenanceView {
    /// 是否有一轮整理正在跑。
    pub organizing: bool,
    /// 最近一次整理完成的时刻（Unix 毫秒）。手动与夜间都写。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_organized_at: Option<i64>,
    /// 最近一次整理的条数概览。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_report: Option<MaintenanceReportView>,
}

/// `POST /api/memories/organize` 的确认：整理已在后台开始。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrganizeAck {
    pub started_at: i64,
}

/// `GET /api/memories/state`：首页与设置页的一次性快照。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryStateView {
    pub enabled: bool,
    pub counts: MemoryCounts,
    pub digest: DigestSummary,
    pub extract: ExtractQuota,
    pub heartbeat: HeartbeatView,
    /// 整理状态。缺省视为"没在整理、也没有历史结果"。
    #[serde(default)]
    pub maintenance: MaintenanceView,
    /// 摘要无法生成时给用户看的一句话（目前只有"置顶超出预算"）。
    /// 快照本身不因它失败——否则用户连取消置顶的入口都看不到。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest_warning: Option<String>,
}

/// digest 快照列表项。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DigestListItem {
    pub id: String,
    pub chars: usize,
    pub created_at: i64,
}

/// 一份 digest 快照全文。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DigestView {
    pub id: String,
    pub content: String,
    pub chars: usize,
    pub created_at: i64,
    pub memory_ids: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enums_round_trip_through_strings() {
        for kind in MemoryKind::ALL {
            assert_eq!(MemoryKind::parse(kind.as_str()), Some(kind));
        }
        for status in [
            MemoryStatus::Candidate,
            MemoryStatus::Active,
            MemoryStatus::Stale,
            MemoryStatus::Archived,
            MemoryStatus::Deleted,
        ] {
            assert_eq!(MemoryStatus::parse(status.as_str()), Some(status));
        }
        assert_eq!(
            MemorySensitivity::parse("secret"),
            None,
            "secret 不落库，不应有对应取值"
        );
    }

    #[test]
    fn enums_serialize_as_snake_case() {
        assert_eq!(
            serde_json::to_string(&MemoryKind::Preference).expect("序列化失败"),
            "\"preference\""
        );
        assert_eq!(
            serde_json::to_string(&MemoryStatus::Candidate).expect("序列化失败"),
            "\"candidate\""
        );
        assert_eq!(
            serde_json::to_string(&EvidenceSource::CodeTask).expect("序列化失败"),
            "\"code_task\""
        );
    }
}

// ---------------------------------------------------------------------------
// 实体（P3）
// ---------------------------------------------------------------------------

/// 实体状态。`merged` 的实体会把 `name_norm` 置空，腾出唯一索引。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityStatus {
    /// 只被一条证据提到过：还不足以成为一个"人"。
    Pending,
    Active,
    Archived,
    Merged,
}

impl EntityStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Active => "active",
            Self::Archived => "archived",
            Self::Merged => "merged",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "pending" => Some(Self::Pending),
            "active" => Some(Self::Active),
            "archived" => Some(Self::Archived),
            "merged" => Some(Self::Merged),
            _ => None,
        }
    }
}

/// 一个主体（人 / 组织 / 项目 / 设备 / 周期事项）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entity {
    pub id: String,
    pub entity_type: EntityType,
    pub name: String,
    pub aliases: Vec<String>,
    pub project_id: Option<String>,
    /// 只有 `project` 实体绑定仓库根。
    pub project_path: Option<String>,
    pub status: EntityStatus,
    pub merged_into: Option<String>,
    /// 一句话状态快照。空串表示"还没有快照"（新建实体在夜间重算前就是这个状态）。
    pub snapshot: String,
    pub snapshot_at: Option<i64>,
    pub confidence: f32,
    pub evidence_count: u32,
    pub last_evidence_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EntitySnapshot {
    pub id: String,
    pub snapshot: String,
    pub evidence_count: u32,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EntityPage {
    pub items: Vec<Entity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EntityDetail {
    pub entity: Entity,
    /// 时间线：一期取最近 50 条，不分页。
    pub timeline: Vec<Memory>,
    pub snapshots: Vec<EntitySnapshot>,
}

/// 局部更新实体。改名字或别名后立即重算归一化名，撞唯一索引返回 `conflict`。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EntityUpdateRequest {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub aliases: Option<Vec<String>>,
    #[serde(default)]
    pub status: Option<EntityStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntityMergeRequest {
    pub source_id: String,
    pub target_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntitySplitRequest {
    pub memory_ids: Vec<String>,
    /// 新实体的名称；缺省时用"未命名实体"，用户可以随后改名。
    #[serde(default)]
    pub name: Option<String>,
}

// ---------------------------------------------------------------------------
// 候选、反馈、遗忘、导出、设置（P2/P4）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CandidateDecision {
    Accept,
    Reject,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CandidateDecisionRequest {
    pub ids: Vec<String>,
    pub decision: CandidateDecision,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CandidateDecisionResult {
    pub accepted: usize,
    pub rejected: usize,
    /// 不是候选、或已被处理过的 id：跳过而不是报错，方便客户端重放。
    #[serde(default)]
    pub skipped: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BatchRevokeRequest {
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchRevokeResult {
    pub batch_id: String,
    pub revoked: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryFeedbackRequest {
    pub useful: bool,
}

/// 遗忘范围：所有字段都是可选条件（AND 关系），**全空 = 拒绝执行**。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ForgetFilter {
    #[serde(default)]
    pub entity_id: Option<String>,
    #[serde(default)]
    pub kind: Option<MemoryKind>,
    #[serde(default)]
    pub source: Option<MemorySource>,
    /// 早于该时刻的记忆（Unix 毫秒）。
    #[serde(default)]
    pub before: Option<i64>,
    #[serde(default)]
    pub batch_id: Option<String>,
    #[serde(default)]
    pub scope: Option<MemoryScope>,
    #[serde(default)]
    pub project_id: Option<String>,
}

impl ForgetFilter {
    /// 全空等于"删掉一切"，必须拒绝。
    pub fn is_empty(&self) -> bool {
        self.entity_id.is_none()
            && self.kind.is_none()
            && self.source.is_none()
            && self.before.is_none()
            && self.batch_id.is_none()
            && self.scope.is_none()
            && self.project_id.is_none()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForgetRequest {
    pub filter: ForgetFilter,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForgetResult {
    pub matched: usize,
    pub forgotten: usize,
    pub dry_run: bool,
}

/// 清空归档：`kind` 缺省 = 全部类别。只动 `status='archived'` 的行，
/// 生效与候选不受影响；与单条删除一样是软删（行保留，读路径排除）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PurgeArchivedRequest {
    #[serde(default)]
    pub kind: Option<MemoryKind>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PurgeArchivedResult {
    pub purged: usize,
}

/// 导出预览：`diff` 是 unified diff 文本，客户端必须展示后才能 apply。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportPreview {
    pub project_id: String,
    pub path: String,
    pub diff: String,
    pub entries: usize,
    /// 当前文件的哈希；apply 时原样回传，不一致就拒绝写入。
    pub content_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportApplyRequest {
    pub project_id: String,
    pub expected_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportApplyResult {
    pub path: String,
    pub bytes: usize,
}

/// 通知类别。心跳只处理本地信号，所以类别只有这三种。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationCategory {
    Due,
    Todo,
    DigestReport,
}

impl NotificationCategory {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Due => "due",
            Self::Todo => "todo",
            Self::DigestReport => "digest_report",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "due" => Some(Self::Due),
            "todo" => Some(Self::Todo),
            "digest_report" => Some(Self::DigestReport),
            _ => None,
        }
    }
}

/// 用户可改的记忆设置。字段缺省表示"不改"。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MemorySettings {
    /// 静音的类别：这些类别仍然记录，但不投递。
    #[serde(default)]
    pub heartbeat_mute: Option<Vec<NotificationCategory>>,
    /// 每日打扰上限。
    #[serde(default)]
    pub daily_limit: Option<u32>,
    /// 常驻摘要开关。
    #[serde(default)]
    pub digest_enabled: Option<bool>,
}

// ---------------------------------------------------------------------------
// 执行授权（G 段）
// ---------------------------------------------------------------------------

/// 授权作用域。解析时三者都从库里查，**不接受客户端直传 scope_id**。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GrantScope {
    /// 本任务内：任务进入终态即失效。
    Task,
    /// 本会话：24 小时。
    Session,
    /// 本项目（项目）：7 天。
    Project,
}

impl GrantScope {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Task => "task",
            Self::Session => "session",
            Self::Project => "project",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "task" => Some(Self::Task),
            "session" => Some(Self::Session),
            "project" => Some(Self::Project),
            _ => None,
        }
    }

    /// 默认有效期（毫秒）。任务级用审批卡自己的 TTL，这里给的是另外两级。
    pub const fn default_ttl_ms(self) -> i64 {
        match self {
            Self::Task => 0,
            Self::Session => 24 * 3_600_000,
            Self::Project => 7 * 86_400_000,
        }
    }
}

/// 一条执行授权：审批的缓存层，只跳过"询问"，不改变"判定"。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Grant {
    pub id: String,
    pub tool: String,
    pub risk: crate::RiskLevel,
    pub scope: GrantScope,
    pub scope_id: String,
    /// 批准它的那条审批记录：所有 grant 都要能追到"当初是哪张卡批准的"。
    pub approved_by: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub revoked_at: Option<i64>,
    pub last_hit_at: Option<i64>,
    pub hit_count: u32,
}

impl Grant {
    /// 是否还能挡住一次询问：未撤销、未过期。
    pub fn is_alive(&self, now: i64) -> bool {
        self.revoked_at.is_none() && self.expires_at > now
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GrantPage {
    pub items: Vec<Grant>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}
