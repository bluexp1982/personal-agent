//! 会话产物「另存到项目」的集成测试。
//!
//! 打真实 Router，覆盖五件事：
//! 1. 成功复制进 `<项目>/artifacts/`，字节与源一致、且能再从 `/raw` 读回来；
//! 2. 同名不静默覆盖（409），源文件与目标文件都不变；
//! 3. 名字没扩展名时按记录里的 mime 补上；
//! 4. 带目录分隔符的名字被拒（落点固定，不允许改路径）;
//! 5. 无归属项目的会话产物、以及不存在的 id 各自的错误码。

mod common;

use axum::http::StatusCode;
use jarvis_service::artifact_store::ArtifactStore;
use jarvis_service::media::records;
use protocol::MediaAsset;

/// 一张"像图片"的最小字节：只验证落盘与复制，不参与解码。
const PNG_BYTES: [u8; 16] = [
    0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, b'I', b'H', b'D', b'R',
];

struct Seeded {
    media_id: String,
    project_id: Option<String>,
    project_dir: std::path::PathBuf,
}

/// 建会话 + 在产物库与 `media_assets` 里各放一份，模拟"已经生成过一张图"。
async fn seed(
    ctx: &common::TestContext,
    token: &str,
    tag: &str,
    with_project: bool,
) -> Seeded {
    let project_id = if with_project {
        Some(ctx.work_project(tag).await)
    } else {
        None
    };

    let mut payload = serde_json::json!({ "title": "季度复盘" });
    if let Some(id) = &project_id {
        payload["project_id"] = serde_json::json!(id);
    }
    let response = ctx.post_json("/api/conversations", token, &payload).await;
    assert_eq!(response.status(), StatusCode::CREATED, "建会话失败");
    let conversation_id = common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();

    let media_id = format!("img_{tag}");
    let store = ArtifactStore::new(ctx.state.config.artifacts_dir());
    let (relative, _) = store
        .save_bytes(&conversation_id, &media_id, Some("image/png"), &PNG_BYTES)
        .await
        .expect("写入产物失败");

    let asset = MediaAsset {
        id: media_id.clone(),
        kind: "image".to_string(),
        mime: "image/png".to_string(),
        bytes: PNG_BYTES.len() as i64,
        model: "qwen-image-3.0".to_string(),
        prompt: "一只橘猫".to_string(),
        width: Some(8),
        height: Some(8),
        duration_ms: None,
        resolution: None,
        created_at: 1_700_000_000_000,
    };
    records::insert_asset(&ctx.state.pool, &conversation_id, &asset, &relative)
        .await
        .expect("写入媒体记录失败");

    Seeded {
        media_id,
        project_id,
        project_dir: ctx.dir.path().join(format!("ws-{tag}")),
    }
}

async fn post_save(
    ctx: &common::TestContext,
    token: &str,
    media_id: &str,
    name: &str,
) -> axum::response::Response {
    ctx.post_json(
        &format!("/api/media/{media_id}/save"),
        token,
        &serde_json::json!({ "name": name }),
    )
    .await
}

#[tokio::test]
async fn saves_into_project_artifacts() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-save-ok").await;
    let seeded = seed(&ctx, &token, "media-save-ok", true).await;

    let response = post_save(
        &ctx,
        &token,
        &seeded.media_id,
        "季度复盘_generate_image_20261105-153012.png",
    )
    .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = common::body_json(response).await;
    assert_eq!(
        body["path"],
        "artifacts/季度复盘_generate_image_20261105-153012.png"
    );
    assert_eq!(body["bytes"], PNG_BYTES.len() as i64);

    let saved = seeded
        .project_dir
        .join("artifacts")
        .join("季度复盘_generate_image_20261105-153012.png");
    assert_eq!(
        std::fs::read(&saved).expect("目标文件应存在"),
        PNG_BYTES,
        "复制后的字节应与源一致"
    );

    // 再从项目文件端点读一遍：证明它真的进了项目边界，而不是只写了个文件名。
    // 该端点按文件树的口径要**绝对路径**（客户端点击文件树时拿到的就是绝对路径）。
    let project_id = seeded.project_id.expect("应有项目");
    let absolute = seeded
        .project_dir
        .canonicalize()
        .expect("项目目录应存在")
        .join("artifacts")
        .join("季度复盘_generate_image_20261105-153012.png");
    let response = ctx
        .call(common::authed_get(
            &format!(
                "/api/projects/{project_id}/raw?path={}",
                urlencoding(&absolute.to_string_lossy())
            ),
            &token,
        ))
        .await;
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取项目文件失败");
    assert_eq!(
        status,
        StatusCode::OK,
        "读回项目文件失败：{}",
        String::from_utf8_lossy(&bytes)
    );
    assert_eq!(bytes.to_vec(), PNG_BYTES);
}

#[tokio::test]
async fn duplicate_name_is_conflict_and_keeps_content() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-save-dup").await;
    let seeded = seed(&ctx, &token, "media-save-dup", true).await;

    let response = post_save(&ctx, &token, &seeded.media_id, "same.png").await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let response = post_save(&ctx, &token, &seeded.media_id, "same.png").await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "conflict", "{body}");
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("换个文件名"),
        "冲突提示要可执行：{body}"
    );

    let saved = seeded.project_dir.join("artifacts").join("same.png");
    assert_eq!(
        std::fs::read(&saved).expect("首次保存的文件应保留"),
        PNG_BYTES,
        "撞名不能把已有文件截断"
    );
}

#[tokio::test]
async fn missing_extension_is_filled_from_mime() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-save-ext").await;
    let seeded = seed(&ctx, &token, "media-save-ext", true).await;

    let response = post_save(&ctx, &token, &seeded.media_id, "季度复盘").await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = common::body_json(response).await;
    assert_eq!(body["path"], "artifacts/季度复盘.png");
}

#[tokio::test]
async fn rejects_names_with_directory_parts() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-save-bad").await;
    let seeded = seed(&ctx, &token, "media-save-bad", true).await;

    for bad in ["../escape.png", "nested/a.png", ".hidden.png", "  "] {
        let response = post_save(&ctx, &token, &seeded.media_id, bad).await;
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "{bad} 应被拒绝"
        );
    }

    // 一个都不该写出去。
    let dir = seeded.project_dir.join("artifacts");
    assert!(
        !dir.exists() || std::fs::read_dir(&dir).expect("列目录失败").next().is_none(),
        "非法名字不应产生文件：{dir:?}"
    );
}

#[tokio::test]
async fn conversation_without_project_cannot_save_to_project() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-save-noproj").await;
    let seeded = seed(&ctx, &token, "media-save-noproj", false).await;

    let response = post_save(&ctx, &token, &seeded.media_id, "a.png").await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("保存到本机"),
        "要指向可用的替代方案：{body}"
    );
}

#[tokio::test]
async fn unknown_media_is_404() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-save-404").await;

    let response = post_save(&ctx, &token, "img_missing", "a.png").await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// 项目文件端点要求 query 里的路径是百分号编码的。
fn urlencoding(raw: &str) -> String {
    raw.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}
