//! OpenAI 兼容网关：流式文本 + 原生 function calling。
//!
//! 协议探测结论（2026-10，`deepseek-v4.1-flash`）：支持 `tools`，流式下
//! 首个 `tool_calls` 帧带 `id` 与 `name`，后续帧按 `index` 增量给 `arguments`，
//! 结束帧 `finish_reason = "tool_calls"`。因此直接走标准协议，不再实现 JSON 兜底。
//!
//! 三个刻意的取舍：
//! - **不转发 `reasoning_content`**：思考过程不进对话内容、不落库；
//! - **密钥不落盘**：只从配置指定的环境变量读取，`Debug` 也不打印；
//! - **工具参数保持原样字符串**：解析与校验交给上层，模型写坏了就报错降级。

use std::collections::BTreeMap;
use std::time::Duration;

use futures_util::stream::{self, StreamExt};
use reqwest::Client;
use tokio::sync::mpsc;

use protocol::TokenUsage;

use crate::chat::{ChatEvent, ChatMessage, ChatModel, ChatRole, ChatStream, ToolSpec};
use crate::model::{estimate_tokens, Completion, CompletionFuture, CompletionModel};
use crate::responder::{PromptMessage, Responder, TokenStream};

const MAX_ERROR_BODY: usize = 300;

/// 建连 + TLS 握手的上限。
///
/// 与"生成多久"无关：网络不通或网关地址写错时应当在十几秒内失败，
/// 而不是让用户对着转圈等到整个生成预算用完。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

/// 流式两帧之间的最长静默。
///
/// 一次长生成的总时长可能是好几分钟，但帧间隔通常只有几十毫秒；
/// 连续这么久没有任何字节，才说明上游真的卡住了。
const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

/// 「测试连接」的往返上限。
///
/// 比建连超时略长：跨境网关握手 + 一次 8 token 的推理，15 秒内该有结论；
/// 再久就不是"慢"，是配置指向了一个不会应答的地址。
const PROBE_TIMEOUT_SECS: u64 = 15;

/// 「推理等级」的四档白名单。
///
/// 上游对白名单之外的值是**直接 400**（实测报错原文会列出它认的名字），
/// 所以客户端传来什么都不能原样透传：一条脏参数不该把整轮对话打死。
/// 大小写不敏感，与上游行为一致。
pub(crate) fn normalize_reasoning(raw: &str) -> Option<&'static str> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "none" => Some("none"),
        "low" => Some("low"),
        "high" => Some("high"),
        "max" => Some("max"),
        _ => None,
    }
}

/// 组一轮 `chat/completions` 的请求体。
///
/// 抽成函数是为了单测能直接断言形状（带档位 / 不带档位 / 有工具），
/// 不必为了验证一个字段去起 HTTP 服务。
fn chat_payload(
    model: &str,
    messages: &[ChatMessage],
    tools: &[ToolSpec],
    effort: Option<&'static str>,
) -> serde_json::Value {
    let mut payload = serde_json::json!({
        "model": model,
        "messages": messages.iter().map(to_wire).collect::<Vec<_>>(),
        "stream": true,
        // 流式默认不带 usage：不开这一项，会话页的"用量"就只能靠估算。
        "stream_options": { "include_usage": true },
    });

    // 不传时上游按自己的默认档（实测是 high）走，与加字段之前的行为一致。
    if let Some(effort) = effort {
        payload["reasoning_effort"] = serde_json::json!(effort);
    }

    if !tools.is_empty() {
        payload["tools"] = serde_json::Value::Array(
            tools
                .iter()
                .map(|tool| {
                    serde_json::json!({
                        "type": "function",
                        "function": {
                            "name": tool.name,
                            "description": tool.description,
                            "parameters": tool.parameters,
                        }
                    })
                })
                .collect(),
        );
        payload["tool_choice"] = serde_json::json!("auto");
    }

    payload
}

/// OpenAI 兼容客户端。`Debug` 只输出模型名，绝不输出密钥。
#[derive(Clone)]
pub struct LlmClient {
    base_url: String,
    /// 完整请求地址。上游是 `{base_url}{api_path}/chat/completions`，
    /// 但路径前缀由配置决定：接入第三方模型之后不能再写死百炼那一条。
    endpoint: String,
    api_key: String,
    model: String,
    http: Client,
    /// 一次**非流式**请求的往返上限。
    ///
    /// 不能设在 `Client` 上：`ClientBuilder::timeout` 的语义是"从连接开始
    /// 直到响应体读完"，对流式请求等于"最多生成 N 秒"——大段输出必然被掐，
    /// 报出来还是容易误导的 `error decoding response body`。
    request_timeout: Duration,
    /// 流式两帧之间的最长静默，见 [`DEFAULT_IDLE_TIMEOUT`]。
    idle_timeout: Duration,
    /// 上游认不认 `reasoning_effort`。假值时无论上层传什么档位都不发该字段——
    /// 「不支持就不发」只在这一处判断，避免客户端与服务端各判一次。
    reasoning: bool,
    /// 这一轮要发的档位。已经过白名单收敛，只会是 `none/low/high/max` 之一。
    effort: Option<&'static str>,
}

impl std::fmt::Debug for LlmClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LlmClient")
            .field("model", &self.model)
            .field("base_url", &self.base_url)
            .field("endpoint", &self.endpoint)
            .finish_non_exhaustive()
    }
}

impl LlmClient {
    /// 按默认路径前缀（百炼的 `/compatible-mode/v1`）构造。
    ///
    /// 只有单测在用：生产路径一律走 [`Self::from_profile`]，端点由配置决定。
    /// 保留这个构造器是为了让既有测试继续用"只给主机名"的老签名。
    #[cfg(test)]
    pub(crate) fn new(
        base_url: impl Into<String>,
        api_key: impl Into<String>,
        model: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        let base_url = base_url.into().trim_end_matches('/').to_string();
        let endpoint = format!(
            "{base_url}{}/chat/completions",
            crate::config::DEFAULT_API_PATH
        );
        Self::with_endpoint(base_url, endpoint, api_key, model, timeout)
    }

