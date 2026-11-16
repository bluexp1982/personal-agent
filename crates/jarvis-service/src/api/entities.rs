//! `/api/entities*`：实体列表、详情、改名/改别名、合并与拆分。
//!
//! 与记忆接口同一套纪律：挂 `protected`、走 [`ApiRejection`]、游标分页、
//! 审计只记 id 与条数。

use axum::extract::{Path, Query, State};
use axum::{Extension, Json};
use serde::Deserialize;

use protocol::{
    Entity, EntityDetail, EntityMergeRequest, EntityPage, EntitySplitRequest, EntityStatus,
    EntityType, EntityUpdateRequest,
};

use crate::api::error::ApiRejection;
use crate::api::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::memory::entity::{self, EntityFilter};
use crate::memory::MemoryError;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    /// `person` / `org` / `project` / `device` / `recurring`
    #[serde(rename = "type")]
    pub entity_type: Option<String>,
    pub status: Option<String>,
    pub q: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<EntityPage>, ApiRejection> {
    let filter = EntityFilter {
        entity_type: match query.entity_type.as_deref() {
            None | Some("") | Some("all") => None,
            Some(raw) => Some(parse_type(raw)?),
        },
        status: match query.status.as_deref() {
            None | Some("") | Some("all") => None,
            Some(raw) => Some(
                EntityStatus::parse(raw)
                    .ok_or_else(|| MemoryError::Invalid(format!("未知的实体状态：{raw}")))?,
            ),
        },
        q: query.q,
    };

    let page = entity::list(
        &state.pool,
        &filter,
        query.cursor.as_deref(),
        query.limit.unwrap_or(20),
    )
    .await?;

    Ok(Json(page))
}

pub async fn detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<EntityDetail>, ApiRejection> {
    entity::get(&state.pool, &id)
        .await?
        .map(Json)
        .ok_or_else(|| MemoryError::NotFound.into())
}

pub async fn update(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<EntityUpdateRequest>,
) -> Result<Json<Entity>, ApiRejection> {
    let entity = entity::update(&state.pool, &id, req).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "memory", "memory.entity_updated", "ok")
            .target(&id)
            .detail(serde_json::json!({ "name_chars": entity.name.chars().count() })),
    )
    .await;

    Ok(Json(entity))
}

pub async fn merge(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(req): ApiJson<EntityMergeRequest>,
) -> Result<Json<EntityDetail>, ApiRejection> {
    entity::merge(
        &state.pool,
        &req.source_id,
        &req.target_id,
        &device.device_id,
    )
    .await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "memory", "memory.entity_merged", "ok")
            .target(&req.target_id)
            .detail(serde_json::json!({
                "source": req.source_id,
                "target": req.target_id,
            })),
    )
    .await;

    entity::get(&state.pool, &req.target_id)
        .await?
        .map(Json)
        .ok_or_else(|| MemoryError::NotFound.into())
}

pub async fn split(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(req): ApiJson<EntitySplitRequest>,
) -> Result<Json<EntityDetail>, ApiRejection> {
    let new_id = entity::split(&state.pool, &id, &req.memory_ids, req.name.as_deref()).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "memory", "memory.entity_split", "ok")
            .target(&id)
            .detail(serde_json::json!({
                "new_entity": new_id,
                "moved": req.memory_ids.len(),
            })),
    )
    .await;

    entity::get(&state.pool, &new_id)
        .await?
        .map(Json)
        .ok_or_else(|| MemoryError::NotFound.into())
}

fn parse_type(raw: &str) -> Result<EntityType, MemoryError> {
    EntityType::parse(raw).ok_or_else(|| MemoryError::Invalid(format!("未知的实体类型：{raw}")))
}
