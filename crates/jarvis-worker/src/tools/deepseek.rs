//! DeepSeek 官方 Search / Fetch 客户端（经 service 回环代理）。
//!
//! 这边**没有密钥**：请求打到 `127.0.0.1` 的代理，由 service 换成真 key 再发上游。
//! 所以这里只做三件事：构造请求体、解析响应、把状态码翻译成一句人话。
//!
//! 上游响应字段会演进，解析一律 `#[serde(default)]`：`date` / `authority` /
//! `summary` 缺失或为 `null` 时退化成"没有这条信息"，而不是整条结果解析失败。

use std::time::Duration;

use serde::Deserialize;
use serde_json::json;

use super::config::ProxyAccess;

/// 与 service 侧 `tool_proxy` 的路径一一对应。
const SEARCH_PATH: &str = "/internal/tools/v1/search";
const FETCH_PATH: &str = "/internal/tools/v1/fetch";

/// 错误体里的上游原文最多带多少字：它是英文报错，只用来帮人定位。
const MAX_ERROR_DETAIL_CHARS: usize = 120;

/// 一条搜索候选（上游原样字段 + 已剔空地址）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SearchItem {
    pub(crate) title: String,
    pub(crate) url: String,
    /// 100–200 字的短摘要，适合展示。
    pub(crate) snippet: String,
    /// 600–800 字的长摘要，文档明确"适用于给模型阅读"。
    pub(crate) summary: String,
    /// 发布时间（UTC RFC 3339），未知为 `None`。
    pub(crate) date: Option<String>,
    /// 权威性 0–4（上游用 -1 表示未知）。
    pub(crate) authority: Option<i64>,
}

/// `Fetch` 的结果：标题 + Markdown 正文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FetchedPage {
    pub(crate) title: String,
    pub(crate) content: String,
}

/// 经 service 回环代理访问官方接口的客户端。
#[derive(Clone)]
pub(crate) struct DeepSeekClient {
    client: reqwest::Client,
    base_url: String,
    /// 进程令牌，不是上游密钥。
    token: String,
    need_content: bool,
}

impl std::fmt::Debug for DeepSeekClient {
    /// 令牌不进日志。
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeepSeekClient")
            .field("base_url", &self.base_url)
            .field("need_content", &self.need_content)
            .finish_non_exhaustive()
    }
}

impl DeepSeekClient {
    pub(crate) fn new(
        proxy: &ProxyAccess,
        timeout: Duration,
        need_content: bool,
    ) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .timeout(timeout)
            // 代理只监听回环，不该出现重定向；真出现就当作失败，别把令牌带去别处。
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|err| format!("创建联网工具客户端失败：{err}"))?;

        Ok(Self {
            client,
            base_url: proxy.url.trim_end_matches('/').to_string(),
            token: proxy.token.clone(),
            need_content,
        })
    }

    /// 关键词搜索。`count` 由调用方夹到 1..=8。
    pub(crate) async fn search(
        &self,
        query: &str,
        count: usize,
    ) -> Result<Vec<SearchItem>, String> {
        let body = json!({
            "query": query,
            "count": count,
            "need_content": self.need_content,
        });
        let text = self.post(SEARCH_PATH, body).await?;
        parse_search(&text)
    }

    /// 读一个公网页面，返回 Markdown 正文。
    pub(crate) async fn fetch(&self, url: &str) -> Result<FetchedPage, String> {
        let text = self.post(FETCH_PATH, json!({ "url": url })).await?;
        parse_fetch(&text)
    }

    async fn post(&self, path: &str, body: serde_json::Value) -> Result<String, String> {
        let response = self
            .client
            .post(format!("{}{}", self.base_url, path))
            .header("authorization", format!("Bearer {}", self.token))
            .json(&body)
            .send()
            .await
            .map_err(|err| format!("联网工具请求失败：{err}"))?;

        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|err| format!("读取联网工具响应失败：{err}"))?;

        if !status.is_success() {
            return Err(status_reason(status.as_u16(), &text));
        }

        Ok(text)
    }
}

/// 把上游状态码翻成模型能据此写「未核实」的中文原因。
///
/// 402 与 429 必须分开说：一个是"没钱了，要人处理"，一个是"太快了，等会儿再来"。
pub(crate) fn status_reason(status: u16, body: &str) -> String {
    let reason = match status {
        401 => "鉴权失败：检查联网工具密钥（tool.web.api_key_env）",
        402 => "余额不足：上游账户需要充值后才能继续搜索/抓取",
        403 => "上游安全策略拒绝读取该地址",
        404 => "上游取不到可读正文（可能是脚本页、被站点拦截或内容类型不支持）",
        408 | 504 => "上游读取超时",
        413 => "请求体超过上游大小限制",
        429 => "上游限流（429）：稍后再试",
        500..=599 => "上游服务异常",
        _ => "上游返回错误",
    };

    match error_detail(body) {
        Some(detail) => format!("{reason}（{status}：{detail}）"),
        None => format!("{reason}（{status}）"),
    }
}

/// 尽力从 OpenAI 兼容错误体里取 `error.message`；取不到就返回 `None`。
fn error_detail(body: &str) -> Option<String> {
    #[derive(Deserialize)]
    struct Body {
        error: Detail,
    }
    #[derive(Deserialize)]
    struct Detail {
        #[serde(default)]
        message: String,
    }

    let parsed: Body = serde_json::from_str(body).ok()?;
    let message = parsed.error.message.trim();
    if message.is_empty() {
        return None;
    }
    Some(truncate(message, MAX_ERROR_DETAIL_CHARS))
}

