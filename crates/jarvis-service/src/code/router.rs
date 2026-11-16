//! 任务路由：按任务形态选 CLI 与模型档位（方案第 10 章）。
//!
//! 纯函数，不碰 IO、不读配置以外的任何东西：`available` 由调用方先用
//! [`super::available_providers`] 算好传进来。这样规则本身可以单测穷举，
//! 也避免"路由过程中去探 PATH"这种藏着副作用的实现。
//!
//! 三条硬约束（与方案 10.1 / 10.2 一致）：
//! 1. **路由在 service 侧**：provider 与 model 要随 `Start` 下发，worker 只执行被指定的那个；
//! 2. **显式指定覆盖一切规则**：用户点名了 provider / 档位就照办，不"智能优化"；
//! 3. **降级只处理"不可用"**：跑失败换 provider 要等两周数据，本期不做。

use crate::config::CodeRoutingConfig;

/// 路由的输入。
#[derive(Debug, Clone)]
pub(crate) struct RouteRequest<'a> {
    /// 用户在任务里显式点名的 provider（`input.provider`）。
    pub(crate) requested_provider: Option<&'a str>,
    /// 用户显式点名的档位（`input.model_tier`）：`fast` / `strong`。
    pub(crate) requested_tier: Option<&'a str>,
    /// 需求字数。
    pub(crate) instruction_chars: usize,
    /// 仓库文件数。拿不到（不是 git 仓库 / 超时）时为 `None`，此时只按需求长度判。
    pub(crate) file_count: Option<usize>,
    /// 需求原文，用来识别"部署/推送/删库"这类不可逆动作关键词。
    pub(crate) instruction: &'a str,
}

/// 路由失败的两类原因。调用方要据此给出不同的错误码与提示：
/// 用户写错档位是 `invalid_request`，没有可用的 CLI 是 `code_unavailable`。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum RouteError {
    #[error("{0}")]
    InvalidTier(String),
    #[error("{0}")]
    Unavailable(String),
    #[error("{0}")]
    RequestedUnavailable(String),
}

impl RouteError {
    /// 给 API 用的错误码。
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::InvalidTier(_) => "invalid_request",
            Self::Unavailable(_) | Self::RequestedUnavailable(_) => "code_unavailable",
        }
    }
}

/// 路由的结论。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RouteDecision {
    pub(crate) provider: String,
    pub(crate) model: String,
    /// `fast` / `strong`
    pub(crate) tier: &'static str,
    /// 人话理由，写进 `change_summary` 顶部与 `code.route` 审计。
    pub(crate) reason: String,
}

/// 需求里出现这些词就按"含不可逆动作"处理：不交给自动选择，走强档 + 合并前确认。
const DANGEROUS_HINTS: &[&str] = &[
    "部署",
    "上线",
    "推送",
    "git push",
    "删库",
    "drop table",
    "reset --hard",
    "生产环境",
];

/// 需求长度超过它就按"大仓重构"处理（与 `large_repo_min` 的 200 文件同一条规则）。
const LONG_INSTRUCTION_CHARS: usize = 2_000;

/// 选 provider + 模型档位。
///
/// `available` 必须保持"优先级顺序"（首选在前），由调用方按
/// `routing.preferred` → `routing.fallback` → `code.provider` 排好。
pub(crate) fn route(
    request: &RouteRequest<'_>,
    routing: &CodeRoutingConfig,
    default_provider: &str,
    available: &[String],
    fast_model: &str,
    strong_model: &str,
) -> Result<RouteDecision, RouteError> {
    if let Some(tier) = request.requested_tier {
        if !matches!(tier, "fast" | "strong") {
            return Err(RouteError::InvalidTier(format!(
                "model_tier=\"{tier}\" 不是合法档位；只能是 fast / strong"
            )));
        }
    }

    let (provider, provider_reason) = pick_provider(request, routing, default_provider, available)?;
    let (tier, shape_reason) = pick_tier(request, routing);

    // 显式点名 provider 时把"为什么是它"写清楚，否则用户会以为路由失效了。
    let reason = if request.requested_provider.is_some() {
        format!("用户指定 provider（{shape_reason}）")
    } else if request.requested_tier.is_some() {
        format!("用户指定档位（{provider_reason}）")
    } else {
        format!("{shape_reason}（{provider_reason}）")
    };

    let model = match tier {
        "fast" => fast_model,
        _ => strong_model,
    };

    Ok(RouteDecision {
        provider,
        model: model.to_string(),
        tier,
        reason,
    })
}

