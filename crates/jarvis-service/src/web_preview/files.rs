//! 文件预览 handler。
//!
//! 入口（`preview_url` 的 `path`）只允许 `html` / `htm`，但站点内后续请求
//! 允许页面能引到的静态资源——否则一个 `index.html` 引了 `style.css` 就半残。
//! 两份名单分开写在 [`mime`] 里。
//!
//! 项目文件与草稿文件共用同一段响应逻辑（[`respond`]），差别只在根从哪来：
//! 前者查项目表，后者固定是 `{data_dir}/drafts/{conversation_id}`。

use axum::body::Body;
use axum::http::{header, HeaderValue, Method, StatusCode};
use axum::response::Response;
use tokio_util::io::ReaderStream;

use super::{decode_path, has_hidden_segment, mime, not_found, project_root, text, WebPreview};
use crate::local_tools::path_guard::ProjectRoot;

/// 项目文件预览。
pub(super) async fn serve(
    state: &WebPreview,
    project_id: &str,
    tail: &str,
    method: &Method,
) -> Response {
    let Some(root) = project_root(&state.pool, project_id).await else {
        return not_found();
    };

    respond(root, tail, method).await
}

/// 会话草稿预览。
///
/// 草稿不是项目，根不从数据库来：`{data_dir}/drafts/{conversation_id}/`。
/// 会话 id 会拼进路径，因此先按目录名合法性校验一次；
/// 目录不存在时一律 404——"没生成过文件"与"路径猜错了"对用户是同一件事。
pub(super) async fn serve_draft(
    state: &WebPreview,
    conversation_id: &str,
    tail: &str,
    method: &Method,
) -> Response {
    if crate::write_store::check_segment(conversation_id).is_err() {
        return not_found();
    }

    let dir = state.config.drafts_dir().join(conversation_id);
    let Ok(root) = ProjectRoot::new(&dir.to_string_lossy()) else {
        return not_found();
    };

    respond(root, tail, method).await
}

/// 从一个根出响应。项目与草稿只有"根怎么来"不同，之后的规则必须完全一致。
async fn respond(root: ProjectRoot, tail: &str, method: &Method) -> Response {
    if *method != Method::GET && *method != Method::HEAD {
        return text(StatusCode::METHOD_NOT_ALLOWED, "预览站只允许 GET / HEAD");
    }

    let Some(relative) = decode_path(tail) else {
        return text(StatusCode::BAD_REQUEST, "路径编码非法");
    };
    if relative.is_empty() {
        return not_found();
    }
    // 隐藏段先拦：`.env` / `.git` 不该通过浏览器面板暴露。
    if has_hidden_segment(&relative) {
        return not_found();
    }

    // `file()` 一次收掉三件事：路径穿越、越界软链接、密钥类文件名。
    // 失败一律 404：区分"不允许"和"不存在"等于告诉探测者哪里有东西。
    let Ok(path) = root.file(&relative) else {
        return not_found();
    };
    if !mime::is_static_resource(&path) {
        return text(StatusCode::FORBIDDEN, "预览站只提供网页与静态资源");
    }

    let file = match tokio::fs::File::open(&path).await {
        Ok(file) => file,
        Err(_) => return not_found(),
    };
    let size = match file.metadata().await {
        Ok(meta) => meta.len(),
        Err(_) => return not_found(),
    };

    // 流式读：大一点的主图或视频不会整个进内存。
    let body = if *method == Method::HEAD {
        Body::empty()
    } else {
        Body::from_stream(ReaderStream::new(file))
    };

    let mut response = Response::new(body);
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(mime::for_path(&path)),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(size));
    // 预览是"改完刷新就看"，任何缓存都会让人对着旧页面排查。
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    // 类型由我们声明，别让浏览器嗅探成别的可执行类型。
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    response
}
