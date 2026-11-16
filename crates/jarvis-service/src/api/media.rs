//! 会话媒体的正文下载。
//!
//! 只按 `id` 取：路径由服务端在生成时写入 `media_assets`，客户端既拿不到也传不进
//! 路径，所以这里没有"路径穿越"这一整类问题。
//!
//! 为什么单独一个端点而不复用 `/api/artifacts/{id}/content`：那张表属于任务
//! （查询要 JOIN tasks），而会话里的媒体没有 task，也不该为了下载伪造一个。

use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::{Extension, Json};
use protocol::{ErrorCode, MediaSaveResult};
use serde::Deserialize;
use tokio::io::AsyncWriteExt;

use super::error::ApiRejection;
use super::ApiJson;
use crate::artifact_store::{extension_for, ArtifactStore, StoreError};
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::local_tools::path_guard::{GuardError, ProjectRoot};
use crate::media::records;
use crate::project;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct ContentQuery {
    /// 带上 `?download=true` 时按附件下载（浏览器存盘），否则内联展示。
    #[serde(default)]
    pub download: bool,
}

pub async fn content(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ContentQuery>,
) -> Result<Response, ApiRejection> {
    let Some((path, mime)) = records::lookup(&state.pool, &id).await.map_err(|err| {
        tracing::error!(%err, media_id = %id, "查询媒体记录失败");
        ApiRejection::new(
            protocol::ErrorCode::InternalError,
            "media lookup failed",
            "读取媒体记录失败，请重试",
        )
    })?
    else {
        return Err(media_missing());
    };

    let store = ArtifactStore::new(state.config.artifacts_dir());
    let bytes = match store.read(&path).await {
        Ok(bytes) => bytes,
        Err(StoreError::Missing) => {
            tracing::warn!(media_id = %id, %path, "媒体记录存在但文件缺失");
            return Err(ApiRejection::new(
                protocol::ErrorCode::NotFound,
                "media file missing",
                "媒体文件已被清理，无法下载",
            ));
        }
        Err(StoreError::InvalidPath(reason)) => {
            tracing::error!(media_id = %id, %path, %reason, "媒体路径非法");
            return Err(ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "media path invalid",
                "媒体路径异常，请查看服务日志",
            ));
        }
        Err(err) => {
            tracing::error!(%err, media_id = %id, "读取媒体失败");
            return Err(ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "media read failed",
                "读取媒体失败，请重试",
            ));
        }
    };

    let length = bytes.len();
    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, mime.clone())
        .header(header::CONTENT_LENGTH, length)
        // 内容按 id 不可变：同一个 id 永远是同一份字节，客户端可以放心长期缓存。
        .header(
            header::CACHE_CONTROL,
            "private, max-age=31536000, immutable",
        )
        .header("x-content-type-options", "nosniff");

    if query.download {
        let file_name = format!("{id}{}", extension_for(Some(&mime)));
        let disposition = HeaderValue::from_str(&format!("attachment; filename=\"{file_name}\""))
            .unwrap_or_else(|_| HeaderValue::from_static("attachment"));
        builder = builder.header(header::CONTENT_DISPOSITION, disposition);
    }

    builder
        .body(Body::from(bytes))
        .map(|response| response.into_response())
        .map_err(|err| {
            tracing::error!(%err, media_id = %id, "构造媒体下载响应失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "media response failed",
                "下载失败，请重试",
            )
        })
}

