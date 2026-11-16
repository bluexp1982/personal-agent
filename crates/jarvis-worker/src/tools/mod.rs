//! 工具注册表。
//!
//! 只读工具三个：`web.search`（关键词搜索）、`web.fetch`（读一个公网页面）、
//! `weather.current`（固定上游的天气）。`code.exec` 只作为能力名登记，
//! 由任务链路另走编码 CLI，不在 [`ToolRegistry::call`] 的分支里。
//!
//! 联网的两个工具都可以换上游（见 [`config::WebTools`]）：默认仍是
//! Bing 结果页 + 本机抓取，配了密钥才可能走 DeepSeek 官方接口。
//! 换上游不改变工具名与对模型的语义，所以注册表对外没有变化。
//!
//! 接口按"名字 + 参数"设计，后续接 MCP（R3）时只需新增一个注册来源，
//! 任务循环与技能校验不用改。

pub(crate) mod config;
pub(crate) mod deepseek;
pub(crate) mod html;
pub(crate) mod http;
pub(crate) mod net_guard;
pub(crate) mod search;
pub(crate) mod weather;

use std::time::Duration;

use config::SearchProvider;
use deepseek::DeepSeekClient;

/// `web.fetch` 交给模型的正文长度上限（字符）。
///
/// 太小会把长页面截成一句摘要，太大则白烧上下文；2000 字足够判断一页在讲什么。
const WEB_TEXT_CHARS: usize = 2000;

/// 工具产出的结果。`size` 用于产物大小，`summary` 进入步骤输出与方案文本。
///
/// 产物种类由技能的 `outputs` 决定，不由工具决定——避免工具"自称完成了什么"。
#[derive(Debug, Clone)]
pub(crate) struct ToolOutput {
    pub(crate) summary: String,
    pub(crate) size: i64,
    /// 实际读取的地址。由工具记录，而不是让调用方回填——避免"来源"被伪造。
    ///
    /// `None` 表示这次调用没有可引用的来源：搜索结果页就是这种情况（候选页
    /// 并没有被读过，把它写成来源等于伪造采集时间）。
    pub(crate) source_url: Option<String>,
    /// 采集时间（Unix 毫秒）。
    pub(crate) fetched_at: i64,
}