    fn with_endpoint(
        base_url: String,
        endpoint: String,
        api_key: impl Into<String>,
        model: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        // 客户端只设建连超时：总时长必须留给各请求自己决定，
        // 否则流式生成会被一个与"卡住"无关的数字掐断。
        let http = Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .unwrap_or_else(|err| {
                tracing::error!(%err, "构建 HTTP 客户端失败，使用默认配置");
                Client::new()
            });

        Self {
            base_url,
            endpoint,
            api_key: api_key.into(),
            model: model.into(),
            http,
            request_timeout: timeout,
            idle_timeout: DEFAULT_IDLE_TIMEOUT,
            reasoning: false,
            effort: None,
        }
    }

    /// 覆盖流式空闲阈值。只由 [`LlmClient::from_profile`] 调用。
    #[must_use]
    pub(crate) fn with_idle_timeout(mut self, idle: Duration) -> Self {
        self.idle_timeout = idle;
        self
    }

    /// 声明上游是否支持 `reasoning_effort`。只由 [`LlmClient::from_profile`] 调用。
    #[must_use]
    pub(crate) fn with_reasoning(mut self, supported: bool) -> Self {
        self.reasoning = supported;
        self
    }

    /// 返回带本轮档位的副本。
    ///
    /// 不改 `ChatModel` 的签名：`chat::run` 在工具多轮里会反复调 `stream`，
    /// 档位跟着客户端实例走比加参数改动面小得多。能力位为假时直接吞掉入参。
    pub(crate) fn with_reasoning_effort(&self, effort: Option<&str>) -> Self {
        let mut client = self.clone();
        if !client.reasoning {
            if effort.is_some() {
                tracing::debug!(
                    model = %client.model,
                    "当前模型配置未声明支持推理等级，已忽略本轮档位"
                );
            }
            client.effort = None;
            return client;
        }
        client.effort = effort.and_then(normalize_reasoning);
        client
    }

    /// 当前这一轮实际会发出去的档位。单测靠它断言能力位与白名单的守门效果。
    #[cfg(test)]
    pub(crate) fn reasoning_effort(&self) -> Option<&'static str> {
        self.effort
    }

    /// 按一份命名配置与已解析的密钥构造客户端。
    ///
    /// 密钥由调用方解析（客户端写入的文件优先，其次环境变量），这里只管建连。
    pub fn from_profile(profile: &crate::config::ModelProfile, api_key: impl Into<String>) -> Self {
        Self::with_endpoint(
            profile.base_url.trim().trim_end_matches('/').to_string(),
            profile.chat_endpoint(),
            api_key,
            profile.model.trim().to_string(),
            Duration::from_millis(profile.timeout_ms.max(1_000)),
        )
        .with_idle_timeout(Duration::from_millis(
            profile.stream_idle_timeout_ms.max(1_000),
        ))
        .with_reasoning(profile.reasoning)
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    /// 完整请求地址。供"测试连接"与排障日志展示，不含密钥。
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// 用一次极小请求探测能否连通。
    ///
    /// 与 [`Self::complete_text`] 分开：这里要把失败原因归类（密钥无效 / 模型
    /// 不存在 / 地址不对 / 超时），而不是返回一句笼统的"模型返回 401"。
    pub async fn probe(&self) -> Result<u64, ProbeFailure> {
        let started = std::time::Instant::now();
        let mut payload = serde_json::json!({
            "model": self.model,
            "messages": [{ "role": "user", "content": "ping" }],
            "max_tokens": 8,
            "stream": false,
        });
        // `max_tokens: 8` 遇上会思考的模型，8 个 token 全被思维链吃掉，
        // 正文为空但状态仍是 200——探测就变成"连接成功但不能说话"。
        // 支持档位的配置在这里显式关掉思考，让 8 个 token 都留给正文。
        if self.reasoning {
            payload["reasoning_effort"] = serde_json::json!("none");
        }

        let response = self
            .http
            .post(&self.endpoint)
            .timeout(Duration::from_secs(PROBE_TIMEOUT_SECS))
            .bearer_auth(&self.api_key)
            .json(&payload)
            .send()
            .await
            .map_err(|err| {
                if err.is_timeout() {
                    ProbeFailure::timeout(err.to_string())
                } else if err.is_connect() {
                    ProbeFailure::unreachable(err.to_string())
                } else {
                    ProbeFailure::bad_response(err.to_string())
                }
            })?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(ProbeFailure::from_status(status.as_u16(), &body));
        }

        let body: serde_json::Value = response.json().await.map_err(|err| {
            ProbeFailure::bad_response(format!("响应不是约定的 JSON 结构：{err}"))
        })?;

        if body.get("choices").is_none() {
            return Err(ProbeFailure::bad_response(
                "响应里没有 choices：这个地址可能不是 OpenAI 兼容端点".to_string(),
            ));
        }

        Ok(started.elapsed().as_millis() as u64)
    }

    /// 非流式生成，供任务步骤与产物归纳使用。
    ///
    /// 不用流式：任务不需要首字延迟，而非流式响应里直接带 `usage`，
    /// 预算是硬约束，靠估算记账会让"12 次调用 / 60k tokens"变成橡皮尺。
    ///
    /// `effort` 只有在调用方明确要求时才下发（会话摘要传 `none` 关掉思考）；
    /// 为 `None` 时请求体与加这个参数之前逐字一致。
    async fn complete_text(
        &self,
        system: &str,
        prompt: &str,
        max_tokens: Option<u32>,
        effort: Option<&'static str>,
    ) -> Result<Completion, String> {
        // 能力位为假时不发这个字段：对不认识它的上游，多一个键就可能 400。
        let effort = if self.reasoning {
            effort.and_then(normalize_reasoning)
        } else {
            None
        };
        let payload = completion_payload(&self.model, system, prompt, max_tokens, effort);

        let response = self
            .http
            .post(&self.endpoint)
            // 非流式：一次往返，给它一个明确的总上限。
            .timeout(self.request_timeout)
            .bearer_auth(&self.api_key)
            .json(&payload)
            .send()
            .await
            .map_err(|err| describe_request_error(&err))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(format!(
                "模型返回 {}: {}",
                status.as_u16(),
                truncate(&body, MAX_ERROR_BODY)
            ));
        }

        let body: serde_json::Value = response
            .json()
            .await
            .map_err(|err| format!("解析模型响应失败: {err}"))?;

        parse_completion(&body, system, prompt)
    }

    async fn run_chat(
        &self,
        messages: Vec<ChatMessage>,
        tools: Vec<ToolSpec>,
        tx: &mpsc::Sender<Result<ChatEvent, String>>,
    ) -> Result<(), String> {
        let payload = chat_payload(&self.model, &messages, &tools, self.effort);

        let response = self
            .http
            .post(&self.endpoint)
            // 流式：**不设总超时**。它等于"最多生成 N 秒"，而长输出的
            // 总时长本来就可能是几分钟；判据该是"还有没有新数据"（见下）。
            .bearer_auth(&self.api_key)
            .json(&payload)
            .send()
            .await
            .map_err(|err| describe_request_error(&err))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(format!(
                "模型返回 {}: {}",
                status.as_u16(),
                truncate(&body, MAX_ERROR_BODY)
            ));
        }

        let mut stream = response.bytes_stream();
        let mut buffer = String::new();
        let mut calls: BTreeMap<usize, PartialCall> = BTreeMap::new();

        loop {
            // 空闲判定：两帧之间超过阈值没有任何字节，才判定上游卡住。
            // 正常情况下帧间隔只有几十毫秒，所以 60 秒足够宽松，
            // 又不会让真卡住的请求拖到用户自己点停止。
            let next = tokio::time::timeout(self.idle_timeout, stream.next()).await;
            let Some(chunk) = (match next {
                Ok(next) => next,
                Err(_) => {
                    return Err(format!(
                        "模型超过 {} 秒没有输出，已中止本次生成；\
                         通常是上游卡住或网络中断，可以稍后重试",
                        self.idle_timeout.as_secs()
                    ))
                }
            }) else {
                break;
            };
            let bytes = chunk.map_err(|err| describe_stream_error(&err))?;
            buffer.push_str(&String::from_utf8_lossy(&bytes));

            while let Some(position) = buffer.find('\n') {
                let line: String = buffer.drain(..=position).collect();
                let line = line.trim();
                if line.is_empty() || line.starts_with(':') {
                    continue;
                }

                let Some(data) = line.strip_prefix("data:") else {
                    continue;
                };
                let data = data.trim();
                if data == "[DONE]" {
                    return flush_calls(&mut calls, tx).await;
                }

                if let Some(text) = handle_frame(data, &mut calls) {
                    if tx.send(Ok(ChatEvent::Text(text))).await.is_err() {
                        return Ok(());
                    }
                }
                if let Some(usage) = handle_usage(data) {
                    if tx.send(Ok(ChatEvent::Usage(usage))).await.is_err() {
                        return Ok(());
                    }
                }
            }
        }

        flush_calls(&mut calls, tx).await
    }
}

