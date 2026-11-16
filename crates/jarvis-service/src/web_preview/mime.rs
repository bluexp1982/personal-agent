//! 预览站的扩展名白名单与 MIME 表。
//!
//! 为什么不引 `mime_guess`：需要的类型是固定的二十来种，多一个依赖换来的
//! 是把整张 IANA 表编进产物。口径与客户端 `LocalStaticServer` 保持一致，
//! 但**去掉了 pdf**：预览站只服务网页，PDF 交给系统应用。

use std::path::Path;

/// 站点内可以取到的静态资源扩展名。
///
/// 入口（`preview_url` 的 `path`）只允许 html/htm，这一层是"页面能引到的资源"。
/// 分开两份名单是必要的：只给入口白名单会让引了 css 的页面半残，
/// 而把所有扩展名都放进来就等于把整个项目目录当文件服务器。
const STATIC_EXTENSIONS: &[&str] = &[
    "html", "htm", "css", "js", "mjs", "json", "map", "svg", "png", "jpg", "jpeg", "gif", "webp",
    "ico", "woff", "woff2", "ttf", "otf", "wasm", "txt", "md", "mp4", "webm",
];

/// 小写扩展名（不含点）。没有扩展名时返回空串。
pub(crate) fn extension(path: &Path) -> String {
    path.extension()
        .map(|ext| ext.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default()
}

/// 是否允许通过预览站取到。
pub(crate) fn is_static_resource(path: &Path) -> bool {
    STATIC_EXTENSIONS.contains(&extension(path).as_str())
}

/// 入口白名单：只允许网页本身。
///
/// 比 [`is_static_resource`] 窄得多，因为入口是**模型点名**的：
/// 资源是页面自己引的，入口是模型挑的，两者的可信度不一样。
pub(crate) fn is_entry(path: &Path) -> bool {
    matches!(extension(path).as_str(), "html" | "htm")
}

/// 按扩展名给 Content-Type。
///
/// 文本类一律带 `charset=utf-8`：不带时浏览器按本地默认编码猜，
/// 中文页面在部分 WebView 上会变成乱码。
pub(crate) fn for_path(path: &Path) -> &'static str {
    match extension(path).as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json",
        "map" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "wasm" => "application/wasm",
        "txt" | "md" => "text/plain; charset=utf-8",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_static_resources_case_insensitively() {
        assert!(is_static_resource(Path::new("index.html")));
        assert!(is_static_resource(Path::new("STYLE.CSS")));
        assert!(is_static_resource(Path::new("a/b/app.js")));
        assert!(!is_static_resource(Path::new("main.rs")));
        assert!(!is_static_resource(Path::new("report.pdf")));
        assert!(!is_static_resource(Path::new("Makefile")));
    }

    #[test]
    fn entry_is_narrower_than_resources() {
        assert!(is_entry(Path::new("index.html")));
        assert!(is_entry(Path::new("REPORT.HTM")));
        // 能当资源，不能当入口：模型不该能点名这些。
        assert!(!is_entry(Path::new("app.js")));
        assert!(!is_entry(Path::new("logo.svg")));
        assert!(!is_entry(Path::new("report.pdf")));
    }

    #[test]
    fn html_and_scripts_carry_utf8_charset() {
        assert_eq!(for_path(Path::new("a.html")), "text/html; charset=utf-8");
        assert_eq!(
            for_path(Path::new("a.mjs")),
            "text/javascript; charset=utf-8"
        );
        assert_eq!(for_path(Path::new("a.png")), "image/png");
        assert_eq!(
            for_path(Path::new("unknown.bin")),
            "application/octet-stream"
        );
    }
}
