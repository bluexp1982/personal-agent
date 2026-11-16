//! `/api/memories*`：显式记忆的增删改查、状态快照、digest 快照。
//!
//! 纪律：
//! - 全部挂在 `protected` 组（`api::mod`），未鉴权不可读；
//! - 错误统一走 [`ApiRejection`]，不返回自定义结构；
//! - 分页一律 `?cursor=&limit=`，`limit` 默认 20、上限 100；
//! - 审计只记元数据，**不记正文**。

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use serde::Deserialize;

use protocol::{
    BatchRevokeRequest, BatchRevokeResult, CandidateDecision, CandidateDecisionRequest,
    CandidateDecisionResult, DigestListItem, DigestView, ExportApplyRequest, ExportApplyResult,
    ExportPreview, ForgetRequest, ForgetResult, Memory, MemoryCreateRequest, MemoryDetail,
    MemoryFeedbackRequest, MemoryKind, MemoryPage, MemoryScope, MemorySource, MemoryStateView,
    MemoryStatus, MemoryUpdateRequest, OrganizeAck, PurgeArchivedRequest, PurgeArchivedResult,
};

use crate::api::error::ApiRejection;
use crate::api::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::memory::store::{MemoryFilter, MemoryPatch};
use crate::memory::MemoryError;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub kind: Option<String>,
    pub status: Option<String>,
    pub scope: Option<String>,
    pub project_id: Option<String>,
    pub entity_id: Option<String>,
    pub batch_id: Option<String>,
    /// 关键词搜索。命中走 FTS，不够再 LIKE 兜底；结果按相关度排序且不分页。
    pub q: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct DigestListQuery {
    pub limit: Option<u32>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<MemoryPage>, ApiRejection> {
    let filter = MemoryFilter {
        kind: parse_kind(query.kind.as_deref())?,
        status: parse_status(query.status.as_deref())?,
        scope: parse_scope(query.scope.as_deref())?,
        project_id: non_empty(query.project_id),
        entity_id: non_empty(query.entity_id),
        batch_id: non_empty(query.batch_id),
        q: non_empty(query.q),
        source: None,
        before: None,
    };

    let (items, next) = state
        .memory
        .store()
        .list(filter, query.cursor.as_deref(), query.limit.unwrap_or(20))
        .await?;

    Ok(Json(MemoryPage {
        items,
        next_cursor: next.map(|cursor| cursor.encode()),
    }))
}

pub async fn create(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(request): ApiJson<MemoryCreateRequest>,
) -> Result<(StatusCode, Json<MemoryDetail>), ApiRejection> {
    let detail = state.memory.remember_explicit(request).await?;

    // 显式写入的审计在服务层已经记了（合并与新增要分开），这里只补设备维度。
    audit::record(
        &state.pool,
        &AuditEntry::new(&detail.memory.id, &device.device_id, "memory.write", "ok")
            .target(&detail.memory.id)
            .detail(serde_json::json!({ "chars": detail.memory.content.chars().count() })),
    )
    .await;

    Ok((StatusCode::CREATED, Json(detail)))
}

pub async fn detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<MemoryDetail>, ApiRejection> {
    let detail = state
        .memory
        .store()
        .get(&id)
        .await?
        .ok_or(MemoryError::NotFound)?;

    Ok(Json(detail))
}

pub async fn update(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<MemoryUpdateRequest>,
) -> Result<Json<MemoryDetail>, ApiRejection> {
    // status 只允许 active / archived：删除必须走 DELETE，要留软删痕迹。
    if let Some(status) = request.status {
        if !matches!(status, MemoryStatus::Active | MemoryStatus::Archived) {
            return Err(ApiRejection::from(MemoryError::Invalid(
                "status 只能改成 active 或 archived；删除请用 DELETE /api/memories/{id}"
                    .to_string(),
            )));
        }
    }
    if let Some(content) = request.content.as_deref() {
        if content.trim().is_empty() {
            return Err(ApiRejection::from(MemoryError::Invalid(
                "content 不能为空".to_string(),
            )));
        }
    }

    // 用户手改正文意味着"这条不再完全来自原话"，来源标记跟着改，审计留痕。
    let content_changed = request.content.is_some();
    let patch = MemoryPatch {
        content: request.content,
        pinned: request.pinned,
        sensitivity: request.sensitivity,
        kind: request.kind,
        status: request.status,
        time_scope: request.time_scope,
        source: content_changed.then_some(MemorySource::UserCorrected),
        importance: None,
    };

    let memory = state.memory.store().update(&id, patch).await?;

    if content_changed {
        audit::record(
            &state.pool,
            &AuditEntry::new(&memory.id, &device.device_id, "memory.corrected", "ok")
                .target(&memory.id)
                .detail(serde_json::json!({ "chars": memory.content.chars().count() })),
        )
        .await;
    }

    let detail = state
        .memory
        .store()
        .get(&memory.id)
        .await?
        .ok_or(MemoryError::NotFound)?;

    Ok(Json(detail))
}

pub async fn delete(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    state.memory.store().soft_delete(&id).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "memory.forgotten", "ok")
            .target(&id)
            .detail(serde_json::json!({ "matched": 1, "forgotten": 1 })),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn state(State(state): State<AppState>) -> Result<Json<MemoryStateView>, ApiRejection> {
    Ok(Json(state.memory.state().await?))
}

pub async fn digest_list(
    State(state): State<AppState>,
    Query(query): Query<DigestListQuery>,
) -> Result<Json<Vec<DigestListItem>>, ApiRejection> {
    let limit = query.limit.unwrap_or(7).clamp(1, 30);

    let rows: Vec<(String, i64, i64)> = sqlx::query_as(
        "SELECT id, chars, created_at FROM memory_digest_snapshots \
         ORDER BY created_at DESC LIMIT ?",
    )
    .bind(i64::from(limit))
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(
        rows.into_iter()
            .map(|(id, chars, created_at)| DigestListItem {
                id,
                chars: chars.max(0) as usize,
                created_at,
            })
            .collect(),
    ))
}

