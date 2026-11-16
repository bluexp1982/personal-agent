//! 只读 HTTP 工具。
//!
//! 两条路径，边界不同，不要混用：
//!
//! - [`fetch`]：读**模型或用户给出的** URL。地址不受限，但必须逐跳过
//!   [`net_guard`] 准入（只 https、拒绝内网与回环、DNS 固定、不自动跟随重定向）；
//! - [`get_text`] / [`get_json`]：读**代码里写死的**固定上游（天气、搜索）。
//!   地址不由调用方决定，没有 SSRF 面，因此不做准入；但超时、体积、编码处理一致。
//!
//! 体积上限 1 MiB、超时取自 `PERSONAL_AGENT_TOOL_TIMEOUT_MS`，两条路径共用。

use std::time::Duration;

use reqwest::header::{CONTENT_TYPE, LOCATION};
use reqwest::redirect::Policy;
use reqwest::{Client, Response, Url};

use super::{html, net_guard, ToolError};

/// 单次响应体上限。
const MAX_BYTES: usize = 1024 * 1024;

/// 一次抓取的结果。
#[derive(Debug)]
pub(crate) struct Fetched {
    /// 已按 charset 解码的文本（HTML 原文，抽取正文由调用方决定）。
    pub(crate) text: String,
    /// 最终地址：跟随重定向后的那一跳，来源卡片记这个。
    pub(crate) final_url: String,
    /// 编码没认出来或字节非法。
    pub(crate) lossy: bool,
}

/// 读一个公网 https 地址。每跳重定向都重新过准入。
pub(crate) async fn fetch(url: &str, timeout: Duration) -> Result<Fetched, ToolError> {
    let mut current =
        Url::parse(url).map_err(|err| ToolError::Denied(format!("URL 非法: {err}")))?;

    // 0..=MAX_REDIRECTS：允许 5 次跳转，第 6 次取到的响应才必须落地。
    for _ in 0..=net_guard::MAX_REDIRECTS {
        let client = net_guard::admit(&current, timeout).await?;

        let response = client
            .get(current.clone())
            .send()
            .await
            .map_err(|err| ToolError::Failed(format!("请求失败: {err}")))?;

        let status = response.status();

        if status.is_redirection() {
            let location = response
                .headers()
                .get(LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| {
                    ToolError::Failed(format!("重定向缺少 Location: {}", status.as_u16()))
                })?;

            // 相对地址按当前地址解析；下一轮循环会重新校验 scheme 与目标地址，
            // 所以"公网页面 302 到 127.0.0.1"在这里就被拦住。
            current = current
                .join(location)
                .map_err(|err| ToolError::Denied(format!("重定向地址非法: {err}")))?;
            continue;
        }

        if !status.is_success() {
            return Err(ToolError::Failed(format!("目标返回 {}", status.as_u16())));
        }

        let charset = header_string(response.headers(), CONTENT_TYPE);
        let bytes = read_capped(response).await?;
        let (text, lossy) = html::decode_body(&bytes, charset.as_deref());

        return Ok(Fetched {
            text,
            final_url: current.to_string(),
            lossy,
        });
    }

    Err(ToolError::Failed(format!(
        "重定向超过 {} 跳",
        net_guard::MAX_REDIRECTS
    )))
}

/// 读固定上游的文本（搜索页）。上游由代码写死，不经过准入。
pub(crate) async fn get_text(url: &str, timeout: Duration) -> Result<String, ToolError> {
    let parsed =
        reqwest::Url::parse(url).map_err(|err| ToolError::Failed(format!("URL 非法: {err}")))?;

    if parsed.scheme() != "https" {
        return Err(ToolError::Failed("固定上游必须走 https".to_string()));
    }

    let response = fixed_client(timeout)?
        .get(parsed)
        .send()
        .await
        .map_err(|err| ToolError::Failed(format!("请求失败: {err}")))?;

    let status = response.status();
    if !status.is_success() {
        return Err(ToolError::Failed(format!("目标返回 {}", status.as_u16())));
    }

    let charset = header_string(response.headers(), CONTENT_TYPE);
    let bytes = read_capped(response).await?;
    Ok(html::decode_body(&bytes, charset.as_deref()).0)
}

