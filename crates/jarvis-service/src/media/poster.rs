//! 视频封面：抽第一帧存成 jpeg。
//!
//! 为什么用宿主机上的 `ffmpeg` 而不是在进程内解码：纯 Rust 解 H.264 要么拖进
//! 一整条 C 工具链（ffmpeg-sys / video-rs），要么只支持极少数编码；而这个项目
//! 的媒体生成本来就依赖外部模型网关，"多一个可选的外部命令"没有额外负担。
//!
//! **这是可选依赖**：没有 ffmpeg 时抽帧返回 [`PosterError::Unavailable`]，
//! 调用方只记 warn、媒体照常生成，客户端回退到播放图标占位块。绝不能因为
//! 宿主机没装 ffmpeg 就让"视频生成"失败——封面是锦上添花。

use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

/// 外部命令名。写成常量便于测试里替换/排查。
const FFMPEG: &str = "ffmpeg";

/// 抽帧超时。10 秒的视频解码一帧在普通机器上是几十毫秒；15 秒还没结束，
/// 基本是文件损坏或 ffmpeg 卡在探测上，继续等只会拖住生成本身。
const TIMEOUT: Duration = Duration::from_secs(15);

/// 封面最大宽度。卡片缩略图最宽也就 400dp、右栏预览撑死 1200，
/// 1280 已经能在高分屏上看清楚，再大只是白占磁盘。
const MAX_WIDTH: u32 = 1280;

