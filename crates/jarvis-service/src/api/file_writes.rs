//! 会话文件生成：覆盖决策与草稿预览。
//!
//! 写入本身在 `local_tools::write_file` 里完成；这里只负责"用户已经决定"之后
//! 的那一步。之所以单独成端点：确认卡是异步的，用户可能隔几分钟才点，
//! 中间还可能跨进程重启。把它塞回对话流就得在 `chat::run` 里挂起等待，
//! 断线、超时、恢复三件事都得处理，代价远大于收益。
//!
//! 两个必须守住的边界：
//!
//! 1. 决策只能作用于**自己会话**的请求：否则拿到别人的 request_id 就能
//!    覆盖别人项目里的文件；
//! 2. 批准时必须**重新解析根**再写：项目可能已被删除、路径可能已被改动，
//!    不能复用挂起时的绝对路径。

use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderValue};
use axum::response::Response;
use axum::{Extension, Json};
use protocol::{ErrorCode, FileWrite, FileWriteDecision, PreviewTarget};
use serde::Deserialize;
use tokio_util::io::ReaderStream;

use super::error::ApiRejection;
use super::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::conversation;
use crate::project_files;
use crate::state::AppState;
use crate::web_preview::{self, TargetError};
use crate::write_store::{self, WriteRequest, WriteScope};

#[derive(Debug, Deserialize)]
pub struct DraftPreviewQuery {
    pub path: String,
}

/// `POST /api/conversations/{id}/file-writes/{request_id}`：覆盖 / 取消。
pub async fn decide(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path((conversation_id, request_id)): Path<(String, String)>,
    ApiJson(request): ApiJson<FileWriteDecision>,
) -> Result<Json<FileWrite>, ApiRejection> {
    // 先收一遍过期：用户可能隔了很久才点，此时内容已按约定作废。
    write_store::expire_overdue(&state.pool)
        .await
        .map_err(store_error)?;

    let Some(row) = write_store::get(&state.pool, &request_id)
        .await
        .map_err(store_error)?
    else {
        return Err(ApiRejection::new(
            ErrorCode::NotFound,
            "file write request not found",
            "这个覆盖请求不存在，可能已被清理；请重新生成一次",
        ));
    };

    if row.conversation_id != conversation_id {
        return Err(ApiRejection::new(
            ErrorCode::Conflict,
            "file write belongs to another conversation",
            "该请求不属于当前会话，请刷新后重试",
        ));
    }

    if row.status != write_store::STATUS_PENDING {
        let hint = if row.status == write_store::STATUS_EXPIRED {
            "这次覆盖请求已经过期，请重新生成一次"
        } else {
            "这个请求已经处理过了，请刷新后查看"
        };
        return Err(ApiRejection::new(
            ErrorCode::Conflict,
            format!("file write status is {}", row.status),
            hint,
        ));
    }

    if !request.approve {
        write_store::mark_decided(
            &state.pool,
            &row.id,
            write_store::STATUS_REJECTED,
            None,
            None,
        )
        .await
        .map_err(store_error)?;

        // 拒绝不碰磁盘，只把卡片状态改掉。
        sync_card(&state.pool, &row, write_store::STATUS_REJECTED, None).await;

        audit_decision(&state, &device, &row, "file.write_rejected", None).await;

        return Ok(Json(to_protocol(&row, write_store::STATUS_REJECTED, None)));
    }

    let scope = WriteScope::parse(&row.scope).ok_or_else(|| {
        ApiRejection::new(
            ErrorCode::InternalError,
            "unknown write scope",
            "这条写请求的作用域已损坏，请重新生成",
        )
    })?;

    // 重新解析根：项目可能已被删除，草稿目录也可能被清过。
    let root = write_store::resolve_root(&state.pool, &state.config, &conversation_id, scope)
        .await
        .map_err(store_error)?;

    let target = root.resolve_new(&row.path).map_err(|err| {
        ApiRejection::new(
            ErrorCode::InvalidRequest,
            "file write path rejected",
            format!("{err}；请重新生成一次"),
        )
    })?;

    // 这期间文件可能被删了：那就没有要备份的东西，直接写。
    let backup = if target.exists {
        match write_store::backup_existing(
            &state.config,
            &conversation_id,
            &row.id,
            &row.path,
            &target.abs,
        )
        .await
        {
            Ok(path) => Some(path),
            Err(err) => {
                // 备份失败就不覆盖：没有退路的覆盖比"没写成"更糟。
                write_store::mark_decided(
                    &state.pool,
                    &row.id,
                    write_store::STATUS_FAILED,
                    None,
                    Some(&err.to_string()),
                )
                .await
                .map_err(store_error)?;
                sync_card(&state.pool, &row, write_store::STATUS_FAILED, None).await;

                return Err(ApiRejection::new(
                    ErrorCode::InternalError,
                    "backup failed",
                    format!("备份原文件失败，没有覆盖：{err}"),
                ));
            }
        }
    } else {
        None
    };

    if let Err(err) = write_store::atomic_write(&target.abs, &row.content).await {
        write_store::mark_decided(
            &state.pool,
            &row.id,
            write_store::STATUS_FAILED,
            backup.as_deref(),
            Some(&err.to_string()),
        )
        .await
        .map_err(store_error)?;
        sync_card(
            &state.pool,
            &row,
            write_store::STATUS_FAILED,
            backup.as_deref(),
        )
        .await;

        return Err(ApiRejection::new(
            ErrorCode::InternalError,
            "file write failed",
            format!("覆盖失败：{err}"),
        ));
    }

    write_store::mark_decided(
        &state.pool,
        &row.id,
        write_store::STATUS_WRITTEN,
        backup.as_deref(),
        None,
    )
    .await
    .map_err(store_error)?;

    sync_card(
        &state.pool,
        &row,
        write_store::STATUS_WRITTEN,
        backup.as_deref(),
    )
    .await;

    audit_decision(&state, &device, &row, "file.write", backup.as_deref()).await;

    Ok(Json(to_protocol(&row, write_store::STATUS_WRITTEN, backup)))
}

