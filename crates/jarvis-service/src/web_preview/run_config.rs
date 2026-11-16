//! 项目级运行配置：`<项目根>/.jarvis/run.json`。
//!
//! 为什么放在项目目录而不是数据库：端口是项目自身的属性，随项目走、
//! 能进版本库、编码任务也能生成。放库里则换一台机器要重配一遍，
//! 而且"这个前端跑在 3001"这种事实离开项目上下文就没有意义。
//!
//! 内容是用户写的，但仍然要校验：一份写错的配置会把浏览器导到
//! 服务端自己的管理面上，那不是"用户自己的选择"，是配置事故。

use std::path::Path;

use serde::Deserialize;

/// 配置相对项目根的路径。错误文案与文档都引用它，只留一份。
pub(crate) const CONFIG_RELATIVE: &str = ".jarvis/run.json";

/// 默认 API 前缀。与前端最常见的 `/api` 约定一致。
const DEFAULT_API_PREFIX: &str = "/api";

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct RunConfig {
    /// 前端端口：页面本身与静态资源都从这里取。
    pub(crate) frontend: u16,
    /// 后端端口：只有命中 `api_prefix` 的请求才转到这里。
    ///
    /// 可选：纯静态站点没有后端，`api_prefix` 也就无处可去。
    #[serde(default)]
    pub(crate) backend: Option<u16>,
    /// 分流前缀，默认 `/api`。
    #[serde(default = "default_api_prefix")]
    pub(crate) api_prefix: String,
}

fn default_api_prefix() -> String {
    DEFAULT_API_PREFIX.to_string()
}

/// 读取并校验配置。
///
/// 失败返回**给人看的中文原因**：它会原样成为 502 的页面正文，
/// 用户按这句话就知道该建哪个文件、哪一栏写错了。
pub(crate) async fn load(root: &Path) -> Result<RunConfig, String> {
    let path = root.join(".jarvis").join("run.json");
    let raw = tokio::fs::read_to_string(&path)
        .await
        .map_err(|err| match err.kind() {
            std::io::ErrorKind::NotFound => {
                format!("项目里没有 {CONFIG_RELATIVE}，无法确定要打开哪个端口")
            }
            _ => format!("读取 {CONFIG_RELATIVE} 失败：{err}"),
        })?;

    let mut config: RunConfig = serde_json::from_str(&raw)
        .map_err(|err| format!("{CONFIG_RELATIVE} 不是合法 JSON（{err}）"))?;

    // 尾斜杠统一去掉：`/api` 与 `/api/` 是同一个前缀，存两种写法只会在匹配处出错。
    config.api_prefix = config.api_prefix.trim().trim_end_matches('/').to_string();

    validate(&config)?;
    Ok(config)
}

fn validate(config: &RunConfig) -> Result<(), String> {
    if config.frontend == 0 {
        return Err("frontend 端口不能为 0".to_string());
    }
    if let Some(backend) = config.backend {
        if backend == 0 {
            return Err("backend 端口不能为 0".to_string());
        }
        if backend == config.frontend {
            return Err("frontend 与 backend 不能是同一个端口：那样分流没有意义".to_string());
        }
    }

    let prefix = config.api_prefix.as_str();
    if !prefix.starts_with('/') {
        return Err(format!("api_prefix 必须以 / 开头，当前是 {prefix:?}"));
    }
    if prefix.is_empty() {
        return Err("api_prefix 不能是根路径 /：那样整个站点都会被当成 API".to_string());
    }
    if prefix.chars().any(|ch| matches!(ch, '?' | '#' | ' ')) {
        return Err(format!("api_prefix 不能包含 ? # 或空格，当前是 {prefix:?}"));
    }
    Ok(())
}

/// 路径是否命中 API 前缀。
///
/// 必须是"等于前缀"或"前缀 + `/`"：`/api` 不能把 `/apidocs` 也一起吃掉。
pub(crate) fn matches_prefix(path: &str, prefix: &str) -> bool {
    path == prefix || path.starts_with(&format!("{prefix}/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(raw: &str) -> Result<RunConfig, String> {
        let mut config: RunConfig =
            serde_json::from_str(raw).map_err(|err| format!("JSON 不合法：{err}"))?;
        config.api_prefix = config.api_prefix.trim().trim_end_matches('/').to_string();
        validate(&config)?;
        Ok(config)
    }

    #[test]
    fn parses_minimal_config_and_defaults_prefix() {
        let parsed = config(r#"{"frontend":3001}"#).expect("应通过");
        assert_eq!(parsed.frontend, 3001);
        assert_eq!(parsed.backend, None);
        assert_eq!(parsed.api_prefix, "/api");
    }

    #[test]
    fn trims_trailing_slash_from_prefix() {
        let parsed =
            config(r#"{"frontend":3000,"backend":8080,"api_prefix":"/v1/"}"#).expect("应通过");
        assert_eq!(parsed.api_prefix, "/v1");
    }

    #[test]
    fn rejects_bad_ports_and_prefixes() {
        assert!(config(r#"{"frontend":0}"#).is_err());
        assert!(config(r#"{"frontend":3000,"backend":0}"#).is_err());
        assert!(
            config(r#"{"frontend":3000,"backend":3000}"#).is_err(),
            "同一端口的分配流没有意义"
        );
        assert!(config(r#"{"frontend":3000,"api_prefix":"api"}"#).is_err());
        assert!(config(r#"{"frontend":3000,"api_prefix":"/"}"#).is_err());
        assert!(config(r#"{"frontend":3000,"api_prefix":"/api?x=1"}"#).is_err());
    }

    #[test]
    fn prefix_matching_respects_segment_boundary() {
        assert!(matches_prefix("/api", "/api"));
        assert!(matches_prefix("/api/users", "/api"));
        assert!(!matches_prefix("/apidocs", "/api"));
        assert!(!matches_prefix("/", "/api"));
    }

    #[tokio::test]
    async fn missing_config_explains_which_file_to_create() {
        let dir = std::env::temp_dir().join(format!("pa-run-cfg-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("建目录失败");

        let reason = load(&dir).await.expect_err("缺文件必须报错");
        assert!(reason.contains(CONFIG_RELATIVE), "{reason}");
        assert!(reason.contains("没有"), "{reason}");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