/// 「测试连接」失败的原因归类。
///
/// 分类不是为了好看：401 要去改密钥，404 要去改路径前缀，连不上要去查网络，
/// 三者处置完全不同。把上游那句 "invalid api key" 直接抛给用户，等于让他自己猜。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeFailure {
    /// 稳定码：`auth_failed` / `model_not_found` / `endpoint_not_found` /
    /// `unreachable` / `timeout` / `rate_limited` / `bad_response`。
    pub code: &'static str,
    /// 面向开发者：上游原话（已截断）。
    pub message: String,
    /// 面向用户：一句话说清接下来该改什么。
    pub hint: &'static str,
    /// 上游 HTTP 状态码；网络层失败时为 `None`。
    pub status: Option<u16>,
}

impl ProbeFailure {
    fn new(code: &'static str, message: impl Into<String>, hint: &'static str) -> Self {
        Self {
            code,
            message: message.into(),
            hint,
            status: None,
        }
    }

    fn timeout(detail: String) -> Self {
        Self::new(
            "timeout",
            detail,
            "上游在 15 秒内没有应答：检查网关地址、网络与代理设置",
        )
    }

    fn unreachable(detail: String) -> Self {
        Self::new(
            "unreachable",
            detail,
            "连不上网关：确认地址拼写、端口，以及这台机器能否访问该站点",
        )
    }

    /// 响应体不是约定的形状：地址多半指向了一个能通但不是 OpenAI 兼容的服务。
    pub fn bad_response(detail: String) -> Self {
        Self::new(
            "bad_response",
            detail,
            "这个地址能连上，但返回的不是 OpenAI 兼容的响应：检查路径前缀与网关类型",
        )
    }

