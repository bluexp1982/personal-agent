//! 文件系统端点：目录选择器与项目文件树。
//!
//! 只读、无副作用，因此不写审计：用户在选择器里每点一次目录都记一条，
//! 只会把 `audit_log` 变成浏览历史，反而埋掉真正的写操作。
//!
//! 两组端点边界不同，不要混用：
//! - `/api/fs/dirs` 给「选项目目录」用，边界是配置里的浏览根，只列目录；
//! - `/api/projects/{id}/files|file` 给「浏览已建项目」用，边界是项目目录。

use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderValue};
use axum::response::Response;
use axum::Json;
use protocol::{DirListing, ErrorCode, PreviewTarget, ProjectFileContent, ProjectListing};
use serde::Deserialize;
use tokio_util::io::ReaderStream;

use super::error::ApiRejection;
use super::projects::parse_mode;
use crate::local_tools::path_guard::ProjectRoot;
use crate::state::AppState;
use crate::web_preview::{self, TargetError};
use crate::{fs_browse, project, project_files};

#[derive(Debug, Deserialize)]
pub struct BrowseQuery {
    pub mode: String,
    pub path: Option<String>,
}

pub async fn dirs(
    State(state): State<AppState>,
    Query(query): Query<BrowseQuery>,
) -> Result<Json<DirListing>, ApiRejection> {
    let mode = parse_mode(&query.mode)?;
    let listing = fs_browse::list(&state.config, mode, query.path.as_deref())?;
    Ok(Json(listing))
}

#[derive(Debug, Deserialize)]
pub struct ProjectFilesQuery {
    pub path: Option<String>,
    #[serde(default)]
    pub show_hidden: bool,
}

/// `GET /api/projects/{id}/files`：列出项目内一层目录。
pub async fn list_project_files(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ProjectFilesQuery>,
) -> Result<Json<ProjectListing>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let listing = project_files::list(&project.path, query.path.as_deref(), query.show_hidden)?;
    Ok(Json(listing))
}

#[derive(Debug, Deserialize)]
pub struct ProjectFileQuery {
    pub path: String,
}

/// 原始字节的查询参数。
///
/// `download` 为真时跳过 64 MB 查看器上限：导出走的就是这条路——
/// 大文件打不开但应当存得下来，否则用户只会以为服务端坏了。
#[derive(Debug, Deserialize)]
pub struct ProjectRawQuery {
    pub path: String,
    #[serde(default)]
    pub download: bool,
}

#[derive(Debug, Deserialize)]
pub struct ProjectPreviewQuery {
    pub path: String,
}

/// `GET /api/projects/{id}/raw`：读取项目内一个文件的原始字节。
///
/// 与 `/file` 的分工：`/file` 只服务文本预览（512 KB 截断、UTF-8 校验），
/// 这里是二进制（图片 / PDF），必须拿到完整字节。两条路各自只做一件事，
/// 不把「先读字节再猜类型」混进同一个端点。
///
/// 响应流式写出：服务端不为转发多占一份内存，目标设备上的大图也照样发得出去。
pub async fn read_project_raw(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ProjectRawQuery>,
) -> Result<Response, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let raw = if query.download {
        project_files::open_raw_for_download(&project.path, &query.path)?
    } else {
        project_files::open_raw(&project.path, &query.path)?
    };

    let file = tokio::fs::File::open(&raw.path).await.map_err(|err| {
        ApiRejection::new(
            ErrorCode::InvalidRequest,
            format!("open project file failed: {err}"),
            format!("文件不可读（{}）：{err}", raw.path.display()),
        )
    })?;

    let mut response = Response::new(Body::from_stream(ReaderStream::new(file)));
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(raw.mime));
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(raw.size));
    // 项目文件随时在改：缓存只会让人对着旧图排查问题。
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    // 类型由我们声明，别让任何消费方再嗅探成别的可执行类型。
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    Ok(response)
}

/// `GET /api/projects/{id}/file`：读取项目内一个文本文件，供右侧栏预览。
pub async fn read_project_file(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ProjectFileQuery>,
) -> Result<Json<ProjectFileContent>, ApiRejection> {
    let project = load_project(&state, &id).await?;
    let content = project_files::read_text(&project.path, &query.path)?;
    Ok(Json(content))
}

/// `GET /api/projects/{id}/preview`：把项目里的网页换成一个可加载的地址。
///
/// 地址里有预览站的随机端口与访问令牌，只能由服务端生成——客户端自己拼端口
/// 是错误方向（令牌不该下发到别处）。
///
/// 与会话里的 `preview_url(path)` 共用 [`web_preview::file_target`]：
/// 准入、入口白名单、地址拼接只有一份实现。
pub async fn preview_target(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ProjectPreviewQuery>,
) -> Result<Json<PreviewTarget>, ApiRejection> {
    let project = load_project(&state, &id).await?;

    let Some(preview) = state.web_preview.as_ref() else {
        return Err(ApiRejection::new(
            ErrorCode::BrowserUnavailable,
            "web preview not started",
            "预览站没有启动，暂时打不开网页；重启服务端后仍失败请查看服务日志",
        ));
    };

    let root = ProjectRoot::new(&project.path).map_err(|err| {
        ApiRejection::new(
            ErrorCode::InvalidRequest,
            "project root unavailable",
            format!("项目目录不可用：{err}"),
        )
    })?;

    let target = web_preview::file_target(preview, &root, &id, &query.path).map_err(|err| {
        // 越界与"不是网页"对用户是同一类：这个文件打不开，换个文件。
        // 差异只体现在文案里，不必造两个错误码。
        let reason = match err {
            TargetError::Denied(reason) | TargetError::Invalid(reason) => reason,
        };
        ApiRejection::new(ErrorCode::InvalidRequest, "preview target rejected", reason)
    })?;

    Ok(Json(PreviewTarget {
        url: target.url,
        display: target.display,
    }))
}

async fn load_project(state: &AppState, id: &str) -> Result<protocol::Project, ApiRejection> {
    project::get(&state.pool, id)
        .await?
        .ok_or_else(|| ApiRejection::from(project::ProjectError::NotFound))
}
