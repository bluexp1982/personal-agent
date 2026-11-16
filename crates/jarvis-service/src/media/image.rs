//! 文生图：`qwen-image-3.0`。
//!
//! 端点选型是实测结论，不是猜的：这个模型挂在
//! `/api/v1/services/aigc/multimodal-generation/generation` 上，
//! 打到老的 `text2image/image-synthesis` 会回 `url error, please check url！`。

use std::time::{Duration, Instant};

use reqwest::Client;
use serde_json::{json, Value};

use crate::artifact_store::ArtifactStore;
use crate::config::ImageGenConfig;
use crate::ids::new_id;

use super::{
    download_bytes, image_metadata, upstream_failure, MediaArtifact, MediaError, MediaRequest,
    CONNECT_TIMEOUT,
};

/// 百炼出图客户端。`Debug` 只输出模型与地址，绝不输出密钥。
pub(crate) struct ImageClient {
    client: Client,
    download_client: Client,
    url: String,
    api_key: String,
    model: String,
    size: String,
    max_bytes: i64,
}

impl std::fmt::Debug for ImageClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ImageClient")
            .field("model", &self.model)
            .field("url", &self.url)
            .finish_non_exhaustive()
    }
}

impl ImageClient {
    pub(crate) fn new(config: &ImageGenConfig, base_url: &str, api_key: String) -> Self {
        let request_timeout = Duration::from_millis(config.timeout_ms.max(1_000));
        let download_timeout = Duration::from_millis(config.download_timeout_ms.max(1_000));

        Self {
            client: Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .timeout(request_timeout)
                .build()
                .unwrap_or_else(|err| {
                    tracing::error!(%err, "构建出图客户端失败，使用默认配置");
                    Client::new()
                }),
            download_client: Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .timeout(download_timeout)
                .build()
                .unwrap_or_else(|err| {
                    tracing::error!(%err, "构建出图下载客户端失败，使用默认配置");
                    Client::new()
                }),
            url: format!("{}{}", base_url.trim_end_matches('/'), config.path),
            api_key,
            model: config.model.clone(),
            size: config.size.clone(),
            max_bytes: config.max_bytes.max(1),
        }
    }

    pub(crate) fn request_body(&self, prompt: &str, size: Option<&str>) -> Value {
        json!({
            "model": self.model,
            "input": {
                "messages": [
                    { "role": "user", "content": [ { "text": prompt } ] }
                ]
            },
            "parameters": {
                // 覆盖值只作用于本次请求：模型临时换档不该改到配置。
                "size": size.unwrap_or(&self.size),
                "n": 1,
                // 让上游补全提示词：个人助理收到的一句话通常很短，
                // 不补全容易出一张"什么都不是"的图。
                "prompt_extend": true,
                "watermark": false
            }
        })
    }

    pub(crate) async fn generate(
        &self,
        request: MediaRequest<'_>,
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError> {
        let prompt = request.prompt.trim();
        if prompt.is_empty() {
            return Err(MediaError::Invalid("提示词不能为空".to_string()));
        }

        let started = Instant::now();
        let response = self
            .client
            .post(&self.url)
            .bearer_auth(&self.api_key)
            .json(&self.request_body(prompt, request.size))
            .send()
            .await
            .map_err(|err| MediaError::Upstream(format!("请求出图服务失败：{err}")))?;

        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|err| MediaError::Upstream(format!("读取出图响应失败：{err}")))?;
        if !status.is_success() {
            return Err(upstream_failure(status.as_u16(), &body));
        }

        let value: Value = serde_json::from_str(&body)
            .map_err(|err| MediaError::Upstream(format!("出图响应无法解析：{err}")))?;
        let url = first_image_url(&value).ok_or_else(|| {
            MediaError::Upstream(format!(
                "出图响应里没有图片地址：{}",
                super::summarize_error(&body)
            ))
        })?;
        let url = url.to_string();

        tracing::info!(model = %self.model, "出图完成，开始下载");
        let bytes = download_bytes(&self.download_client, &url, self.max_bytes, "生成图片").await?;
        let (mime, pixels) = image_metadata(&bytes);

        let artifact_id = new_id("img");
        let (relative, size) = store
            .save_bytes(task_id, &artifact_id, Some(mime), &bytes)
            .await?;

        Ok(MediaArtifact {
            absolute_path: store.root().join(&relative).to_string_lossy().to_string(),
            relative_path: relative,
            mime,
            bytes: size as u64,
            elapsed_ms: started.elapsed().as_millis() as u64,
            width: pixels.map(|(width, _)| width),
            height: pixels.map(|(_, height)| height),
            duration_ms: None,
            upstream_task_id: None,
        })
    }
}

/// 从出图响应里取第一张图片地址。
///
/// 结构是 `output.choices[*].message.content[*].image`。文字与图片可能混在
/// 同一个数组里，因此按"哪个元素带 image 字段"找，而不是按下标取。
pub(crate) fn first_image_url(body: &Value) -> Option<&str> {
    body.get("output")?
        .get("choices")?
        .as_array()?
        .iter()
        .find_map(|choice| {
            choice
                .get("message")?
                .get("content")?
                .as_array()?
                .iter()
                .find_map(|part| part.get("image").and_then(Value::as_str))
        })
        .filter(|url| !url.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn client() -> ImageClient {
        ImageClient::new(
            &ImageGenConfig::default(),
            "https://example.com/",
            "test-key".into(),
        )
    }

    #[test]
    fn request_body_uses_multimodal_messages() {
        let body = client().request_body("一只在窗台上晒太阳的橘猫", None);
        assert_eq!(body["model"], "qwen-image-3.0");
        assert_eq!(body["input"]["messages"][0]["role"], "user");
        assert_eq!(
            body["input"]["messages"][0]["content"][0]["text"],
            "一只在窗台上晒太阳的橘猫"
        );
        assert_eq!(body["input"]["messages"][0]["content"][1], Value::Null);
        assert_eq!(body["parameters"]["n"], 1);
        assert_eq!(body["parameters"]["size"], "1328*1328");
    }

    #[test]
    fn size_override_only_affects_this_request() {
        let client = client();
        let body = client.request_body("方形图", Some("1024*1024"));
        assert_eq!(body["parameters"]["size"], "1024*1024");

        // 下一次请求必须回到配置默认值：覆盖值不能写回客户端状态。
        let again = client.request_body("方形图", None);
        assert_eq!(again["parameters"]["size"], "1328*1328");
    }

    #[test]
    fn parses_first_image_url_skipping_text_parts() {
        let body: Value = serde_json::from_str(
            r#"{"output":{"choices":[{"message":{"role":"assistant","content":[
                {"text":"（补全后的提示词）"},
                {"image":"https://dashscope-result.oss-cn-beijing.aliyuncs.com/a.png?Expires=1"}
            ]}}]},"usage":{"image_count":1}}"#,
        )
        .expect("样例 JSON 应能解析");

        assert_eq!(
            first_image_url(&body),
            Some("https://dashscope-result.oss-cn-beijing.aliyuncs.com/a.png?Expires=1")
        );
    }

    #[test]
    fn missing_image_url_is_none() {
        let body: Value = serde_json::from_str(r#"{"output":{"choices":[]}}"#).expect("解析失败");
        assert!(first_image_url(&body).is_none());
    }
}
