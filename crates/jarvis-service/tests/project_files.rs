//! 项目文件树与文本预览端点的集成测试。
//!
//! 覆盖：目录与文件混合排序、隐藏项开关、越界拒绝、未知项目 404、
//! 文本读取与二进制拒绝。边界相关的细枝末节（软链接、截断）在
//! `project_files` 的单元测试里覆盖，这里只确保 HTTP 层接对了。

mod common;

use std::path::PathBuf;

use axum::http::StatusCode;

async fn project_dir(ctx: &common::TestContext, id: &str) -> PathBuf {
    let project = jarvis_service::project::get(&ctx.state.pool, id)
        .await
        .expect("查询项目失败")
        .expect("项目不存在");
    PathBuf::from(project.path)
}

fn names(body: &serde_json::Value) -> Vec<String> {
    body["entries"]
        .as_array()
        .expect("entries 不是数组")
        .iter()
        .filter_map(|entry| entry["name"].as_str().map(str::to_string))
        .collect()
}

#[tokio::test]
async fn lists_project_files_and_honours_hidden_toggle() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-files-list").await;
    let id = ctx.work_project("files-list").await;
    let dir = project_dir(&ctx, &id).await;

    std::fs::create_dir_all(dir.join("src")).expect("建目录失败");
    std::fs::write(dir.join("main.rs"), "fn main() {}\n").expect("写文件失败");
    std::fs::write(dir.join(".env"), "SECRET=1\n").expect("写隐藏文件失败");

    let response = ctx
        .get_json(&format!("/api/projects/{id}/files"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(names(&body), vec!["src", "main.rs"], "目录优先、隐藏项不列");
    assert_eq!(body["path"], dir.to_string_lossy().as_ref());
    assert_eq!(body["entries"][0]["kind"], "dir");
    assert_eq!(body["entries"][1]["kind"], "file");
    assert_eq!(body["entries"][1]["size"], 13);

    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/files?show_hidden=true"),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert!(
        names(&body).contains(&".env".to_string()),
        "打开开关后隐藏文件应出现：{body}"
    );
}

#[tokio::test]
async fn rejects_subdirectory_outside_project() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-files-escape").await;
    let id = ctx.work_project("files-escape").await;

    let response = ctx
        .get_json(&format!("/api/projects/{id}/files?path=/"), &token)
        .await;
    assert_eq!(
        response.status(),
        StatusCode::BAD_REQUEST,
        "项目外的路径必须被拒绝"
    );
}

#[tokio::test]
async fn unknown_project_is_not_found() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-files-404").await;

    let response = ctx
        .get_json("/api/projects/ws_missing/files", &token)
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn reads_text_and_rejects_binary() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-files-read").await;
    let id = ctx.work_project("files-read").await;
    let dir = project_dir(&ctx, &id).await;

    let text_file = dir.join("note.txt");
    std::fs::write(&text_file, "hello 世界").expect("写文件失败");
    let binary_file = dir.join("blob.bin");
    std::fs::write(&binary_file, [0x00, 0x01, 0xFF]).expect("写文件失败");

    let response = ctx
        .get_json(
            &format!(
                "/api/projects/{id}/file?path={}",
                text_file.to_string_lossy()
            ),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["text"], "hello 世界");
    assert_eq!(body["truncated"], false);

    let response = ctx
        .get_json(
            &format!(
                "/api/projects/{id}/file?path={}",
                binary_file.to_string_lossy()
            ),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("二进制"),
        "二进制提示要能直接展示：{body}"
    );
}

/// 读取响应体的原始字节。
async fn body_bytes(response: axum::response::Response) -> Vec<u8> {
    use http_body_util::BodyExt;

    response
        .into_body()
        .collect()
        .await
        .expect("读取响应体失败")
        .to_bytes()
        .to_vec()
}

#[tokio::test]
async fn serves_raw_bytes_with_declared_type() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-raw-serve").await;
    let id = ctx.work_project("files-raw-serve").await;
    let dir = project_dir(&ctx, &id).await;

    // PNG 魔数即可：服务端不解码，只按扩展名声明的类型转发。
    let png = dir.join("screen.PNG");
    let payload: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    std::fs::write(&png, payload).expect("写文件失败");

    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/raw?path={}", png.to_string_lossy()),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers()["content-type"], "image/png",
        "类型按扩展名给，大小写不敏感"
    );
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert_eq!(response.headers()["x-content-type-options"], "nosniff");
    assert_eq!(body_bytes(response).await, payload, "原始字节不能被改写");
}

#[tokio::test]
async fn raw_falls_back_to_octet_stream_for_unknown_extension() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-raw-unknown").await;
    let id = ctx.work_project("files-raw-unknown").await;
    let dir = project_dir(&ctx, &id).await;

    let blob = dir.join("data.xyz");
    std::fs::write(&blob, [0x00, 0x01, 0xFF]).expect("写文件失败");

    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/raw?path={}", blob.to_string_lossy()),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "application/octet-stream");
}

#[tokio::test]
async fn raw_endpoint_requires_token() {
    let ctx = common::setup().await;
    let id = ctx.work_project("files-raw-auth").await;

    let response = ctx
        .call(common::get(&format!(
            "/api/projects/{id}/raw?path=/etc/hosts"
        )))
        .await;
    assert_eq!(
        response.status(),
        StatusCode::UNAUTHORIZED,
        "未带令牌不能读任何文件"
    );
}

#[tokio::test]
async fn raw_rejects_escape_and_oversized_files() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("ws-raw-guard").await;
    let id = ctx.work_project("files-raw-guard").await;
    let dir = project_dir(&ctx, &id).await;

    let response = ctx
        .get_json(&format!("/api/projects/{id}/raw?path=/etc/hosts"), &token)
        .await;
    assert_eq!(
        response.status(),
        StatusCode::BAD_REQUEST,
        "项目外的路径必须被拒绝"
    );

    // 稀疏文件：只改元数据，测试不必真的写 64 MB。
    let huge = dir.join("huge.pdf");
    let handle = std::fs::File::create(&huge).expect("建文件失败");
    handle
        .set_len(jarvis_service::project_files::MAX_RAW_BYTES + 1)
        .expect("设置文件长度失败");
    drop(handle);

    let response = ctx
        .get_json(
            &format!("/api/projects/{id}/raw?path={}", huge.to_string_lossy()),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    let hint = body["hint"].as_str().unwrap_or_default();
    assert!(hint.contains("另存"), "超限提示要能直接展示：{body}");
    assert!(hint.contains("64 MB"), "提示要写明上限：{body}");

    // 导出路径不受上限约束：打不开的大文件仍然要能存下来。
    let response = ctx
        .get_json(
            &format!(
                "/api/projects/{id}/raw?download=true&path={}",
                huge.to_string_lossy()
            ),
            &token,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK, "download=true 应跳过上限");
}
