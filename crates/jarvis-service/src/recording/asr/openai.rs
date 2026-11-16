//! OpenAI 兼容形态的转写实现。
//!
//! 两个 provider 的差别只在"音频怎么放进请求"：
//! - [`ChatAudioAsr`]：`input_audio` 的 data URL，走 `/chat/completions`；
//! - [`TranscriptionsAsr`]：multipart，走 `/audio/transcriptions`。
//!
//! 解析侧都尽量宽容：真实的 ASR 网关返回形态并不完全统一
//! （`choices[0].message.content` / `output.choices` / 顶层 `text`），
//! 只认一种就会在换厂商时整条链路静默出空文本。

use async_trait::async_trait;
use base64::Engine;
use serde_json::{json, Value};

use super::{AsrError, SpeechToText};

/// 上游返回体里可解析为文本的位置。
pub(super) fn extract_text(value: &Value) -> Option<String> {
    let mut candidates: Vec<Option<&Value>> = vec![
        value.get("text"),
        value.pointer("/choices/0/message/content"),
        value.pointer("/output/choices/0/message/content"),
        value.pointer("/output/text"),
        value.pointer("/output/sentence/text"),
    ];

    while let Some(candidate) = candidates.pop() {
        let Some(candidate) = candidate else {
            continue;
        };
        match candidate {
            Value::String(text) => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
            // 多模态返回可能是 `[{"type":"text","text":"..."}]`。
            Value::Array(parts) => {
                let joined = parts
                    .iter()
                    .filter_map(|part| part.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("");
                if !joined.trim().is_empty() {
                    return Some(joined.trim().to_string());
                }
            }
            _ => {}
        }
    }

    None
}

pub(super) fn truncate(body: &str) -> String {
    let cleaned = body.trim().replace('\n', " ");
    cleaned.chars().take(300).collect()
}

/// 上游明确表示"这段音频里没听到词"。
///
/// 百炼原生 ASR 对纯噪声/瞬态会返回 HTTP 400 + `ASR_RESPONSE_HAVE_NO_WORDS`。
/// 这不是系统故障，不能落成"上游拒绝了这段音频"，否则界面会出现
/// "部分失败"并让用户反复重试一段根本没有语音的音频。
pub(super) fn is_no_words_error(body: &str) -> bool {
    let lower = body.to_ascii_lowercase();
    lower.contains("asr_response_have_no_words")
        || lower.contains("have_no_words")
        || lower.contains("no words")
        || lower.contains("no speech")
}

/// 返回体里是否有"转写结果"的结构。
///
/// 有 `choices` / `text` / `output` 但内容为空，说明模型正常返回、只是没有语音；
/// 只有 `status_message` 这类占位体才是配置/端点不对。
pub(super) fn transcript_structure_present(value: &Value) -> bool {
    value.get("text").is_some() || value.get("output").is_some() || value.get("choices").is_some()
}

/// 把模型的"回答"收敛成转写文本。
///
/// 用通用音频模型做转写时，即使提示词已经要求"只输出原话"，仍可能带
/// `转写结果：`、引号或首尾空白；这些不清理会直接进转写稿。
pub(super) fn clean_transcript(raw: &str) -> String {
    let mut text = raw.trim();
    for prefix in [
        "转写结果：",
        "转写内容：",
        "转写：",
        "音频中的原话是：",
        "音频内容是：",
        "Transcript:",
    ] {
        if let Some(rest) = text.strip_prefix(prefix) {
            text = rest.trim();
        }
    }
    // 只剥首尾的成对引号，不动正文里的引号。
    text.trim_matches(|ch| {
        matches!(
            ch,
            '"' | '\'' | '“' | '”' | '‘' | '’' | '「' | '」' | '『' | '』'
        )
    })
    .trim()
    .to_string()
}

pub(super) fn empty_transcript_error(body: &str) -> AsrError {
    AsrError::Failed(format!(
        "上游没有返回转写文本（响应：{}）；请检查 asr.model 是否支持音频转写",
        truncate(body)
    ))
}

pub(super) fn status_error(status: reqwest::StatusCode, body: &str, url: &str) -> AsrError {
    let detail = truncate(body);
    match status.as_u16() {
        401 | 403 => AsrError::Unavailable("转写服务鉴权失败，请检查 asr 配置的密钥".to_string()),
        404 => AsrError::Unavailable(format!("转写端点不存在：{url}")),
        400 => AsrError::Failed(format!("上游拒绝了这段音频：{detail}")),
        _ => AsrError::Failed(format!("上游返回 HTTP {status}：{detail}")),
    }
}

/// 把音频塞进 chat completions 的 `input_audio`。
#[derive(Debug)]
pub struct ChatAudioAsr {
    client: reqwest::Client,
    url: String,
    model: String,
    api_key: String,
    prompt: Option<String>,
}

impl ChatAudioAsr {
    pub fn new(
        client: reqwest::Client,
        url: String,
        model: String,
        api_key: String,
        prompt: Option<String>,
    ) -> Self {
        Self {
            client,
            url,
            model,
            api_key,
            prompt,
        }
    }

    fn request_body(&self, data_url: String, language: Option<&str>) -> Value {
        let mut messages = Vec::new();
        if let Some(prompt) = self.prompt.as_deref().map(str::trim) {
            if !prompt.is_empty() {
                messages.push(json!({ "role": "system", "content": prompt }));
            }
        }
        messages.push(json!({
            "role": "user",
            "content": [{
                "type": "input_audio",
                "input_audio": { "data": data_url, "format": "wav" }
            }]
        }));

        let mut asr_options = json!({ "enable_itn": true });
        if let Some(language) = language.filter(|value| !value.trim().is_empty()) {
            asr_options["language"] = json!(language);
        }

        json!({
            "model": self.model,
            "messages": messages,
            "asr_options": asr_options,
            "temperature": 0,
            "stream": false
        })
    }
}

#[async_trait]
impl SpeechToText for ChatAudioAsr {
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

/// OpenAI 兼容的 `/audio/transcriptions`（multipart）。
#[derive(Debug)]
pub struct TranscriptionsAsr {
    client: reqwest::Client,
    url: String,
    model: String,
    api_key: String,
}

impl TranscriptionsAsr {
    pub fn new(client: reqwest::Client, url: String, model: String, api_key: String) -> Self {
        Self {
            client,
            url,
            model,
            api_key,
        }
    }
}

#[async_trait]
impl SpeechToText for TranscriptionsAsr {
    async fn transcribe(&self, wav: &[u8], language: Option<&str>) -> Result<String, AsrError> {
        let part = reqwest::multipart::Part::bytes(wav.to_vec())
            .file_name("segment.wav")
            .mime_str("audio/wav")
            .map_err(|err| AsrError::Failed(format!("构造音频分片失败：{err}")))?;

        let mut form = reqwest::multipart::Form::new()
            .part("file", part)
            .text("model", self.model.clone())
            .text("response_format", "json");
        if let Some(language) = language.filter(|value| !value.trim().is_empty()) {
            form = form.text("language", language.to_string());
        }

        let response = self
            .client
            .post(&self.url)
            .bearer_auth(&self.api_key)
            .multipart(form)
            .send()
            .await
            .map_err(|err| AsrError::Failed(format!("请求转写服务失败：{err}")))?;

        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|err| AsrError::Failed(format!("读取转写响应失败：{err}")))?;

        if !status.is_success() {
            if is_no_words_error(&text) {
                return Ok(String::new());
            }
            return Err(status_error(status, &text, &self.url));
        }

        if let Ok(value) = serde_json::from_str::<Value>(&text) {
            if let Some(raw) = extract_text(&value) {
                let cleaned = clean_transcript(&raw);
                return Ok(cleaned);
            }
            if transcript_structure_present(&value) {
                return Ok(String::new());
            }
        }
        // 有的兼容实现直接回纯文本；200 的空文本就是"没听到词"。
        Ok(clean_transcript(&text))
    }

    fn model(&self) -> &str {
        &self.model
    }
}

/// 测试与本地验收用：不访问网络，返回可断言的固定文本。
#[derive(Debug)]
pub struct MockAsr {
    model: String,
}

impl MockAsr {
    pub fn new(model: &str) -> Self {
        Self {
            model: model.to_string(),
        }
    }
}

#[async_trait]
impl SpeechToText for MockAsr {
    async fn transcribe(&self, wav: &[u8], _language: Option<&str>) -> Result<String, AsrError> {
        Ok(format!("语音片段（{} 字节）", wav.len()))
    }

    fn model(&self) -> &str {
        &self.model
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_chat_completion_content() {
        let value = json!({
            "choices": [{ "message": { "role": "assistant", "content": " 今天下午三点开会 " } }]
        });
        assert_eq!(extract_text(&value).as_deref(), Some("今天下午三点开会"));
    }

    #[test]
    fn extracts_native_style_and_text_field() {
        let native = json!({
            "output": { "choices": [{ "message": { "content": "从原生形态取到" } }] }
        });
        assert_eq!(extract_text(&native).as_deref(), Some("从原生形态取到"));

        let plain = json!({ "text": "顶层 text" });
        assert_eq!(extract_text(&plain).as_deref(), Some("顶层 text"));
    }

    #[test]
    fn joins_multimodal_parts() {
        let value = json!({
            "choices": [{ "message": { "content": [
                { "type": "text", "text": "前半句" },
                { "type": "text", "text": "后半句" }
            ] } }]
        });
        assert_eq!(extract_text(&value).as_deref(), Some("前半句后半句"));
    }

    #[test]
    fn empty_content_extracts_none() {
        let value = json!({ "choices": [{ "message": { "content": "" } }] });
        assert_eq!(extract_text(&value), None);
    }

    #[test]
    fn prompt_is_sent_as_system_message() {
        let asr = ChatAudioAsr::new(
            reqwest::Client::new(),
            "http://127.0.0.1/asr".to_string(),
            "qwen3.8-omni-flash".to_string(),
            "key".to_string(),
            Some("只转写".to_string()),
        );
        let body = asr.request_body("data:audio/wav;base64,AA==".to_string(), Some("zh"));
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], "只转写");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(
            body["messages"][1]["content"][0]["input_audio"]["format"],
            "wav"
        );
        assert_eq!(body["asr_options"]["language"], "zh");
    }

    #[test]
    fn empty_prompt_is_not_sent() {
        let asr = ChatAudioAsr::new(
            reqwest::Client::new(),
            "http://127.0.0.1/asr".to_string(),
            "real-asr".to_string(),
            "key".to_string(),
            Some("   ".to_string()),
        );
        let body = asr.request_body("data:audio/wav;base64,AA==".to_string(), None);
        assert_eq!(body["messages"][0]["role"], "user");
    }

    #[test]
    fn cleans_prefixes_and_quotes() {
        assert_eq!(
            clean_transcript("  转写结果： “今天下午开会。”  "),
            "今天下午开会。"
        );
        assert_eq!(clean_transcript("Transcript: hello"), "hello");
        assert_eq!(clean_transcript("\"你好\""), "你好");
    }

    #[test]
    fn recognizes_no_words_as_empty_speech() {
        let body = r#"{"code":"CLIENT_ERROR","message":"ASR_RESPONSE_HAVE_NO_WORDS"}"#;
        assert!(is_no_words_error(body));
        assert!(!is_no_words_error(r#"{"message":"invalid api key"}"#));
    }

    #[test]
    fn distinguishes_structured_empty_from_stub() {
        let structured = json!({ "choices": [{ "message": { "content": "" } }] });
        assert!(transcript_structure_present(&structured));
        let stub = json!({ "status_message": "Success." });
        assert!(!transcript_structure_present(&stub));
    }

    #[test]
    fn status_only_response_is_explained() {
        let body = r#"{"status_message":"Success."}"#;
        let error = empty_transcript_error(body);
        let message = error.message();
        assert!(message.contains("没有返回转写文本"));
        assert!(message.contains("status_message"));
    }

    #[test]
    fn error_body_is_truncated_and_single_line() {
        let body = format!("line1\nline2 {}", "x".repeat(500));
        let detail = truncate(&body);
        assert!(!detail.contains('\n'));
        assert!(detail.chars().count() <= 300);
    }
}