/// `GET /api/conversations/{id}/file-preview?path=`：把会话里的文件换成可加载地址。
///
/// 一个入口同时覆盖两种落点：会话绑了项目就按项目预览，没绑就按草稿目录。
/// 让客户端自己判断"该调哪个端点"等于把会话归属逻辑复制一份到界面，
/// 而它本来只需要说"打开这个文件"。
///
/// 地址里有预览站的随机端口与令牌，只能由服务端生成；
/// 客户端自己拼端口是错误方向（令牌不该下发到别处）。
pub async fn file_preview(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    Query(query): Query<DraftPreviewQuery>,
) -> Result<Json<PreviewTarget>, ApiRejection> {
    let Some(preview) = state.web_preview.as_ref() else {
        return Err(ApiRejection::new(
            ErrorCode::BrowserUnavailable,
            "web preview not started",
            "预览站没有启动，暂时打不开网页；重启服务端后仍失败请查看服务日志",
        ));
    };

    // 只认没被逻辑删除的项目：项目删掉之后，旧文件不该还能通过旧会话打开。
    let project_id: Option<String> = sqlx::query_scalar(
        "SELECT c.project_id FROM conversations c \
         JOIN projects p ON p.id = c.project_id \
         WHERE c.id = ? AND p.deleted_at IS NULL AND c.project_id != ''",
    )
    .bind(&conversation_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(|err| {
        ApiRejection::new(
            ErrorCode::InternalError,
            "conversation lookup failed",
            format!("查询会话失败：{err}"),
        )
    })?;

    let target = match project_id.as_deref() {
        Some(id) => {
            let project = crate::project::get(&state.pool, id)
                .await
                .map_err(|err| {
                    ApiRejection::new(
                        ErrorCode::InternalError,
                        "project lookup failed",
                        format!("查询项目失败：{err}"),
                    )
                })?
                .ok_or_else(|| {
                    ApiRejection::new(
                        ErrorCode::NotFound,
                        "project not found",
                        "这个会话所属的项目已被删除，文件打不开了",
                    )
                })?;

            let root =
                crate::local_tools::path_guard::ProjectRoot::new(&project.path).map_err(|err| {
                    ApiRejection::new(
                        ErrorCode::InvalidRequest,
                        "project root unavailable",
                        format!("项目目录不可用：{err}"),
                    )
                })?;

            web_preview::file_target(preview, &root, id, &query.path)
        }
        None => web_preview::draft_target(preview, &state.config, &conversation_id, &query.path),
    }
    .map_err(|err| {
        let reason = match err {
            TargetError::Denied(reason) | TargetError::Invalid(reason) => reason,
        };
        ApiRejection::new(ErrorCode::InvalidRequest, "file preview rejected", reason)
    })?;

    Ok(Json(PreviewTarget {
        url: target.url,
        display: target.display,
    }))
}

/// 草案文件字节的查询参数。
///
/// `download` 与项目端点同一个口径：带上就跳过查看器上限并给附件头。
#[derive(Debug, Deserialize)]
pub struct DraftFileQuery {
    pub path: String,
    #[serde(default)]
    pub download: bool,
}

/// `GET /api/conversations/{id}/draft-file?path=`：草案文件的原始字节。
///
/// 只服务「另存为 / 系统分享」：草案里的 html 已经有预览站地址，但 md / png /
/// mp4 之类的文件在此之前没有任何读取通道，用户只能看到一个存不下来的卡片。
///
/// 与 `file-preview` 的分工：那个换的是"能在 WebView 里加载的地址"，白名单只认
/// html/htm；这个给的是字节，不参与预览，因此也不扩大预览站的暴露面。
pub async fn draft_file(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    Query(query): Query<DraftFileQuery>,
) -> Result<Response, ApiRejection> {
    let root = state.config.drafts_dir().join(&conversation_id);
    if !root.is_dir() {
        return Err(ApiRejection::new(
            ErrorCode::NotFound,
            "draft directory missing",
            "这个会话还没有生成过文件",
        ));
    }
    let root = root.to_string_lossy().to_string();

    // `open_raw*` 与文件树同一口径：参数必须是**绝对路径**，再 canonicalize 复核
    // 仍在根内。草稿这边对外收的是根内相对路径（客户端只知道 `notes.md`），
    // 所以先拼绝对再走同一套准入——`..` 与软链接仍然由那次规范化收掉。
    let absolute = std::path::Path::new(&root).join(&query.path);
    // 解析不到就给 404：对用户而言这是"文件没了（可能被重新生成）"，
    // 与项目端点的 400「路径不可访问」不是同一类事，别让界面提示"请求写错了"。
    let Ok(resolved) = absolute.canonicalize() else {
        return Err(ApiRejection::new(
            ErrorCode::NotFound,
            "draft file missing",
            "草案里没有这个文件，可能已被重新生成",
        ));
    };
    let resolved = resolved.to_string_lossy().to_string();
    let raw = if query.download {
        project_files::open_raw_for_download(&root, &resolved)?
    } else {
        project_files::open_raw(&root, &resolved)?
    };

    let file = tokio::fs::File::open(&raw.path).await.map_err(|err| {
        ApiRejection::new(
            ErrorCode::InvalidRequest,
            format!("open draft file failed: {err}"),
            format!("文件不可读（{}）：{err}", raw.path.display()),
        )
    })?;

    let mut response = Response::new(Body::from_stream(ReaderStream::new(file)));
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(raw.mime));
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(raw.size));
    // 草案随时被重新生成：缓存只会让人对着旧内容排查问题。
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );

    if query.download {
        let name = std::path::Path::new(&query.path)
            .file_name()
            .map(|value| value.to_string_lossy().to_string())
            .unwrap_or_else(|| "draft".to_string());
        // 文件名可能含引号或中文：拼不进去就退回不带名字的 attachment，
        // 让系统按 URL 猜——比返回 500 好。
        let disposition = HeaderValue::from_str(&format!("attachment; filename=\"{name}\""))
            .unwrap_or_else(|_| HeaderValue::from_static("attachment"));
        headers.insert(header::CONTENT_DISPOSITION, disposition);
    }

    Ok(response)
}

