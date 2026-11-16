//! 录音笔记载荷。字段与 `api-spec/openapi.yaml` 一致。
//!
//! 定位：转写稿是主数据，音频是归档。客户端先在本地分段落盘，再按模式上传：
//! - `realtime`：每段闭合就上传，服务端内联转写并回传该段文本；
//! - `batch`：录音期间不上传，`complete` 后由服务端后台整体转写。
//!
//! 时间统一 Unix 毫秒；录音内的秒数用毫秒；分页沿用 cursor（`updated_at` + `id`）。

use serde::{Deserialize, Serialize};

use crate::cursor::Cursor;

/// 上传/转写模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecordingMode {
    /// 边录边传、边转写。
    Realtime,
    /// 录完再整体上传、整体转写。
    Batch,
}

impl RecordingMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Realtime => "realtime",
            Self::Batch => "batch",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "realtime" => Some(Self::Realtime),
            "batch" => Some(Self::Batch),
            _ => None,
        }
    }
}

/// 一条录音的聚合状态。
///
/// `partial` 是刻意保留的中间态：一段失败就让整条转写失败不诚实，
/// 直接标 `ready` 又会把缺失藏起来。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecordingStatus {
    /// 正在录（客户端已创建记录但还没 complete）。
    Recording,
    /// 录音结束，等待上传或转写。
    Recorded,
    /// 转写进行中。
    Transcribing,
    /// 全部段落转写完成。
    Ready,
    /// 部分段落失败，其余可用。
    Partial,
    /// 全部失败或没有可用段落。
    Failed,
}

impl RecordingStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Recording => "recording",
            Self::Recorded => "recorded",
            Self::Transcribing => "transcribing",
            Self::Ready => "ready",
            Self::Partial => "partial",
            Self::Failed => "failed",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "recording" => Some(Self::Recording),
            "recorded" => Some(Self::Recorded),
            "transcribing" => Some(Self::Transcribing),
            "ready" => Some(Self::Ready),
            "partial" => Some(Self::Partial),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// 录音总结的生成状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SummaryStatus {
    /// 还没生成过（历史录音或刚转写完）。
    #[default]
    None,
    /// 已排队，等待生成。
    Pending,
    /// 正在调用模型生成。
    Running,
    /// 已生成。
    Ready,
    /// 生成失败，等待用户手动重试。
    Failed,
}

impl SummaryStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "none" => Some(Self::None),
            "pending" => Some(Self::Pending),
            "running" => Some(Self::Running),
            "ready" => Some(Self::Ready),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// 总结 TTS 音频的合成状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SummaryAudioStatus {
    #[default]
    None,
    Pending,
    Running,
    Ready,
    Failed,
}

impl SummaryAudioStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "none" => Some(Self::None),
            "pending" => Some(Self::Pending),
            "running" => Some(Self::Running),
            "ready" => Some(Self::Ready),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// 总结形式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SummaryStyle {
    /// 会议纪要：概要 + 关键要点 + 待办/结论。
    Minutes,
    /// 3–5 句话的简短摘要（新录音默认）。
    #[default]
    Brief,
    /// 按话题分段的详细摘要。
    Detailed,
}

impl SummaryStyle {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Minutes => "minutes",
            Self::Brief => "brief",
            Self::Detailed => "detailed",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "minutes" => Some(Self::Minutes),
            "brief" => Some(Self::Brief),
            "detailed" => Some(Self::Detailed),
            _ => None,
        }
    }
}

/// 录音总结与其语音状态。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RecordingSummary {
    pub status: SummaryStatus,
    #[serde(default)]
    pub text: String,
    /// 当前总结正文实际使用的形式；未生成过时省略。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub style: Option<SummaryStyle>,
    /// 用户选中的下一版形式；已有正文尚未按它重生时与 `style` 不同。
    #[serde(default)]
    pub style_preference: SummaryStyle,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<i64>,
    pub audio_status: SummaryAudioStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_error: Option<String>,
    #[serde(default)]
    pub audio_bytes: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_format: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_updated_at: Option<i64>,
    #[serde(default)]
    pub audio_truncated: bool,
}

