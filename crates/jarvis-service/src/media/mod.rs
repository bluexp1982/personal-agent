//! 百炼媒体生成：文生图（`qwen-image-3.0`）与文生视频（`wan3.0-video-prime`）。
//!
//! 形态与 `recording::asr` / `recording::tts` 同构——服务内上游客户端 + 落盘：
//! 密钥只在 service 进程里，调用方拿到的始终是自己产物根下的相对路径，
//! 不接触厂商地址与签名参数。
//!
//! 三条来自实测的硬约束：
//!
//! - 端点必须是百炼原生 host（`dashscope.aliyuncs.com`），**不能**跟着
//!   `llm.base_url` 的 MaaS 网关走，那里没有图像与视频端点；
//! - 出图走 `multimodal-generation/generation`：`text2image/image-synthesis`
//!   对 `qwen-image-3.0` 直接回 `url error`；
//! - 出片是异步任务：提交只拿到 `task_id`，轮询到终态后再下载；上游给的是
//!   带签名的临时地址，不下载下来就留不住。

mod image;
pub mod poster;
pub mod records;
mod video;

use std::time::Duration;

use reqwest::Client;
use serde_json::Value;

use crate::artifact_store::{ArtifactStore, StoreError};
use crate::config::Config;

use image::ImageClient;
use video::VideoClient;

/// 上游错误体的截断长度：够看清原因，又不会把整页 HTML 塞进日志。
pub(crate) const MAX_ERROR_BODY: usize = 300;

/// 建连上限。与生成耗时无关：地址写错要在十几秒内失败，而不是等到超时。
pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaError {
    /// 未启用或缺少密钥：重试不会变好。
    Disabled(String),
    /// 参数不合法（空提示词、尺寸档不被接受等）。
    Invalid(String),
    /// 上游拒绝、超时或返回不可解析。
    Upstream(String),
    /// 成图/成片下载失败。
    Download(String),
    /// 产物落盘失败。
    Store(String),
}

impl MediaError {
    pub fn message(&self) -> &str {
        match self {
            Self::Disabled(reason)
            | Self::Invalid(reason)
            | Self::Upstream(reason)
            | Self::Download(reason)
            | Self::Store(reason) => reason,
        }
    }
}

impl std::fmt::Display for MediaError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let prefix = match self {
            Self::Disabled(_) => "媒体生成未就绪",
            Self::Invalid(_) => "媒体生成参数不合法",
            Self::Upstream(_) => "媒体生成上游失败",
            Self::Download(_) => "媒体产物下载失败",
            Self::Store(_) => "媒体产物落盘失败",
        };
        write!(formatter, "{prefix}：{}", self.message())
    }
}

impl std::error::Error for MediaError {}

impl From<StoreError> for MediaError {
    fn from(err: StoreError) -> Self {
        Self::Store(err.to_string())
    }
}

/// 一次成功生成留下的产物。
#[derive(Debug, Clone)]
pub struct MediaArtifact {
    /// 相对产物根（`<data_dir>/artifacts`）的路径，用于入库与下载端点。
    pub relative_path: String,
    /// 本地绝对路径，只用于人工确认与日志，不对外返回。
    pub absolute_path: String,
    pub mime: &'static str,
    pub bytes: u64,
    /// 从提交到落盘的总耗时。
    pub elapsed_ms: u64,
    /// 图片像素宽高（按文件头解析）；视频不解析 mp4，保持 `None`。
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// 视频时长（毫秒）；图片为 `None`。
    pub duration_ms: Option<u32>,
    /// 视频才有：上游任务号，排障时唯一有用的线索。
    pub upstream_task_id: Option<String>,
}

/// 一次生成请求。字段都是可选的"覆盖项"，`None` 表示用配置默认值。
///
/// 为什么不让工具直接改 `Config`：配置是服务级共享状态，模型的一时要求
/// 不该改到下一轮、下一个人；覆盖只作用于本次请求。
#[derive(Debug, Clone, Copy, Default)]
pub struct MediaRequest<'a> {
    pub prompt: &'a str,
    /// 图片尺寸，例如 `1328*1328`；对视频无效。
    pub size: Option<&'a str>,
    /// 视频分辨率档，例如 `480P`；对图片无效。调用方负责白名单校验。
    pub resolution: Option<&'a str>,
    /// 视频时长（秒），2–15；对图片无效。
    pub duration_s: Option<u32>,
}

