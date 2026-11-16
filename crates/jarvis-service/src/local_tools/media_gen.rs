//! 对话里的媒体生成工具：`generate_image` / `generate_video`。
//!
//! 职责边界：**校验参数 → 调后端 → 登记元信息 → 给一张卡片**。
//! 真正的上游调用与落盘在 [`crate::media`]：这里不拼 HTTP、不碰密钥。
//!
//! 四件事刻意放在这一层：
//!
//! - **参数白名单**：视频 `resolution` 只收 480P/720P/1080P、`duration` 只收 2–15。
//!   非法值不发给上游——那会创建出一个"提交成功但注定失败"的付费任务。
//! - **尺寸裁决**：图片尺寸只认两处——用户这一句原话里的显式尺寸、配置里的
//!   `media.image.size`。模型传的 `size` 不采纳：它曾经把配置整段盖掉，
//!   用户改了配置却还是拿到 `1328*1328`（见 [`size_in_text`] 的说明）。
//! - **登记在落盘之后**：先有文件再写记录。反过来的话，登记成功但落盘失败会留下
//!   一条指向空气的记录，客户端每次打开会话都看到一个打不开的卡片。
//! - **超时不在这里做**：`chat::run` 给媒体调用单独的超时上限，
//!   工具层再包一层只会出现两个互相打架的时间。

use std::sync::Arc;

use protocol::MediaAsset;
use sqlx::SqlitePool;

use crate::artifact_store::ArtifactStore;
use crate::chat::{ChatUiAction, LocalTool, LocalToolOutcome, ToolSpec};
use crate::config::Config;
use crate::local_tools::{fail, format_size};
use crate::media::{MediaBackend, MediaRequest};

/// 视频分辨率档位：上游只认这三个（用空 prompt 探测校验得到）。
const VIDEO_RESOLUTIONS: [&str; 3] = ["480P", "720P", "1080P"];

/// 视频时长范围（秒）。
const VIDEO_DURATION_RANGE: std::ops::RangeInclusive<u32> = 2..=15;

/// 图片尺寸的粗略边界：挡掉明显写错的值，不假装知道上游支持的全部档位。
const IMAGE_SIDE_RANGE: std::ops::RangeInclusive<u32> = 256..=4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MediaKind {
    Image,
    Video,
}

impl MediaKind {
    fn tool_name(self) -> &'static str {
        match self {
            Self::Image => "generate_image",
            Self::Video => "generate_video",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Image => "图片",
            Self::Video => "视频",
        }
    }

    fn asset_kind(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::Video => "video",
        }
    }
}

/// 一次媒体生成。两个工具共用实现，只有 `kind` 不同。
#[derive(Debug)]
pub(crate) struct GenerateMediaTool {
    kind: MediaKind,
    backend: Arc<dyn MediaBackend>,
    pool: SqlitePool,
    store: ArtifactStore,
    conversation_id: String,
    /// 默认档位与模型名取自配置。视频的档位仍可被模型本次覆盖，图片尺寸不行。
    default_size: String,
    /// 本轮用户原话里点名的尺寸。`None` 表示"没点名，按配置来"。
    ///
    /// 只对图片有效：视频的 `resolution` / `duration` 仍由模型按参数表填。
    user_size: Option<String>,
    default_resolution: String,
    default_duration_s: u32,
    model: String,
}

impl GenerateMediaTool {
    pub(crate) fn new(
        kind: MediaKind,
        backend: Arc<dyn MediaBackend>,
        pool: SqlitePool,
        conversation_id: impl Into<String>,
        config: &Config,
        user_text: &str,
    ) -> Self {
        let (default_size, default_resolution, default_duration_s, model) = match kind {
            MediaKind::Image => (
                config.media.image.size.clone(),
                String::new(),
                0,
                config.media.image.model.clone(),
            ),
            MediaKind::Video => (
                String::new(),
                config.media.video.resolution.clone(),
                config.media.video.duration_s,
                config.media.video.model.clone(),
            ),
        };
        // 尺寸的权威只有两个来源：用户这一句里的显式尺寸、配置里的默认值。
        // 模型传来的 size 一律不采纳——它曾经把 `media.image.size` 整段盖掉。
        let user_size = match kind {
            MediaKind::Image => size_in_text(user_text),
            MediaKind::Video => None,
        };

        Self {
            kind,
            backend,
            pool,
            store: ArtifactStore::new(config.artifacts_dir()),
            conversation_id: conversation_id.into(),
            default_size,
            user_size,
            default_resolution,
            default_duration_s,
            model,
        }
    }

