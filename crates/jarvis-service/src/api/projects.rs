//! 项目端点：列表、新建、详情、重命名、删除。
//!
//! handler 只做参数解析、审计与错误映射；目录与模式的所有校验都在 [`crate::project`] 里，
//! 保证"从哪个入口进来都过同一道闸"。

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use protocol::{ErrorCode, Project, ProjectCreate, ProjectMode, ProjectPreflight, ProjectUpdate};
use serde::Deserialize;

use super::error::ApiRejection;
use super::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::project;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    /// 省略即返回全部项目。界面已不区分模式，新客户端不再传它；
    /// 保留该参数是为了让旧客户端与调试脚本仍能按能力类型过滤。
    pub mode: Option<String>,
}

/// 解析 `mode` 查询参数。大小写不敏感会让 `CODE` 与 `code` 都通过，
/// 但契约里只有小写，因此严格要求，避免客户端以为大小写无关。
pub(crate) fn parse_mode(raw: &str) -> Result<ProjectMode, ApiRejection> {
    ProjectMode::parse(raw.trim()).ok_or_else(|| {
        ApiRejection::new(
            ErrorCode::InvalidRequest,
            "unknown project mode",
            "模式取值应为 code 或 work",
        )
    })
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<Vec<Project>>, ApiRejection> {
    let mode = match query.mode.as_deref().map(str::trim) {
        Some(raw) if !raw.is_empty() => Some(parse_mode(raw)?),
        _ => None,
    };
    Ok(Json(project::list(&state.pool, mode).await?))
}

#[derive(Debug, Deserialize)]
pub struct PreflightQuery {
    pub mode: String,
    pub path: String,
}

/// 建项目之前的预检。只读：不写库、不改磁盘。
///
/// 客户端在目录选好之后调它，就能知道"能不能直接建 / 要不要先问一句初始化"，
/// 不必靠解析创建失败的错误文案来猜。
pub async fn preflight(
    State(state): State<AppState>,
    Query(query): Query<PreflightQuery>,
) -> Result<Json<ProjectPreflight>, ApiRejection> {
    let mode = parse_mode(&query.mode)?;
    let preflight = project::preflight(&state.config, mode, &query.path).await?;
    Ok(Json(preflight))
}

pub async fn create(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(request): ApiJson<ProjectCreate>,
) -> Result<(StatusCode, Json<Project>), ApiRejection> {
    let created = project::create(&state.pool, &state.config, &request).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&created.id, &device.device_id, "project.created", "ok")
            .target(&created.id)
            .detail(serde_json::json!({
                "mode": created.mode.as_str(),
                "path": created.path,
            })),
    )
    .await;

    Ok((StatusCode::CREATED, Json(created)))
}

pub async fn detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Project>, ApiRejection> {
    let project = project::get(&state.pool, &id)
        .await?
        .ok_or_else(|| ApiRejection::from(project::ProjectError::NotFound))?;
    Ok(Json(project))
}

pub async fn rename(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<ProjectUpdate>,
) -> Result<Json<Project>, ApiRejection> {
    let renamed = project::rename(&state.pool, &id, &request.name).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "project.renamed", "ok")
            .target(&id)
            .detail(serde_json::json!({ "name": renamed.name })),
    )
    .await;

    Ok(Json(renamed))
}

pub async fn delete(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    project::delete(&state.pool, &id).await?;

    // 项目没了：项目级授权与它上面的项目记忆一起失效。
    if let Err(err) =
        crate::grants::revoke_by_scope(&state.pool, protocol::GrantScope::Project, &id).await
    {
        tracing::warn!(%err, project_id = %id, "撤销项目级执行授权失败");
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "project.deleted", "ok").target(&id),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}