/// 固定上游的 JSON GET。调用方必须传代码里写死的 https 地址。
pub(crate) async fn get_json(url: &str, timeout: Duration) -> Result<serde_json::Value, ToolError> {
    let parsed =
        reqwest::Url::parse(url).map_err(|err| ToolError::Failed(format!("URL 非法: {err}")))?;

    if parsed.scheme() != "https" {
        return Err(ToolError::Failed("固定上游必须走 https".to_string()));
    }

    let response = fixed_client(timeout)?
        .get(parsed)
        .send()
        .await
        .map_err(|err| ToolError::Failed(format!("请求失败: {err}")))?;

    let status = response.status();
    if !status.is_success() {
        return Err(ToolError::Failed(format!("目标返回 {}", status.as_u16())));
    }

    let charset = header_string(response.headers(), CONTENT_TYPE);
    let bytes = read_capped(response).await?;
    let (text, _) = html::decode_body(&bytes, charset.as_deref());
    serde_json::from_str(&text)
        .map_err(|err| ToolError::Failed(format!("响应不是合法 JSON: {err}")))
}

fn fixed_client(timeout: Duration) -> Result<Client, ToolError> {
    Client::builder()
        .timeout(timeout)
        // 固定上游允许少量跳转（例如搜索引擎把 www 跳到不带 www 的主机名），
        // 但上限要比公网抓取更紧：这条路径没有准入兜底。
        .redirect(Policy::limited(3))
        .user_agent(format!("personal-agent/{}", protocol::VERSION))
        .build()
        .map_err(|err| ToolError::Failed(format!("创建 HTTP 客户端失败: {err}")))
}

fn header_string(
    headers: &reqwest::header::HeaderMap,
    name: reqwest::header::HeaderName,
) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string)
}

/// 边读边截断：慢站点不能把内存吃满，也不能把对话框堵死。
async fn read_capped(mut response: Response) -> Result<Vec<u8>, ToolError> {
    let mut collected: Vec<u8> = Vec::new();

    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|err| ToolError::Failed(format!("读取响应失败: {err}")))?
    {
        collected.extend_from_slice(&chunk);
        if collected.len() >= MAX_BYTES {
            collected.truncate(MAX_BYTES);
            break;
        }
    }

    Ok(collected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_non_https() {
        let error = fetch("http://example.com", Duration::from_secs(1))
            .await
            .expect_err("http 应被拒绝");
        assert!(matches!(error, ToolError::Denied(_)));
    }

    #[tokio::test]
    async fn rejects_private_targets_without_touching_the_network() {
        for target in [
            "https://127.0.0.1/",
            "https://192.168.1.1/",
            "https://localhost/",
            "https://metadata.internal/",
        ] {
            let error = fetch(target, Duration::from_secs(1))
                .await
                .expect_err("内网地址应被拒绝");
            // 文案必须含"拒绝"：service 侧按关键字区分 Denied 与 Failed。
            assert!(matches!(error, ToolError::Denied(_)), "{target}: {error}");
            assert!(error.to_string().contains("拒绝"), "{target}: {error}");
        }
    }

    #[tokio::test]
    async fn json_helper_still_requires_https() {
        let error = get_json(
            "http://api.open-meteo.com/v1/forecast",
            Duration::from_secs(1),
        )
        .await
        .expect_err("固定上游也必须 https");
        assert!(matches!(error, ToolError::Failed(_)));
    }

    #[tokio::test]
    async fn text_helper_rejects_plain_http() {
        let error = get_text("http://example.com", Duration::from_secs(1))
            .await
            .expect_err("固定上游也必须 https");
        assert!(matches!(error, ToolError::Failed(_)));
    }
}
