//! 总结语音合成。
//!
//! 百炼原生 TTS 接口返回的是一个临时音频 URL，不是音频字节：
//! 服务端必须在合成请求成功后立刻下载并落盘，客户端只面对自己的
//! `/summary/audio` 下载端点，不接触厂商地址与密钥。

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use reqwest::Client;
use serde_json::{json, Value};

use crate::config::Config;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TtsError {
    /// 未启用、缺少密钥或 provider 不可用；重试不会变好。
    Unavailable(String),
    /// 上游调用失败、超时或返回不可解析，值得重试。
    Failed(String),
}

impl TtsError {
    pub fn message(&self) -> &str {
        match self {
            Self::Unavailable(reason) | Self::Failed(reason) => reason,
        }
    }
}

impl std::fmt::Display for TtsError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(_) => formatter.write_str("语音合成服务未就绪"),
            Self::Failed(_) => formatter.write_str("语音合成失败"),
        }
    }
}

impl std::error::Error for TtsError {}

#[async_trait]
pub trait SpeechSynthesizer: Send + Sync + std::fmt::Debug {
    async fn synthesize(&self, text: &str) -> Result<Vec<u8>, TtsError>;
    fn model(&self) -> &str;
    fn voice(&self) -> &str;
    fn format(&self) -> &str;
}

/// 百炼原生 `/api/v1/services/audio/tts/SpeechSynthesizer`。
#[derive(Debug)]
pub struct NativeTts {
    client: Client,
    download_client: Client,
    url: String,
    api_key: String,
    model: String,
    voice: String,
    format: String,
    sample_rate: u32,
    max_audio_bytes: i64,
}

impl NativeTts {
    pub fn new(config: &Config, api_key: String) -> Self {
        let timeout = Duration::from_millis(config.tts.timeout_ms.max(1_000));
        let download_timeout = Duration::from_millis(config.tts.download_timeout_ms.max(1_000));
        Self {
            client: Client::builder()
                .timeout(timeout)
                .build()
                .unwrap_or_else(|err| {
                    tracing::error!(%err, "构建 TTS 客户端失败，使用默认配置");
                    Client::new()
                }),
            download_client: Client::builder()
                .timeout(download_timeout)
                .build()
                .unwrap_or_else(|err| {
                    tracing::error!(%err, "构建 TTS 下载客户端失败，使用默认配置");
                    Client::new()
                }),
            url: format!("{}{}", config.tts_upstream_base_url(), config.tts.path),
            api_key,
            model: config.tts.model.clone(),
            voice: config.tts.voice.clone(),
            format: config.tts.format.clone(),
            sample_rate: config.tts.sample_rate,
            max_audio_bytes: config.tts.max_audio_bytes.max(1),
        }
    }

    fn request_body(&self, text: &str) -> Value {
        json!({
            "model": self.model,
            "input": {
                "text": text,
                "voice": self.voice
            },
            "parameters": {
                "format": self.format,
                "sample_rate": self.sample_rate
            }
        })
    }

    async fn download(&self, url: &str) -> Result<Vec<u8>, TtsError> {
        if let Some(encoded) = url.strip_prefix("data:") {
            let payload = encoded
                .split_once(",")
                .map(|(_, value)| value)
                .unwrap_or(encoded);
            return base64::engine::general_purpose::STANDARD
                .decode(payload)
                .map_err(|err| TtsError::Failed(format!("解析内联音频失败：{err}")));
        }

        let response = self
            .download_client
            .get(url)
            .send()
            .await
            .map_err(|err| TtsError::Failed(format!("下载合成音频失败：{err}")))?;
        let status = response.status();
        if !status.is_success() {
            return Err(TtsError::Failed(format!(
                "下载合成音频返回 HTTP {}",
                status.as_u16()
            )));
        }
        if let Some(length) = response.content_length() {
            if length as i64 > self.max_audio_bytes {
                return Err(TtsError::Failed("合成音频超过大小上限".to_string()));
            }
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|err| TtsError::Failed(format!("读取合成音频失败：{err}")))?;
        if bytes.len() as i64 > self.max_audio_bytes {
            return Err(TtsError::Failed("合成音频超过大小上限".to_string()));
        }
        Ok(bytes.to_vec())
    }
}