pub async fn digest_detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<DigestView>, ApiRejection> {
    let row: Option<(String, String, i64, i64, String)> = sqlx::query_as(
        "SELECT id, content, chars, created_at, memory_ids_json \
         FROM memory_digest_snapshots WHERE id = ?",
    )
    .bind(&id)
    .fetch_optional(&state.pool)
    .await?;

    let (id, content, chars, created_at, memory_ids_json) = row.ok_or(MemoryError::NotFound)?;
    let memory_ids: Vec<String> = serde_json::from_str(&memory_ids_json).unwrap_or_default();

    Ok(Json(DigestView {
        id,
        content,
        chars: chars.max(0) as usize,
        created_at,
        memory_ids,
    }))
}

fn non_empty(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn parse_kind(raw: Option<&str>) -> Result<Option<MemoryKind>, ApiRejection> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        None => Ok(None),
        Some(value) => MemoryKind::parse(value).map(Some).ok_or_else(|| {
            invalid(format!(
                "kind=\"{value}\" 不合法，可选 profile / preference / event / project"
            ))
        }),
    }
}

/// `status=all` 表示不过滤——客户端用同一个参数表达"看全部"，
/// 不必为此多一个布尔开关。
fn parse_status(raw: Option<&str>) -> Result<Option<MemoryStatus>, ApiRejection> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        None | Some("all") => Ok(None),
        Some("active") => Ok(Some(MemoryStatus::Active)),
        Some(value) => MemoryStatus::parse(value).map(Some).ok_or_else(|| {
            invalid(format!(
                "status=\"{value}\" 不合法，可选 all / active / candidate / stale / archived"
            ))
        }),
    }
}

fn parse_scope(raw: Option<&str>) -> Result<Option<MemoryScope>, ApiRejection> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        None => Ok(None),
        Some(value) => MemoryScope::parse(value)
            .map(Some)
            .ok_or_else(|| invalid(format!("scope=\"{value}\" 不合法，可选 global / project"))),
    }
}

