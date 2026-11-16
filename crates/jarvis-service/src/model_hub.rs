//! 运行期的模型快照。
//!
//! `AppState.config` 是 `Arc<Config>`，进程起来之后不可变；而"切一个模型"
//! 恰恰要改变运行期行为。所以模型相关的运行期事实统一收在这里：
//!
//! - [`ActiveModel`]：当前生效的配置 + 已建好的客户端，一次读锁即可拿到；
//! - [`ModelHub`]：全部配置、密钥状态与生效项的唯一权威；
//! - [`HubResponder`]：按快照在"模型回答"与"确定性回答"之间切换，
//!   让调用方不必知道模型到底可不可用。
//!
//! 热路径（每轮对话）只读 RwLock 快照，不做 IO、不读环境变量。

use std::collections::BTreeMap;
use std::sync::{Arc, RwLock};

use crate::chat::ChatModel;
use crate::config::{Config, LlmConfig, ModelProfile};
use crate::llm::{LlmClient, ModelResponder};
use crate::model::CompletionModel;
use crate::model_profiles::{self, ProfileView};
use crate::model_secrets::{KeyState, ModelSecrets};
use crate::responder::{DeterministicResponder, PromptMessage, Responder, TokenStream};

/// 当前生效的模型。
///
/// `client` 为 `None` 时 `reason` 一定非空——"不可用"和"为什么不可用"
/// 不允许出现一个有一个没有的组合，否则前端只能显示一个光秃秃的红点。
#[derive(Clone, Debug)]
pub struct ActiveModel {
    pub id: String,
    pub name: String,
    pub model: String,
    /// 这个模型能不能读图。附件路径按它决定是送图像还是换成一句说明。
    pub vision: bool,
    /// 上游认不认 `reasoning_effort`。客户端据此决定要不要显示「推理等级」。
    pub reasoning: bool,
    pub client: Option<Arc<LlmClient>>,
    pub reason: Option<String>,
}

impl ActiveModel {
    pub fn available(&self) -> bool {
        self.client.is_some()
    }

    /// 流式对话能力。不可用时为 `None`，调用方回退确定性回答。
    pub fn chat(&self) -> Option<Arc<dyn ChatModel>> {
        self.client
            .as_ref()
            .map(|client| client.clone() as Arc<dyn ChatModel>)
    }

    /// 带推理等级的流式能力。
    ///
    /// 档位只活在这一次调用返回的克隆里，不写回快照：它是随消息走的会话级
    /// 选择，不是配置的一部分。当前配置不支持该参数时，客户端会自己吞掉档位。
    pub fn chat_with(&self, effort: Option<&str>) -> Option<Arc<dyn ChatModel>> {
        self.client
            .as_ref()
            .map(|client| Arc::new(client.with_reasoning_effort(effort)) as Arc<dyn ChatModel>)
    }

    /// 非流式能力（任务步骤、标题、记忆抽取、录音摘要）。
    pub fn completion(&self) -> Option<Arc<dyn CompletionModel>> {
        self.client
            .as_ref()
            .map(|client| client.clone() as Arc<dyn CompletionModel>)
    }

    /// 给日志与接口用的一句话摘要。
    pub fn label(&self) -> String {
        if self.model.is_empty() {
            self.name.clone()
        } else {
            format!("{} / {}", self.name, self.model)
        }
    }
}

/// 不可用时的占位：保留 id/名字，方便界面显示"这条配置现在不能用"。
fn unavailable(llm: &LlmConfig, reason: String) -> ActiveModel {
    let profile = llm.active_profile();
    ActiveModel {
        id: profile.id.clone(),
        name: model_profiles::display_name(&profile),
        model: profile.model.clone(),
        vision: profile.vision,
        reasoning: profile.reasoning,
        client: None,
        reason: Some(reason),
    }
}

/// 由配置 + 密钥算出当前生效项。
fn resolve_active(llm: &LlmConfig, profile: &ModelProfile, secrets: &ModelSecrets) -> ActiveModel {
    let resolved = model_profiles::resolve_key(profile, secrets);
    if let Some(reason) = model_profiles::unavailable_reason(profile, &resolved.state) {
        return unavailable(llm, reason);
    }

    let Some(key) = resolved.key else {
        // 理论上走不到：unavailable_reason 已经拦过"缺少密钥"。
        return unavailable(llm, "缺少密钥".to_string());
    };

    ActiveModel {
        id: profile.id.clone(),
        name: model_profiles::display_name(profile),
        model: profile.model.trim().to_string(),
        vision: profile.vision,
        reasoning: profile.reasoning,
        client: Some(Arc::new(LlmClient::from_profile(profile, key))),
        reason: None,
    }
}

