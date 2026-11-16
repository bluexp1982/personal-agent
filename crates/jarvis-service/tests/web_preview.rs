//! 预览站与运行代理的端到端测试。
//!
//! 真的绑一个回环端口、真的发 http 请求：这一层要验证的正是"浏览器会怎么看到"，
//! 用 oneshot 打 Router 测不出流式响应、HEAD、MIME 与代理分流。

mod common;

use std::path::PathBuf;
use std::sync::Arc;

use jarvis_service::web_preview::WebPreview;

async fn project_dir(ctx: &common::TestContext, id: &str) -> PathBuf {
    let project = jarvis_service::project::get(&ctx.state.pool, id)
        .await
        .expect("查询项目失败")
        .expect("项目不存在");
    PathBuf::from(project.path)
}

async fn start(ctx: &common::TestContext) -> Arc<WebPreview> {
    let preview = WebPreview::start(ctx.state.pool.clone(), ctx.state.config.clone())
        .await
        .expect("预览站启动失败");
    preview
}

/// 假的 dev server：`tag` 就是它的响应正文，用来分辨请求去了哪个端口。
async fn fake_upstream(tag: &'static str) -> (u16, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定上游失败");
    let port = listener.local_addr().expect("读取上游端口失败").port();
    let app = axum::Router::new().fallback(move || async move { tag });
    let handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    (port, handle)
}

#[tokio::test]
async fn serves_html_with_utf8_and_no_store() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-html").await;
    let root = project_dir(&ctx, &id).await;
    std::fs::write(root.join("index.html"), "<h1>你好</h1>").expect("写文件失败");

    let preview = start(&ctx).await;
    let response = reqwest::get(preview.file_url(&id, "index.html"))
        .await
        .expect("请求失败");

    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers()["content-type"],
        "text/html; charset=utf-8",
        "中文页面必须带 charset，否则部分 WebView 会按本地编码猜"
    );
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert_eq!(response.headers()["x-content-type-options"], "nosniff");
    let body = response.text().await.expect("读正文失败");
    assert!(body.contains("你好"), "{body}");

    preview.stop();
}

#[tokio::test]
async fn serves_sibling_static_resources() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-assets").await;
    let root = project_dir(&ctx, &id).await;
    std::fs::write(root.join("app.js"), "console.log(1)").expect("写文件失败");
    std::fs::write(root.join("theme.css"), "body{}").expect("写文件失败");

    let preview = start(&ctx).await;

    let js = reqwest::get(preview.file_url(&id, "app.js"))
        .await
        .expect("请求失败");
    assert_eq!(js.status(), 200);
    assert_eq!(
        js.headers()["content-type"],
        "text/javascript; charset=utf-8",
        "模块脚本必须带 JS MIME，否则 WKWebView 会拒绝执行"
    );

    let css = reqwest::get(preview.file_url(&id, "theme.css"))
        .await
        .expect("请求失败");
    assert_eq!(css.status(), 200);
    assert_eq!(css.headers()["content-type"], "text/css; charset=utf-8");

    preview.stop();
}

#[tokio::test]
async fn head_returns_length_without_body() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-head").await;
    let root = project_dir(&ctx, &id).await;
    std::fs::write(root.join("index.html"), "<h1>hi</h1>").expect("写文件失败");

    let preview = start(&ctx).await;
    let client = reqwest::Client::new();
    let response = client
        .head(preview.file_url(&id, "index.html"))
        .send()
        .await
        .expect("请求失败");

    assert_eq!(response.status(), 200);
    assert!(response.headers()["content-length"] != "0");
    assert!(
        response.text().await.expect("读正文失败").is_empty(),
        "HEAD 不能回正文"
    );

    preview.stop();
}

#[tokio::test]
async fn rejects_wrong_token_traversal_and_hidden_files() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-deny").await;
    let root = project_dir(&ctx, &id).await;
    std::fs::write(root.join("index.html"), "<h1>ok</h1>").expect("写文件失败");
    std::fs::write(root.join(".env"), "SECRET=1").expect("写文件失败");
    std::fs::write(root.join("main.rs"), "fn main() {}").expect("写文件失败");

    let preview = start(&ctx).await;
    let client = reqwest::Client::new();

    let good = preview.file_url(&id, "index.html");
    let bad_token = format!(
        "http://127.0.0.1:{}/f/{}/{}",
        preview.port(),
        "0".repeat(24),
        id
    );
    let response = client.get(&bad_token).send().await.expect("请求失败");
    assert_eq!(response.status(), 404, "token 不对必须 404");

    for path in ["%2e%2e/%2e%2e/etc/hosts", ".env", ".git/config", "main.rs"] {
        let url = format!(
            "http://127.0.0.1:{}/f/{}/{}/{}",
            preview.port(),
            token_of(&good),
            id,
            path
        );
        let response = client.get(&url).send().await.expect("请求失败");
        assert!(
            response.status() == 404 || response.status() == 403,
            "{path} 不该被取到，实际 {}",
            response.status()
        );
    }

    preview.stop();
}

#[tokio::test]
async fn missing_project_is_not_found() {
    let ctx = common::setup().await;
    let _ = ctx.work_project("preview-noproj").await;
    let preview = start(&ctx).await;

    let url = preview.file_url("prj_does_not_exist", "index.html");
    let response = reqwest::get(url).await.expect("请求失败");
    assert_eq!(response.status(), 404);

    preview.stop();
}