impl<'a> MediaRequest<'a> {
    pub fn new(prompt: &'a str) -> Self {
        Self {
            prompt,
            ..Self::default()
        }
    }
}

/// 媒体生成后端。
///
/// 抽成 trait 的唯一理由是**可测**：对话工具的测试不能依赖真密钥与真网络，
/// 也不能等两分钟；线上装配时换成 [`MediaGenerator`]。
#[async_trait::async_trait]
pub trait MediaBackend: Send + Sync + std::fmt::Debug {
    fn image_enabled(&self) -> bool;
    fn video_enabled(&self) -> bool;

    async fn image(
        &self,
        request: MediaRequest<'_>,
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError>;

    async fn video(
        &self,
        request: MediaRequest<'_>,
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError>;
}

/// 媒体生成入口。
///
/// 两节都关闭时 [`Self::from_config`] 返回 [`MediaError::Disabled`]：
/// 未配置的部署不该在启动路径上多出一个必然失败的依赖。
#[derive(Debug)]
pub struct MediaGenerator {
    image: Option<ImageClient>,
    video: Option<VideoClient>,
}

impl MediaGenerator {
    pub fn from_config(config: &Config) -> Result<Self, MediaError> {
        let image = if config.media.image.enabled {
            let key = config.media_image_api_key().ok_or_else(|| {
                MediaError::Disabled(format!(
                    "media.image 已启用，但环境变量 {} 为空",
                    config.media_image_api_key_env()
                ))
            })?;
            Some(ImageClient::new(
                &config.media.image,
                config.media_image_upstream_base_url(),
                key,
            ))
        } else {
            None
        };

        let video = if config.media.video.enabled {
            let key = config.media_video_api_key().ok_or_else(|| {
                MediaError::Disabled(format!(
                    "media.video 已启用，但环境变量 {} 为空",
                    config.media_video_api_key_env()
                ))
            })?;
            Some(VideoClient::new(
                &config.media.video,
                config.media_video_upstream_base_url(),
                key,
            ))
        } else {
            None
        };

        if image.is_none() && video.is_none() {
            return Err(MediaError::Disabled(
                "media.image / media.video 都是关闭的".to_string(),
            ));
        }

        Ok(Self { image, video })
    }

    pub fn image_enabled(&self) -> bool {
        self.image.is_some()
    }

    pub fn video_enabled(&self) -> bool {
        self.video.is_some()
    }
}

#[async_trait::async_trait]
impl MediaBackend for MediaGenerator {
    fn image_enabled(&self) -> bool {
        self.image.is_some()
    }

    fn video_enabled(&self) -> bool {
        self.video.is_some()
    }

    async fn image(
        &self,
        request: MediaRequest<'_>,
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError> {
        let client = self.image.as_ref().ok_or_else(|| {
            MediaError::Disabled("文生图未启用（media.image.enabled=false）".into())
        })?;
        client.generate(request, store, task_id).await
    }

    async fn video(
        &self,
        request: MediaRequest<'_>,
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError> {
        let client = self.video.as_ref().ok_or_else(|| {
            MediaError::Disabled("文生视频未启用（media.video.enabled=false）".into())
        })?;
        client.generate(request, store, task_id).await
    }
}

/// 按文件头判断图片 mime 与像素尺寸。
///
/// 不信任响应头：OSS 签名地址有时给 `application/octet-stream`，而落盘扩展名
/// 直接由这里的结论决定，判错就等于让客户端的预览器认不出文件。
/// 尺寸同理：卡片要知道真实比例才能先把占位块画对。
pub(crate) fn image_metadata(bytes: &[u8]) -> (&'static str, Option<(u32, u32)>) {
    use crate::local_tools::image::{dimensions, sniff, ImageFormat};

    match sniff(bytes) {
        Some(format) => {
            let mime = match format {
                ImageFormat::Jpeg => "image/jpeg",
                // `qwen-image-3.0` 只会回 png；其余格式仍按 png 记，避免落下 `.bin`。
                _ => "image/png",
            };
            (mime, dimensions(bytes, format))
        }
        None => ("image/png", None),
    }
}

/// 下载上游给的临时地址。
///
/// 这不是多余的一步：链接带签名与有效期，过期后连提交者自己也取不回来；
/// 而产物约定是"文件系统是唯一副本"。
pub(crate) async fn download_bytes(
    client: &Client,
    url: &str,
    max_bytes: i64,
    label: &str,
) -> Result<Vec<u8>, MediaError> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err(MediaError::Download(format!(
            "{label}地址不是 http(s)：{url}"
        )));
    }

    let response = client
        .get(url)
        .send()
        .await
        .map_err(|err| MediaError::Download(format!("下载{label}失败：{err}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(MediaError::Download(format!(
            "下载{label}返回 HTTP {}",
            status.as_u16()
        )));
    }
    if let Some(length) = response.content_length() {
        if length as i64 > max_bytes {
            return Err(MediaError::Download(format!(
                "{label}超过大小上限（{length} 字节 > {max_bytes}）"
            )));
        }
    }

    let bytes = response
        .bytes()
        .await
        .map_err(|err| MediaError::Download(format!("读取{label}失败：{err}")))?;
    if bytes.len() as i64 > max_bytes {
        return Err(MediaError::Download(format!(
            "{label}超过大小上限（{} 字节 > {max_bytes}）",
            bytes.len()
        )));
    }
    Ok(bytes.to_vec())
}

/// `HTTP 状态 + 上游错误体` 的统一失败。
pub(crate) fn upstream_failure(status: u16, body: &str) -> MediaError {
    MediaError::Upstream(format!("百炼返回 HTTP {status}：{}", summarize_error(body)))
}

/// 把上游错误体压成一行：优先抽 `code` / `message` / `request_id`。
///
/// `request_id` 必须留下——没有它，用户拿截图去问阿里云也定位不到请求。
pub(crate) fn summarize_error(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return "（空响应体）".to_string();
    }

    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        let field = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or("");
        let mut parts = Vec::new();
        for (key, raw) in [
            ("code", field("code")),
            ("message", field("message")),
            ("request_id", field("request_id")),
        ] {
            if !raw.trim().is_empty() {
                parts.push(format!("{key}={raw}"));
            }
        }
        if !parts.is_empty() {
            return truncate(&parts.join("；"));
        }
    }

    truncate(trimmed)
}

