//! 语音转写能力抽象。
//!
//! 与 `llm` 同一条纪律：**真密钥只在 service 进程里**，客户端既不直连厂商、
//! 也不持有 Key。客户端只面对 `/api/recordings/*`，不关心背后是哪家模型。
//!
//! 当前实现覆盖三种形态：
//! - `multimodal`：百炼原生 `/api/v1/services/aigc/multimodal-generation/generation`；
//! - `chat_audio`：音频以 data URL 放进 chat completions 的 `input_audio`；
//! - `transcriptions`：OpenAI 兼容 `/audio/transcriptions` 的 multipart。
//!
//! endpoint / model / 超时全部进配置，代码里不写死。

mod native;
mod openai;

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;

use crate::config::Config;

pub use native::MultimodalAsr;
pub use openai::{ChatAudioAsr, MockAsr, TranscriptionsAsr};

/// 转写失败的两类原因。客户端据此决定"稍后重试"还是"去改配置"。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsrError {
    /// 未配置、密钥缺失或 provider 不可用：重试不会变好，除非改配置。
    Unavailable(String),
    /// 上游调用失败：网络、超时、限流或返回不可解析，值得重试。
    Failed(String),
}

impl AsrError {
    pub fn message(&self) -> &str {
        match self {
            Self::Unavailable(reason) | Self::Failed(reason) => reason,
        }
    }
}

/// 面向用户的失败提示。写进分段的 `error` 字段，详情页直接展示。
impl std::fmt::Display for AsrError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(_) => f.write_str("转写服务未就绪，音频已保存；开启后可重试"),
            Self::Failed(_) => f.write_str("转写失败，音频已保存；可稍后重试"),
        }
    }
}

impl std::error::Error for AsrError {}

/// 一段音频的转写能力。实现必须线程安全：会被多个并发任务同时调用。
#[async_trait]
pub trait SpeechToText: Send + Sync + std::fmt::Debug {
    /// 返回转写文本。
    ///
    /// 上游**明确表示没有语音**（如 `ASR_RESPONSE_HAVE_NO_WORDS`）时返回空串，
    /// 由上层落成"ready、无文本"，不要当成失败；只有响应形态不对（例如只有
    /// `status_message` 的占位体）才返回错误。
    async fn transcribe(&self, wav: &[u8], language: Option<&str>) -> Result<String, AsrError>;

    /// 实际使用的模型标识，只用于展示与日志。
    fn model(&self) -> &str;
}

/// 按配置装配。未开启或缺少密钥时返回 `None`：
/// 此时录音仍然能上传归档，只是不出文本。
pub fn from_config(config: &Config) -> Option<Arc<dyn SpeechToText>> {
    if !config.asr.enabled {
        return None;
    }

    if config.asr.provider == "mock" {
        tracing::warn!("转写使用 mock provider：不访问网络，只用于测试与本地验收");
        return Some(Arc::new(MockAsr::new(&config.asr.model)));
    }

    let key = match config.asr_api_key() {
        Some(key) => key,
        None => {
            tracing::warn!(
                env = config.asr_api_key_env(),
                "asr.enabled=true 但密钥为空：录音只归档，不出转写文本"
            );
            return None;
        }
    };

    let url = format!("{}{}", config.asr_upstream_base_url(), config.asr_path());
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_millis(config.asr.timeout_ms.max(1_000)))
        .build()
    {
        Ok(client) => client,
        Err(err) => {
            tracing::error!(%err, "构建转写 HTTP 客户端失败");
            return None;
        }
    };
    let model = config.asr.model.clone();

    match config.asr.provider.as_str() {
        "multimodal" => Some(Arc::new(MultimodalAsr::new(client, url, model, key))),
        "chat_audio" => Some(Arc::new(ChatAudioAsr::new(
            client,
            url,
            model,
            key,
            config.asr.prompt.clone(),
        ))),
        "transcriptions" => Some(Arc::new(TranscriptionsAsr::new(client, url, model, key))),
        other => {
            tracing::error!(provider = %other, "未知的 asr.provider，转写已禁用");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn mock_returns_text_without_network() {
        let asr = MockAsr::new("mock-model");
        let text = asr
            .transcribe(b"fake-wav", Some("zh"))
            .await
            .expect("mock 不该失败");
        assert!(text.contains("语音片段"));
        assert_eq!(asr.model(), "mock-model");
    }

    #[test]
    fn disabled_config_builds_nothing() {
        let config = Config::default();
        assert!(
            from_config(&config).is_none(),
            "默认关闭时不应装配 provider"
        );
    }
}