/// 一份一致的运行期视图：配置、密钥状态与生效项必须同时替换。
struct HubState {
    llm: LlmConfig,
    keys: BTreeMap<String, KeyState>,
    active: ActiveModel,
}

pub struct ModelHub {
    state: RwLock<HubState>,
    secrets: ModelSecrets,
}

impl std::fmt::Debug for ModelHub {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = self
            .state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        formatter
            .debug_struct("ModelHub")
            .field("active", &state.active.id)
            .field("model", &state.active.model)
            .field("available", &state.active.available())
            .field("profiles", &state.llm.all_profiles().len())
            .finish_non_exhaustive()
    }
}

impl ModelHub {
    /// 按启动配置装配。密钥文件放在 `data_dir` 下。
    pub fn new(config: &Config) -> Arc<Self> {
        let secrets = ModelSecrets::new(&config.data_dir);
        let llm = config.llm.clone();
        let keys = model_profiles::key_states(&llm, &secrets);
        let active = resolve_active(&llm, &llm.active_profile(), &secrets);

        if active.available() {
            tracing::info!(
                profile = %active.id,
                model = %active.model,
                "对话回答使用模型"
            );
        } else {
            tracing::info!(
                profile = %active.id,
                reason = active.reason.as_deref().unwrap_or("-"),
                "对话回答使用确定性实现（当前配置不可用）"
            );
        }

        Arc::new(Self {
            state: RwLock::new(HubState { llm, keys, active }),
            secrets,
        })
    }

    pub fn secrets(&self) -> &ModelSecrets {
        &self.secrets
    }

    /// 当前 `llm` 节的完整快照。落盘与展示都以它为准。
    pub fn llm(&self) -> LlmConfig {
        self.state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .llm
            .clone()
    }

    pub fn active(&self) -> ActiveModel {
        self.state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .active
            .clone()
    }

    pub fn active_id(&self) -> String {
        self.active().id
    }

    /// 当前生效模型的上下文窗口（tokens）。未知时为 0。
    ///
    /// 客户端用它算输入栏的占比，上下文压缩用它算触发阈值——两处必须同一个数。
    pub fn context_window(&self) -> u32 {
        let active = self.active_id();
        self.profiles()
            .into_iter()
            .find(|profile| profile.id == active)
            .map(|profile| profile.context_window)
            .unwrap_or(0)
    }

    pub fn profiles(&self) -> Vec<ModelProfile> {
        self.llm().all_profiles()
    }

    /// 列表页要的全部信息，读缓存、无 IO。
    pub fn views(&self) -> Vec<ProfileView> {
        let state = self
            .state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        model_profiles::views(&state.llm, &state.keys, &state.active.id)
    }

    /// 换一份 `llm` 配置并立即生效。
    ///
    /// 调用方负责先落盘再调这里：写盘失败就干脆不生效，避免出现
    /// "这次能用、重启就没了"的错觉。
    pub fn install(&self, llm: LlmConfig) -> ActiveModel {
        let keys = model_profiles::key_states(&llm, &self.secrets);
        let active = resolve_active(&llm, &llm.active_profile(), &self.secrets);

        {
            let mut state = self
                .state
                .write()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *state = HubState {
                llm,
                keys,
                active: active.clone(),
            };
        }

        if active.available() {
            tracing::info!(
                profile = %active.id,
                model = %active.model,
                endpoint = active
                    .client
                    .as_ref()
                    .map(|client| client.endpoint().to_string())
                    .unwrap_or_default(),
                "模型已切换"
            );
        } else {
            tracing::warn!(
                profile = %active.id,
                reason = active.reason.as_deref().unwrap_or("-"),
                "模型已切换，但当前配置不可用，回答回退为确定性实现"
            );
        }

        active
    }

    /// 流式对话模型。
    pub fn chat(&self) -> Option<Arc<dyn ChatModel>> {
        self.active().chat()
    }

