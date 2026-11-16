//! 文生视频：`wan3.0-video-prime`。
//!
//! 与出图最大的差别是**异步**：提交只拿到 `task_id`，成片要轮询任务状态。
//! 因此这里的失败排查比出图难得多，凡是能带上 `task_id` / `code` /
//! `request_id` 的地方都必须带上——否则用户只能看到一句"失败了"。

use std::time::{Duration, Instant};

use reqwest::Client;
use serde_json::{json, Value};

use crate::artifact_store::ArtifactStore;
use crate::config::VideoGenConfig;
use crate::ids::new_id;

use super::{
    download_bytes, summarize_error, upstream_failure, MediaArtifact, MediaError, MediaRequest,
    CONNECT_TIMEOUT,
};

/// 轮询中还没结束的状态。`QUEUED` 是少数账号会看到的前置态。
const RUNNING_STATES: [&str; 3] = ["PENDING", "QUEUED", "RUNNING"];

/// 百炼视频客户端。`Debug` 只输出模型与地址，绝不输出密钥。
pub(crate) struct VideoClient {
    client: Client,
    download_client: Client,
    submit_url: String,
    task_url_prefix: String,
    api_key: String,
    model: String,
    resolution: String,
    ratio: String,
    duration_s: u32,
    poll_interval: Duration,
    max_wait: Duration,
    max_bytes: i64,
}

impl std::fmt::Debug for VideoClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("VideoClient")
            .field("model", &self.model)
            .field("submit_url", &self.submit_url)
            .field("poll_interval_ms", &self.poll_interval.as_millis())
            .field("max_wait_ms", &self.max_wait.as_millis())
            .finish_non_exhaustive()
    }
}

impl VideoClient {
    pub(crate) fn new(config: &VideoGenConfig, base_url: &str, api_key: String) -> Self {
        let request_timeout = Duration::from_millis(config.timeout_ms.max(1_000));
        let download_timeout = Duration::from_millis(config.download_timeout_ms.max(1_000));
        let base_url = base_url.trim_end_matches('/');
        let task_path = config.task_path.trim_start_matches('/');

        Self {
            client: Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .timeout(request_timeout)
                .build()
                .unwrap_or_else(|err| {
                    tracing::error!(%err, "构建视频客户端失败，使用默认配置");
                    Client::new()
                }),
            download_client: Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .timeout(download_timeout)
                .build()
                .unwrap_or_else(|err| {
                    tracing::error!(%err, "构建视频下载客户端失败，使用默认配置");
                    Client::new()
                }),
            submit_url: format!("{}{}", base_url, config.path),
            // 统一补一个尾部斜杠：`task_path` 少写一个 `/` 会拼出 `/api/v1/tasksabc`。
            task_url_prefix: format!("{base_url}/{}/", task_path.trim_end_matches('/')),
            api_key,
            model: config.model.clone(),
            resolution: config.resolution.clone(),
            ratio: config.ratio.clone(),
            duration_s: config.duration_s,
            poll_interval: Duration::from_millis(config.poll_interval_ms.max(1)),
            max_wait: Duration::from_millis(config.max_wait_ms.max(1)),
            max_bytes: config.max_bytes.max(1),
        }
    }