fn pick_provider(
    request: &RouteRequest<'_>,
    routing: &CodeRoutingConfig,
    default_provider: &str,
    available: &[String],
) -> Result<(String, String), RouteError> {
    if let Some(wanted) = request.requested_provider {
        if available.iter().any(|id| id == wanted) {
            return Ok((wanted.to_string(), "用户指定".to_string()));
        }
        // 点名了却不可用：直接失败，不悄悄换成别的 CLI——用户会以为自己的选择生效了。
        return Err(RouteError::RequestedUnavailable(format!(
            "指定的编码 CLI \"{wanted}\" 不可用：请检查它是否已安装\
             （或用 code.providers.{wanted}.bin 指向可执行文件），\
             以及没有被 code.providers.{wanted}.enabled = false 关掉"
        )));
    }

    let mut ordered: Vec<&str> = Vec::new();
    for id in routing.preferred.iter().chain(routing.fallback.iter()) {
        if !ordered.contains(&id.as_str()) {
            ordered.push(id.as_str());
        }
    }
    if ordered.is_empty() {
        ordered.push(default_provider);
    }

    for (index, id) in ordered.iter().enumerate() {
        if !available.iter().any(|candidate| candidate == id) {
            continue;
        }
        let reason = if index == 0 {
            "首选可用".to_string()
        } else {
            format!("首选不可用，降级到 {id}")
        };
        return Ok(((*id).to_string(), reason));
    }

    Err(RouteError::Unavailable(format!(
        "没有可用的编码 CLI（候选：{}）：安装后重试，或在 code.providers 里指定 bin",
        ordered.join(" / ")
    )))
}