fn invalid(reason: String) -> ApiRejection {
    ApiRejection::from(MemoryError::Invalid(reason))
}

// ---------------------------------------------------------------------------
// P2/P3/P4：反馈、候选决策、整批撤销、批量遗忘、导出
// ---------------------------------------------------------------------------

pub async fn feedback(
    State(state): State<AppState>,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<MemoryFeedbackRequest>,
) -> Result<Json<Memory>, ApiRejection> {
    let memory = state.memory.store().feedback(&id, req.useful).await?;
    Ok(Json(memory))
}

pub async fn decide(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(req): ApiJson<CandidateDecisionRequest>,
) -> Result<Json<CandidateDecisionResult>, ApiRejection> {
    if req.ids.is_empty() {
        return Err(MemoryError::Invalid("ids 不能为空".to_string()).into());
    }

    let accept = req.decision == CandidateDecision::Accept;
    let (accepted, rejected, skipped) = state.memory.store().decide(&req.ids, accept).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(
            &device.device_id,
            "memory",
            "memory.candidate_decided",
            "ok",
        )
        .target(if accept { "accept" } else { "reject" })
        .detail(serde_json::json!({
            "accepted": accepted,
            "rejected": rejected,
            "skipped": skipped.len(),
        })),
    )
    .await;

    Ok(Json(CandidateDecisionResult {
        accepted,
        rejected,
        skipped,
    }))
}

pub async fn revoke_batch(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(batch_id): Path<String>,
    ApiJson(req): ApiJson<BatchRevokeRequest>,
) -> Result<Json<BatchRevokeResult>, ApiRejection> {
    let revoked = state.memory.store().revoke_batch(&batch_id).await?;
    if revoked == 0 {
        return Err(MemoryError::Conflict("这一批没有可撤销的记忆".to_string()).into());
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "memory", "memory.batch_revoked", "ok")
            .target(&batch_id)
            .detail(serde_json::json!({
                "batch_id": batch_id,
                "revoked": revoked,
                "reason": req.reason.unwrap_or_default(),
            })),
    )
    .await;

    Ok(Json(BatchRevokeResult { batch_id, revoked }))
}

pub async fn forget(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(req): ApiJson<ForgetRequest>,
) -> Result<Json<ForgetResult>, ApiRejection> {
    // 全空等于"删掉一切"：必须拒绝，避免客户端漏传字段造成灾难。
    if req.filter.is_empty() {
        return Err(MemoryError::Invalid(
            "遗忘条件不能全为空：至少给出实体、类型、来源或时间之一".to_string(),
        )
        .into());
    }

    let filter = MemoryFilter {
        kind: req.filter.kind,
        source: req.filter.source,
        before: req.filter.before,
        batch_id: req.filter.batch_id.clone(),
        scope: req.filter.scope,
        project_id: req.filter.project_id.clone(),
        entity_id: req.filter.entity_id.clone(),
        status: None,
        q: None,
    };

    let store = state.memory.store();
    let matched = store.count_matching(&filter).await?;
    let forgotten = if req.dry_run {
        0
    } else {
        store.forget_matching(&filter).await?
    };

    if !req.dry_run {
        audit::record(
            &state.pool,
            &AuditEntry::new(&device.device_id, "memory", "memory.forgotten", "ok")
                .target("bulk")
                .detail(serde_json::json!({
                    "matched": matched,
                    "forgotten": forgotten,
                    "dry_run": false,
                })),
        )
        .await;
    }

    Ok(Json(ForgetResult {
        matched,
        forgotten,
        dry_run: req.dry_run,
    }))
}

