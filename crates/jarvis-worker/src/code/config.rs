//! 编码任务在 worker 侧的配置。
//!
//! 全部来自 `jarvis-service` 下发的环境变量（沿用 `PERSONAL_AGENT_TOOL_*` 的既有做法）：
//! worker 不读配置文件、不读数据库，这样"策略只有一个来源"。
//!
//! **这里没有模型密钥**：真 key 只在 service，worker 拿到的是随 `Start` 下发的一次性
//! 代理令牌。

use std::path::PathBuf;
use std::time::Duration;

use super::hooks::ApprovalPolicy;

/// 与 service 的 `CodeConfig` 对应（密钥除外）。
#[derive(Debug, Clone)]
pub(crate) struct CodeConfig {
    pub(crate) enabled: bool,
    pub(crate) provider: String,
    pub(crate) model: String,
    /// CLI 可执行文件覆盖；为空表示走 PATH。
    pub(crate) bin: Option<PathBuf>,
    /// worktree 根目录。缺失说明 service 与 worker 版本不匹配，执行时判不可用。
    pub(crate) worktree_root: Option<PathBuf>,
    /// 代理基地址（如 `http://127.0.0.1:51234`）。缺失同上。
    pub(crate) proxy_url: Option<String>,
    pub(crate) timeout: Duration,
    pub(crate) max_concurrent: usize,
    /// 工具级审批开关：关掉等于"只在合并前审批"。钩子仍然注入
    /// （无头模式下它是工具能执行的唯一通道），只是对所有调用一律放行。
    pub(crate) tool_approval: bool,
    /// 工具级等待上限。service 的审批 TTL 必须比它长，否则 CLI 已卡死才判过期。
    pub(crate) tool_approval_ttl: Duration,
    /// 必须人工的风险档（service 下发，默认只有 `irreversible_write`）。
    pub(crate) always_ask: Vec<String>,
    /// 默认审批策略。任务 `input.approval` 优先，缺省时用它。
    pub(crate) approval: ApprovalPolicy,
    /// 配置里追加的风险规则（JSON 数组）。只能加严，规则名进审计。
    pub(crate) extra_rules: Vec<protocol::RiskRule>,
}

impl CodeConfig {
    pub(crate) fn from_env() -> Self {
        Self {
            enabled: env_flag("PERSONAL_AGENT_CODE_ENABLED"),
            provider: env_string("PERSONAL_AGENT_CODE_PROVIDER")
                .unwrap_or_else(|| "opencode".to_string()),
            model: env_string("PERSONAL_AGENT_CODE_MODEL").unwrap_or_default(),
            bin: env_string("PERSONAL_AGENT_CODE_BIN").map(PathBuf::from),
            worktree_root: env_string("PERSONAL_AGENT_CODE_WORKTREE_DIR").map(PathBuf::from),
            proxy_url: env_string("PERSONAL_AGENT_CODE_PROXY_URL"),
            timeout: Duration::from_millis(
                env_u64("PERSONAL_AGENT_CODE_TIMEOUT_MS").unwrap_or(13 * 60 * 1000),
            ),
            max_concurrent: env_u64("PERSONAL_AGENT_CODE_MAX_CONCURRENT")
                .unwrap_or(1)
                .max(1) as usize,
            // 默认开启：这是本能力的安全属性，漏发变量时按"要人看"处理更稳。
            tool_approval: env_flag_or("PERSONAL_AGENT_CODE_TOOL_APPROVAL", true),
            tool_approval_ttl: Duration::from_millis(
                env_u64("PERSONAL_AGENT_CODE_TOOL_APPROVAL_TTL_MS").unwrap_or(120_000),
            ),
            // 必须是人工的风险档。未下发时按最保守的一档处理：
            // 宁可多问一次，也不要默认放行一次不可逆操作。
            always_ask: env_string("PERSONAL_AGENT_CODE_ALWAYS_ASK")
                .map(|raw| {
                    raw.split(',')
                        .map(str::trim)
                        .filter(|level| !level.is_empty())
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .filter(|levels| !levels.is_empty())
                .unwrap_or_else(|| vec!["irreversible_write".to_string()]),
            // 默认最保守的一档：客户端没选、老客户端没这个字段时都按"要人看"处理。
            approval: env_string("PERSONAL_AGENT_CODE_APPROVAL")
                .map(|raw| ApprovalPolicy::parse(&raw))
                .unwrap_or(ApprovalPolicy::Request),
            extra_rules: parse_extra_rules(env_string("PERSONAL_AGENT_CODE_EXTRA_RULES")),
        }
    }
}

/// 解析 service 下发的追加规则。
///
/// 解析失败时**只记错误、不带规则**：内置规则仍然生效，任务不会因为一条配置
/// 写错就拒绝执行；但这条 error 日志要能让人立刻发现"规则没起作用"。
fn parse_extra_rules(raw: Option<String>) -> Vec<protocol::RiskRule> {
    let Some(raw) = raw else {
        return Vec::new();
    };
    match serde_json::from_str::<Vec<protocol::RiskRule>>(&raw) {
        Ok(rules) => rules,
        Err(err) => {
            tracing::error!(%err, "PERSONAL_AGENT_CODE_EXTRA_RULES 不是合法的规则数组，已忽略");
            Vec::new()
        }
    }
}

/// 空串按"未设置"处理：服务端把 `Option` 序列化成环境变量时可能出现空值。
fn env_string(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn env_u64(key: &str) -> Option<u64> {
    env_string(key).and_then(|value| value.parse().ok())
}

/// `1` / `true` / `yes` 都算开启；其余（含未设置）为关闭。
fn env_flag(key: &str) -> bool {
    env_string(key).map(|value| truthy(&value)).unwrap_or(false)
}

fn truthy(value: &str) -> bool {
    matches!(value, "1" | "true" | "TRUE" | "yes")
}

/// 未设置时取 `default`；显式配置时按 truthy 判定。
fn env_flag_or(key: &str, default: bool) -> bool {
    env_string(key)
        .map(|value| truthy(&value))
        .unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_explicit_truthy_values_enable_the_capability() {
        // 默认关闭是关键安全属性：服务端漏发变量时不能悄悄跑起编码任务。
        assert!(truthy("1"));
        assert!(truthy("true"));
        assert!(truthy("yes"));
        for value in ["0", "false", "on", "", "  "] {
            assert!(!truthy(value), "{value:?} 不应视为开启");
        }
    }

    #[test]
    fn empty_env_value_counts_as_unset() {
        // 空串在环境变量里很常见（`Option::None` 被序列化成空值时），
        // 必须按"没配"处理，否则会得到一个空路径而不是 None。
        assert!(env_string("PERSONAL_AGENT_CODE_DEFINITELY_UNSET_KEY").is_none());
    }
}