pub(crate) fn parse_search(text: &str) -> Result<Vec<SearchItem>, String> {
    #[derive(Deserialize)]
    struct Response {
        #[serde(default)]
        results: Vec<Item>,
    }
    #[derive(Deserialize)]
    struct Item {
        #[serde(default)]
        title: String,
        #[serde(default)]
        url: String,
        #[serde(default)]
        snippet: String,
        #[serde(default)]
        summary: String,
        #[serde(default)]
        date: Option<String>,
        #[serde(default)]
        authority: Option<i64>,
    }

    let parsed: Response =
        serde_json::from_str(text).map_err(|err| format!("联网工具响应不是预期结构：{err}"))?;

    Ok(parsed
        .results
        .into_iter()
        .filter(|item| !item.url.trim().is_empty())
        .map(|item| SearchItem {
            title: if item.title.trim().is_empty() {
                item.url.clone()
            } else {
                item.title
            },
            url: item.url,
            snippet: item.snippet,
            summary: item.summary,
            // 上游用 -1 表示"未知权威性"，别把它当分数显示给模型。
            authority: item.authority.filter(|value| *value >= 0),
            date: item.date.filter(|value| !value.trim().is_empty()),
        })
        .collect())
}

pub(crate) fn parse_fetch(text: &str) -> Result<FetchedPage, String> {
    #[derive(Deserialize)]
    struct Response {
        #[serde(default)]
        title: String,
        #[serde(default)]
        content: String,
    }

    let parsed: Response =
        serde_json::from_str(text).map_err(|err| format!("联网工具响应不是预期结构：{err}"))?;

    Ok(FetchedPage {
        title: parsed.title,
        content: parsed.content,
    })
}

/// 按字符截断（不是字节），并补省略号。
fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max_chars).collect();
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_results_and_drops_empty_urls() {
        let body = r#"{
            "results": [
                {
                    "rerank_score": 2.4,
                    "title": "DeepSeek V4 发布",
                    "url": "https://example.com/a",
                    "snippet": "短摘要",
                    "summary": "长摘要",
                    "date": "2026-06-01T00:00:00+00:00",
                    "authority": 3
                },
                { "title": "没有地址的条目", "url": "" }
            ]
        }"#;

        let items = parse_search(body).expect("应解析成功");
        assert_eq!(items.len(), 1, "空地址的候选应被丢弃");
        assert_eq!(items[0].title, "DeepSeek V4 发布");
        assert_eq!(items[0].summary, "长摘要");
        assert_eq!(items[0].authority, Some(3));
        assert!(items[0].date.is_some());
    }

    #[test]
    fn missing_null_fields_degrade_instead_of_failing() {
        let body = r#"{
            "results": [{
                "url": "https://example.com/b",
                "date": null,
                "authority": null
            }]
        }"#;

        let items = parse_search(body).expect("缺字段不该整条失败");
        assert_eq!(items.len(), 1);
        // 没标题时用地址兜底，模型至少知道勾的是哪一条。
        assert_eq!(items[0].title, "https://example.com/b");
        assert!(items[0].date.is_none());
        assert!(items[0].authority.is_none());
    }

    #[test]
    fn unknown_authority_minus_one_is_hidden() {
        let body = r#"{"results":[{"url":"https://example.com/c","authority":-1}]}"#;
        let items = parse_search(body).expect("应解析成功");
        assert_eq!(items[0].authority, None, "-1 是未知，不该当成低分");
    }

    #[test]
    fn empty_results_is_ok_not_an_error() {
        let items = parse_search(r#"{"results":[]}"#).expect("空结果不是解析错误");
        assert!(items.is_empty());
    }

    #[test]
    fn non_json_body_reports_structure_problem() {
        let err = parse_search("<html>502</html>").expect_err("应报错");
        assert!(err.contains("预期结构"), "{err}");
    }

    #[test]
    fn parses_fetch_markdown() {
        let page = parse_fetch(r##"{"title":"Example","content":"# Example\n\n正文"}"##)
            .expect("应解析成功");
        assert_eq!(page.title, "Example");
        assert!(page.content.contains("正文"));
    }

    #[test]
    fn status_reasons_are_actionable_and_distinct() {
        assert!(status_reason(402, "").contains("余额"));
        assert!(status_reason(429, "").contains("限流"));
        assert!(status_reason(404, "").contains("正文"));
        assert!(status_reason(401, "").contains("密钥"));
        // 上游原文只作为补充，长度受控。
        let long = format!(r#"{{"error":{{"message":"{}"}}}}"#, "x".repeat(400));
        let reason = status_reason(400, &long);
        assert!(reason.contains("400"), "{reason}");
        assert!(
            reason.chars().count() < MAX_ERROR_DETAIL_CHARS + 60,
            "错误原文要截断：{reason}"
        );
    }

    #[test]
    fn non_json_error_body_falls_back_to_status_only() {
        let reason = status_reason(500, "<html>oops</html>");
        assert!(reason.contains("上游服务异常"), "{reason}");
        assert!(reason.contains("500"), "{reason}");
    }
}