/// 总结语音的波形峰值。
///
/// `peaks` 是定长（[`SummaryAudioPeaks::buckets`]）的 `0..255` 线性幅度，
/// 按时间顺序排列；服务端只负责解码与取最大值，视觉映射在客户端做。
/// `version` 直接复用 `summary.audio_updated_at`：重新生成语音后版本变化，
/// 客户端据此丢弃旧缓存。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SummaryAudioPeaks {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<i64>,
    pub buckets: u32,
    pub peaks: Vec<u8>,
}

/// 只保存总结形式，不触发生成。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingSummaryStyleUpdate {
    pub style: SummaryStyle,
}

/// 按指定形式重新生成总结；省略时使用已保存的 preference。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RecordingSummaryGenerate {
    #[serde(default)]
    pub style: Option<SummaryStyle>,
}

/// 单个音频分段的转写状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SegmentState {
    /// 音频已落盘，还没转写。
    Stored,
    /// 正在转写。
    Transcribing,
    /// 转写完成（文本可能为空：静音段）。
    Ready,
    /// 转写失败，可重试。
    Failed,
}

impl SegmentState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Stored => "stored",
            Self::Transcribing => "transcribing",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "stored" => Some(Self::Stored),
            "transcribing" => Some(Self::Transcribing),
            "ready" => Some(Self::Ready),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// 列表与详情共用的录音元信息。
///
/// `preview` 是转写稿前若干个字，列表页不需要为每一行再拉一次详情。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Recording {
    pub id: String,
    /// 客户端生成的稳定标识，用于重试与断点续传时幂等创建。
    pub client_recording_id: String,
    pub title: String,
    pub mode: RecordingMode,
    pub status: RecordingStatus,
    /// 音频总时长（毫秒）。
    pub duration_ms: i64,
    /// 已上传音频的总字节数。
    pub bytes: i64,
    pub segment_count: i64,
    /// 已转写成功的段数。
    pub ready_count: i64,
    /// 转写稿开头一小段，供列表预览；完整文本看详情。
    pub preview: String,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 新建录音。客户端在开始录音时调用（realtime 模式必须在录完前建好）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingCreate {
    /// 客户端生成的标识；同一个值重复创建返回已有记录（幂等）。
    pub client_recording_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub mode: RecordingMode,
}

/// 重命名。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingUpdate {
    pub title: String,
}

/// 一个音频分段。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingSegment {
    /// 录音内单调序号，从 0 开始。
    pub seq: u32,
    /// 相对录音开头的偏移。
    pub start_ms: i64,
    pub end_ms: i64,
    /// 音频字节数（WAV 文件大小，含头）。
    pub bytes: i64,
    /// 转写文本；`stored` / `failed` 时为空。
    pub text: String,
    pub state: SegmentState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 录音详情：元信息 + 全部分段 + 总结。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingDetail {
    pub recording: Recording,
    #[serde(default)]
    pub segments: Vec<RecordingSegment>,
    #[serde(default)]
    pub summary: RecordingSummary,
}

/// 结束录音。`duration_ms` 由客户端给出时优先采信（比"最后一段的 end_ms"更准）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RecordingComplete {
    #[serde(default)]
    pub duration_ms: Option<i64>,
}