fn pick_tier(request: &RouteRequest<'_>, routing: &CodeRoutingConfig) -> (&'static str, String) {
    if let Some(tier) = request.requested_tier {
        let shape = if tier == "fast" { "快档" } else { "强档" };
        return (
            if tier == "fast" { "fast" } else { "strong" },
            shape.to_string(),
        );
    }

    let lower = request.instruction.to_lowercase();
    if DANGEROUS_HINTS
        .iter()
        .any(|hint| lower.contains(&hint.to_lowercase()))
    {
        return ("strong", "需求含不可逆动作关键词，按强档单派".to_string());
    }

    let long_instruction = request.instruction_chars > LONG_INSTRUCTION_CHARS;
    match request.file_count {
        Some(files) if files >= routing.large_repo_min || long_instruction => {
            ("strong", "大仓重构".to_string())
        }
        Some(files)
            if files <= routing.single_file_max
                && request.instruction_chars <= routing.short_instruction_max =>
        {
            ("fast", "单文件脚本".to_string())
        }
        Some(_) => ("strong", "多文件项目".to_string()),
        // 拿不到文件数（非 git 仓库）时只能按需求长度判：短需求给快档，
        // 长需求给强档。理由里写明"未能统计文件数"，避免用户以为是随机结果。
        None => {
            if request.instruction_chars <= routing.short_instruction_max && !long_instruction {
                ("fast", "短需求（未能统计文件数）".to_string())
            } else {
                ("strong", "长需求（未能统计文件数）".to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FAST: &str = "fast-model";
    const STRONG: &str = "strong-model";

    fn routing() -> CodeRoutingConfig {
        CodeRoutingConfig {
            preferred: vec!["codebuddy".to_string(), "opencode".to_string()],
            fallback: vec!["codex".to_string()],
            ..CodeRoutingConfig::default()
        }
    }

    fn available(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|id| (*id).to_string()).collect()
    }

    fn request<'a>(instruction: &'a str, files: Option<usize>) -> RouteRequest<'a> {
        RouteRequest {
            requested_provider: None,
            requested_tier: None,
            instruction_chars: instruction.chars().count(),
            file_count: files,
            instruction,
        }
    }

    #[test]
    fn single_file_script_takes_the_fast_tier_with_the_first_provider() {
        let decision = route(
            &request("改一个按钮的文案", Some(2)),
            &routing(),
            "opencode",
            &available(&["codebuddy", "opencode"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.provider, "codebuddy");
        assert_eq!(decision.model, FAST);
        assert_eq!(decision.tier, "fast");
        assert!(decision.reason.contains("单文件脚本"), "{decision:?}");
    }

    #[test]
    fn multi_file_project_takes_the_strong_tier() {
        let decision = route(
            &request("把接口拆成两层", Some(42)),
            &routing(),
            "opencode",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.tier, "strong");
        assert_eq!(decision.model, STRONG);
        assert!(decision.reason.contains("多文件项目"));
    }

    #[test]
    fn large_repo_or_long_instruction_goes_strong() {
        let big = route(
            &request("重构", Some(500)),
            &routing(),
            "opencode",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(big.tier, "strong");
        assert!(big.reason.contains("大仓重构"));

        let long = "改".repeat(LONG_INSTRUCTION_CHARS + 1);
        let long = route(
            &request(&long, Some(2)),
            &routing(),
            "opencode",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(long.tier, "strong", "超长需求即使文件很少也给强档");
    }

    #[test]
    fn explicit_provider_wins_over_the_rules() {
        let mut req = request("改一个按钮的文案", Some(2));
        req.requested_provider = Some("opencode");
        let decision = route(
            &req,
            &routing(),
            "codebuddy",
            &available(&["codebuddy", "opencode"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.provider, "opencode");
        assert_eq!(decision.tier, "fast", "档位仍按任务形态判");
        assert!(decision.reason.contains("用户指定"), "{decision:?}");
    }

    #[test]
    fn explicit_provider_outside_the_routing_lists_is_honoured() {
        // 可用清单由 `available_providers` 产出，末尾会追加"本机装了但没写进
        // preferred/fallback"的 CLI；用户显式点名它们时必须照办，而不是报不可用。
        let mut req = request("改个 bug", Some(2));
        req.requested_provider = Some("claude");
        let decision = route(
            &req,
            &routing(),
            "codebuddy",
            &available(&["codebuddy", "opencode", "codex", "claude"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.provider, "claude");
        assert!(decision.reason.contains("用户指定"), "{decision:?}");
    }

    #[test]
    fn explicit_provider_that_is_unavailable_is_an_error() {
        // 不能悄悄换成别的 CLI：用户会以为自己的选择生效了。
        let mut req = request("改个 bug", Some(2));
        req.requested_provider = Some("claude");
        let err = route(
            &req,
            &routing(),
            "codebuddy",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect_err("应报错");
        assert!(err.to_string().contains("claude"), "{err}");
        assert!(err.to_string().contains("不可用"), "{err}");
    }

    #[test]
    fn explicit_tier_wins_and_is_validated() {
        let mut req = request("改个 bug", Some(500));
        req.requested_tier = Some("fast");
        let decision = route(
            &req,
            &routing(),
            "codebuddy",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.tier, "fast");
        assert_eq!(decision.model, FAST);

        req.requested_tier = Some("turbo");
        let err = route(
            &req,
            &routing(),
            "codebuddy",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect_err("非法档位应报错");
        assert!(err.to_string().contains("model_tier"), "{err}");
    }

    #[test]
    fn falls_back_in_order_when_the_first_choice_is_missing() {
        let decision = route(
            &request("改个 bug", Some(9)),
            &routing(),
            "opencode",
            &available(&["codex", "opencode"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        // preferred 里 codebuddy 不可用、opencode 可用 → 用它（不是 fallback 的 codex）。
        assert_eq!(decision.provider, "opencode");
        assert!(decision.reason.contains("降级"), "{decision:?}");

        let decision = route(
            &request("改个 bug", Some(9)),
            &routing(),
            "codebuddy",
            &available(&["codex"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(
            decision.provider, "codex",
            "首选与次选都不可用时用 fallback"
        );
    }

    #[test]
    fn no_candidate_at_all_is_a_readable_error() {
        let err = route(
            &request("改个 bug", Some(1)),
            &routing(),
            "codebuddy",
            &[],
            FAST,
            STRONG,
        )
        .expect_err("应报错");
        assert!(err.to_string().contains("没有可用的编码 CLI"), "{err}");
        assert!(err.to_string().contains("codebuddy"), "{err}");
    }

    #[test]
    fn empty_routing_falls_back_to_the_configured_provider() {
        let routing = CodeRoutingConfig::default();
        let decision = route(
            &request("改个 bug", Some(1)),
            &routing,
            "opencode",
            &available(&["opencode"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.provider, "opencode");
    }

    #[test]
    fn unknown_file_count_only_uses_the_instruction_length() {
        let decision = route(
            &request("改个 bug", None),
            &routing(),
            "codebuddy",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.tier, "fast");
        assert!(decision.reason.contains("未能统计文件数"), "{decision:?}");

        let long = "改".repeat(LONG_INSTRUCTION_CHARS + 1);
        let decision = route(
            &request(&long, None),
            &routing(),
            "codebuddy",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.tier, "strong");
    }

    #[test]
    fn dangerous_wording_forces_the_strong_tier() {
        let decision = route(
            &request("改完后直接 git push 到生产环境", Some(1)),
            &routing(),
            "codebuddy",
            &available(&["codebuddy"]),
            FAST,
            STRONG,
        )
        .expect("应能路由");
        assert_eq!(decision.tier, "strong");
        assert!(decision.reason.contains("不可逆"), "{decision:?}");
    }
}