    fn from_status(status: u16, body: &str) -> Self {
        let body = truncate(body, MAX_ERROR_BODY);
        let lowered = body.to_lowercase();
        let mentions_model = lowered.contains("model")
            && (lowered.contains("not found")
                || lowered.contains("not exist")
                || lowered.contains("does not exist")
                || lowered.contains("invalid"));

        let (code, hint) = match status {
            401 | 403 => (
                "auth_failed",
                "密钥无效或没有该模型的权限：重新填写 API Key 后再试",
            ),
            404 if mentions_model => ("model_not_found", "上游没有这个模型：核对模型名拼写"),
            404 => (
                "endpoint_not_found",
                "这个地址没有 /chat/completions：检查路径前缀（常见为 /v1）",
            ),
            400 if mentions_model => (
                "model_not_found",
                "上游不认识这个模型名：核对拼写与账号权限",
            ),
            429 => (
                "rate_limited",
                "上游限流：稍等片刻再试，或换一个配额更宽的服务商",
            ),
            500..=599 => (
                "bad_response",
                "上游服务端错误：这不是配置问题，稍后重试或换服务商",
            ),
            _ => (
                "bad_response",
                "上游拒绝了这次请求：检查模型名、路径前缀与账号状态",
            ),
        };

        Self {
            code,
            message: format!("HTTP {status}: {body}"),
            hint,
            status: Some(status),
        }
    }
}

/// 一帧里累积到一半的工具调用。
#[derive(Debug, Default)]
struct PartialCall {
    id: String,
    name: String,
    arguments: String,
}

impl ChatModel for LlmClient {
    fn stream(&self, messages: Vec<ChatMessage>, tools: Vec<ToolSpec>) -> ChatStream {
        let (tx, rx) = mpsc::channel::<Result<ChatEvent, String>>(32);
        let client = self.clone();

        tokio::spawn(async move {
            if let Err(err) = client.run_chat(messages, tools, &tx).await {
                let _ = tx.send(Err(err)).await;
            }
        });

        Box::pin(stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|item| (item, rx))
        }))
    }
}

impl CompletionModel for LlmClient {
    fn complete(
        &self,
        system: &str,
        prompt: &str,
        max_tokens: Option<u32>,
    ) -> CompletionFuture<'_> {
        // 参数转成 owned：返回的 future 生命周期只跟随 `&self`，
        // 否则调用方传入的临时字符串会让签名无法满足 `'_`。
        let system = system.to_string();
        let prompt = prompt.to_string();
        Box::pin(async move { self.complete_text(&system, &prompt, max_tokens, None).await })
    }

    fn complete_with_effort(
        &self,
        system: &str,
        prompt: &str,
        max_tokens: Option<u32>,
        effort: Option<&'static str>,
    ) -> CompletionFuture<'_> {
        let system = system.to_string();
        let prompt = prompt.to_string();
        Box::pin(async move {
            self.complete_text(&system, &prompt, max_tokens, effort)
                .await
        })
    }
}

/// 非流式请求体。抽成纯函数才好单测「档位到底发没发」。
fn completion_payload(
    model: &str,
    system: &str,
    prompt: &str,
    max_tokens: Option<u32>,
    effort: Option<&'static str>,
) -> serde_json::Value {
    let mut payload = serde_json::json!({
        "model": model,
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": prompt },
        ],
        "stream": false,
    });
    if let Some(max_tokens) = max_tokens {
        payload["max_tokens"] = serde_json::json!(max_tokens);
    }
    if let Some(effort) = effort {
        payload["reasoning_effort"] = serde_json::json!(effort);
    }
    payload
}

/// 解析非流式响应。
///
/// 空正文要按 `finish_reason` 分档：上游在"思考吃光额度"时同样回 200，
/// 只回一句"没有返回内容"会把"上限太小"误报成"模型不说话"。
fn parse_completion(
    body: &serde_json::Value,
    system: &str,
    prompt: &str,
) -> Result<Completion, String> {
    let choice = body.get("choices").and_then(|choices| choices.get(0));
    let text = choice
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(|content| content.as_str())
        .unwrap_or_default()
        .trim()
        .to_string();
    let finish_reason = choice
        .and_then(|choice| choice.get("finish_reason"))
        .and_then(|value| value.as_str())
        .map(str::to_string);

    if text.is_empty() {
        return Err(match finish_reason.as_deref() {
            Some("length") => {
                "输出被上限截断（finish_reason=length）：max_tokens 可能太小".to_string()
            }
            _ => "模型没有返回内容".to_string(),
        });
    }

    // `usage` 缺失时按字符估算并打标，审计能区分真实值与估算值。
    let usage = body.get("usage");
    let prompt_tokens = usage
        .and_then(|usage| usage.get("prompt_tokens"))
        .and_then(|value| value.as_u64())
        .and_then(|value| u32::try_from(value).ok());
    let completion_tokens = usage
        .and_then(|usage| usage.get("completion_tokens"))
        .and_then(|value| value.as_u64())
        .and_then(|value| u32::try_from(value).ok());

    let (prompt_tokens, completion_tokens, tokens_estimated) =
        match (prompt_tokens, completion_tokens) {
            (Some(prompt_tokens), Some(completion_tokens)) => {
                (prompt_tokens, completion_tokens, false)
            }
            _ => (
                estimate_tokens(system) + estimate_tokens(prompt),
                estimate_tokens(&text),
                true,
            ),
        };

    Ok(Completion {
        text,
        prompt_tokens,
        completion_tokens,
        tokens_estimated,
        finish_reason,
    })
}

/// 从一帧里取 `usage`。
///
/// 开了 `include_usage` 之后，网关在收尾的最后一帧单独给用量（`choices` 为空）；
/// 中间帧可能带 `"usage": null`，一律当没有。先用子串筛掉普通增量帧，
/// 免得每个分片都多解析一次 JSON。
fn handle_usage(data: &str) -> Option<TokenUsage> {
    if !data.contains("\"usage\"") {
        return None;
    }

    let value: serde_json::Value = serde_json::from_str(data).ok()?;
    let usage = value.get("usage")?;
    let prompt_tokens = usage
        .get("prompt_tokens")
        .and_then(|value| value.as_u64())
        .and_then(|value| u32::try_from(value).ok())?;
    let completion_tokens = usage
        .get("completion_tokens")
        .and_then(|value| value.as_u64())
        .and_then(|value| u32::try_from(value).ok())?;

    Some(TokenUsage {
        prompt_tokens,
        completion_tokens,
        tokens_estimated: false,
        // 单次调用的 prompt 就是该次喂进去的上下文体积：整轮多步合并时
        // 只留最后一次（见 `chat::merge_usage`）。
        context_tokens: prompt_tokens,
    })
}

