//! Git 面板端点：变更、diff、暂存、提交、历史。
//!
//! handler 只做参数解析、审计与错误映射；所有 git 调用与路径校验都在 [`crate::git`] 里，
//! 保证"从哪个入口进来都过同一道闸"。
//!
//! 只读端点（status / diff / commits）不写审计：面板一开一关就是两三条记录，
//! 会把 `audit_log` 变成操作流水。写端点（stage / unstage / discard / commit）必须写，
//! 撤销与提交都是改用户仓库的动作，事后要查得到。

use std::path::Path as StdPath;

use axum::extract::{Path, Query, State};
use axum::{Extension, Json};
use protocol::{
    GitCommitRequest, GitCommitResult, GitCommitsPage, GitDiffReport, GitPathsRequest,
    GitStatusReport, Project,
};
use serde::Deserialize;

use super::error::ApiRejection;
use super::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::git;
use crate::project;
use crate::state::AppState;

async fn load_project(state: &AppState, id: &str) -> Result<Project, ApiRejection> {
    project::get(&state.pool, id)
        .await?
        .ok_or_else(|| ApiRejection::from(project::ProjectError::NotFound))
}

/// 审计里的路径样本上限：只记"改了哪些"，不把几百条路径塞进 detail。
const AUDIT_SAMPLE: usize = 20;

async fn record(
    state: &AppState,
    device: &AuthDevice,
    id: &str,
    action: &str,
    paths: &[String],
    commit: Option<&str>,
) {
    let mut detail = serde_json::json!({ "count": paths.len() });
    let sample = &paths[..paths.len().min(AUDIT_SAMPLE)];
    detail["paths"] = serde_json::json!(sample);
    if let Some(commit) = commit {
        detail["commit"] = serde_json::json!(commit);
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(id, &device.device_id, action, "ok")
            .target(id)
            .detail(detail),
    )
    .await;
}

/// `GET /api/projects/{id}/git/status`：分支、三组变更、进行中的操作。
pub async fn status(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<GitStatusReport>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    Ok(Json(git::status(StdPath::new(&project.path)).await?))
}

#[derive(Debug, Deserialize)]
pub struct DiffQuery {
    /// 仓库内相对路径；`commit` 有值时可省略（看整次提交）。
    pub path: Option<String>,
    /// 看暂存区（`--cached`）。
    #[serde(default)]
    pub staged: bool,
    /// 看某次提交。
    pub commit: Option<String>,
}

/// `GET /api/projects/{id}/git/diff`：单文件或某次提交的 diff。
pub async fn diff(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<DiffQuery>,
) -> Result<Json<GitDiffReport>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let report = git::diff(
        StdPath::new(&project.path),
        query.path.as_deref(),
        query.staged,
        query.commit.as_deref(),
    )
    .await?;
    Ok(Json(report))
}

/// `POST /api/projects/{id}/git/stage`：暂存文件。
pub async fn stage(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<GitPathsRequest>,
) -> Result<Json<GitStatusReport>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let report = git::stage(StdPath::new(&project.path), &request.paths).await?;
    record(&state, &device, &id, "git.staged", &request.paths, None).await;
    Ok(Json(report))
}

/// `POST /api/projects/{id}/git/unstage`：取消暂存。
pub async fn unstage(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<GitPathsRequest>,
) -> Result<Json<GitStatusReport>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let report = git::unstage(StdPath::new(&project.path), &request.paths).await?;
    record(&state, &device, &id, "git.unstaged", &request.paths, None).await;
    Ok(Json(report))
}

/// `POST /api/projects/{id}/git/discard`：撤销已跟踪文件的改动（不可恢复）。
pub async fn discard(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<GitPathsRequest>,
) -> Result<Json<GitStatusReport>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let report = git::discard(StdPath::new(&project.path), &request.paths).await?;
    record(&state, &device, &id, "git.discarded", &request.paths, None).await;
    Ok(Json(report))
}

/// `POST /api/projects/{id}/git/commit`：提交已暂存的内容。
pub async fn commit(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<GitCommitRequest>,
) -> Result<Json<GitCommitResult>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let result = git::commit(StdPath::new(&project.path), &request.message).await?;
    record(
        &state,
        &device,
        &id,
        "git.committed",
        &[],
        Some(&result.commit.hash),
    )
    .await;
    Ok(Json(result))
}

#[derive(Debug, Deserialize)]
pub struct HistoryQuery {
    pub limit: Option<u32>,
    pub skip: Option<u32>,
}

/// `GET /api/projects/{id}/git/commits`：提交历史（新到旧）。
pub async fn history(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<GitCommitsPage>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let page = git::history(StdPath::new(&project.path), query.limit, query.skip).await?;
    Ok(Json(page))
}