    /// 带本轮推理等级的流式对话模型。语义见 [`ActiveModel::chat_with`]。
    pub fn chat_with(&self, effort: Option<&str>) -> Option<Arc<dyn ChatModel>> {
        self.active().chat_with(effort)
    }

    /// 非流式模型。
    pub fn completion(&self) -> Option<Arc<dyn CompletionModel>> {
        self.active().completion()
    }
}

/// 把回答生成架在 [`ModelHub`] 之上：每一轮都按当时的快照决定用谁。
///
/// 相比"启动时选一次实现"，这样切换模型后连纯文本回答也会跟着换，
/// 不需要重启，也不用让调用方重新取一遍 responder。
#[derive(Debug)]
pub struct HubResponder {
    hub: Arc<ModelHub>,
}

impl HubResponder {
    pub fn new(hub: Arc<ModelHub>) -> Self {
        Self { hub }
    }
}

impl Responder for HubResponder {
    fn kind(&self) -> &'static str {
        // 与 `deterministic` 区分开：管理面与日志据此判断"这一轮到底有没有模型"。
        if self.hub.active().available() {
            "model"
        } else {
            "deterministic"
        }
    }

    fn stream(&self, messages: Vec<PromptMessage>) -> TokenStream {
        match self.hub.active().client {
            Some(client) => ModelResponder::new((*client).clone()).stream(messages),
            None => DeterministicResponder.stream(messages),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ModelProfile;

    fn temp_config() -> (tempfile::TempDir, Config) {
        let dir = tempfile::tempdir().expect("创建临时目录失败");
        let config = Config {
            data_dir: dir.path().to_path_buf(),
            ..Config::default()
        };
        (dir, config)
    }

    #[test]
    fn disabled_llm_has_no_client() {
        let (_dir, config) = temp_config();
        let hub = ModelHub::new(&config);
        let active = hub.active();
        assert!(!active.available());
        assert_eq!(active.id, crate::config::DEFAULT_PROFILE_ID);
        assert!(active.reason.is_some(), "不可用时必须给出原因");
    }

    #[test]
    fn switching_to_profile_without_key_keeps_reason() {
        let (_dir, mut config) = temp_config();
        config.llm.enabled = true;
        config.llm.profiles.push(ModelProfile {
            id: "third".to_string(),
            name: "第三方".to_string(),
            base_url: "https://api.example.com".to_string(),
            api_path: "/v1".to_string(),
            model: "m".to_string(),
            ..ModelProfile::default()
        });
        let hub = ModelHub::new(&config);

        let mut llm = hub.llm();
        llm.active = "third".to_string();
        let active = hub.install(llm);

        assert_eq!(active.id, "third");
        assert!(!active.available());
        assert_eq!(active.reason.as_deref(), Some("缺少密钥"));
    }

    #[test]
    fn switching_to_unknown_id_falls_back_to_default() {
        let (_dir, config) = temp_config();
        let hub = ModelHub::new(&config);

        let mut llm = hub.llm();
        llm.active = "does-not-exist".to_string();
        let active = hub.install(llm);

        assert_eq!(active.id, crate::config::DEFAULT_PROFILE_ID);
    }

    #[test]
    fn activated_profile_gets_a_client() {
        let (dir, mut config) = temp_config();
        config.llm.enabled = true;
        config.llm.profiles.push(ModelProfile {
            id: "third".to_string(),
            name: "第三方".to_string(),
            base_url: "https://api.example.com".to_string(),
            api_path: "/v1".to_string(),
            model: "m".to_string(),
            ..ModelProfile::default()
        });
        let hub = ModelHub::new(&config);
        hub.secrets()
            .set("third", "sk-test-1234")
            .expect("写入密钥失败");

        let mut llm = hub.llm();
        llm.active = "third".to_string();
        let active = hub.install(llm);

        assert!(active.available(), "{:?}", active.reason);
        assert_eq!(
            active
                .client
                .as_ref()
                .map(|client| client.endpoint().to_string()),
            Some("https://api.example.com/v1/chat/completions".to_string())
        );
        assert!(
            dir.path().join(crate::model_secrets::SECRETS_FILE).exists(),
            "密钥应落在数据目录下"
        );
    }
}
