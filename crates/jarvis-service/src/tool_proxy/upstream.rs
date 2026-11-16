//! 联网工具上游的调用封装。
//!
//! 与 `code_proxy::upstream` 同一个原则：**只拼 URL、换密钥、把请求原样转出去**。
//! 不改写请求体——上游字段（`need_content`、`localization` 之类）会演进，
//! 我们看不懂的字段原样保留才不会被自己拦住。

use std::time::Duration;

use axum::body::Bytes;
use reqwest::Response;

use crate::config::Config;

#[derive(Debug, thiserror::Error)]
pub(crate) enum UpstreamError {
    #[error("未配置联网工具密钥：请设置环境变量 {0}")]
    MissingKey(String),
    #[error("构造上游客户端失败：{0}")]
    Client(String),
}

pub(crate) struct Upstream {
    client: reqwest::Client,
    /// 已去掉尾部 `/` 的上游根地址（默认 `https://api.deepseek.com`）。
    base_url: String,
    api_key: String,
}

impl std::fmt::Debug for Upstream {
    /// 密钥不进日志：`Debug` 只暴露地址。
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Upstream")
            .field("base_url", &self.base_url)
            .finish_non_exhaustive()
    }
}

impl Upstream {
    pub(crate) fn from_config(config: &Config) -> Result<Self, UpstreamError> {
        let key = config
            .web_tools_api_key()
            .ok_or_else(|| UpstreamError::MissingKey(config.web_tools_api_key_env().to_string()))?;

        let timeout = Duration::from_millis(config.tool.web.timeout_ms.max(500));
        let client = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .map_err(|err| UpstreamError::Client(err.to_string()))?;

        Ok(Self {
            client,
            base_url: config.web_tools_base_url(),
            api_key: key,
        })
    }

    /// 转发一次请求。worker 带来的 `Authorization` 在路由层已被校验并丢弃，
    /// 这里换上真密钥。
    pub(crate) async fn post(&self, path: &str, body: Bytes) -> Result<Response, String> {
        self.client
            .post(format!("{}{}", self.base_url, path))
            .header("authorization", format!("Bearer {}", self.api_key))
            .header("content-type", "application/json")
            .body(body)
            .send()
            .await
            .map_err(|err| format!("上游请求失败：{err}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_key_names_the_environment_variable() {
        std::env::remove_var("PERSONAL_AGENT_TEST_WEB_UPSTREAM_KEY");
        let mut config = Config::default();
        config.tool.web.api_key_env = "PERSONAL_AGENT_TEST_WEB_UPSTREAM_KEY".to_string();

        let err = Upstream::from_config(&config).expect_err("缺密钥应报错");
        assert!(
            err.to_string()
                .contains("PERSONAL_AGENT_TEST_WEB_UPSTREAM_KEY"),
            "{err}"
        );
    }

    #[test]
    fn base_url_is_normalized_without_trailing_slash() {
        std::env::set_var("PERSONAL_AGENT_TEST_WEB_UPSTREAM_KEY_OK", "test-key");
        let mut config = Config::default();
        config.tool.web.api_key_env = "PERSONAL_AGENT_TEST_WEB_UPSTREAM_KEY_OK".to_string();
        config.tool.web.base_url = "https://api.deepseek.com/".to_string();

        let upstream = Upstream::from_config(&config).expect("构造应成功");
        assert_eq!(upstream.base_url, "https://api.deepseek.com");
        assert!(
            !format!("{upstream:?}").contains("test-key"),
            "Debug 不能带出密钥"
        );
    }
}