    pub(crate) fn request_body(
        &self,
        prompt: &str,
        resolution: Option<&str>,
        duration_s: Option<u32>,
    ) -> Value {
        json!({
            "model": self.model,
            "input": { "prompt": prompt },
            "parameters": {
                // 新协议用 `resolution` + `ratio`；老协议的 `size` 会被静默忽略，
                // 成片仍按默认 1080P 出，既贵又难分辨。
                "resolution": resolution.unwrap_or(&self.resolution),
                "ratio": self.ratio,
                "duration": duration_s.unwrap_or(self.duration_s)
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
        let resolution = request.resolution.unwrap_or(&self.resolution);
        let duration_s = request.duration_s.unwrap_or(self.duration_s);

        let started = Instant::now();
        let upstream_task = self
            .submit(prompt, request.resolution, request.duration_s)
            .await?;
        tracing::info!(
            model = %self.model,
            task_id = %upstream_task,
            resolution = %resolution,
            ratio = %self.ratio,
            duration_s,
            "视频任务已提交"
        );

        let url = self.wait_for_video(&upstream_task, started).await?;
        tracing::info!(task_id = %upstream_task, "视频已生成，开始下载");

        let bytes = download_bytes(&self.download_client, &url, self.max_bytes, "生成视频").await?;
        if !looks_like_mp4(&bytes) {
            return Err(MediaError::Download(format!(
                "下载到的不是 mp4（task_id={upstream_task}，{} 字节）",
                bytes.len()
            )));
        }

        let artifact_id = new_id("vid");
        let (relative, size) = store
            .save_bytes(task_id, &artifact_id, Some("video/mp4"), &bytes)
            .await?;

        Ok(MediaArtifact {
            absolute_path: store.root().join(&relative).to_string_lossy().to_string(),
            relative_path: relative,
            mime: "video/mp4",
            bytes: size as u64,
            elapsed_ms: started.elapsed().as_millis() as u64,
            width: None,
            height: None,
            duration_ms: Some(duration_s.saturating_mul(1_000)),
            upstream_task_id: Some(upstream_task),
        })
    }

    /// 提交异步任务，返回上游 `task_id`。
    async fn submit(
        &self,
        prompt: &str,
        resolution: Option<&str>,
        duration_s: Option<u32>,
    ) -> Result<String, MediaError> {
        let response = self
            .client
            .post(&self.submit_url)
            .bearer_auth(&self.api_key)
            .header("X-DashScope-Async", "enable")
            .json(&self.request_body(prompt, resolution, duration_s))
            .send()
            .await
            .map_err(|err| MediaError::Upstream(format!("提交视频任务失败：{err}")))?;

        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|err| MediaError::Upstream(format!("读取提交响应失败：{err}")))?;
        if !status.is_success() {
            return Err(upstream_failure(status.as_u16(), &body));
        }

        let value: Value = serde_json::from_str(&body)
            .map_err(|err| MediaError::Upstream(format!("提交响应无法解析：{err}")))?;
        task_id_of(&value).map(str::to_string).ok_or_else(|| {
            MediaError::Upstream(format!(
                "提交响应里没有 task_id：{}",
                summarize_error(&body)
            ))
        })
    }

    /// 轮询到终态，返回成片地址。
    async fn wait_for_video(&self, task_id: &str, started: Instant) -> Result<String, MediaError> {
        let url = format!("{}{task_id}", self.task_url_prefix);
        let mut last_status = String::new();

        loop {
            if started.elapsed() >= self.max_wait {
                return Err(MediaError::Upstream(format!(
                    "等待出片超时（{} 秒），最后状态 {}，task_id={task_id}",
                    self.max_wait.as_secs(),
                    if last_status.is_empty() {
                        "未知"
                    } else {
                        last_status.as_str()
                    }
                )));
            }

            tokio::time::sleep(self.poll_interval).await;

            let response = self
                .client
                .get(&url)
                .bearer_auth(&self.api_key)
                .send()
                .await
                .map_err(|err| MediaError::Upstream(format!("查询视频任务失败：{err}")))?;
            let status = response.status();
            let body = response
                .text()
                .await
                .map_err(|err| MediaError::Upstream(format!("读取任务响应失败：{err}")))?;
            if !status.is_success() {
                return Err(upstream_failure(status.as_u16(), &body));
            }

            let value: Value = serde_json::from_str(&body)
                .map_err(|err| MediaError::Upstream(format!("任务响应无法解析：{err}")))?;
            let state = task_status_of(&value).unwrap_or_default().to_string();
            if state != last_status {
                tracing::info!(task_id, status = %state, "视频任务状态变化");
                last_status = state.clone();
            }

            if RUNNING_STATES.contains(&state.as_str()) {
                continue;
            }
            if state == "SUCCEEDED" {
                return video_url_of(&value).map(str::to_string).ok_or_else(|| {
                    MediaError::Upstream(format!(
                        "任务成功但没有成片地址（task_id={task_id}）：{}",
                        summarize_error(&body)
                    ))
                });
            }
            if state.is_empty() {
                return Err(MediaError::Upstream(format!(
                    "任务响应里没有 task_status（task_id={task_id}）：{}",
                    summarize_error(&body)
                )));
            }

            return Err(failed_task_error(&value, &body, task_id, &state));
        }
    }
}

/// 从提交响应里取任务号：`output.task_id`。
pub(crate) fn task_id_of(body: &Value) -> Option<&str> {
    body.pointer("/output/task_id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
}

/// 从任务查询响应里取状态：`output.task_status`。
pub(crate) fn task_status_of(body: &Value) -> Option<&str> {
    body.pointer("/output/task_status")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
}

/// 成片地址：`output.video_url`。
pub(crate) fn video_url_of(body: &Value) -> Option<&str> {
    body.pointer("/output/video_url")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
}

/// 失败任务的错误文案。
///
/// 失败时 `code` / `message` 嵌在 `output` 里，而 `request_id` 在顶层——
/// 这两个位置都必须读，否则用户拿到的是一句没有线索的"失败"。
fn failed_task_error(value: &Value, body: &str, task_id: &str, state: &str) -> MediaError {
    let output = |key: &str| {
        value
            .pointer(&format!("/output/{key}"))
            .and_then(Value::as_str)
            .unwrap_or("")
    };
    let code = output("code");
    let message = output("message");
    let request_id = value
        .get("request_id")
        .and_then(Value::as_str)
        .unwrap_or("");

    if code.is_empty() && message.is_empty() && request_id.is_empty() {
        return MediaError::Upstream(format!(
            "视频任务失败（task_id={task_id}，status={state}）：{}",
            summarize_error(body)
        ));
    }
    MediaError::Upstream(format!(
        "视频任务失败（task_id={task_id}，status={state}，code={code}，message={message}，request_id={request_id}）"
    ))
}

/// mp4 判定：`ftyp` box 通常在偏移 4。
fn looks_like_mp4(bytes: &[u8]) -> bool {
    bytes.len() >= 12 && &bytes[4..8] == b"ftyp"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn client() -> VideoClient {
        VideoClient::new(
            &VideoGenConfig::default(),
            "https://example.com/",
            "test-key".into(),
        )
    }

    #[test]
    fn request_body_carries_resolution_and_duration() {
        let body = client().request_body("海边日落，镜头缓慢推进", None, None);
        assert_eq!(body["model"], "wan3.0-video-prime");
        assert_eq!(body["input"]["prompt"], "海边日落，镜头缓慢推进");
        assert_eq!(body["parameters"]["resolution"], "480P");
        assert_eq!(body["parameters"]["ratio"], "16:9");
        assert_eq!(body["parameters"]["duration"], 5);
        assert_eq!(
            body["parameters"].get("size"),
            None,
            "size 会被上游静默忽略，不能发"
        );
    }

    #[test]
    fn overrides_only_affect_this_request() {
        let client = client();
        let body = client.request_body("慢镜头", Some("720P"), Some(10));
        assert_eq!(body["parameters"]["resolution"], "720P");
        assert_eq!(body["parameters"]["duration"], 10);

        // 下一次必须回到配置默认：模型的一次要求不该改到后续请求。
        let again = client.request_body("慢镜头", None, None);
        assert_eq!(again["parameters"]["resolution"], "480P");
        assert_eq!(again["parameters"]["duration"], 5);
    }

    #[test]
    fn task_url_prefix_is_normalized() {
        let client = client();
        assert_eq!(client.task_url_prefix, "https://example.com/api/v1/tasks/");
        assert_eq!(
            client.submit_url,
            "https://example.com/api/v1/services/aigc/video-generation/video-synthesis"
        );
    }

    #[test]
    fn parses_submit_response() {
        let body: Value = serde_json::from_str(
            r#"{"request_id":"req-1","output":{"task_id":"b75b1970","task_status":"PENDING"}}"#,
        )
        .expect("解析失败");
        assert_eq!(task_id_of(&body), Some("b75b1970"));
        assert_eq!(task_status_of(&body), Some("PENDING"));
        assert!(video_url_of(&body).is_none());
    }

    #[test]
    fn parses_succeeded_task() {
        let body: Value = serde_json::from_str(
            r#"{"output":{"task_id":"t1","task_status":"SUCCEEDED","video_url":"https://oss.example.com/a.mp4?Expires=1"}}"#,
        )
        .expect("解析失败");
        assert_eq!(task_status_of(&body), Some("SUCCEEDED"));
        assert_eq!(
            video_url_of(&body),
            Some("https://oss.example.com/a.mp4?Expires=1")
        );
    }

    #[test]
    fn failed_task_error_keeps_code_and_request_id() {
        let body: Value = serde_json::from_str(
            r#"{"request_id":"req-9","output":{"task_id":"t1","task_status":"FAILED","code":"InvalidParameter","message":"prompt and media cannot both be empty"}}"#,
        )
        .expect("解析失败");
        let error = failed_task_error(&body, "", "t1", "FAILED");
        let text = error.message();
        assert!(text.contains("task_id=t1"), "{text}");
        assert!(text.contains("InvalidParameter"), "{text}");
        assert!(text.contains("req-9"), "{text}");
        assert!(text.contains("prompt and media"), "{text}");
    }

    #[test]
    fn detects_mp4_header() {
        let mut bytes = vec![0u8, 0, 0, 0x18];
        bytes.extend_from_slice(b"ftypisom");
        assert!(looks_like_mp4(&bytes));
        assert!(!looks_like_mp4(b"<html>error</html>"));
    }
}
