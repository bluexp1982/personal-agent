//! 视频封面端点的集成测试。
//!
//! 两条线分开验：
//! 1. 已有封面 → 直接发；没有封面（且补不出来）→ 404。这层不需要 ffmpeg，
//!    封面文件直接写进产物库；
//! 2. 老视频按需补封面 → 用真 ffmpeg 生成一段测试视频，走一遍"取封面"的
//!    完整链路（宿主机没装 ffmpeg 时该用例自动跳过）。

mod common;

use axum::http::StatusCode;
use jarvis_service::artifact_store::ArtifactStore;
use jarvis_service::media::records;
use protocol::MediaAsset;

/// 一张"像 jpeg"的最小字节：端点只转发，不解码。
const POSTER_BYTES: [u8; 12] = [
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00, 0x01,
];

async fn seed(ctx: &common::TestContext, token: &str, tag: &str) -> (String, String) {
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "海边日落" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "建会话失败");
    let conversation_id = common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();

    let media_id = format!("vid_{tag}");
    let store = ArtifactStore::new(ctx.state.config.artifacts_dir());
    let (relative, _) = store
        .save_bytes(&conversation_id, &media_id, Some("video/mp4"), b"fake-mp4")
        .await
        .expect("写入视频失败");

    let asset = MediaAsset {
        id: media_id.clone(),
        kind: "video".to_string(),
        mime: "video/mp4".to_string(),
        bytes: 8,
        model: "wan3.0-video-prime".to_string(),
        prompt: "海边日落".to_string(),
        width: None,
        height: None,
        duration_ms: Some(5000),
        resolution: Some("480P".to_string()),
        created_at: 1_700_000_000_000,
    };
    records::insert_asset(&ctx.state.pool, &conversation_id, &asset, &relative)
        .await
        .expect("写入媒体记录失败");

    (conversation_id, media_id)
}

/// 把封面写进产物库并登记到媒体记录上（模拟"生成时抽帧成功"）。
async fn attach_poster(ctx: &common::TestContext, conversation_id: &str, media_id: &str) -> String {
    let store = ArtifactStore::new(ctx.state.config.artifacts_dir());
    let (relative, _) = store
        .save_bytes(
            conversation_id,
            &format!("{media_id}-poster"),
            Some("image/jpeg"),
            &POSTER_BYTES,
        )
        .await
        .expect("写入封面失败");
    records::set_poster(&ctx.state.pool, media_id, &relative)
        .await
        .expect("登记封面失败");
    relative
}

#[tokio::test]
async fn serves_the_stored_poster() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-poster-ok").await;
    let (conversation_id, media_id) = seed(&ctx, &token, "media-poster-ok").await;
    attach_poster(&ctx, &conversation_id, &media_id).await;

    let response = ctx
        .call(common::authed_get(
            &format!("/api/media/{media_id}/poster"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok()),
        Some("image/jpeg")
    );

    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取响应体失败");
    assert_eq!(bytes.to_vec(), POSTER_BYTES);
}

#[tokio::test]
async fn missing_poster_and_unknown_media_are_404() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-poster-missing").await;

    // 旧视频：媒体记录在，但没有封面。
    let (_, media_id) = seed(&ctx, &token, "media-poster-missing").await;
    let response = ctx
        .call(common::authed_get(
            &format!("/api/media/{media_id}/poster"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "not_found", "{body}");

    // 完全不存在的 id：同一个状态码，客户端只需一条回退路径。
    let response = ctx
        .call(common::authed_get("/api/media/vid_absent/poster", &token))
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn poster_file_missing_on_disk_is_404() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-poster-lost").await;
    let (conversation_id, media_id) = seed(&ctx, &token, "media-poster-lost").await;
    let relative = attach_poster(&ctx, &conversation_id, &media_id).await;

    // 数据目录被清理：记录还在，文件没了。
    std::fs::remove_file(
        ctx.state
            .config
            .artifacts_dir()
            .join(relative),
    )
    .expect("删除封面文件失败");

    let response = ctx
        .call(common::authed_get(
            &format!("/api/media/{media_id}/poster"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn requires_authentication() {
    let ctx = common::setup().await;
    let response = ctx
        .call(
            axum::http::Request::builder()
                .uri("/api/media/vid_x/poster")
                .body(axum::body::Body::empty())
                .expect("构造请求失败"),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

/// 宿主机有没有 ffmpeg。没有就跳过"按需补封面"的用例——抽帧是可选能力。
fn ffmpeg_available() -> bool {
    std::process::Command::new("ffmpeg")
        .arg("-version")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// 造一段 1 秒的测试视频，返回字节。
fn sample_video_bytes() -> Vec<u8> {
    let path = std::env::temp_dir().join(format!(
        "jarvis-poster-it-{}.mp4",
        std::process::id()
    ));
    let status = std::process::Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=320x180:rate=10:duration=1",
            "-pix_fmt",
            "yuv420p",
        ])
        .arg(&path)
        .status()
        .expect("生成测试视频失败");
    assert!(status.success(), "生成测试视频失败");
    let bytes = std::fs::read(&path).expect("读取测试视频失败");
    let _ = std::fs::remove_file(&path);
    bytes
}

#[tokio::test]
async fn backfills_poster_for_old_video() {
    if !ffmpeg_available() {
        eprintln!("宿主机没有 ffmpeg，跳过按需补封面用例");
        return;
    }

    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("media-poster-backfill").await;

    let response = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "title": "老视频" }),
        )
        .await;
    let conversation_id = common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();

    // 模拟抽帧能力上线前生成的视频：正文在，poster_path 为空。
    let video = sample_video_bytes();
    let media_id = "vid_old";
    let store = ArtifactStore::new(ctx.state.config.artifacts_dir());
    let (relative, _) = store
        .save_bytes(&conversation_id, media_id, Some("video/mp4"), &video)
        .await
        .expect("写入视频失败");
    let asset = MediaAsset {
        id: media_id.to_string(),
        kind: "video".to_string(),
        mime: "video/mp4".to_string(),
        bytes: video.len() as i64,
        model: "wan3.0-video-prime".to_string(),
        prompt: "海边日落".to_string(),
        width: None,
        height: None,
        duration_ms: Some(5000),
        resolution: Some("480P".to_string()),
        created_at: 1_700_000_000_000,
    };
    records::insert_asset(&ctx.state.pool, &conversation_id, &asset, &relative)
        .await
        .expect("写入媒体记录失败");

    // 第一次请求触发补帧，返回真实的 jpeg。
    let response = ctx
        .call(common::authed_get(
            &format!("/api/media/{media_id}/poster"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::OK, "老视频应按需补出封面");
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取封面失败");
    assert_eq!(&bytes[..2], &[0xFF, 0xD8], "应返回 JPEG");

    // 补完写库：第二次请求走缓存，结果一致。
    let stored: Option<String> = sqlx::query_scalar(
        "SELECT poster_path FROM media_assets WHERE id = ?",
    )
    .bind(media_id)
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查询封面路径失败");
    assert!(stored.is_some(), "补完必须把路径写回媒体记录");

    let response = ctx
        .call(common::authed_get(
            &format!("/api/media/{media_id}/poster"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let again = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取封面失败");
    assert_eq!(again.to_vec(), bytes.to_vec(), "缓存读到的应是同一张图");
}