/// 解析一帧，返回需要的文本增量。
fn handle_frame(data: &str, calls: &mut BTreeMap<usize, PartialCall>) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(data).ok()?;
    let delta = value.get("choices")?.get(0)?.get("delta")?;

    if let Some(items) = delta.get("tool_calls").and_then(|item| item.as_array()) {
        for item in items {
            let index = item
                .get("index")
                .and_then(|value| value.as_u64())
                .unwrap_or(0) as usize;
            let entry = calls.entry(index).or_default();

            if let Some(id) = item.get("id").and_then(|value| value.as_str()) {
                if !id.is_empty() {
                    entry.id = id.to_string();
                }
            }
            if let Some(function) = item.get("function") {
                if let Some(name) = function.get("name").and_then(|value| value.as_str()) {
                    if !name.is_empty() {
                        entry.name = name.to_string();
                    }
                }
                if let Some(arguments) = function.get("arguments").and_then(|value| value.as_str())
                {
                    entry.arguments.push_str(arguments);
                }
            }
        }
    }

    delta
        .get("content")
        .and_then(|value| value.as_str())
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

async fn flush_calls(
    calls: &mut BTreeMap<usize, PartialCall>,
    tx: &mpsc::Sender<Result<ChatEvent, String>>,
) -> Result<(), String> {
    if calls.is_empty() {
        return Ok(());
    }

    let collected: Vec<ChatToolCallWire> = std::mem::take(calls)
        .into_values()
        .filter(|call| !call.name.is_empty())
        .map(|call| ChatToolCallWire {
            id: call.id,
            name: call.name,
            arguments: call.arguments,
        })
        .collect();

    if collected.is_empty() {
        return Ok(());
    }

    if tx
        .send(Ok(ChatEvent::ToolCalls(
            collected
                .into_iter()
                .map(|call| crate::chat::ChatToolCall {
                    id: call.id,
                    name: call.name,
                    arguments: call.arguments,
                })
                .collect(),
        )))
        .await
        .is_err()
    {
        return Ok(());
    }

    Ok(())
}

struct ChatToolCallWire {
    id: String,
    name: String,
    arguments: String,
}

fn to_wire(message: &ChatMessage) -> serde_json::Value {
    // 没有图片时 `content` 仍是字符串：所有既有调用点与测试形状不变，
    // 纯文本消息也少一层数组开销。带图片时才切成多模态 content parts。
    let content = if message.images.is_empty() {
        serde_json::json!(message.content)
    } else {
        let mut parts = Vec::with_capacity(message.images.len() + 1);
        // 文字必须排第一：多数网关按"先文本后图"理解这条消息在问什么。
        if !message.content.is_empty() {
            parts.push(serde_json::json!({
                "type": "text",
                "text": message.content,
            }));
        }
        for image in &message.images {
            parts.push(serde_json::json!({
                "type": "image_url",
                "image_url": { "url": image },
            }));
        }
        serde_json::Value::Array(parts)
    };

    let mut value = serde_json::json!({
        "role": message.role.as_str(),
        "content": content,
    });

    if !message.tool_calls.is_empty() {
        value["tool_calls"] = serde_json::Value::Array(
            message
                .tool_calls
                .iter()
                .map(|call| {
                    serde_json::json!({
                        "id": call.id,
                        "type": "function",
                        "function": {
                            "name": call.name,
                            "arguments": call.arguments,
                        }
                    })
                })
                .collect(),
        );
    }

    if let Some(call_id) = &message.tool_call_id {
        value["tool_call_id"] = serde_json::json!(call_id);
    }

    value
}

fn truncate(text: &str, max: usize) -> String {
    let compact = text.replace(['\n', '\r'], " ");
    if compact.chars().count() <= max {
        return compact;
    }
    compact.chars().take(max).collect::<String>() + "…"
}

/// 非流式请求失败的归因。
///
/// 「超时」与「连不上」的处置完全不同：前者要调大上限或重试，
/// 后者通常是网关地址、DNS 或代理的问题。原始描述留在末尾，方便对照日志。
fn describe_request_error(err: &reqwest::Error) -> String {
    if err.is_timeout() {
        return format!("模型请求超过时限没有返回：{err}");
    }
    if err.is_connect() {
        return format!("连不上模型网关（检查地址与网络）：{err}");
    }
    format!("模型请求失败: {err}")
}

/// 流式读取中断的归因。
///
/// `is_decode` 表示 body 没读完连接就没了：可能是我们这侧掐的，
/// 也可能是上游按自己的时长限制断流。原文案只说"解码失败"，
/// 排查时会往 JSON 解析上找——实际与解析无关，是传输层中断了。
fn describe_stream_error(err: &reqwest::Error) -> String {
    if err.is_timeout() {
        return format!("读取模型流超时：{err}");
    }
    if err.is_decode() {
        return format!(
            "模型流被中断：连接没有正常收尾（上游限时或网络中断都可能）。\
             已完成的内容仍会保留。原始错误：{err}"
        );
    }
    format!("读取模型流失败: {err}")
}

/// 把纯文本接口（[`Responder`]）架在 [`ChatModel`] 之上。
///
/// 不启用工具时用它；启用工具的对话走 [`crate::chat::run`]。
#[derive(Debug, Clone)]
pub struct ModelResponder {
    client: LlmClient,
}

impl ModelResponder {
    pub fn new(client: LlmClient) -> Self {
        Self { client }
    }