#[derive(Debug, thiserror::Error)]
pub(crate) enum PosterError {
    #[error("宿主机没有 ffmpeg，跳过视频封面（装好后重新生成视频即可）")]
    Unavailable,
    #[error("ffmpeg 抽帧失败: {0}")]
    Failed(String),
    #[error("视频文件不可用: {0}")]
    Missing(String),
    #[error("封面读写失败: {0}")]
    Io(#[from] std::io::Error),
}

/// 确保某条视频有封面，返回它在产物库里的相对路径。
///
/// 生成链路与「按需补封面」共用这一份：前者在视频登记成功后调，后者在
/// `/api/media/{id}/poster` 发现 `poster_path` 为空时调（补抽帧能力上线前
/// 生成的老视频）。两处若各写一份，落点、命名、写库迟早会不一致。
///
/// 落点与生成时一致：`<conversation_id>/<media_id>-poster.jpg`，同一 id 重复
/// 补两次也只会覆盖成同一张图。
pub(crate) async fn ensure(
    pool: &sqlx::SqlitePool,
    store: &crate::artifact_store::ArtifactStore,
    media_id: &str,
    conversation_id: &str,
    source_relative: &str,
) -> Result<String, PosterError> {
    let source = store
        .resolve(source_relative)
        .map_err(|err| PosterError::Missing(format!("{source_relative}（{err}）")))?;

    let bytes = first_frame(&source).await?;
    let poster_id = format!("{media_id}-poster");
    let (relative, _) = store
        .save_bytes(conversation_id, &poster_id, Some("image/jpeg"), &bytes)
        .await
        .map_err(|err| PosterError::Missing(format!("封面落盘失败：{err}")))?;

    crate::media::records::set_poster(pool, media_id, &relative)
        .await
        .map_err(|err| PosterError::Missing(format!("封面路径登记失败：{err}")))?;

    Ok(relative)
}

/// 本机是否装了 ffmpeg。
///
/// 探测结果缓存到进程结束：每次生成视频都 spawn 一次 `ffmpeg -version`，
/// 在"批量生成"的场景里是纯浪费；而 ffmpeg 在服务运行期间装上/卸掉的概率
/// 低到可以忽略（真遇到了重启服务即可）。
pub(crate) async fn available() -> bool {
    static AVAILABLE: OnceLock<bool> = OnceLock::new();
    if let Some(value) = AVAILABLE.get() {
        return *value;
    }

    let probed = tokio::time::timeout(
        Duration::from_secs(5),
        tokio::process::Command::new(FFMPEG)
            .arg("-version")
            .output(),
    )
    .await
    .ok()
    .and_then(Result::ok)
    .is_some_and(|output| output.status.success());

    let _ = AVAILABLE.set(probed);
    *AVAILABLE.get().unwrap_or(&false)
}

/// 抽第一帧，返回 jpeg 字节。
///
/// 取第 0 秒：需求就是"第一帧"。有些片子首帧是纯黑（淡入），这时封面会是黑的——
/// 与其猜一个"有内容的时间点"，不如老老实实给第一帧，用户点开就知道是不是想要的。
pub(crate) async fn first_frame(source: &Path) -> Result<Vec<u8>, PosterError> {
    if !available().await {
        return Err(PosterError::Unavailable);
    }

    // 输出到系统临时目录：ffmpeg 写文件比写管道稳（不会因为早退产生半截数据），
    // 读完立刻删，不占用户的磁盘。
    let output = std::env::temp_dir().join(format!(
        "jarvis-poster-{}.jpg",
        crate::ids::new_id("poster")
    ));

    let scale = format!("scale='min({MAX_WIDTH},iw)':-2");
    let mut command = tokio::process::Command::new(FFMPEG);
    command
        .args(["-hide_banner", "-loglevel", "error", "-y", "-ss", "0", "-i"])
        .arg(source)
        .args(["-frames:v", "1", "-vf", scale.as_str(), "-q:v", "4"])
        .arg(&output);

    let result = tokio::time::timeout(TIMEOUT, command.output()).await;
    let cleanup = || {
        let _ = std::fs::remove_file(&output);
    };

    match result {
        Err(_) => {
            cleanup();
            Err(PosterError::Failed(format!(
                "超时（{} 秒）",
                TIMEOUT.as_secs()
            )))
        }
        Ok(Err(err)) if err.kind() == std::io::ErrorKind::NotFound => {
            cleanup();
            Err(PosterError::Unavailable)
        }
        Ok(Err(err)) => {
            cleanup();
            Err(PosterError::Io(err))
        }
        Ok(Ok(exit)) if !exit.status.success() => {
            cleanup();
            let stderr = String::from_utf8_lossy(&exit.stderr);
            Err(PosterError::Failed(stderr.trim().to_string()))
        }
        Ok(Ok(_)) => {
            let bytes = match std::fs::read(&output) {
                Ok(bytes) => bytes,
                Err(err) => {
                    cleanup();
                    return Err(PosterError::Io(err));
                }
            };
            cleanup();
            if bytes.is_empty() {
                return Err(PosterError::Failed("ffmpeg 输出为空".to_string()));
            }
            Ok(bytes)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 造一段 1 秒的测试视频（色块 + 跳动的方块）。没装 ffmpeg 时返回 None，
    /// 让用例跳过而不是红——抽帧本来就是可选能力。
    async fn sample_video() -> Option<std::path::PathBuf> {
        if !available().await {
            return None;
        }
        let path = std::env::temp_dir().join(format!(
            "jarvis-poster-src-{}.mp4",
            crate::ids::new_id("test")
        ));
        let status = tokio::process::Command::new(FFMPEG)
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
            .await
            .expect("生成测试视频失败");
        assert!(status.success(), "生成测试视频失败");
        Some(path)
    }

    #[tokio::test]
    async fn extracts_a_jpeg_frame() {
        let Some(source) = sample_video().await else {
            eprintln!("宿主机没有 ffmpeg，跳过抽帧用例");
            return;
        };

        let bytes = first_frame(&source).await.expect("抽帧应成功");
        let _ = std::fs::remove_file(&source);

        assert!(
            bytes.len() > 1024,
            "封面不该是一张空图：{} 字节",
            bytes.len()
        );
        // JPEG 的 SOI 标记：证明 ffmpeg 真的按 jpeg 编码了，而不是把 mp4 原样拷回来。
        assert_eq!(&bytes[..2], &[0xFF, 0xD8], "应以 JPEG SOI 开头");
    }

    #[tokio::test]
    async fn missing_file_is_an_error_not_a_panic() {
        if !available().await {
            eprintln!("宿主机没有 ffmpeg，跳过抽帧用例");
            return;
        }
        let err = first_frame(Path::new("/nonexistent/clip.mp4"))
            .await
            .expect_err("不存在的文件必须报错");
        assert!(matches!(err, PosterError::Failed(_)), "{err}");
    }
}
