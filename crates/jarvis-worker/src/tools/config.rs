//! 联网工具的运行期参数（由 service 通过环境变量下发）。
//!
//! worker **读不到配置文件，也看不到密钥**：`provider` 与兜底开关都是
//! service 算好的**实际生效值**（缺密钥时已经降级），这里只做解析，
//! 外加一条自保规则——没拿到代理地址就当作"付费上游不可用"。

/// 搜索上游。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SearchProvider {
    /// 抓 `cn.bing.com` 结果页，无需密钥。
    Bing,
    /// 官方 Search 接口，经 service 回环代理。
    DeepSeek,
}

/// 回环代理的地址与进程令牌。**不含真密钥**。
#[derive(Debug, Clone)]
pub(crate) struct ProxyAccess {
    pub(crate) url: String,
    pub(crate) token: String,
}

/// 联网工具的运行期配置。
#[derive(Debug, Clone)]
pub(crate) struct WebTools {
    pub(crate) search: SearchProvider,
    /// 本机抓取失败时是否回落到官方 Fetch。
    pub(crate) fetch_fallback: bool,
    /// 搜索是否直接要正文（对应上游 `need_content`）。
    pub(crate) need_content: bool,
    /// 为 `None` 时付费上游全部不可用。
    pub(crate) proxy: Option<ProxyAccess>,
}

impl Default for WebTools {
    fn default() -> Self {
        Self {
            search: SearchProvider::Bing,
            fetch_fallback: false,
            need_content: false,
            proxy: None,
        }
    }
}

impl WebTools {
    pub(crate) fn from_env() -> Self {
        let proxy = proxy_from_env();

        let configured =
            env_string("PERSONAL_AGENT_WEB_SEARCH_PROVIDER").unwrap_or_else(|| "bing".to_string());
        let search = resolve_search(&configured, proxy.is_some());

        let fetch_fallback = env_flag("PERSONAL_AGENT_WEB_FETCH_FALLBACK");
        let fetch_fallback = if fetch_fallback && proxy.is_none() {
            tracing::warn!("抓取兜底已开启但没拿到代理地址，本次不启用");
            false
        } else {
            fetch_fallback
        };

        Self {
            search,
            fetch_fallback,
            need_content: env_flag("PERSONAL_AGENT_WEB_NEED_CONTENT"),
            proxy,
        }
    }
}

/// 按"配置的 provider + 有没有代理地址"决定实际走哪条路。
///
/// 纯函数，不读环境：测试只测这一层，避免并发测试互相踩全局 env。
fn resolve_search(configured: &str, has_proxy: bool) -> SearchProvider {
    match configured {
        "deepseek" => {
            if has_proxy {
                SearchProvider::DeepSeek
            } else {
                // 服务端已经降级过一次，走到这里说明中途出了岔子：宁可少花钱。
                tracing::warn!("搜索上游配成 deepseek 但没拿到代理地址，本次退回 Bing");
                SearchProvider::Bing
            }
        }
        "bing" => SearchProvider::Bing,
        other => {
            tracing::warn!(provider = other, "未知的搜索上游，本次退回 Bing");
            SearchProvider::Bing
        }
    }
}

/// 地址与令牌必须**同时**存在：只有一半时视为没配。
fn proxy_from_env() -> Option<ProxyAccess> {
    let url = env_string("PERSONAL_AGENT_TOOL_PROXY_URL")?;
    let token = env_string("PERSONAL_AGENT_TOOL_PROXY_TOKEN")?;
    Some(ProxyAccess { url, token })
}

fn env_string(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn env_flag(key: &str) -> bool {
    matches!(
        env_string(key).as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_bing_without_proxy() {
        let web = WebTools::default();
        assert_eq!(web.search, SearchProvider::Bing);
        assert!(!web.fetch_fallback);
        assert!(web.proxy.is_none());
    }

    #[test]
    fn flags_accept_common_truthy_spellings() {
        std::env::set_var("PERSONAL_AGENT_TEST_FLAG_ON", "true");
        std::env::set_var("PERSONAL_AGENT_TEST_FLAG_OFF", "0");
        assert!(env_flag("PERSONAL_AGENT_TEST_FLAG_ON"));
        assert!(!env_flag("PERSONAL_AGENT_TEST_FLAG_OFF"));
        std::env::remove_var("PERSONAL_AGENT_TEST_FLAG_ON");
        std::env::remove_var("PERSONAL_AGENT_TEST_FLAG_OFF");
    }

    #[test]
    fn deepseek_without_proxy_falls_back_to_bing() {
        assert_eq!(
            resolve_search("deepseek", false),
            SearchProvider::Bing,
            "没代理就用不了官方接口"
        );
        assert_eq!(
            resolve_search("deepseek", true),
            SearchProvider::DeepSeek,
            "有代理才走官方接口"
        );
    }

    #[test]
    fn unknown_provider_falls_back_to_bing() {
        assert_eq!(resolve_search("google", true), SearchProvider::Bing);
        assert_eq!(resolve_search("", true), SearchProvider::Bing);
    }
}