    pub fn model(&self) -> &str {
        self.client.model()
    }
}

impl Responder for ModelResponder {
    fn kind(&self) -> &'static str {
        "model"
    }

    fn stream(&self, messages: Vec<PromptMessage>) -> TokenStream {
        let chat_messages: Vec<ChatMessage> = messages
            .into_iter()
            .map(|message| ChatMessage {
                role: match message.role {
                    "system" => ChatRole::System,
                    "assistant" => ChatRole::Assistant,
                    _ => ChatRole::User,
                },
                content: message.content,
                // 这条路径只服务"纯文本一问一答"（摘要、标题、步骤），没有图片。
                images: Vec::new(),
                tool_calls: Vec::new(),
                tool_call_id: None,
            })
            .collect();

        let inner = self.client.stream(chat_messages, Vec::new());
        Box::pin(stream::unfold(inner, |mut inner| async move {
            loop {
                match inner.next().await {
                    Some(Ok(ChatEvent::Text(text))) => return Some((Ok(text), inner)),
                    // 纯文本回答不记账：用量只服务于会话页的元信息行。
                    Some(Ok(ChatEvent::ToolCalls(_) | ChatEvent::Usage(_))) => continue,
                    Some(Err(err)) => return Some((Err(err), inner)),
                    None => return None,
                }
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;

    #[test]
    fn wire_content_stays_a_string_without_images() {
        // 老形状必须原样保留：所有既有的纯文本路径都靠它。
        let wire = to_wire(&ChatMessage::user("你好"));
        assert_eq!(wire["content"], "你好");
    }

    #[test]
    fn reasoning_levels_are_normalized_to_four() {
        assert_eq!(normalize_reasoning("High"), Some("high"), "大小写不敏感");
        assert_eq!(normalize_reasoning(" NONE "), Some("none"));
        assert_eq!(normalize_reasoning("low"), Some("low"));
        assert_eq!(normalize_reasoning("max"), Some("max"));
        // 上游白名单还有 minimal/medium/xhigh/ultra，但它们只是映射到四档，
        // 实测 medium 与 high 的排序不稳定，所以对外只认这四档。
        assert_eq!(normalize_reasoning("medium"), None);
        assert_eq!(normalize_reasoning("ultra"), None);
        assert_eq!(normalize_reasoning(""), None);
    }

    #[test]
    fn chat_payload_carries_effort_only_when_set() {
        let messages = vec![ChatMessage::user("你好")];

        let plain = chat_payload("m", &messages, &[], None);
        assert!(
            plain.get("reasoning_effort").is_none(),
            "不指定档位时请求形状必须与改造前完全一致"
        );
        assert_eq!(plain["model"], "m");
        assert_eq!(plain["stream"], true);

        let tuned = chat_payload("m", &messages, &[], Some("max"));
        assert_eq!(tuned["reasoning_effort"], "max");
    }

    #[test]
    fn capability_off_drops_the_effort() {
        let client = LlmClient::new("https://a.test", "k", "m", Duration::from_secs(1));
        assert_eq!(
            client.with_reasoning_effort(Some("max")).reasoning_effort(),
            None,
            "没声明支持能力的配置，一个字段都不许发"
        );

        let supported = client.with_reasoning(true);
        assert_eq!(
            supported
                .with_reasoning_effort(Some("MAX"))
                .reasoning_effort(),
            Some("max")
        );
        assert_eq!(
            supported
                .with_reasoning_effort(Some("nonsense"))
                .reasoning_effort(),
            None,
            "白名单之外的值宁可不下发"
        );
    }

    #[test]
    fn wire_content_turns_into_parts_with_images() {
        let mut message = ChatMessage::user("看看这张图");
        message.images = vec!["data:image/png;base64,AAAA".to_string()];

        let wire = to_wire(&message);
        let parts = wire["content"].as_array().expect("图片消息应是内容数组");
        assert_eq!(parts.len(), 2, "一段文字 + 一张图");
        assert_eq!(parts[0]["type"], "text");
        assert_eq!(parts[0]["text"], "看看这张图");
        assert_eq!(parts[1]["type"], "image_url");
        assert_eq!(parts[1]["image_url"]["url"], "data:image/png;base64,AAAA");
    }

    #[test]
    fn wire_omits_empty_text_part_when_only_images() {
        // 只发附件不写文字：不能给上游一个空 text 段，部分网关会因此 400。
        let mut message = ChatMessage::user("");
        message.images = vec!["data:image/png;base64,AAAA".to_string()];

        let wire = to_wire(&message);
        let parts = wire["content"].as_array().expect("图片消息应是内容数组");
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0]["type"], "image_url");
    }

    #[test]
    fn merges_streamed_tool_call_arguments() {
        let mut calls = BTreeMap::new();

        handle_frame(
            r#"{"choices":[{"delta":{"tool_calls":[{"id":"call_1","type":"function","index":0,"function":{"name":"web_fetch","arguments":""}}]}}]}"#,
            &mut calls,
        );
        handle_frame(
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"url\":"}}]}}]}"#,
            &mut calls,
        );
        handle_frame(
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"https://example.com\"}"}}]}}]}"#,
            &mut calls,
        );

        let call = calls.get(&0).expect("应累积到一次调用");
        assert_eq!(call.id, "call_1");
        assert_eq!(call.name, "web_fetch");
        assert_eq!(call.arguments, r#"{"url":"https://example.com"}"#);
    }

    #[test]
    fn ignores_reasoning_and_empty_content() {
        assert_eq!(
            handle_frame(
                r#"{"choices":[{"delta":{"reasoning_content":"想一想"}}]}"#,
                &mut BTreeMap::new()
            ),
            None
        );
        assert_eq!(
            handle_frame(
                r#"{"choices":[{"delta":{"content":""}}]}"#,
                &mut BTreeMap::new()
            ),
            None
        );
    }

    #[test]
    fn malformed_frame_is_ignored() {
        assert_eq!(handle_frame("not-json", &mut BTreeMap::new()), None);
        assert_eq!(handle_frame("{}", &mut BTreeMap::new()), None);
    }

    #[test]
    fn usage_frame_is_parsed() {
        // 收尾帧 `choices` 为空：文本解析拿不到东西，但用量必须取出来。
        let data = r#"{"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30}}"#;
        assert_eq!(handle_frame(data, &mut BTreeMap::new()), None);

        let usage = handle_usage(data).expect("应解析出用量");
        assert_eq!(usage.prompt_tokens, 120);
        assert_eq!(usage.completion_tokens, 30);
        assert!(!usage.tokens_estimated);
    }

    #[test]
    fn null_usage_and_plain_frames_are_ignored() {
        // 中间帧的 `usage` 是 null，不能因此产生一条 0 用量的记录。
        assert!(handle_usage(r#"{"choices":[{"delta":{"content":"你"}}],"usage":null}"#).is_none());
        assert!(handle_usage(r#"{"choices":[{"delta":{"content":"你"}}]}"#).is_none());
        assert!(handle_usage("not-json").is_none());
    }

    #[test]
    fn debug_does_not_leak_key() {
        let client = LlmClient::new(
            "https://example.com",
            "sk-secret-value",
            "m",
            Duration::from_secs(1),
        );
        let rendered = format!("{client:?}");
        assert!(!rendered.contains("sk-secret-value"));
        assert!(rendered.contains('m'));
    }

    #[test]
    fn wire_message_carries_tool_calls_and_ids() {
        let message = ChatMessage::tool_result("call_1", "结果");
        let wire = to_wire(&message);
        assert_eq!(wire["role"], "tool");
        assert_eq!(wire["tool_call_id"], "call_1");

        let assistant = ChatMessage::assistant(
            "",
            vec![crate::chat::ChatToolCall {
                id: "call_2".to_string(),
                name: "web_fetch".to_string(),
                arguments: "{}".to_string(),
            }],
        );
        let wire = to_wire(&assistant);
        assert_eq!(wire["tool_calls"][0]["function"]["name"], "web_fetch");
    }

    #[tokio::test]
    async fn streams_text_and_tool_calls_from_endpoint() {
        use axum::response::IntoResponse;
        use axum::routing::post;
        use axum::Router;

        let app = Router::new().route(
            "/compatible-mode/v1/chat/completions",
            post(|| async {
                let body = concat!(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"我查一下\"}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"index\":0,\"function\":{\"name\":\"web_fetch\",\"arguments\":\"\"}}]}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"url\\\":\\\"https://example.com\\\"}\"}}]}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
                    "data: [DONE]\n\n",
                );
                (
                    [(axum::http::header::CONTENT_TYPE, "text/event-stream")],
                    body,
                )
                    .into_response()
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定失败");
        let addr = listener.local_addr().expect("取地址失败");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = LlmClient::new(
            format!("http://{addr}"),
            "test-key",
            "deepseek-v4.1-flash",
            Duration::from_secs(5),
        );

        let mut stream = client.stream(
            vec![ChatMessage::user("查一下 example.com")],
            vec![ToolSpec::web_fetch()],
        );

        let mut text = String::new();
        let mut calls = Vec::new();
        while let Some(item) = stream.next().await {
            match item.expect("不应出错") {
                ChatEvent::Text(piece) => text.push_str(&piece),
                ChatEvent::ToolCalls(list) => calls.extend(list),
                ChatEvent::Usage(_) => {}
            }
        }

        assert_eq!(text, "我查一下");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "web_fetch");
        assert_eq!(calls[0].arguments, r#"{"url":"https://example.com"}"#);
    }

    /// 起一个假网关，按固定节奏吐 `frames` 帧后结束。
    async fn paced_stream_client(
        frames: usize,
        gap: Duration,
        request_timeout: Duration,
        idle_timeout: Duration,
    ) -> LlmClient {
        use axum::body::Body;
        use axum::routing::post;
        use axum::Router;

        let app = Router::new().route(
            "/compatible-mode/v1/chat/completions",
            post(move || async move {
                let body = stream::iter(0..frames).then(move |index| async move {
                    tokio::time::sleep(gap).await;
                    Ok::<_, std::io::Error>(axum::body::Bytes::from(format!(
                        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{index}\"}}}}]}}\n\n"
                    )))
                });
                (
                    [(axum::http::header::CONTENT_TYPE, "text/event-stream")],
                    Body::from_stream(body),
                )
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定失败");
        let addr = listener.local_addr().expect("取地址失败");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        LlmClient::new(
            format!("http://{addr}"),
            "test-key",
            "deepseek-v4.1-flash",
            request_timeout,
        )
        .with_idle_timeout(idle_timeout)
    }

    #[tokio::test]
    async fn long_stream_is_not_cut_by_request_timeout() {
        // 10 帧 × 120ms ≈ 1.2 秒，远超 200ms 的"请求上限"。
        // 这个上限只该管非流式；流式只要一直有数据就不该被掐。
        let client = paced_stream_client(
            10,
            Duration::from_millis(120),
            Duration::from_millis(200),
            Duration::from_secs(2),
        )
        .await;

        let mut stream = client.stream(vec![ChatMessage::user("写个长页面")], Vec::new());
        let mut text = String::new();
        while let Some(item) = stream.next().await {
            match item.expect("长流不该被总时长掐断") {
                ChatEvent::Text(piece) => text.push_str(&piece),
                ChatEvent::ToolCalls(_) | ChatEvent::Usage(_) => {}
            }
        }

        assert_eq!(text, "0123456789");
    }

    #[tokio::test]
    async fn silent_stream_reports_idle_timeout() {
        use axum::body::Body;
        use axum::routing::post;
        use axum::Router;

        // 发一帧就挂住不关连接：这才是"上游卡住"的样子。
        let app = Router::new().route(
            "/compatible-mode/v1/chat/completions",
            post(|| async {
                let body = stream::once(async {
                    Ok::<_, std::io::Error>(axum::body::Bytes::from(
                        "data: {\"choices\":[{\"delta\":{\"content\":\"开\"}}]}\n\n",
                    ))
                })
                .chain(stream::pending());
                (
                    [(axum::http::header::CONTENT_TYPE, "text/event-stream")],
                    Body::from_stream(body),
                )
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定失败");
        let addr = listener.local_addr().expect("取地址失败");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = LlmClient::new(
            format!("http://{addr}"),
            "test-key",
            "deepseek-v4.1-flash",
            Duration::from_secs(5),
        )
        .with_idle_timeout(Duration::from_millis(100));

        let mut stream = client.stream(vec![ChatMessage::user("hi")], Vec::new());
        let mut error = String::new();
        while let Some(item) = stream.next().await {
            if let Err(err) = item {
                error = err;
                break;
            }
        }

        assert!(
            error.contains("没有输出"),
            "要报空闲超时，而不是含糊的传输错误：{error}"
        );
    }

    #[tokio::test]
    async fn complete_still_respects_request_timeout() {
        use axum::routing::post;
        use axum::Router;

        let app = Router::new().route(
            "/compatible-mode/v1/chat/completions",
            post(|| async {
                tokio::time::sleep(Duration::from_millis(400)).await;
                axum::Json(serde_json::json!({
                    "choices": [{ "message": { "content": "迟到" } }],
                }))
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定失败");
        let addr = listener.local_addr().expect("取地址失败");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = LlmClient::new(
            format!("http://{addr}"),
            "test-key",
            "deepseek-v4.1-flash",
            Duration::from_millis(100),
        );

        let error = client
            .complete("系统", "用户", None)
            .await
            .expect_err("非流式仍该受单次请求上限约束");
        assert!(error.contains("超过时限"), "{error}");
    }

    /// 起一个假的非流式网关，返回固定 body。
    async fn chat_client_with_body(body: serde_json::Value) -> LlmClient {
        use axum::routing::post;
        use axum::Router;

        let app = Router::new().route(
            "/compatible-mode/v1/chat/completions",
            post(move || {
                let body = body.clone();
                async move { axum::Json(body) }
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定失败");
        let addr = listener.local_addr().expect("取地址失败");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        LlmClient::new(
            format!("http://{addr}"),
            "test-key",
            "deepseek-v4.1-flash",
            Duration::from_secs(5),
        )
    }

    #[tokio::test]
    async fn complete_parses_text_and_usage() {
        let client = chat_client_with_body(serde_json::json!({
            "choices": [{ "message": { "content": "  上海 10 月 28 日多云  " } }],
            "usage": { "prompt_tokens": 120, "completion_tokens": 30 }
        }))
        .await;

        let done = client
            .complete_text("系统提示", "当前步骤：查询参考信息", Some(100), None)
            .await
            .expect("不应失败");

        assert_eq!(done.text, "上海 10 月 28 日多云");
        assert_eq!(done.prompt_tokens, 120);
        assert_eq!(done.completion_tokens, 30);
        assert!(!done.tokens_estimated);
    }

    #[tokio::test]
    async fn complete_estimates_tokens_when_usage_missing() {
        let client = chat_client_with_body(serde_json::json!({
            "choices": [{ "message": { "content": "结论：未获取到实时班次" } }]
        }))
        .await;

        let done = client
            .complete_text("系统", "提示", None, None)
            .await
            .expect("不应失败");

        assert!(done.tokens_estimated, "缺 usage 时必须标记为估算值");
        assert_eq!(done.prompt_tokens, 4);
        assert!(done.completion_tokens > 0);
    }

    #[tokio::test]
    async fn complete_rejects_empty_content() {
        let client = chat_client_with_body(serde_json::json!({
            "choices": [{ "message": { "content": "   " } }]
        }))
        .await;

        let err = client
            .complete_text("系统", "提示", None, None)
            .await
            .expect_err("空内容应报错");
        assert!(err.contains("没有返回内容"), "实际错误：{err}");
    }

    #[test]
    fn payload_only_sends_effort_when_asked() {
        let plain = completion_payload("m", "s", "p", Some(300), None);
        assert!(
            plain.get("reasoning_effort").is_none(),
            "没要求就不发这个字段：{plain}"
        );

        let off = completion_payload("m", "s", "p", Some(300), Some("none"));
        assert_eq!(off["reasoning_effort"], "none");
        assert_eq!(off["max_tokens"], 300);
    }

    #[test]
    fn empty_content_is_reported_as_truncation_when_hitting_limit() {
        let hit_limit = serde_json::json!({
            "choices": [{ "message": { "content": "" }, "finish_reason": "length" }],
        });
        let err = parse_completion(&hit_limit, "s", "p").expect_err("空正文应当报错");
        assert!(err.contains("截断"), "上限截断要单独分档：{err}");

        let silent = serde_json::json!({
            "choices": [{ "message": { "content": "" }, "finish_reason": "stop" }],
        });
        let err = parse_completion(&silent, "s", "p").expect_err("空正文应当报错");
        assert!(err.contains("没有返回内容"), "实际错误：{err}");
    }

    #[test]
    fn finish_reason_is_kept_for_non_empty_text() {
        let body = serde_json::json!({
            "choices": [{ "message": { "content": "半截摘要" }, "finish_reason": "length" }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 },
        });
        let done = parse_completion(&body, "s", "p").expect("应当解析成功");
        assert_eq!(done.text, "半截摘要");
        assert_eq!(done.finish_reason.as_deref(), Some("length"));
    }
}
