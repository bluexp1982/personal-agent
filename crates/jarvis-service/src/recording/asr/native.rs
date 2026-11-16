//! 百炼原生 ASR：`/api/v1/services/aigc/multimodal-generation/generation`。
//!
//! 兼容层 `/compatible-mode/v1` 没有 ASR 端点，`qwen-audio-3.1-asr-flash`
//! 只能走这条原生路径。请求形状与参考项目一致：
//!
//! ```json
//! {
//!   "model": "qwen-audio-3.1-asr-flash",
//!   "input": { "messages": [{ "role": "user", "content": [{ "audio": "data:audio/wav;base64,..." }] }] },
//!   "parameters": { "format": "wav", "asr_options": { "language": "zh", "enable_itn": true } }
//! }
//! ```
//!
//! `parameters.format` 是必填项：缺了网关会直接返回 400（甚至空响应体）。

use async_trait::async_trait;
use base64::Engine;
use serde_json::{json, Value};

use super::openai::{
    clean_transcript, empty_transcript_error, extract_text, is_no_words_error, status_error,
    transcript_structure_present,
};
use super::{AsrError, SpeechToText};

#[derive(Debug)]
pub struct MultimodalAsr {
    client: reqwest::Client,
    url: String,
    model: String,
    api_key: String,
}

impl MultimodalAsr {
    pub fn new(client: reqwest::Client, url: String, model: String, api_key: String) -> Self {
        Self {
            client,
            url,
            model,
            api_key,
        }
    }

    fn request_body(&self, data_url: String, language: Option<&str>) -> Value {
        let mut asr_options = json!({ "enable_itn": true });
        if let Some(language) = language.filter(|value| !value.trim().is_empty()) {
            asr_options["language"] = json!(language);
        }

        json!({
            "model": self.model,
            "input": {
                "messages": [{
                    "role": "user",
                    "content": [{ "audio": data_url }]
                }]
            },
            "parameters": {
                "format": "wav",
                "asr_options": asr_options
            }
        })
    }
}

#[async_trait]
impl SpeechToText for MultimodalAsr {
    async fn transcribe(&self, wav: &[u8], language: Option<&str>) -> Result<String, AsrError> {
        let encoded = base64::engine::general_purpose::STANDARD.encode(wav);
        let data_url = format!("data:audio/wav;base64,{encoded}");
        let body = self.request_body(data_url, language);

        let response = self
            .client
            .post(&self.url)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|err| AsrError::Failed(format!("请求转写服务失败：{err}")))?;

        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|err| AsrError::Failed(format!("读取转写响应失败：{err}")))?;

        if !status.is_success() {
            // 纯噪声/瞬态会得到 400 + ASR_RESPONSE_HAVE_NO_WORDS：这是"没说话"，
            // 不是故障。落成空文本，由界面显示为一段没有语音的记录。
            if is_no_words_error(&text) {
                return Ok(String::new());
            }
            return Err(status_error(status, &text, &self.url));
        }

        let value: Value = serde_json::from_str(&text)
            .map_err(|err| AsrError::Failed(format!("转写响应不是合法 JSON：{err}")))?;

        let Some(raw) = extract_text(&value) else {
            if transcript_structure_present(&value) {
                return Ok(String::new());
            }
            return Err(empty_transcript_error(&text));
        };
        let cleaned = clean_transcript(&raw);
        if cleaned.is_empty() {
            return Ok(String::new());
        }
        Ok(cleaned)
    }

    fn model(&self) -> &str {
        &self.model
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_matches_native_shape() {
        let asr = MultimodalAsr::new(
            reqwest::Client::new(),
            "http://127.0.0.1/asr".to_string(),
            "qwen-audio-3.1-asr-flash".to_string(),
            "key".to_string(),
        );
        let body = asr.request_body("data:audio/wav;base64,AA==".to_string(), Some("zh"));
        assert_eq!(body["model"], "qwen-audio-3.1-asr-flash");
        assert_eq!(
            body["input"]["messages"][0]["content"][0]["audio"],
            "data:audio/wav;base64,AA=="
        );
        assert_eq!(body["parameters"]["format"], "wav");
        assert_eq!(body["parameters"]["asr_options"]["language"], "zh");
        assert_eq!(body["parameters"]["asr_options"]["enable_itn"], true);
    }

    #[test]
    fn parses_native_sentence_response() {
        let value = json!({
            "text": "测试测试，一二三。",
            "output": { "sentence": { "text": "测试测试，一二三。" } }
        });
        assert_eq!(extract_text(&value).as_deref(), Some("测试测试，一二三。"));
    }
}