    /// 解析参数。返回提示词与视频档位/时长。
    ///
    /// 图片尺寸**不解析**：模型按旧习惯带上 `size` 时明确忽略（只记一条 debug），
    /// 免得上游收到一个和配置不一样的尺寸却没人知道是谁改的。
    fn parse(&self, arguments: &str) -> Result<ParsedArgs, String> {
        let value: serde_json::Value =
            serde_json::from_str(arguments).map_err(|err| format!("不是合法 JSON（{err}）"))?;

        let prompt = value
            .get("prompt")
            .and_then(|item| item.as_str())
            .map(str::trim)
            .filter(|prompt| !prompt.is_empty())
            .ok_or_else(|| "缺少 prompt（要生成什么）".to_string())?;
        if prompt.chars().count() > MAX_PROMPT_CHARS {
            return Err(format!(
                "prompt 太长（{} 字，上限 {MAX_PROMPT_CHARS} 字），请精简成一个画面描述",
                prompt.chars().count()
            ));
        }
        let prompt = prompt.to_string();

        match self.kind {
            MediaKind::Image => {
                if let Some(raw) = value.get("size").and_then(|item| item.as_str()) {
                    tracing::debug!(
                        conversation_id = %self.conversation_id,
                        size = raw,
                        "忽略模型指定的尺寸：尺寸取用户原话或 media.image.size"
                    );
                }
                Ok(ParsedArgs {
                    prompt,
                    resolution: None,
                    duration_s: None,
                })
            }
            MediaKind::Video => {
                let resolution = match value.get("resolution").and_then(|item| item.as_str()) {
                    None => None,
                    Some(raw) => Some(validate_resolution(raw)?),
                };
                let duration_s = match value.get("duration") {
                    None | Some(serde_json::Value::Null) => None,
                    Some(item) => {
                        let raw = item
                            .as_u64()
                            .ok_or_else(|| "duration 必须是整数秒".to_string())?;
                        let duration = u32::try_from(raw)
                            .map_err(|_| "duration 超出范围（2–15 秒）".to_string())?;
                        Some(validate_duration(duration)?)
                    }
                };
                Ok(ParsedArgs {
                    prompt,
                    resolution,
                    duration_s,
                })
            }
        }
    }

    /// 本次实际要用的图片尺寸。`None` = 没点名，由上游客户端取配置里的默认值。
    fn requested_size(&self) -> Option<&str> {
        match self.kind {
            MediaKind::Image => self.user_size.as_deref(),
            MediaKind::Video => None,
        }
    }

    fn target_label(&self, parsed: &ParsedArgs) -> String {
        match self.kind {
            MediaKind::Image => format!(
                "image:{}",
                self.requested_size().unwrap_or(&self.default_size)
            ),
            MediaKind::Video => format!(
                "video:{}/{}s",
                parsed
                    .resolution
                    .as_deref()
                    .unwrap_or(&self.default_resolution),
                parsed.duration_s.unwrap_or(self.default_duration_s)
            ),
        }
    }

    /// 成功回执：告诉模型"卡片已经给了，别重复生成"。
    fn success_content(&self, asset: &MediaAsset) -> String {
        let size = if asset.kind == "image" {
            match (asset.width, asset.height) {
                (Some(width), Some(height)) => format!("{width}×{height}"),
                _ => asset.resolution.clone().unwrap_or_default(),
            }
        } else {
            asset.resolution.clone().unwrap_or_default()
        };
        format!(
            "{label}已生成（{size}，{}），卡片已经出现在回答里。\
             不要重复调用生成工具；用一两句话说明画面内容即可。",
            format_size(asset.bytes as u64),
            label = self.kind.label()
        )
    }

    /// 给视频抽一帧封面并登记。
    ///
    /// 抽帧的三段（没有 ffmpeg / 抽帧报错 / 落盘或写库失败）都由
    /// [`crate::media::poster::ensure`] 收在一个返回值里，这里只负责记 warn：
    /// 视频已经生成好了，封面拿不到最多是卡片上少一张图，**不能**让用户以为
    /// 生成失败。老视频没有封面走端点的按需补帧（同一份 `ensure`）。
    async fn attach_poster(&self, media_id: &str, source_relative: &str) {
        if let Err(err) = crate::media::poster::ensure(
            &self.pool,
            &self.store,
            media_id,
            &self.conversation_id,
            source_relative,
        )
        .await
        {
            tracing::warn!(
                conversation_id = %self.conversation_id,
                media_id = %media_id,
                %err,
                "视频封面不可用，卡片回退到占位块"
            );
        }
    }
}