/// 把决策结果同步进消息里的卡片。失败只告警：决策本身已经生效。
async fn sync_card(
    pool: &sqlx::SqlitePool,
    row: &WriteRequest,
    status: &str,
    backup: Option<&str>,
) {
    let Some(message_id) = row.message_id.as_deref() else {
        return;
    };

    if let Err(err) =
        conversation::update_file_write_status(pool, message_id, &row.id, status, backup).await
    {
        tracing::warn!(%err, request_id = %row.id, "同步文件卡片状态失败");
    }
}

/// 写操作审计：只记路径与字节数，不记正文。
async fn audit_decision(
    state: &AppState,
    device: &AuthDevice,
    row: &WriteRequest,
    action: &str,
    backup: Option<&str>,
) {
    audit::record(
        &state.pool,
        &AuditEntry::new(&row.conversation_id, &device.device_id, action, "ok")
            .target(&row.path)
            .detail(serde_json::json!({
                "scope": row.scope,
                "bytes": row.bytes,
                "existing_bytes": row.existing_bytes,
                "backup": backup,
            })),
    )
    .await;
}

fn to_protocol(row: &WriteRequest, status: &str, backup: Option<String>) -> FileWrite {
    FileWrite {
        request_id: row.id.clone(),
        path: row.path.clone(),
        scope: row.scope.clone(),
        status: status.to_string(),
        bytes: row.bytes,
        existing_bytes: row.existing_bytes,
        backup_path: backup,
        // 决策之后不再有"过期"这回事。
        expires_at: None,
        created_at: row.created_at,
    }
}

fn store_error(err: write_store::WriteError) -> ApiRejection {
    match err {
        write_store::WriteError::Denied(reason) | write_store::WriteError::Invalid(reason) => {
            ApiRejection::new(ErrorCode::InvalidRequest, "file write rejected", reason)
        }
        write_store::WriteError::Io(err) => ApiRejection::new(
            ErrorCode::InternalError,
            "file write io failed",
            format!("写入失败：{err}"),
        ),
        write_store::WriteError::Db(err) => ApiRejection::new(
            ErrorCode::InternalError,
            "file write db failed",
            format!("数据库不可用：{err}"),
        ),
    }
}