/// `GET /api/media/{id}/poster`：视频封面（生成时抽的第一帧）。
///
/// 老视频（抽帧能力上线前生成的）`poster_path` 是空的：这里**按需补一张**
/// 再返回，补完写库，之后就走缓存。补不出来（没装 ffmpeg / 源文件损坏）才 404，
/// 客户端据此回退到播放图标占位块。**不用 204**：404 让"没有这张图"
/// 与"端点不存在"在客户端是同一种处理，少一条分支。
pub async fn poster(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Response, ApiRejection> {
    let record = records::lookup_poster_source(&state.pool, &id)
        .await
        .map_err(|err| {
            tracing::error!(%err, media_id = %id, "查询视频封面失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "poster lookup failed",
                "读取封面记录失败，请重试",
            )
        })?;

    let Some((source_path, mime, conversation_id, poster_path)) = record else {
        return Err(media_missing());
    };

    let store = ArtifactStore::new(state.config.artifacts_dir());

    let relative = match poster_path {
        Some(relative) => relative,
        // 图片没有封面这回事；视频缺封面就当场补一张。
        None if mime.starts_with("video/") => {
            match crate::media::poster::ensure(
                &state.pool,
                &store,
                &id,
                &conversation_id,
                &source_path,
            )
            .await
            {
                Ok(relative) => {
                    tracing::info!(media_id = %id, %relative, "为老视频补上了封面");
                    relative
                }
                Err(err) => {
                    tracing::warn!(media_id = %id, %err, "补封面失败，卡片回退到占位块");
                    return Err(ApiRejection::new(
                        protocol::ErrorCode::NotFound,
                        "poster missing",
                        "这条视频还没有封面（服务端未安装 ffmpeg，或视频文件不可用）",
                    ));
                }
            }
        }
        None => {
            return Err(ApiRejection::new(
                protocol::ErrorCode::NotFound,
                "poster missing",
                "这条产物没有封面",
            ));
        }
    };

    let bytes = match store.read(&relative).await {
        Ok(bytes) => bytes,
        Err(StoreError::Missing) => {
            // 记录在、文件没了：与正文缺失同一类，属于数据目录被清理。
            tracing::warn!(media_id = %id, %relative, "封面记录存在但文件缺失");
            return Err(ApiRejection::new(
                protocol::ErrorCode::NotFound,
                "poster file missing",
                "封面文件已被清理，重新生成视频即可",
            ));
        }
        Err(err) => {
            tracing::error!(%err, media_id = %id, "读取封面失败");
            return Err(ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "poster read failed",
                "读取封面失败，请重试",
            ));
        }
    };

    let length = bytes.len();
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "image/jpeg")
        .header(header::CONTENT_LENGTH, length)
        // 与正文同一口径：同一 id 的封面不会变，客户端可以长期缓存。
        .header(
            header::CACHE_CONTROL,
            "private, max-age=31536000, immutable",
        )
        .header("x-content-type-options", "nosniff")
        .body(Body::from(bytes))
        .map_err(|err| {
            tracing::error!(%err, media_id = %id, "构造封面响应失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "poster response failed",
                "读取封面失败，请重试",
            )
        })
}

fn media_missing() -> ApiRejection {
    ApiRejection::new(
        protocol::ErrorCode::NotFound,
        "media not found",
        "媒体不存在或已被清理",
    )
}

/// 「另存到项目」的请求体。
#[derive(Debug, Deserialize)]
pub struct SaveRequest {
    /// 用户确认过的文件名（含扩展名）。不带目录——落点固定是 `<项目>/artifacts/`。
    pub name: String,
}

/// 项目内固定落点。不放进项目根：模型生成的文件已经在根上，
/// 用户产物再混进去，文件树里就分不清"谁写的"。
const MEDIA_SAVE_DIR: &str = "artifacts";

/// 文件名长度上限。macOS 单个文件名上限 255 字节，中文占 3 字节，
/// 留出扩展名与余量后取 180 字符。
const MAX_SAVE_NAME_CHARS: usize = 180;

/// 文件名里不允许出现的字符：路径分隔符、Windows 保留字符。
///
/// 客户端也会拦一遍，但服务端是唯一写盘方：请求可以来自任何拿到令牌的设备，
/// 不能指望对面校验过。
const FORBIDDEN_NAME_CHARS: [char; 9] = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];

