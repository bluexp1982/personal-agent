//! 模型配置的校验、密钥归并与对外视图。
//!
//! 这一层不碰网络也不碰运行期状态：输入是配置 + 密钥文件，输出是"能不能用、
//! 为什么不能用"以及可以安全发给客户端的结构。切换与请求路径都靠它给结论。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::config::{LlmConfig, ModelProfile, DEFAULT_PROFILE_ID};
use crate::ids;
use crate::model_secrets::{KeySource, KeyState, ModelSecrets};

/// 新建配置的 id 前缀。与 `ids::new_id` 的约定一致：`model_<26 字符>`。
pub const MODEL_ID_PREFIX: &str = "model";

/// 一份配置对客户端的完整视图。
///
/// **不含密钥**：只有"有没有"、来源与末四位。这个结构会直接序列化进 HTTP 响应，
/// 任何字段都必须是可公开的。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileView {
    pub id: String,
    pub name: String,
    /// 默认档（来自配置文件主节）为 `true`：可编辑、可设为当前，但删不掉。
    pub builtin: bool,
    /// 是否为当前生效的配置。
    pub active: bool,
    pub enabled: bool,
    pub base_url: String,
    pub api_path: String,
    /// 发给上游的模型 ID。
    pub model: String,
    /// 人可读的模型名，可空；空时客户端回退显示 `model`。
    pub model_name: String,
    pub vision: bool,
    /// 上游认不认 `reasoning_effort`：为假时客户端不显示「推理等级」，
    /// 服务端也不会把这个字段发给上游。
    pub reasoning: bool,
    /// 模型最大上下文窗口（tokens）：客户端用它做输入栏占比的分母。
    pub context_window: u32,
    /// 现在能不能发请求。
    pub available: bool,
    /// 不能用的原因，直接给用户看（"缺少密钥"这种）。
    pub reason: Option<String>,
    /// `secrets` / `env` / `none`。
    pub api_key_source: String,
    /// 末四位提示，形如 `…9f2a`。
    pub api_key_hint: Option<String>,
}

/// 密钥解析结果：完整值只在服务端进程内流转，`state` 才是可以外发的那部分。
#[derive(Debug)]
pub struct ResolvedKey {
    pub key: Option<String>,
    pub state: KeyState,
}

/// 解析一份配置的密钥：客户端写的密钥文件优先，其次 `api_key_env` 指向的环境变量。
///
/// 顺序不能反：用户在客户端里改 Key 就是为了立刻生效，此时若服务器上还留着
/// 一个同名的旧环境变量，按"环境变量优先"会让人以为保存没成功。
pub fn resolve_key(profile: &ModelProfile, secrets: &ModelSecrets) -> ResolvedKey {
    if let Some(key) = secrets.get(&profile.id) {
        let state = KeyState {
            present: true,
            source: Some(KeySource::Secrets),
            hint: Some(ModelSecrets::hint_of(&key)),
        };
        return ResolvedKey {
            key: Some(key),
            state,
        };
    }

    let env_name = profile.api_key_env.trim();
    if !env_name.is_empty() {
        if let Ok(value) = std::env::var(env_name) {
            let value = value.trim().to_string();
            if !value.is_empty() {
                let state = KeyState {
                    present: true,
                    source: Some(KeySource::Env),
                    hint: Some(ModelSecrets::hint_of(&value)),
                };
                return ResolvedKey {
                    key: Some(value),
                    state,
                };
            }
        }
    }

    ResolvedKey {
        key: None,
        state: KeyState::default(),
    }
}

/// 所有配置的密钥状态。切换/增删改时算一次，列表接口直接读缓存。
pub fn key_states(llm: &LlmConfig, secrets: &ModelSecrets) -> BTreeMap<String, KeyState> {
    llm.all_profiles()
        .into_iter()
        .map(|profile| {
            let state = resolve_key(&profile, secrets).state;
            (profile.id, state)
        })
        .collect()
}

/// 组装视图列表。默认档永远在第一行，与 `LlmConfig::all_profiles` 同序。
pub fn views(
    llm: &LlmConfig,
    keys: &BTreeMap<String, KeyState>,
    active_id: &str,
) -> Vec<ProfileView> {
    llm.all_profiles()
        .iter()
        .map(|profile| view_of(profile, keys, active_id))
        .collect()
}

/// 单条视图。
pub fn view_of(
    profile: &ModelProfile,
    keys: &BTreeMap<String, KeyState>,
    active_id: &str,
) -> ProfileView {
    let state = keys.get(&profile.id).cloned().unwrap_or_default();
    let reason = unavailable_reason(profile, &state);

    ProfileView {
        id: profile.id.clone(),
        name: display_name(profile),
        builtin: profile.id == DEFAULT_PROFILE_ID,
        active: profile.id == active_id,
        enabled: profile.enabled,
        base_url: profile.base_url.trim().to_string(),
        api_path: profile.normalized_api_path(),
        model: profile.model.trim().to_string(),
        model_name: profile.model_name.trim().to_string(),
        vision: profile.vision,
        reasoning: profile.reasoning,
        context_window: profile.context_window,
        available: reason.is_none(),
        reason,
        api_key_source: state.source().as_str().to_string(),
        api_key_hint: state.hint.clone(),
    }
}