/// 转写能力与配额。客户端据此决定"仅本地"还是"允许上传"。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingInfo {
    /// 服务端是否开启转写（`asr.enabled`）。
    pub asr_enabled: bool,
    /// 转写是否真的可用（开启 + 配了密钥 + provider 就绪）。
    pub asr_available: bool,
    /// 实际使用的模型标识；未配置时省略。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub asr_model: Option<String>,
    /// 单个分段的大小上限。
    pub max_segment_bytes: i64,
    /// 单条录音的时长上限（毫秒）。
    pub max_duration_ms: i64,
    /// 单条录音的音频总量上限。
    pub max_total_bytes: i64,
    /// 总结能力是否就绪（模型已配置）。
    #[serde(default)]
    pub summary_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary_model: Option<String>,
    /// 新录音自动总结使用的默认形式。
    #[serde(default)]
    pub summary_default_style: SummaryStyle,
    /// TTS 配置是否开启。
    #[serde(default)]
    pub tts_enabled: bool,
    /// TTS 是否真的可用（开启 + 密钥 + provider 就绪）。
    #[serde(default)]
    pub tts_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tts_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tts_voice: Option<String>,
}

/// 录音列表页。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingPage {
    pub items: Vec<Recording>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

impl RecordingPage {
    pub fn from_items(items: Vec<Recording>, cursor: Option<Cursor>) -> Self {
        Self {
            items,
            next_cursor: cursor.map(|cursor| cursor.encode()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_style_wire_values() {
        for style in [
            SummaryStyle::Minutes,
            SummaryStyle::Brief,
            SummaryStyle::Detailed,
        ] {
            let value = serde_json::to_value(style).expect("序列化失败");
            let raw = value.as_str().expect("应为字符串");
            assert_eq!(SummaryStyle::parse(raw), Some(style));
        }
        assert_eq!(SummaryStyle::default(), SummaryStyle::Brief);
    }

    #[test]
    fn mode_and_status_roundtrip() {
        for mode in [RecordingMode::Realtime, RecordingMode::Batch] {
            assert_eq!(RecordingMode::parse(mode.as_str()), Some(mode));
        }
        for status in [
            RecordingStatus::Recording,
            RecordingStatus::Recorded,
            RecordingStatus::Transcribing,
            RecordingStatus::Ready,
            RecordingStatus::Partial,
            RecordingStatus::Failed,
        ] {
            assert_eq!(RecordingStatus::parse(status.as_str()), Some(status));
        }
        for state in [
            SegmentState::Stored,
            SegmentState::Transcribing,
            SegmentState::Ready,
            SegmentState::Failed,
        ] {
            assert_eq!(SegmentState::parse(state.as_str()), Some(state));
        }
        assert_eq!(RecordingMode::parse("REALTIME"), None);
        assert_eq!(RecordingStatus::parse("done"), None);
    }

    #[test]
    fn detail_serializes_nested_recording_and_omits_absent_error() {
        let detail = RecordingDetail {
            recording: Recording {
                id: "rec_1".to_string(),
                client_recording_id: "local-1".to_string(),
                title: "周会".to_string(),
                mode: RecordingMode::Realtime,
                status: RecordingStatus::Partial,
                duration_ms: 65_000,
                bytes: 2_000_000,
                segment_count: 3,
                ready_count: 2,
                preview: "今天先对齐目标".to_string(),
                created_at: 1,
                updated_at: 2,
            },
            segments: vec![RecordingSegment {
                seq: 0,
                start_ms: 0,
                end_ms: 20_000,
                bytes: 640_000,
                text: "今天先对齐目标".to_string(),
                state: SegmentState::Ready,
                error: None,
            }],
            summary: RecordingSummary::default(),
        };

        let value = serde_json::to_value(&detail).expect("序列化失败");
        assert_eq!(value["recording"]["mode"], "realtime");
        assert_eq!(value["recording"]["status"], "partial");
        assert_eq!(value["segments"][0]["state"], "ready");
        assert!(
            value["segments"][0].get("error").is_none(),
            "没有错误时不该下发 error 字段"
        );
    }

    #[test]
    fn create_request_defaults_title() {
        let request: RecordingCreate =
            serde_json::from_str(r#"{"client_recording_id":"local-1","mode":"batch"}"#)
                .expect("解析失败");
        assert!(request.title.is_none());
        assert_eq!(request.mode, RecordingMode::Batch);
    }
}