/// `POST /api/media/{id}/save`：把一枚会话产物复制进它所属项目的 `artifacts/` 目录。
///
/// 为什么由服务端复制而不是客户端回传字节：视频动辄几十 MB，回传等于多走一遍
/// 网络、多落一次盘。源文件本来就在服务端的产物库里，直接流式复制即可。
///
/// 为什么客户端不传 projectId：会话页只有项目目录、没有项目 id；归属由
/// `media_assets → conversations.project_id` 反查，客户端无法指定任意项目。
pub async fn save(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<SaveRequest>,
) -> Result<(StatusCode, Json<MediaSaveResult>), ApiRejection> {
    let Some((relative, mime, conversation_id, project_id)) =
        records::lookup_with_project(&state.pool, &id)
            .await
            .map_err(|err| {
                tracing::error!(%err, media_id = %id, "查询媒体记录失败");
                ApiRejection::new(
                    ErrorCode::InternalError,
                    "media lookup failed",
                    "读取媒体记录失败，请重试",
                )
            })?
    else {
        return Err(media_missing());
    };

    let Some(project_id) = project_id else {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "media has no project",
            "这份产物没有归属项目，只能保存到本机",
        ));
    };

    let project = project::get(&state.pool, &project_id)
        .await
        .map_err(|err| {
            tracing::error!(%err, project_id = %project_id, "查询产物所属项目失败");
            ApiRejection::new(
                ErrorCode::InternalError,
                "project lookup failed",
                "读取项目信息失败，请重试",
            )
        })?
        .ok_or_else(|| {
            ApiRejection::new(
                ErrorCode::NotFound,
                "project not found",
                "产物所属项目已被删除，只能保存到本机",
            )
        })?;

    // 用户给的名字补上记录里的扩展名：手输"季度复盘"时不该存成一个没有后缀的文件。
    let name = normalize_file_name(&request.name, &mime)?;
    let relative_path = format!("{MEDIA_SAVE_DIR}/{name}");

    let root = ProjectRoot::new(&project.path).map_err(|err| {
        ApiRejection::new(
            ErrorCode::InvalidRequest,
            "project root unavailable",
            format!("项目目录不可用：{err}"),
        )
    })?;
    let target = root.resolve_new(&relative_path).map_err(guard_rejection)?;

    let store = ArtifactStore::new(state.config.artifacts_dir());
    let source = store.resolve(&relative).map_err(|err| match err {
        StoreError::Missing => ApiRejection::new(
            ErrorCode::NotFound,
            "media file missing",
            "媒体文件已被清理，无法保存",
        ),
        StoreError::InvalidPath(reason) => ApiRejection::new(
            ErrorCode::InternalError,
            format!("media path invalid: {reason}"),
            "媒体路径异常，请查看服务日志",
        ),
        StoreError::Io(err) => ApiRejection::new(
            ErrorCode::InternalError,
            format!("media resolve failed: {err}"),
            "读取媒体失败，请重试",
        ),
    })?;
    let mut source_file = tokio::fs::File::open(&source).await.map_err(|err| {
        tracing::warn!(%err, media_id = %id, path = %source.display(), "打开产物源文件失败");
        ApiRejection::new(
            ErrorCode::NotFound,
            "media file missing",
            "媒体文件已被清理，无法保存",
        )
    })?;

    if let Some(parent) = target.abs.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(|err| {
            tracing::error!(%err, path = %parent.display(), "创建 artifacts 目录失败");
            ApiRejection::new(
                ErrorCode::InternalError,
                "create artifacts dir failed",
                "无法在项目里创建 artifacts 目录，请检查目录权限",
            )
        })?;
    }

    // `create_new` 是"检查 + 占用"的原子版本：先查存在再写会有 TOCTOU，
    // 而静默覆盖用户项目里同名文件是不可接受的副作用。
    let mut target_file = match tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&target.abs)
        .await
    {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(ApiRejection::new(
                ErrorCode::Conflict,
                "target file exists",
                format!("项目里已经有 {}，换个文件名再保存", target.relative),
            ));
        }
        Err(err) => {
            tracing::error!(%err, path = %target.abs.display(), "创建目标文件失败");
            return Err(ApiRejection::new(
                ErrorCode::InternalError,
                "create target file failed",
                "写入项目失败，请检查目录权限后重试",
            ));
        }
    };

    // 流式复制：视频不整片进内存；失败时把半截文件删掉，否则项目里会留下一个
    // 打不开的同名文件，而用户下次保存又会撞 409。
    let copied = match tokio::io::copy(&mut source_file, &mut target_file).await {
        Ok(bytes) => bytes,
        Err(err) => {
            drop(target_file);
            let _ = tokio::fs::remove_file(&target.abs).await;
            tracing::error!(%err, path = %target.abs.display(), "复制产物到项目失败");
            return Err(ApiRejection::new(
                ErrorCode::InternalError,
                "copy media into project failed",
                "写入项目失败，请检查磁盘空间后重试",
            ));
        }
    };
    if let Err(err) = target_file.flush().await {
        drop(target_file);
        let _ = tokio::fs::remove_file(&target.abs).await;
        tracing::error!(%err, path = %target.abs.display(), "刷新产物文件失败");
        return Err(ApiRejection::new(
            ErrorCode::InternalError,
            "flush media file failed",
            "写入项目失败，请重试",
        ));
    }
    drop(target_file);

    audit::record(
        &state.pool,
        &AuditEntry::new(&conversation_id, &device.device_id, "media_save", "ok")
            .target(&target.relative)
            .detail(serde_json::json!({ "media_id": id, "bytes": copied })),
    )
    .await;

    Ok((
        StatusCode::CREATED,
        Json(MediaSaveResult {
            path: target.relative,
            bytes: copied as i64,
        }),
    ))
}