/// 名字为空时用 id 顶上：列表里出现一行没有标题的配置，用户没法选中它。
pub fn display_name(profile: &ModelProfile) -> String {
    let name = profile.name.trim();
    if name.is_empty() {
        if profile.id == DEFAULT_PROFILE_ID {
            return "默认".to_string();
        }
        return profile.id.clone();
    }
    name.to_string()
}

/// 不可用的原因；`None` 表示可用。顺序即排查顺序。
pub fn unavailable_reason(profile: &ModelProfile, key: &KeyState) -> Option<String> {
    if !profile.enabled {
        return Some("已停用".to_string());
    }
    if profile.base_url.trim().is_empty() {
        return Some("未填网关地址".to_string());
    }
    if profile.model.trim().is_empty() {
        return Some("未填模型ID".to_string());
    }
    if !key.present {
        return Some("缺少密钥".to_string());
    }
    None
}

/// 校验通过的字段（均已规整）。
///
/// 用具名字段而不是元组：「配置名」与「模型名」只差一个字，返回元组时调用方
/// 很容易把两个 `String` 传反。
#[derive(Debug, Clone)]
pub struct ValidatedFields {
    /// 配置名（列表标题），必填，≤ 40 字符。
    pub name: String,
    /// 人可读的模型名，可空，≤ 60 字符。
    pub model_name: String,
    /// 网关地址，去尾部 `/`。
    pub base_url: String,
    /// 模型ID（发给上游的 `model`），必填。
    pub model: String,
    /// 路径前缀，已补前导 `/`。
    pub api_path: String,
}

/// 校验用户填的核心字段，返回规整后的值。
///
/// 报错信息直接给用户看，所以每条都说清"哪里不对 + 该怎么填"。
pub fn validate_fields(
    name: &str,
    model_name: &str,
    base_url: &str,
    model: &str,
    api_path: &str,
) -> Result<ValidatedFields, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("配置名称不能为空：列表里要用它区分不同配置".to_string());
    }
    if name.chars().count() > 40 {
        return Err("配置名称最多 40 个字符".to_string());
    }

    let base_url = base_url.trim().trim_end_matches('/');
    if base_url.is_empty() {
        return Err("网关地址不能为空，例如 https://api.deepseek.com".to_string());
    }
    if !(base_url.starts_with("http://") || base_url.starts_with("https://")) {
        return Err(format!(
            "网关地址必须以 http:// 或 https:// 开头，当前是 \"{base_url}\""
        ));
    }
    if base_url.ends_with("/chat/completions") {
        return Err(
            "网关地址只填到域名（含可选的版本前缀），不要带 /chat/completions：\
             路径前缀由下一栏决定"
                .to_string(),
        );
    }

    let model = model.trim();
    if model.is_empty() {
        return Err("模型ID不能为空，例如 deepseek-chat".to_string());
    }

    // 模型名只是给人看的：允许留空（界面回退模型ID），只挡超长。
    let model_name = model_name.trim();
    if model_name.chars().count() > 60 {
        return Err("模型名最多 60 个字符".to_string());
    }

    let api_path = api_path.trim().trim_end_matches('/');
    if api_path.contains("://") {
        return Err(
            "路径前缀只填 /v1 这样的部分，不要填完整地址：完整地址请填在网关地址栏".to_string(),
        );
    }
    if api_path.chars().any(|ch| ch.is_whitespace()) {
        return Err("路径前缀不能包含空格".to_string());
    }
    let api_path = if api_path.is_empty() {
        String::new()
    } else if api_path.starts_with('/') {
        api_path.to_string()
    } else {
        format!("/{api_path}")
    };

    Ok(ValidatedFields {
        name: name.to_string(),
        model_name: model_name.to_string(),
        base_url: base_url.to_string(),
        model: model.to_string(),
        api_path,
    })
}

/// 上下文窗口的合法区间（tokens）。
///
/// 下限 1K 挡住手滑少写几个 0（那样占比会直接爆表）；上限 1 亿足够覆盖
/// 当前所有商用模型，也避免把 `u32` 之外的值当成正常配置。
pub const MIN_CONTEXT_WINDOW: u32 = 1_000;
pub const MAX_CONTEXT_WINDOW: u32 = 100_000_000;

/// 校验模型上下文窗口。
///
/// 单独一个函数而不是塞进 [`validate_fields`]：更新接口里这个字段是可选的，
/// `None` 表示"不改动"，而 `validate_fields` 的入参都是必填项，混在一起
/// 会逼调用方为"不修改"编一个假值。
pub fn validate_context_window(value: u32) -> Result<u32, String> {
    if !(MIN_CONTEXT_WINDOW..=MAX_CONTEXT_WINDOW).contains(&value) {
        return Err(format!(
            "上下文窗口需在 {MIN_CONTEXT_WINDOW} ~ {MAX_CONTEXT_WINDOW} tokens 之间，\
             当前是 {value}"
        ));
    }
    Ok(value)
}

