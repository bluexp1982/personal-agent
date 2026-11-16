//! 百炼文生图 / 文生视频的**真联网**冒烟。
//!
//! 默认 `#[ignore]`：跑一次会真花钱，CI 不该跑。手动执行：
//!
//! ```bash
//! cargo test -p jarvis-service --test media_smoke -- --ignored --nocapture
//! # 只想跑一条：
//! cargo test -p jarvis-service --test media_smoke -- --ignored --nocapture smoke_generates_image
//! ```
//!
//! 需要环境变量 `BAILIAN_API_KEY`（百炼控制台的 API Key）。产物落在
//! `${MEDIA_SMOKE_DIR:-<repo>/.dev/media-smoke}`，用例结束也会打印绝对路径——
//! 用临时目录就"跑完即删"，人根本来不及看成片。

use std::path::PathBuf;

use jarvis_service::artifact_store::ArtifactStore;
use jarvis_service::config::Config;
use jarvis_service::media::{MediaArtifact, MediaBackend, MediaGenerator, MediaRequest};

/// 冒烟产物的落盘根（等价于线上 `<data_dir>/artifacts`）。
fn smoke_root() -> PathBuf {
    match std::env::var("MEDIA_SMOKE_DIR") {
        Ok(raw) if !raw.trim().is_empty() => PathBuf::from(raw),
        _ => {
            // `<repo>/crates/jarvis-service` 往上两层才是仓库根；
            // 直接用 `..` 拼会让打印出来的路径带一串不好读的 `../../`。
            let crate_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
            crate_dir
                .ancestors()
                .nth(2)
                .unwrap_or(crate_dir)
                .join(".dev/media-smoke")
        }
    }
}

/// 组装一份只打开指定能力的配置。
///
/// `MEDIA_SMOKE_SIZE` 可以把出图尺寸换成指定档（例如 `1024*1024`）：
/// 上游对不支持的尺寸可能"不报错但按自己的档位出图"，这件事只能真跑一次才知道。
fn smoke_config(image: bool, video: bool) -> Config {
    let mut config = Config::default();
    config.media.image.enabled = image;
    config.media.video.enabled = video;
    if let Ok(raw) = std::env::var("MEDIA_SMOKE_SIZE") {
        let raw = raw.trim();
        if !raw.is_empty() {
            config.media.image.size = raw.to_string();
        }
    }
    config
}

fn report(label: &str, artifact: &MediaArtifact) {
    println!(
        "{label}：{} 字节，{} ms，mime={}，task_id={}",
        artifact.bytes,
        artifact.elapsed_ms,
        artifact.mime,
        artifact.upstream_task_id.as_deref().unwrap_or("-")
    );
    println!("{label}落盘：{}", artifact.absolute_path);
}

#[tokio::test]
#[ignore = "联网冒烟，需 BAILIAN_API_KEY"]
#[allow(clippy::print_stdout)] // 手动跑冒烟时要看到参数、路径与耗时
async fn smoke_generates_image() {
    let config = smoke_config(true, false);
    config
        .validate()
        .expect("media.image 配置自检失败：先确认 BAILIAN_API_KEY 已设置");

    let generator = MediaGenerator::from_config(&config).expect("构造出图客户端失败");
    assert!(generator.image_enabled());

    let store = ArtifactStore::new(smoke_root());
    println!(
        "出图参数：model={} size={}",
        config.media.image.model, config.media.image.size
    );

    let artifact = generator
        .image(
            MediaRequest::new("一只在窗台上晒太阳的橘猫，水彩风格，暖光"),
            &store,
            "smoke-image",
        )
        .await
        .expect("真实出图失败");

    report("出图", &artifact);
    assert!(artifact.bytes > 1024, "图片过小，可能不是成图");
    assert_eq!(artifact.mime, "image/png");

    // 扩展名与服务端落盘必须一致，否则客户端预览器认不出来。
    assert!(artifact.relative_path.ends_with(".png"), "{artifact:?}");

    let bytes = store.read(&artifact.relative_path).await.expect("读取失败");
    assert_eq!(
        &bytes[..8],
        &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A],
        "落盘内容不是 PNG"
    );
}

#[tokio::test]
#[ignore = "联网冒烟，需 BAILIAN_API_KEY（会产生真实费用）"]
#[allow(clippy::print_stdout)]
async fn smoke_generates_video() {
    let config = smoke_config(false, true);
    config
        .validate()
        .expect("media.video 配置自检失败：先确认 BAILIAN_API_KEY 已设置");

    let generator = MediaGenerator::from_config(&config).expect("构造视频客户端失败");
    assert!(generator.video_enabled());

    let store = ArtifactStore::new(smoke_root());
    println!(
        "出片参数：model={} resolution={} ratio={} duration={}s poll={}ms max_wait={}ms",
        config.media.video.model,
        config.media.video.resolution,
        config.media.video.ratio,
        config.media.video.duration_s,
        config.media.video.poll_interval_ms,
        config.media.video.max_wait_ms
    );

    let artifact = generator
        .video(
            MediaRequest::new("海边日落，镜头缓慢向前推进，海浪拍打礁石"),
            &store,
            "smoke-video",
        )
        .await
        .expect("真实出片失败");

    report("出片", &artifact);
    assert!(artifact.bytes > 10 * 1024, "视频过小，可能不是成片");
    assert_eq!(artifact.mime, "video/mp4");
    assert!(artifact.relative_path.ends_with(".mp4"), "{artifact:?}");
    assert!(
        artifact.upstream_task_id.is_some(),
        "视频产物必须留下上游 task_id"
    );

    let bytes = store.read(&artifact.relative_path).await.expect("读取失败");
    assert_eq!(&bytes[4..8], b"ftyp", "落盘内容不是 mp4");
}