#[tokio::test]
async fn run_proxy_splits_frontend_and_api() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-proxy").await;
    let root = project_dir(&ctx, &id).await;

    let (front, front_task) = fake_upstream("frontend").await;
    let (back, back_task) = fake_upstream("backend").await;

    std::fs::create_dir_all(root.join(".jarvis")).expect("建目录失败");
    std::fs::write(
        root.join(".jarvis").join("run.json"),
        format!(
            r#"{{"frontend":{front},"backend":{back},"api_prefix":"/api"}}"#
        ),
    )
    .expect("写配置失败");

    let preview = start(&ctx).await;
    let base = preview.run_url(&id);
    assert!(base.ends_with('/'), "代理根必须以斜杠结尾：{base}");

    let page = reqwest::get(&base).await.expect("请求失败");
    assert_eq!(page.status(), 200);
    assert_eq!(page.text().await.expect("读正文失败"), "frontend");

    let api = reqwest::get(format!("{base}api/users")).await.expect("请求失败");
    assert_eq!(api.status(), 200);
    assert_eq!(api.text().await.expect("读正文失败"), "backend");

    // 前缀必须按段匹配：`/apidocs` 不能被当成 API。
    let docs = reqwest::get(format!("{base}apidocs")).await.expect("请求失败");
    assert_eq!(docs.text().await.expect("读正文失败"), "frontend");

    preview.stop();
    front_task.abort();
    back_task.abort();
}

#[tokio::test]
async fn run_proxy_explains_missing_config() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-nocfg").await;
    let preview = start(&ctx).await;

    let response = reqwest::get(preview.run_url(&id)).await.expect("请求失败");
    assert_eq!(
        response.status(),
        502,
        "缺配置属于服务端没法路由，不是 404"
    );
    let body = response.text().await.expect("读正文失败");
    assert!(body.contains(".jarvis/run.json"), "要说清该建哪个文件: {body}");

    preview.stop();
}

#[tokio::test]
async fn run_proxy_refuses_reserved_ports() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-reserved").await;
    let root = project_dir(&ctx, &id).await;

    // 指向 sshd 的端口：配置写错时不能把浏览器导到本机管理面上。
    std::fs::create_dir_all(root.join(".jarvis")).expect("建目录失败");
    std::fs::write(
        root.join(".jarvis").join("run.json"),
        r#"{"frontend":22}"#,
    )
    .expect("写配置失败");

    let preview = start(&ctx).await;
    let response = reqwest::get(preview.run_url(&id)).await.expect("请求失败");
    assert_eq!(response.status(), 502);
    let body = response.text().await.expect("读正文失败");
    assert!(body.contains("冲突"), "要说明为什么拒绝: {body}");

    preview.stop();
}

/// 把绝对路径塞进 query：只处理这三种字符，测试路径里不会有别的。
fn query_encode(value: &str) -> String {
    value
        .replace('%', "%25")
        .replace('/', "%2F")
        .replace(' ', "%20")
}

#[tokio::test]
async fn preview_endpoint_returns_loadable_url_for_html() {
    let mut ctx = common::setup().await;
    let id = ctx.work_project("preview-api").await;
    let root = project_dir(&ctx, &id).await;
    std::fs::write(root.join("clock.html"), "<h1>clock</h1>").expect("写文件失败");

    let preview = WebPreview::start(ctx.state.pool.clone(), ctx.state.config.clone())
        .await
        .expect("预览站启动失败");
    ctx.state.web_preview = Some(preview.clone());

    let (_, token) = ctx.pair_and_login("preview-api").await;
    let path = root.join("clock.html").to_string_lossy().to_string();
    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/preview?path={}", query_encode(&path)),
            &token,
        )
        .await;
    assert_eq!(response.status(), 200);

    let body = common::body_json(response).await;
    let url = body["url"].as_str().expect("缺少 url");
    assert!(
        url.starts_with(&format!("http://127.0.0.1:{}/f/", preview.port())),
        "预览地址应指向预览站：{url}"
    );
    assert!(url.ends_with("/clock.html"), "{url}");
    assert_eq!(
        body["display"], "ws-preview-api/clock.html",
        "地址栏显示的是项目名 + 相对路径，不含令牌：{body}"
    );

    preview.stop();
}

#[tokio::test]
async fn preview_endpoint_rejects_non_html() {
    let mut ctx = common::setup().await;
    let id = ctx.work_project("preview-api-md").await;
    let root = project_dir(&ctx, &id).await;
    std::fs::write(root.join("notes.md"), "# n").expect("写文件失败");

    let preview = WebPreview::start(ctx.state.pool.clone(), ctx.state.config.clone())
        .await
        .expect("预览站启动失败");
    ctx.state.web_preview = Some(preview.clone());

    let (_, token) = ctx.pair_and_login("preview-api-md").await;
    let path = root.join("notes.md").to_string_lossy().to_string();
    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/preview?path={}", query_encode(&path)),
            &token,
        )
        .await;

    assert_eq!(response.status(), 400, "非网页必须是 400，不是 500");
    let body = common::body_json(response).await;
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("html"),
        "要说清只支持 html/htm：{body}"
    );

    preview.stop();
}

#[tokio::test]
async fn preview_endpoint_reports_preview_unavailable() {
    let ctx = common::setup().await;
    let id = ctx.work_project("preview-api-down").await;
    let (_, token) = ctx.pair_and_login("preview-api-down").await;

    // 故意不启动预览站：客户端要拿到"服务端没准备好"，而不是一个空地址。
    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/preview?path=index.html"),
            &token,
        )
        .await;

    assert_eq!(response.status(), 503);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "browser_unavailable", "{body}");
}

/// 从完整 URL 里取出 token 段。测试用，不想为它把 token 暴露成公开字段。
fn token_of(url: &str) -> String {
    let parts: Vec<&str> = url.split('/').collect();
    // http:/""127.0.0.1:port/f/token/project/index.html
    parts
        .iter()
        .position(|part| *part == "f")
        .and_then(|index| parts.get(index + 1))
        .map(|token| (*token).to_string())
        .expect("URL 里应有 token 段")
}