/// 按字符截断，避免切断 UTF-8 边界。
fn truncate(text: &str) -> String {
    if text.chars().count() <= MAX_ERROR_BODY {
        return text.to_string();
    }
    let kept: String = text.chars().take(MAX_ERROR_BODY).collect();
    format!("{kept}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_summary_prefers_structured_fields() {
        let body = r#"{"request_id":"abc-123","code":"InvalidParameter","message":"Field 'text' cannot be an empty string."}"#;
        let summary = summarize_error(body);
        assert!(summary.contains("code=InvalidParameter"), "{summary}");
        assert!(summary.contains("request_id=abc-123"), "{summary}");
        assert!(summary.contains("text"), "{summary}");
    }

    #[test]
    fn error_summary_truncates_html() {
        let body = "x".repeat(MAX_ERROR_BODY * 3);
        let summary = summarize_error(&body);
        assert!(summary.chars().count() <= MAX_ERROR_BODY + 1, "{summary}");
    }

    #[test]
    fn error_summary_handles_empty_body() {
        assert_eq!(summarize_error("   "), "（空响应体）");
    }

    #[test]
    fn sniffs_image_mime_and_pixels_from_header_bytes() {
        // 8 字节签名 + IHDR 长度 + "IHDR" + 宽高各 4 字节大端（无需真实像素）。
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        png.extend_from_slice(&13u32.to_be_bytes());
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&1328u32.to_be_bytes());
        png.extend_from_slice(&1328u32.to_be_bytes());

        assert_eq!(image_metadata(&png), ("image/png", Some((1328, 1328))));
        assert_eq!(
            image_metadata(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
            ("image/jpeg", None),
            "JPEG 只认格式，尺寸不解析"
        );
        assert_eq!(image_metadata(b"not an image"), ("image/png", None));
    }

    #[test]
    fn disabled_config_reports_clearly() {
        let config = Config::default();
        let error = MediaGenerator::from_config(&config).unwrap_err();
        assert!(matches!(error, MediaError::Disabled(_)), "{error}");
    }
}