struct ParsedArgs {
    prompt: String,
    resolution: Option<String>,
    duration_s: Option<u32>,
}

/// prompt 上限：视频描述写长一点很常见，但几万字那种是把整篇文章塞进来了。
const MAX_PROMPT_CHARS: usize = 2_000;

/// 用户原话里的显式尺寸：`1024*1024` / `1024x1024` / `1024×1024`。
///
/// 为什么用正则而不是"让模型自己判断该用多大"：尺寸直接决定账单，
/// 判错的代价是用户拿到一张自己没要的图。机械匹配的失败模式是"漏认"，
/// 漏认会回落到配置默认值，代价远小于让模型替用户改配置。
static SIZE_PATTERN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();

fn size_in_text(text: &str) -> Option<String> {
    let pattern = SIZE_PATTERN.get_or_init(|| {
        regex::Regex::new(r"(?i)(\d{2,4})\s*[*x×]\s*(\d{2,4})").expect("尺寸正则编译失败")
    });
    let caps = pattern.captures(text)?;
    let raw = format!("{}*{}", &caps[1], &caps[2]);
    match validate_size(&raw) {
        Ok(size) => Some(size),
        // 用户说了个用不了的尺寸：不静默改大小，按"没点名"处理，但留一条证据。
        Err(reason) => {
            tracing::warn!(size = %raw, %reason, "用户原话里的尺寸不可用，回落到配置默认");
            None
        }
    }
}

fn validate_size(raw: &str) -> Result<String, String> {
    let raw = raw.trim();
    let (width, height) = raw
        .split_once('*')
        .ok_or_else(|| format!("尺寸\"{raw}\"格式应为 宽*高，例如 1024*1024"))?;
    let parse = |part: &str| {
        part.trim()
            .parse::<u32>()
            .map_err(|_| format!("尺寸\"{raw}\"里的宽高必须是整数"))
    };
    let (width, height) = (parse(width)?, parse(height)?);
    if !IMAGE_SIDE_RANGE.contains(&width) || !IMAGE_SIDE_RANGE.contains(&height) {
        return Err(format!(
            "尺寸\"{raw}\"超出范围：宽高都要在 {}–{} 之间",
            IMAGE_SIDE_RANGE.start(),
            IMAGE_SIDE_RANGE.end()
        ));
    }
    Ok(format!("{width}*{height}"))
}

fn validate_resolution(raw: &str) -> Result<String, String> {
    let normalized = raw.trim().to_ascii_uppercase();
    if VIDEO_RESOLUTIONS.contains(&normalized.as_str()) {
        return Ok(normalized);
    }
    Err(format!(
        "resolution=\"{raw}\" 不支持；只能是 {}",
        VIDEO_RESOLUTIONS.join(" / ")
    ))
}

fn validate_duration(seconds: u32) -> Result<u32, String> {
    if VIDEO_DURATION_RANGE.contains(&seconds) {
        return Ok(seconds);
    }
    Err(format!(
        "duration={seconds} 超出范围：只能是 {}–{} 秒",
        VIDEO_DURATION_RANGE.start(),
        VIDEO_DURATION_RANGE.end()
    ))
}