/// 清空归档：只把 `status='archived'` 的行软删，可选按类别收窄。
///
/// 与 `forget` 分开做而不是给它加 status 条件：`forget` 的契约是"多条件 AND 的
/// 精确遗忘"，清空归档是"把坟场整个清掉"的粗操作，入口分开，审计码也分开。
pub async fn purge_archived(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(req): ApiJson<PurgeArchivedRequest>,
) -> Result<Json<PurgeArchivedResult>, ApiRejection> {
    let purged = state.memory.store().purge_archived(req.kind).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "memory", "memory.purge_archived", "ok")
            .target("archived")
            .detail(serde_json::json!({
                "kind": req.kind.map(MemoryKind::as_str),
                "purged": purged,
            })),
    )
    .await;

    Ok(Json(PurgeArchivedResult { purged }))
}

pub async fn export_preview(
    State(state): State<AppState>,
    ApiJson(req): ApiJson<ExportPreviewRequest>,
) -> Result<Json<ExportPreview>, ApiRejection> {
    Ok(Json(
        crate::memory::export::preview(&state.pool, &req.project_id).await?,
    ))
}

pub async fn export_apply(
    State(state): State<AppState>,
    ApiJson(req): ApiJson<ExportApplyRequest>,
) -> Result<Json<ExportApplyResult>, ApiRejection> {
    Ok(Json(
        crate::memory::export::apply(&state.pool, &req.project_id, &req.expected_hash).await?,
    ))
}

#[derive(Debug, Deserialize)]
pub struct ExportPreviewRequest {
    pub project_id: String,
}

/// 手动整理：立即返回，整理在后台跑。
///
/// **不走同步**：整理最多触发 `nightly_limit`（默认 50）次模型调用，同步等会让
/// 请求挂上几十秒。完成状态由 `GET /api/memories/state` 的 `maintenance` 节回读。
///
/// 只看 `memory.enabled`，不看自动整理开关：手动触发是用户的显式意图，
/// 没开自动整理的机器也该能点一下。
pub async fn organize(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
) -> Result<Json<OrganizeAck>, ApiRejection> {
    if !state.memory.enabled() {
        return Err(MemoryError::Disabled.into());
    }

    // 先抢闸门再 spawn：抢不到就是真有一轮在跑，直接告诉用户，不排队也不重复跑。
    let Some(lease) = state.memory.try_begin_organize() else {
        return Err(MemoryError::Conflict("正在整理，请稍候".to_string()).into());
    };

    let now = crate::clock::now_ms();
    let memory = state.memory.clone();
    tokio::spawn(async move {
        match memory.organize_holding(lease, now).await {
            Ok(report) => tracing::info!(?report, "手动整理完成"),
            Err(err) => tracing::warn!(%err, "手动整理失败"),
        }
    });

    crate::memory::audit_reject(
        &state.pool,
        "memory.organize_requested",
        serde_json::json!({
            "device_id": device.device_id,
            "started_at": now,
        }),
    )
    .await;

    Ok(Json(OrganizeAck { started_at: now }))
}

pub async fn settings(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(req): ApiJson<protocol::MemorySettings>,
) -> Result<Json<MemoryStateView>, ApiRejection> {
    let current = crate::memory::settings::load(&state.pool).await;
    let mut mute = current.mute;
    let mut daily_limit = current.daily_limit;
    let mut digest_enabled = current.digest_enabled;

    if let Some(items) = req.heartbeat_mute {
        mute = items
            .into_iter()
            .map(|category| category.as_str().to_string())
            .collect();
    }
    if let Some(limit) = req.daily_limit {
        daily_limit = limit;
    }
    if let Some(enabled) = req.digest_enabled {
        digest_enabled = enabled;
    }
    if daily_limit > 10 {
        return Err(MemoryError::Invalid("每日打扰上限最大 10 条".to_string()).into());
    }

    crate::memory::settings::save(
        &state.pool,
        &crate::memory::settings::RuntimeSettings {
            mute: mute.clone(),
            daily_limit,
            digest_enabled,
        },
    )
    .await
    .map_err(MemoryError::Db)?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "memory", "memory.settings_changed", "ok")
            .target("settings")
            .detail(serde_json::json!({
                "mute": mute.len(),
                "daily_limit": daily_limit,
                "digest_enabled": digest_enabled,
            })),
    )
    .await;

    Ok(Json(state.memory.state().await?))
}