impl ToolOutput {
    /// 网页类结果：正文 + 来源地址。
    fn web(summary: String, source_url: Option<String>) -> Self {
        Self {
            size: summary.len() as i64,
            summary,
            source_url,
            fetched_at: now_ms(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum ToolError {
    #[error("未知工具: {0}")]
    Unknown(String),
    #[error("工具调用被拒绝: {0}")]
    Denied(String),
    #[error("工具调用失败: {0}")]
    Failed(String),
}

/// 工具注册表。
///
/// 不再持有域名白名单：`web.fetch` 的准入改成"只放行公网地址"，
/// 规则唯一实现在 [`net_guard`]。`weather.current` / `web.search` 的目标是
/// 代码里写死的上游，不受准入约束——那套规则是为了拦住"模型指定的任意 URL"。
#[derive(Debug)]
pub(crate) struct ToolRegistry {
    timeout: Duration,
    weather: weather::Weather,
    /// 联网工具的上游选择（由 service 通过环境变量下发）。
    web: config::WebTools,
    /// 官方接口客户端。`None` 时两个工具都退回"无需密钥"的路径。
    deepseek: Option<DeepSeekClient>,
}

impl ToolRegistry {
    pub(crate) fn new() -> Self {
        let timeout = timeout_from_env();
        let web = config::WebTools::from_env();
        let deepseek = build_client(&web, timeout);

        Self {
            timeout,
            weather: weather::Weather::default(),
            web,
            deepseek,
        }
    }

    /// 已注册的工具名，供技能校验 `required_tools`。
    ///
    /// `code.exec` 只作为**能力名**登记：它不在 `call()` 的分支里，因此模型即使在
    /// 对话中喊出这个名字也拿不到执行（对话侧另有 `prepare_call` 白名单）。
    pub(crate) fn names(&self) -> &'static [&'static str] {
        &["web.search", "web.fetch", "weather.current", "code.exec"]
    }

    pub(crate) fn has(&self, name: &str) -> bool {
        self.names().contains(&name)
    }

    /// 调用工具。参数由调用方按工具语义构造，非法参数直接拒绝。
    pub(crate) async fn call(
        &self,
        name: &str,
        args: &serde_json::Value,
    ) -> Result<ToolOutput, ToolError> {
        match name {
            "web.search" => {
                let query = args
                    .get("query")
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|query| !query.is_empty())
                    .ok_or_else(|| ToolError::Denied("缺少 query 参数".to_string()))?;

                let limit = args
                    .get("limit")
                    .and_then(serde_json::Value::as_u64)
                    .unwrap_or(6)
                    .clamp(1, 8) as usize;

                // `deepseek` 只在"配了官方上游且客户端建起来了"时才非空；
                // 否则 `search` 自己走 Bing，不需要再判一次 provider。
                search::search(query, limit, self.timeout, self.deepseek.as_ref()).await
            }
            "web.fetch" => self.fetch(args).await,
            "weather.current" => {
                let city = args
                    .get("city")
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|city| !city.is_empty())
                    .ok_or_else(|| ToolError::Denied("缺少 city 参数".to_string()))?;

                let days = args
                    .get("days")
                    .and_then(serde_json::Value::as_u64)
                    .unwrap_or(3)
                    .clamp(1, 7) as u8;

                // 天气两跳都要有明确上限：慢了就让步骤降级，别拖着整个任务。
                self.weather
                    .lookup(city, days, self.timeout.min(Duration::from_secs(6)))
                    .await
            }
            other => Err(ToolError::Unknown(other.to_string())),
        }
    }

    /// 读一个公网页面：本机优先，取不到才（按白名单）回落到官方 Fetch。
    ///
    /// **被准入拒绝的地址永不外发**——非 https、内网、回环、带账号密码的 URL
    /// 属于本机拓扑，交给第三方既没意义也泄露信息。
    async fn fetch(&self, args: &serde_json::Value) -> Result<ToolOutput, ToolError> {
        let url = args
            .get("url")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| ToolError::Denied("缺少 url 参数".to_string()))?
            .to_string();

        let local = http::fetch(&url, self.timeout).await;

        // 准入拒绝：直接返回，连兜底都不考虑。
        if let Err(ToolError::Denied(reason)) = &local {
            return Err(ToolError::Denied(reason.clone()));
        }

        // 本机结果分三种：能用、乱码（还能勉强用）、完全取不到。
        let mut lossy: Option<(String, String)> = None;
        let reason: String;

        match &local {
            Ok(fetched) => {
                let text = html::extract_text(&fetched.text, WEB_TEXT_CHARS);
                if !text.is_empty() && !fetched.lossy {
                    return Ok(ToolOutput::web(text, Some(fetched.final_url.clone())));
                }
                if !text.is_empty() {
                    // 编码没认出来：留着原文，兜底也失败时还能交回模型（并附说明）。
                    lossy = Some((text, fetched.final_url.clone()));
                    reason = format!("页面编码未识别: {}", fetched.final_url);
                } else {
                    reason = format!(
                        "页面没有可读正文（可能是纯脚本页或空页）: {}",
                        fetched.final_url
                    );
                }
            }
            Err(err) => reason = err.to_string(),
        }

        let client = match (&self.deepseek, self.web.fetch_fallback) {
            (Some(client), true) => client,
            _ => {
                return match lossy {
                    // 不兜底时保持旧行为：乱码正文照旧返回并明说，别把能看的东西也扔掉。
                    Some((text, final_url)) => Ok(ToolOutput::web(
                        format!("{text}\n（页面编码未识别，正文可能有乱码）"),
                        Some(final_url),
                    )),
                    None => Err(ToolError::Failed(reason)),
                };
            }
        };

        match client.fetch(&url).await {
            Ok(page) if !page.content.trim().is_empty() => {
                let text = html::truncate(page.content.trim(), WEB_TEXT_CHARS);
                // 来源记**请求的地址**：兜底这一跳拿不到最终重定向地址，
                // 编一个出来就等于伪造。
                Ok(ToolOutput::web(text, Some(url)))
            }
            Ok(_) => match lossy {
                Some((text, final_url)) => Ok(ToolOutput::web(
                    format!("{text}\n（页面编码未识别，正文可能有乱码）"),
                    Some(final_url),
                )),
                None => Err(ToolError::Failed(format!("{reason}；上游兜底也取不到正文"))),
            },
            Err(err) => match lossy {
                Some((text, final_url)) => Ok(ToolOutput::web(
                    format!("{text}\n（页面编码未识别，正文可能有乱码）"),
                    Some(final_url),
                )),
                None => Err(ToolError::Failed(format!("{reason}；上游兜底失败：{err}"))),
            },
        }
    }
}

