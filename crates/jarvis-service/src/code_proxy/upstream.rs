//! 上游模型网关的调用封装。
//!
//! 只做三件事：拼 URL、换密钥、把请求原样转出去。**不重构请求体**：
//! opencode 发的是它自己那套 OpenAI 兼容载荷，我们看不懂的字段原样保留才是安全的。

use std::time::Duration;

use axum::body::Bytes;
use reqwest::Response;

use crate::config::Config;

#[derive(Debug, thiserror::Error)]
pub(crate) enum UpstreamError {
    #[error("未配置模型密钥：请设置环境变量 {0}")]
    MissingKey(String),
    #[error("构造上游客户端失败：{0}")]
    Client(String),
}

#[derive(Debug)]
pub(crate) struct Upstream {
    client: reqwest::Client,
    /// 已拼好的完整地址（含 `/chat/completions`）。
    url: String,
    api_key: String,
    /// 允许的模型；空配置时只放行 `upstream.model` 一个。
    models: Vec<String>,
}

impl Upstream {
    pub(crate) fn from_config(config: &Config) -> Result<Self, UpstreamError> {
        let key = config.code_upstream_api_key().ok_or_else(|| {
            UpstreamError::MissingKey(config.code_upstream_api_key_env().to_string())
        })?;

        let timeout = Duration::from_millis(config.code.upstream.timeout_ms.max(1_000));
        let client = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .map_err(|err| UpstreamError::Client(err.to_string()))?;

        // base_url 是兼容根（默认已含 `/compatible-mode/v1`），这里只补最后一段。
        let url = format!("{}/chat/completions", config.code_upstream_base_url());

        let mut models = config.code.upstream.allowed_models.clone();
        if models.is_empty() {
            models.push(config.code_upstream_model().to_string());
        }

        Ok(Self {
            client,
            url,
            api_key: key,
            models,
        })
    }

    /// 模型是否在白名单内。空体（比如健康探测）不放行。
    pub(crate) fn allows(&self, model: &str) -> bool {
        !model.is_empty() && self.models.iter().any(|allowed| allowed == model)
    }

    pub(crate) fn models(&self) -> &[String] {
        &self.models
    }

    /// 转发一次请求。客户端带来的 `Authorization` 会被丢弃并换成真 key。
    pub(crate) async fn post(&self, body: Bytes) -> Result<Response, String> {
        self.client
            .post(&self.url)
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
    fn allowlist_defaults_to_the_configured_model() {
        let config = Config::default();
        // 没有密钥时构造失败，这里只验证 URL 与白名单逻辑，所以临时给一个。
        std::env::set_var("PERSONAL_AGENT_TEST_UPSTREAM_KEY", "test-key");

        let mut config = config;
        config.code.upstream.api_key_env = Some("PERSONAL_AGENT_TEST_UPSTREAM_KEY".to_string());
        config.code.upstream.model = Some("only-model".to_string());
        config.code.upstream.base_url = Some("http://127.0.0.1:1/v1/".to_string());

        let upstream = Upstream::from_config(&config).expect("构造应成功");
        assert!(upstream.allows("only-model"));
        assert!(!upstream.allows("other-model"));
        assert!(!upstream.allows(""), "空模型名不能放行");
        assert_eq!(upstream.models(), ["only-model".to_string()]);
        assert!(
            upstream.url.ends_with("/v1/chat/completions"),
            "{}",
            upstream.url
        );
    }

    #[test]
    fn default_upstream_path_uses_compatible_mode_prefix() {
        // 回归用例：默认曾直接返回 llm.base_url，路径少了 `/compatible-mode/v1`，
        // 网关回 404 而错误信息只有一句 "Provider request failed with HTTP 404"。
        std::env::set_var("PERSONAL_AGENT_TEST_UPSTREAM_KEY_DEFAULT", "test-key");

        let mut config = Config::default();
        config.code.upstream.api_key_env =
            Some("PERSONAL_AGENT_TEST_UPSTREAM_KEY_DEFAULT".to_string());
        config.code.upstream.base_url = None;

        let upstream = Upstream::from_config(&config).expect("构造应成功");
        assert_eq!(
            upstream.url,
            format!(
                "{}/compatible-mode/v1/chat/completions",
                config.llm.base_url.trim_end_matches('/')
            )
        );
    }

    #[test]
    fn missing_key_is_reported_with_the_variable_name() {
        let mut config = Config::default();
        config.code.upstream.api_key_env = Some("PERSONAL_AGENT_UNSET_KEY_FOR_TEST".to_string());
        std::env::remove_var("PERSONAL_AGENT_UNSET_KEY_FOR_TEST");

        let err = Upstream::from_config(&config).expect_err("缺密钥应报错");
        assert!(
            err.to_string()
                .contains("PERSONAL_AGENT_UNSET_KEY_FOR_TEST"),
            "{err}"
        );
    }
}