#[async_trait::async_trait]
impl LocalTool for GenerateMediaTool {
    fn spec(&self) -> ToolSpec {
        match self.kind {
            // 描述里的默认尺寸取自配置：写死一个数字就会出现"描述说 1328、
            // 配置是 1024"，模型按描述传参，配置永远不生效。
            MediaKind::Image => ToolSpec::generate_image(&self.default_size),
            MediaKind::Video => ToolSpec::generate_video(),
        }
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let target_hint = format!("{}:invalid", self.kind.asset_kind());
        let parsed = match self.parse(arguments) {
            Ok(parsed) => parsed,
            Err(reason) => {
                return fail(
                    format!("无法生成{}：{reason}", self.kind.label()),
                    target_hint,
                );
            }
        };

        let target = self.target_label(&parsed);
        let request = MediaRequest {
            prompt: parsed.prompt.as_str(),
            size: self.requested_size(),
            resolution: parsed.resolution.as_deref(),
            duration_s: parsed.duration_s,
        };

        // 每次生成一个独立目录：同一轮里两张图的产物不该混在一个 task 下。
        let directory = crate::ids::new_id("media");
        let artifact = match self.kind {
            MediaKind::Image => self.backend.image(request, &self.store, &directory).await,
            MediaKind::Video => self.backend.video(request, &self.store, &directory).await,
        };
        let artifact = match artifact {
            Ok(artifact) => artifact,
            Err(err) => {
                tracing::warn!(
                    conversation_id = %self.conversation_id,
                    tool = self.kind.tool_name(),
                    model = %self.model,
                    error = %err.message(),
                    "媒体生成失败"
                );
                return fail(
                    format!("生成{}失败：{}", self.kind.label(), err.message()),
                    target,
                );
            }
        };

        let asset = MediaAsset {
            id: crate::ids::new_id(self.kind.asset_kind()),
            kind: self.kind.asset_kind().to_string(),
            mime: artifact.mime.to_string(),
            bytes: artifact.bytes as i64,
            model: self.model.clone(),
            prompt: parsed.prompt.clone(),
            width: artifact.width,
            height: artifact.height,
            duration_ms: artifact.duration_ms,
            resolution: match self.kind {
                MediaKind::Image => None,
                MediaKind::Video => Some(
                    parsed
                        .resolution
                        .clone()
                        .unwrap_or_else(|| self.default_resolution.clone()),
                ),
            },
            created_at: crate::clock::now_ms(),
        };

        if let Err(err) = crate::media::records::insert_asset(
            &self.pool,
            &self.conversation_id,
            &asset,
            &artifact.relative_path,
        )
        .await
        {
            // 文件已经落盘了：不留记录等于"生成了但再也打不开"，必须说清而不是装作成功。
            tracing::error!(
                conversation_id = %self.conversation_id,
                path = %artifact.relative_path,
                %err,
                "媒体产物登记失败"
            );
            return fail(
                format!(
                    "{}已生成但登记失败（产物在 {}），请重试或查看服务日志",
                    self.kind.label(),
                    artifact.absolute_path
                ),
                target,
            );
        }

        // 抽帧放在登记成功之后：封面只是一条 UPDATE，失败连这条媒体记录都不影响。
        if matches!(self.kind, MediaKind::Video) {
            self.attach_poster(&asset.id, &artifact.relative_path).await;
        }

        tracing::info!(
            conversation_id = %self.conversation_id,
            tool = self.kind.tool_name(),
            model = %self.model,
            path = %artifact.relative_path,
            bytes = artifact.bytes,
            elapsed_ms = artifact.elapsed_ms,
            "媒体生成完成"
        );

        let content = self.success_content(&asset);
        LocalToolOutcome {
            content,
            sources: Vec::new(),
            ok: true,
            target,
            ui: vec![ChatUiAction::Media {
                asset: Box::new(asset),
            }],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unknown_resolution_before_spending_money() {
        assert!(validate_resolution("480P").is_ok());
        assert!(validate_resolution("1080p").is_ok(), "大小写不该成为障碍");
        let error = validate_resolution("2K").expect_err("非法档位应拒绝");
        assert!(error.contains("480P / 720P / 1080P"), "{error}");
    }

    #[test]
    fn duration_is_bounded() {
        assert_eq!(validate_duration(2).expect("下界合法"), 2);
        assert_eq!(validate_duration(15).expect("上界合法"), 15);
        assert!(validate_duration(1).is_err());
        assert!(validate_duration(16).is_err());
    }

    #[test]
    fn size_must_be_width_height() {
        assert_eq!(validate_size("1328*1328").expect("合法"), "1328*1328");
        assert!(validate_size("1328x1328").is_err());
        assert!(validate_size("100*100").is_err(), "过小的尺寸应拒绝");
        assert!(validate_size("*1328").is_err());
    }

    #[test]
    fn size_is_read_only_from_the_users_own_words() {
        assert_eq!(
            size_in_text("画一只在窗台上晒太阳的橘猫"),
            None,
            "没点名尺寸就该回落到配置默认值"
        );
        assert_eq!(
            size_in_text("来一张 1024x1024 的方图").as_deref(),
            Some("1024*1024")
        );
        assert_eq!(
            size_in_text("竖版 1024 × 1536").as_deref(),
            Some("1024*1536"),
            "乘号与空格都要认"
        );
        assert_eq!(size_in_text("16:9 的横图"), None, "比例不是像素尺寸");
        assert_eq!(size_in_text("100x100 的小图"), None, "超出档位范围不算点名");
    }
}