/// 校验用户给的文件名，并按记录里的 mime 补扩展名。
///
/// 只接受"纯文件名"：带目录的分支一律拒绝（落点固定），由 [`ProjectRoot::resolve_new`]
/// 再兜第二道；这里提前拦是为了给出可读文案。
fn normalize_file_name(raw: &str, mime: &str) -> Result<String, ApiRejection> {
    let name = raw.trim();

    if name.is_empty() {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "empty file name",
            "文件名不能为空",
        ));
    }
    if name.chars().count() > MAX_SAVE_NAME_CHARS {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "file name too long",
            format!("文件名太长（上限 {MAX_SAVE_NAME_CHARS} 个字符）"),
        ));
    }
    if name.starts_with('.') {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "hidden file name",
            "文件名不能以点开头",
        ));
    }
    if let Some(bad) = name
        .chars()
        .find(|ch| FORBIDDEN_NAME_CHARS.contains(ch) || ch.is_control())
    {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            format!("file name contains invalid char: {bad:?}"),
            "文件名不能包含 / \\ : * ? \" < > | 或控制字符",
        ));
    }

    let trimmed = name.trim_end_matches(['.', ' ']);
    if trimmed.is_empty() {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "empty file name",
            "文件名不能为空",
        ));
    }

    // 名字里已经带扩展名就尊重用户（他可能就是要 `.txt`），否则按真实 mime 补。
    let has_extension = std::path::Path::new(trimmed)
        .extension()
        .is_some_and(|ext| !ext.is_empty());
    if has_extension {
        Ok(trimmed.to_string())
    } else {
        Ok(format!("{trimmed}{}", extension_for(Some(mime))))
    }
}

/// 路径守卫的错误按"能不能换个名字再试"分流：越界是禁止，其余是参数不对。
fn guard_rejection(err: GuardError) -> ApiRejection {
    match err {
        GuardError::Denied(reason) => {
            ApiRejection::new(ErrorCode::Forbidden, reason.clone(), reason)
        }
        GuardError::Invalid(reason) => {
            ApiRejection::new(ErrorCode::InvalidRequest, reason.clone(), reason)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn code_of(result: Result<String, ApiRejection>) -> ErrorCode {
        match result {
            Ok(name) => panic!("应被拒绝，实际通过：{name}"),
            Err(rejection) => rejection.0.code,
        }
    }

    #[test]
    fn appends_extension_from_mime() {
        assert_eq!(
            normalize_file_name("季度复盘_generate_image_20261105-153012", "image/png")
                .expect("应通过"),
            "季度复盘_generate_image_20261105-153012.png"
        );
        assert_eq!(
            normalize_file_name("clip", "video/mp4").expect("应通过"),
            "clip.mp4"
        );
    }

    #[test]
    fn keeps_user_extension() {
        assert_eq!(
            normalize_file_name("a.txt", "image/png").expect("应通过"),
            "a.txt"
        );
    }

    #[test]
    fn trims_trailing_dots_and_spaces() {
        // Windows 会把结尾的点和空格吃掉，留着会让"同名判断"和实际落盘不一致。
        assert_eq!(
            normalize_file_name("  报告.png...  ", "image/png").expect("应通过"),
            "报告.png"
        );
    }

    #[test]
    fn rejects_empty_hidden_and_separators() {
        for bad in [
            "", "   ", ".env", "../x.png", "a/b.png", "a\\b.png", "a:b.png",
        ] {
            let code = code_of(normalize_file_name(bad, "image/png"));
            assert_eq!(code, ErrorCode::InvalidRequest, "{bad} 应被拒绝");
        }
    }

    #[test]
    fn rejects_control_chars_and_overlong_names() {
        assert_eq!(
            code_of(normalize_file_name("a\u{0}b.png", "image/png")),
            ErrorCode::InvalidRequest
        );
        assert_eq!(
            code_of(normalize_file_name(
                &"长".repeat(MAX_SAVE_NAME_CHARS + 1),
                "image/png"
            )),
            ErrorCode::InvalidRequest
        );
    }
}