#[async_trait]
impl SpeechSynthesizer for NativeTts {
    async fn synthesize(&self, text: &str) -> Result<Vec<u8>, TtsError> {
        let body = self.request_body(text);
        let response = self
            .client
            .post(&self.url)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|err| TtsError::Failed(format!("请求语音合成服务失败：{err}")))?;

        let status = response.status();
        let raw = response
            .text()
            .await
            .map_err(|err| TtsError::Failed(format!("读取语音合成响应失败：{err}")))?;

        if !status.is_success() {
            let detail: String = raw.trim().chars().take(300).collect();
            return Err(match status.as_u16() {
                401 | 403 => {
                    TtsError::Unavailable("语音合成鉴权失败，请检查 tts 配置的密钥".to_string())
                }
                404 => TtsError::Unavailable(format!("语音合成端点不存在：{}", self.url)),
                400 => TtsError::Failed(format!("上游拒绝了这段文本：{detail}")),
                _ => TtsError::Failed(format!("上游返回 HTTP {status}：{detail}")),
            });
        }

        let value: Value = serde_json::from_str(&raw)
            .map_err(|err| TtsError::Failed(format!("语音合成响应不是合法 JSON：{err}")))?;
        let url = value
            .pointer("/output/audio/url")
            .and_then(Value::as_str)
            .or_else(|| value.pointer("/output/audio/data").and_then(Value::as_str))
            .ok_or_else(|| {
                TtsError::Failed(format!(
                    "语音合成响应里没有音频地址：{}",
                    raw.chars().take(200).collect::<String>()
                ))
            })?;

        self.download(url).await
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn voice(&self) -> &str {
        &self.voice
    }

    fn format(&self) -> &str {
        &self.format
    }
}

/// 测试用：不访问网络，返回可断言的固定字节。
#[derive(Debug)]
pub struct MockTts {
    model: String,
    voice: String,
    format: String,
}

impl MockTts {
    pub fn new() -> Self {
        Self {
            model: "mock-tts".to_string(),
            voice: "mock-voice".to_string(),
            format: "mp3".to_string(),
        }
    }
}

impl Default for MockTts {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl SpeechSynthesizer for MockTts {
    async fn synthesize(&self, text: &str) -> Result<Vec<u8>, TtsError> {
        Ok(format!("mock-audio:{}", text.chars().count()).into_bytes())
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn voice(&self) -> &str {
        &self.voice
    }

    fn format(&self) -> &str {
        &self.format
    }
}

pub fn from_config(config: &Config) -> Option<Arc<dyn SpeechSynthesizer>> {
    if !config.tts.enabled {
        return None;
    }
    let Some(api_key) = config.tts_api_key() else {
        tracing::warn!("tts.enabled=true 但密钥为空：总结只出文字，不合成语音");
        return None;
    };
    Some(Arc::new(NativeTts::new(config, api_key)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::TtsConfig;

    #[test]
    fn request_body_contains_voice_and_format() {
        let config = Config {
            tts: TtsConfig {
                enabled: true,
                voice: "longanhuan_v3.1".to_string(),
                format: "mp3".to_string(),
                sample_rate: 24_000,
                ..TtsConfig::default()
            },
            ..Config::default()
        };
        let tts = NativeTts::new(&config, "key".to_string());
        let body = tts.request_body("你好");
        assert_eq!(body["input"]["text"], "你好");
        assert_eq!(body["input"]["voice"], "longanhuan_v3.1");
        assert_eq!(body["parameters"]["format"], "mp3");
        assert_eq!(body["parameters"]["sample_rate"], 24_000);
    }
}
