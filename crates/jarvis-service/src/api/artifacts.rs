//! 产物端点：元信息与内容下载。
//!
//! 元信息与正文分开取：列表/详情页只需要几十字节的元信息，
//! 正文按需拉取，避免打开任务详情时把每个产物的全文都读一遍。

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use protocol::{Artifact, ErrorCode};

use super::error::ApiRejection;
use crate::artifact_store::{extension_for, ArtifactStore, StoreError};
use crate::state::AppState;

pub async fn get(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Artifact>, ApiRejection> {
    // JOIN 任务表：已逻辑删除的任务，其产物也应当像不存在一样。
    let row = sqlx::query_as::<_, (String, String, String, i64, Option<String>, i64)>(
        "SELECT a.id, a.task_id, a.kind, a.size, a.mime, a.created_at \
         FROM artifacts a JOIN tasks t ON t.id = a.task_id \
         WHERE a.id = ? AND t.deleted_at IS NULL",
    )
    .bind(&id)
    .fetch_optional(&state.pool)
    .await?;

    let (id, task_id, kind, size, mime, created_at) = row.ok_or_else(artifact_missing)?;

    Ok(Json(Artifact {
        id,
        task_id,
        kind,
        size,
        mime,
        created_at,
    }))
}

/// 下载产物正文。
///
/// 返回原始字节而不是 JSON：客户端要的是文件本身，「另存为」不该再做一次解码。
pub async fn content(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Response, ApiRejection> {
    let row = sqlx::query_as::<_, (String, String, Option<String>)>(
        "SELECT a.path, a.kind, a.mime \
         FROM artifacts a JOIN tasks t ON t.id = a.task_id \
         WHERE a.id = ? AND t.deleted_at IS NULL",
    )
    .bind(&id)
    .fetch_optional(&state.pool)
    .await?;

    let (path, kind, mime) = row.ok_or_else(artifact_missing)?;

    let store = ArtifactStore::new(state.config.artifacts_dir());
    let bytes = match store.read(&path).await {
        Ok(bytes) => bytes,
        Err(StoreError::Missing) => {
            // 记录在、文件没了：这是"被清理过"而不是"不存在"，提示要区分开。
            tracing::warn!(artifact_id = %id, %path, "产物记录存在但文件缺失");
            return Err(ApiRejection::new(
                ErrorCode::NotFound,
                "artifact file missing",
                "产物文件已被清理，无法下载",
            ));
        }
        Err(StoreError::InvalidPath(reason)) => {
            tracing::error!(artifact_id = %id, %path, %reason, "产物路径非法");
            return Err(ApiRejection::new(
                ErrorCode::InternalError,
                "artifact path invalid",
                "产物路径异常，请查看服务日志",
            ));
        }
        Err(err) => {
            tracing::error!(%err, artifact_id = %id, "读取产物失败");
            return Err(ApiRejection::new(
                ErrorCode::InternalError,
                "artifact read failed",
                "读取产物失败，请重试",
            ));
        }
    };

    let mime = mime.unwrap_or_else(|| "application/octet-stream".to_string());
    let file_name = format!("{}-{id}{}", sanitize(&kind), extension_for(Some(&mime)));
    let disposition = HeaderValue::from_str(&format!("attachment; filename=\"{file_name}\""))
        .unwrap_or_else(|_| HeaderValue::from_static("attachment"));

    let response = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, mime)
        .header(header::CONTENT_DISPOSITION, disposition)
        .header(header::CONTENT_LENGTH, bytes.len())
        // 产物内容来自外部抓取，绝不允许浏览器按嗅探结果执行它。
        .header("x-content-type-options", "nosniff")
        .body(Body::from(bytes))
        .map_err(|err| {
            tracing::error!(%err, "构造产物下载响应失败");
            ApiRejection::new(
                ErrorCode::InternalError,
                "artifact response failed",
                "下载失败，请重试",
            )
        })?;

    Ok(response.into_response())
}

fn artifact_missing() -> ApiRejection {
    ApiRejection::new(
        ErrorCode::NotFound,
        "artifact not found",
        "产物不存在或已被清理",
    )
}

/// 文件名只保留安全字符：`content-disposition` 是响应头，任何控制字符或
/// 引号都可能被用来截断头部，所以宁可替换成下划线也不原样透出。
fn sanitize(value: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "artifact".to_string()
    } else {
        cleaned
    }
}

#[cfg(test)]
mod tests {
    use super::sanitize;

    #[test]
    fn sanitize_strips_header_breakers() {
        assert_eq!(sanitize("plan_table"), "plan_table");
        assert_eq!(sanitize("a\";\nX: y"), "a___X__y");
        assert_eq!(sanitize(""), "artifact");
        assert_eq!(sanitize("产物"), "__");
    }
}