/// 新建配置的 id。前缀 + 26 字符随机，天然满足 `llm.profiles[].id` 的字符约束。
pub fn new_profile_id() -> String {
    ids::new_id(MODEL_ID_PREFIX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::LlmConfig;

    fn profile(id: &str, model: &str) -> ModelProfile {
        ModelProfile {
            id: id.to_string(),
            name: format!("配置 {id}"),
            model: model.to_string(),
            base_url: "https://api.example.com".to_string(),
            api_path: "/v1".to_string(),
            ..ModelProfile::default()
        }
    }

    fn key(present: bool) -> KeyState {
        KeyState {
            present,
            source: present.then_some(KeySource::Secrets),
            hint: present.then(|| "…9f2a".to_string()),
        }
    }

    #[test]
    fn unavailable_reason_follows_check_order() {
        let mut item = profile("a", "");
        assert_eq!(
            unavailable_reason(&item, &key(true)).as_deref(),
            Some("未填模型ID")
        );
        item.model = "m".to_string();
        assert_eq!(
            unavailable_reason(&item, &key(false)).as_deref(),
            Some("缺少密钥")
        );
        assert_eq!(unavailable_reason(&item, &key(true)), None);

        item.enabled = false;
        assert_eq!(
            unavailable_reason(&item, &key(true)).as_deref(),
            Some("已停用"),
            "停用是第一位原因：它盖过其它一切"
        );
    }

    #[test]
    fn views_mark_the_active_one() {
        let mut llm = LlmConfig::default();
        llm.profiles.push(profile("a", "m"));
        let keys = key_states(
            &llm,
            &ModelSecrets::new(std::path::Path::new("/nonexistent")),
        );
        let views = views(&llm, &keys, "a");

        assert_eq!(views.len(), 2, "默认档 + 一条自定义");
        assert!(views[0].builtin);
        assert!(!views[0].active);
        assert!(views[1].active);
    }

    #[test]
    fn default_profile_name_falls_back_to_label() {
        let mut item = profile(DEFAULT_PROFILE_ID, "m");
        item.name = String::new();
        assert_eq!(display_name(&item), "默认");
    }

    #[test]
    fn validate_rejects_full_endpoint_as_base_url() {
        let err = validate_fields("x", "", "https://a.com/v1/chat/completions", "m", "/v1")
            .expect_err("带完整路径的地址应被拒绝");
        assert!(err.contains("/chat/completions"), "{err}");
    }

    #[test]
    fn validate_rejects_url_in_api_path() {
        let err = validate_fields("x", "", "https://a.com", "m", "https://a.com/v1")
            .expect_err("路径前缀里不该出现完整地址");
        assert!(err.contains("完整地址"), "{err}");
    }

    #[test]
    fn validate_normalizes_api_path() {
        let path = validate_fields("x", "", "https://a.com/", "m", "v1/").expect("应通过");
        assert_eq!(path.api_path, "/v1");
        let empty = validate_fields("x", "", "https://a.com/", "m", "").expect("应通过");
        assert_eq!(
            empty.base_url, "https://a.com",
            "尾部斜杠要去掉，否则拼出来的地址多一层"
        );
        assert_eq!(empty.api_path, "", "空前缀交给 normalized_api_path 兜底");
    }

    #[test]
    fn validate_keeps_model_name_optional() {
        let blank =
            validate_fields("x", "  ", "https://a.com", "deepseek-chat", "").expect("模型名可留空");
        assert_eq!(blank.model, "deepseek-chat");
        assert_eq!(blank.model_name, "", "留空就是空串，界面回退模型ID");

        let named = validate_fields(
            "x",
            " DeepSeek V3.2 Flash ",
            "https://a.com",
            "deepseek-chat",
            "",
        )
        .expect("应通过");
        assert_eq!(named.model_name, "DeepSeek V3.2 Flash", "两侧空白要去掉");

        let long = "模".repeat(61);
        let err =
            validate_fields("x", &long, "https://a.com", "m", "").expect_err("超长模型名应被拒绝");
        assert!(err.contains("60"), "{err}");
    }

    #[test]
    fn validate_rejects_empty_model_id() {
        let err =
            validate_fields("x", "模型名", "https://a.com", "", "").expect_err("模型ID是必填的");
        assert!(err.contains("模型ID"), "{err}");
    }

    #[test]
    fn env_key_is_used_when_no_secret_written() {
        let mut item = profile("envonly", "m");
        item.api_key_env = "JARVIS_TEST_MODEL_KEY".to_string();
        // SAFETY: 单测并发跑在同一进程里，用这个测试专属的名字避免影响别人。
        std::env::set_var("JARVIS_TEST_MODEL_KEY", "sk-env-value");

        let resolved = resolve_key(
            &item,
            &ModelSecrets::new(std::path::Path::new("/nonexistent")),
        );
        assert_eq!(resolved.key.as_deref(), Some("sk-env-value"));
        assert_eq!(resolved.state.source(), KeySource::Env);

        std::env::remove_var("JARVIS_TEST_MODEL_KEY");
    }
}
