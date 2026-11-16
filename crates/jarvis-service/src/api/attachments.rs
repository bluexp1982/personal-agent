//! 输入框附件端点。
//!
//! 上传是裸字节 + `content-type` 即 mime，不做 base64/multipart：
//! 客户端手里本来就是字节，多一层编码只会让请求体大 33%，多一层解析还多一处出错点。
//! 请求体上限由路由层单独挂 `DefaultBodyLimit`（`attachment.max_bytes` + 1MB 余量）。
//!
//! 下载只按 `id`：路径由服务端在上传时生成并写库，客户端既拿不到也传不进路径，
//! 所以这里没有"路径穿越"这一整类问题。

use axum::body::{Body, Bytes};
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;

use super::error::ApiRejection;
use crate::attachment::{self, AttachmentError};
use crate::auth::AuthDevice;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct UploadQuery {
    /// 原始文件名（客户端做 URL 编码）。只用于展示与下载时的存盘名。
    pub name: Option<String>,
    /// 图片像素宽高。客户端解码缩略图时已经知道，服务端不必再解析一遍。
    pub w: Option<u32>,
    pub h: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct ContentQuery {
    /// 带上 `?download=true` 时按附件下载（浏览器存盘），否则内联展示。
    #[serde(default)]
    pub download: bool,
}

/// 上传一枚附件，返回登记后的元信息。
pub async fn upload(
    State(state): State<AppState>,
    axum::Extension(device): axum::Extension<AuthDevice>,
    Query(query): Query<UploadQuery>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<protocol::Attachment>), ApiRejection> {
    let mime = mime_of(&headers);
    let name = attachment::sanitize_name(query.name.as_deref());

    // 这里先判一次而不是只靠 `record_upload`：请求体已经完整读进内存了，
    // 但能省掉一次磁盘写。`DefaultBodyLimit` 留的 1MB 余量就是为这一步。
    let bytes = i64::try_from(body.len()).unwrap_or(i64::MAX);
    let max = state.config.attachment.max_bytes;
    if bytes > max {
        return Err(ApiRejection::new(
            protocol::ErrorCode::PayloadTooLarge,
            format!("attachment too large: {bytes} > {max}"),
            format!(
                "文件超过服务端上限（{}），请换一个小一些的文件",
                attachment::human_size(max)
            ),
        ));
    }

    let attachment = attachment::record_upload(
        &state,
        &device.device_id,
        &name,
        &mime,
        query.w,
        query.h,
        &body,
    )
    .await?;

    Ok((StatusCode::CREATED, Json(attachment)))
}

/// 读取附件正文。
pub async fn content(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ContentQuery>,
) -> Result<Response, ApiRejection> {
    let (attachment, bytes) = attachment::body_of(&state, &id).await?;

    let length = bytes.len();
    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, attachment.mime.clone())
        .header(header::CONTENT_LENGTH, length)
        // 内容按 id 不可变：同一个 id 永远是同一份字节，客户端可以放心长期缓存，
        // 气泡里的图片也就不必每次进会话都重下一遍。
        .header(
            header::CACHE_CONTROL,
            "private, max-age=31536000, immutable",
        )
        .header("x-content-type-options", "nosniff");

    if query.download {
        // 文件名来自用户，可能含引号或非 ASCII：拼不进 header 就退回不带名字。
        let disposition = HeaderValue::from_str(&format!(
            "attachment; filename=\"{}\"",
            attachment.name.replace('"', "_")
        ))
        .unwrap_or_else(|_| HeaderValue::from_static("attachment"));
        builder = builder.header(header::CONTENT_DISPOSITION, disposition);
    }

    builder
        .body(Body::from(bytes))
        .map(|response| response.into_response())
        .map_err(|err| {
            tracing::error!(%err, attachment_id = %id, "构造附件下载响应失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "attachment response failed",
                "下载失败，请重试",
            )
        })
}

/// 删除一枚还没发送的附件（用户撤掉 chip 时清文件）。
pub async fn delete(
    State(state): State<AppState>,
    axum::Extension(device): axum::Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    attachment::delete(&state, &device.device_id, &id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// 取请求体声明的 mime。缺省 `application/octet-stream`，参数段（`; charset=...`）丢掉。
fn mime_of(headers: &HeaderMap) -> String {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.split(';').next().unwrap_or_default().trim())
        .filter(|value| !value.is_empty())
        .unwrap_or("application/octet-stream")
        .to_ascii_lowercase()
}

impl From<AttachmentError> for ApiRejection {
    fn from(err: AttachmentError) -> Self {
        match err {
            AttachmentError::Db(source) => {
                tracing::error!(%source, "附件数据库操作失败");
                Self::new(
                    protocol::ErrorCode::InternalError,
                    "attachment storage failed",
                    "服务内部错误，请查看日志",
                )
            }
            AttachmentError::NotFound => Self::new(
                protocol::ErrorCode::NotFound,
                "attachment not found",
                "附件不存在或已被清理，请重新添加",
            ),
            AttachmentError::Empty => Self::new(
                protocol::ErrorCode::InvalidRequest,
                "empty attachment body",
                "这个文件是空的，没法作为附件",
            ),
            AttachmentError::TooLarge { bytes, max } => Self::new(
                protocol::ErrorCode::PayloadTooLarge,
                format!("attachment too large: {bytes} > {max}"),
                format!(
                    "文件超过服务端上限（{}），请换一个小一些的文件",
                    attachment::human_size(max)
                ),
            ),
            AttachmentError::TooMany { count, max } => Self::new(
                protocol::ErrorCode::InvalidRequest,
                format!("too many attachments: {count} > {max}"),
                format!("一条消息最多带 {max} 个附件，请先移除一些"),
            ),
            AttachmentError::AlreadyBound => Self::new(
                protocol::ErrorCode::Conflict,
                "attachment already bound to a message",
                "这个附件已经发过了，请重新添加",
            ),
            AttachmentError::NotOwned => Self::new(
                protocol::ErrorCode::Forbidden,
                "attachment belongs to another device",
                "这个附件不属于当前设备，请重新添加",
            ),
            AttachmentError::Invalid(reason) => Self::new(
                protocol::ErrorCode::InvalidRequest,
                format!("invalid attachment request: {reason}"),
                "附件参数不正确",
            ),
            AttachmentError::Store(reason) => {
                tracing::error!(%reason, "附件落盘失败");
                Self::new(
                    protocol::ErrorCode::InternalError,
                    format!("attachment storage failed: {reason}"),
                    "附件保存失败，请重试",
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::mime_of;
    use axum::http::{header, HeaderMap, HeaderValue};

    fn headers(value: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(header::CONTENT_TYPE, HeaderValue::from_str(value).unwrap());
        headers
    }

    #[test]
    fn mime_drops_parameters_and_lowercases() {
        assert_eq!(mime_of(&headers("image/PNG; charset=binary")), "image/png");
        assert_eq!(mime_of(&headers("text/markdown")), "text/markdown");
    }

    #[test]
    fn missing_content_type_falls_back_to_octet_stream() {
        assert_eq!(mime_of(&HeaderMap::new()), "application/octet-stream");
    }
}