/// 按运行时配置构造官方接口客户端。
///
/// 只有"搜索走官方"或"抓取要兜底"时才真的建客户端；缺地址、缺令牌或
/// 建客户端失败都退回 `None`，工具自动停留在无需密钥的路径上。
fn build_client(web: &config::WebTools, timeout: Duration) -> Option<DeepSeekClient> {
    let needed = web.search == SearchProvider::DeepSeek || web.fetch_fallback;
    if !needed {
        return None;
    }

    let proxy = web.proxy.as_ref()?;
    // 比本机工具再少 1 秒：这一跳多了一次回环转发，超时要留出代理回话的余量。
    let timeout = timeout
        .saturating_sub(Duration::from_millis(1_000))
        .max(Duration::from_millis(500));

    match DeepSeekClient::new(proxy, timeout, web.need_content) {
        Ok(client) => Some(client),
        Err(err) => {
            tracing::warn!(%err, "联网工具客户端创建失败：本次退回 Bing + 本机抓取");
            None
        }
    }
}

/// 单次抓取超时。
///
/// 必须**小于** service 侧的等待超时：否则慢请求会先被 service 判为“工具调用超时”，
/// 真正的失败原因（DNS、TLS、站点错误）就丢失了。
fn timeout_from_env() -> Duration {
    let millis = std::env::var("PERSONAL_AGENT_TOOL_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value >= 500)
        .unwrap_or(8_000);
    Duration::from_millis(millis)
}

/// 当前时间（Unix 毫秒）。工具结果用它标注采集时间。
pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_exposes_read_only_tools() {
        let registry = ToolRegistry::new();
        assert!(registry.has("web.search"));
        assert!(registry.has("web.fetch"));
        assert!(registry.has("weather.current"));
        assert!(!registry.has("web.fetch.nonexistent"));
    }

    #[test]
    fn no_proxy_means_no_deepseek_client() {
        // 测试环境没有代理地址，必须自然退回"无需密钥"的路径。
        let registry = ToolRegistry::new();
        assert!(
            registry.deepseek.is_none(),
            "没有代理地址时不该建官方接口客户端"
        );
        assert_eq!(registry.web.search, SearchProvider::Bing);
        assert!(!registry.web.fetch_fallback);
    }

    #[tokio::test]
    async fn weather_requires_city_before_network() {
        let registry = ToolRegistry::new();
        let error = registry
            .call("weather.current", &serde_json::json!({ "days": 3 }))
            .await
            .expect_err("缺城市应拒绝");
        assert!(matches!(error, ToolError::Denied(_)));
    }

    #[tokio::test]
    async fn search_requires_query_before_network() {
        let registry = ToolRegistry::new();
        let error = registry
            .call("web.search", &serde_json::json!({ "limit": 3 }))
            .await
            .expect_err("缺关键词应拒绝");
        assert!(matches!(error, ToolError::Denied(_)));
    }

    #[tokio::test]
    async fn unknown_tool_is_rejected() {
        let registry = ToolRegistry::new();
        let error = registry
            .call("shell.exec", &serde_json::json!({}))
            .await
            .expect_err("未知工具应拒绝");
        assert!(matches!(error, ToolError::Unknown(_)));
    }

    #[tokio::test]
    async fn private_address_is_denied_before_any_fallback() {
        // 内网地址必须在本机这一层就被拒，绝不会交给第三方去抓。
        let registry = ToolRegistry::new();
        for target in ["https://127.0.0.1/", "https://192.168.1.1/"] {
            let error = registry
                .call("web.fetch", &serde_json::json!({ "url": target }))
                .await
                .expect_err("内网地址应被拒绝");
            assert!(matches!(error, ToolError::Denied(_)), "{target}: {error}");
        }
    }

    /// 真联网冒烟（**会真实计费**）：需要 service 已在跑、配好密钥，并把代理地址
    /// 与令牌传进来。只验证链路与解析，不检查余额。
    ///
    /// ```bash
    /// PERSONAL_AGENT_WEB_SEARCH_PROVIDER=deepseek \
    /// PERSONAL_AGENT_WEB_FETCH_FALLBACK=1 \
    /// PERSONAL_AGENT_TOOL_PROXY_URL=http://127.0.0.1:<port> \
    /// PERSONAL_AGENT_TOOL_PROXY_TOKEN=<token> \
    ///   cargo test -p jarvis-worker -- --ignored live_deepseek --nocapture
    /// ```
    #[tokio::test]
    #[ignore = "联网冒烟（真实计费），需手动执行"]
    async fn live_deepseek_search_and_fetch() {
        // 让 `ToolRegistry::new()` 走官方上游：环境里已经有代理地址与令牌。
        std::env::set_var("PERSONAL_AGENT_WEB_SEARCH_PROVIDER", "deepseek");
        std::env::set_var("PERSONAL_AGENT_WEB_FETCH_FALLBACK", "1");

        let registry = ToolRegistry::new();
        assert!(
            registry.deepseek.is_some(),
            "缺少 PERSONAL_AGENT_TOOL_PROXY_URL / _TOKEN：先起 service 再跑"
        );

        let output = registry
            .call(
                "web.search",
                &serde_json::json!({ "query": "DeepSeek V4 发布", "limit": 3 }),
            )
            .await
            .expect("官方搜索不应失败");
        eprintln!("{}", output.summary);
        assert!(output.summary.contains("http"), "候选里应带地址");
        assert!(
            output.source_url.is_none(),
            "搜索不产出来源（候选页没被读过）"
        );

        let fetched = registry
            .call(
                "web.fetch",
                &serde_json::json!({ "url": "https://example.com" }),
            )
            .await
            .expect("抓取示例页不应失败");
        eprintln!("{}", fetched.summary);
        assert!(fetched.source_url.is_some(), "抓取成功必须带来源");
    }

    /// 真联网冒烟：公网准入 + 正文抽取一起验，不进 CI。
    ///
    /// `cargo test -p jarvis-worker -- --ignored live_fetch --nocapture`
    #[tokio::test]
    #[ignore = "联网冒烟，需手动执行"]
    async fn live_fetch_extracts_text() {
        let registry = ToolRegistry::new();
        let output = registry
            .call(
                "web.fetch",
                &serde_json::json!({ "url": "https://example.com" }),
            )
            .await
            .expect("抓取示例页不应失败");

        eprintln!("{}", output.summary);
        assert!(output.summary.contains("Example Domain"));
        assert!(
            !output.summary.contains("<html"),
            "不应把原始 HTML 交给模型"
        );
        assert!(output.source_url.is_some(), "抓取成功必须有来源");
    }
}
