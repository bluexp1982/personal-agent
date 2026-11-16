//! 进程内共享状态。
//!
//! 全部字段都是 `Arc` 或连接池，克隆廉价，可直接塞进 axum 的 `State`。
//! 管理面与 `/api/*` 共用同一份状态：它们访问的是同一个池、同一份身份与同一组限流器。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};

use sqlx::SqlitePool;

use crate::auth::{ChallengeStore, RateLimiter};
use crate::config::Config;
use crate::identity::Identity;
use crate::model_hub::{ActiveModel, HubResponder, ModelHub};
use protocol::SkillManifest;

use crate::chat::{ChatModel, StopSignal};
use crate::model::CompletionModel;
use crate::responder::Responder;
use crate::runner::{SimulatedExecutor, TaskExecutor};
use crate::shutdown::ShutdownNotice;
use crate::tls::TlsIdentity;
use crate::tool_gateway::{DisabledToolGateway, ToolGateway};
use crate::worker::model_bridge::ModelBridge;
use crate::worker::WorkerHandle;

#[derive(Clone, Debug)]
pub struct AppState {
    pub pool: SqlitePool,
    pub identity: Arc<Identity>,
    pub config: Arc<Config>,
    pub challenges: Arc<Mutex<ChallengeStore>>,
    pub limiter: Arc<Mutex<RateLimiter>>,
    /// 回答生成器。按 [`ModelHub`] 的当前快照决定用模型还是确定性实现。
    pub responder: Arc<dyn Responder>,
    /// 任务执行器。M3 为模拟实现；M4 换成 `jarvis-worker` IPC 实现。
    pub executor: Arc<dyn TaskExecutor>,
    /// 模型配置与当前生效项的唯一权威。
    ///
    /// 对话、任务、标题、记忆抽取、录音摘要全都从这里取模型：切换模型时
    /// 只需要换一次快照，这些能力下一轮自动跟上，不必各自重启。
    pub models: Arc<ModelHub>,
    /// 测试注入通道：对话模型。**生产路径永远为 `None`**。
    ///
    /// 集成测试要在 `AppState` 建好之后塞假模型；保留这两个字段让既有测试
    /// 一行都不用改。读取一律走 [`Self::chat_model`] / [`Self::completion_model`]，
    /// 它们先看这里、再问 [`Self::models`]。
    #[doc(hidden)]
    pub chat_model: Option<Arc<dyn ChatModel>>,
    /// 测试注入通道：非流式模型。生产路径永远为 `None`。
    #[doc(hidden)]
    pub completion_model: Option<Arc<dyn CompletionModel>>,
    /// 任务模型调用的桥：预算、审计、密钥都在这里，worker 只发请求。
    pub model_bridge: Arc<ModelBridge>,
    /// 只读工具网关。worker 未启用时为 `DisabledToolGateway`（一律失败，回答写"未核实"）。
    pub tool_gateway: Arc<dyn ToolGateway>,
    /// worker 上报的技能清单。M4 只含内置技能；服务端据此校验产物与展示能力。
    pub skills: Arc<RwLock<Vec<SkillManifest>>>,
    /// worker 监督状态。未启用时 phase 为 `disabled`。
    pub worker: WorkerHandle,
    /// 自签 TLS 材料。回环明文模式为 `None`；管理面据此展示证书指纹。
    pub tls: Option<Arc<TlsIdentity>>,
    /// 编码任务的模型代理。`code.enabled=false` 时为 `None`。
    ///
    /// 它同时承担三件事：给任务发令牌、代持真 key、按任务记账。
    pub code_proxy: Option<Arc<crate::code_proxy::CodeProxy>>,
    /// 联网查证工具的回环代理。不需要付费上游时为 `None`。
    ///
    /// 它只做一件事：替 worker 换掉 `Authorization`。真密钥不进 worker 进程。
    pub tool_proxy: Option<Arc<crate::tool_proxy::ToolProxy>>,
    /// 会话预览站与运行代理。`app::run` 里装配，测试默认 `None`。
    ///
    /// 工具要拿它拼地址，浏览器隧道要拿它放行端口——两处必须看到同一个实例。
    pub web_preview: Option<Arc<crate::web_preview::WebPreview>>,
    /// SSH 隧道的并发闸门。每条隧道背后都是一个真实 shell 进程，
    /// 不设上限时几十个终端可以把这台机器拖到没响应。
    pub ssh_slots: Arc<tokio::sync::Semaphore>,
    /// 浏览器隧道的并发闸门。按 TCP 连接计：一个页面通常同时开 6 到 10 条。
    pub browser_slots: Arc<tokio::sync::Semaphore>,
    /// 每台设备当前持有的浏览器隧道数。超限直接拒绝，
    /// 避免一台设备把全局名额吃光。
    pub browser_devices: Arc<Mutex<HashMap<String, usize>>>,
    /// 录音转写：实时内联与批量后台共用同一个并发闸门与 provider。
    ///
    /// 未配置转写时仍存在，只是 `available=false`——录音照常归档，不出文本。
    pub transcription: Arc<crate::recording::job::TranscriptionJobs>,
    /// 录音总结：转写完成后自动生成，失败不影响转写。
    pub summary: Arc<crate::recording::summary::SummaryJobs>,
    /// 会话上下文压缩：把更早的对话归纳成摘要，装配时前置。
    ///
    /// `compaction.enabled=false` 或没有模型时仍然存在，只是什么都不做——
    /// 调用点不必到处判空。
    pub compaction: Arc<crate::compaction::Jobs>,
    /// 总结语音合成：按需触发，缓存在录音目录。
    pub summary_audio: Arc<crate::recording::audio_jobs::SummaryAudioJobs>,
    /// 记忆权威服务。
    ///
    /// `memory.enabled=false` 时它仍然存在，只是写接口返回 `memory_unavailable`、
    /// 摘要为空——这样调用点不需要到处判空，也不会漏判出半残行为。
    pub memory: Arc<crate::memory::MemoryService>,
    /// 正在生成中的会话轮次：键见 [`chat_stop_key`]，值是这一轮的停止信号。
    ///
    /// 生成任务需要一个"被外部喊停"的入口：SSE 响应流本身没有取消句柄，
    /// 而"客户端断开"在服务端看来只是发送失败——两者语义相反
    /// （断开要丢弃半截回答，停止要落库），只能靠显式登记区分。
    pub chat_stops: Arc<Mutex<HashMap<String, Arc<StopSignal>>>>,
    /// 关闭通知。SSH 隧道是长连接：不主动收尾会拖住优雅关闭。
    pub shutdown: Arc<ShutdownNotice>,
    /// 媒体生成后端（文生图 / 文生视频）。
    ///
    /// 两节都关闭时为 `None`：对话里就不会注册这两个工具。测试可以把它换成
    /// 假实现，从而在不联网、不花钱的前提下覆盖整条链路。
    pub media: Option<Arc<dyn crate::media::MediaBackend>>,
}

/// 一轮生成的登记凭据。`Drop` 时摘除：任务正常结束、提前 return 或
/// panic 都不会把条目留在表里，否则同一 `client_msg_id` 重发时会命中旧信号。
#[derive(Debug)]
pub struct ChatStopGuard {
    stops: Arc<Mutex<HashMap<String, Arc<StopSignal>>>>,
    key: String,
}

impl Drop for ChatStopGuard {
    fn drop(&mut self) {
        self.stops
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&self.key);
    }
}

/// 停止信号的注册键。
///
/// 带上会话 id：同一台设备可能在两个会话里同时生成，只按 `client_msg_id` 登记
/// 会让停止串台（虽然实际很难撞上，但键本身没有理由不带作用域）。
pub fn chat_stop_key(conversation_id: &str, client_msg_id: &str) -> String {
    format!("{conversation_id}:{client_msg_id}")
}

/// 一次浏览器隧道的设备名额。`Drop` 时归还：
/// 隧道异常结束（对端断开、panic）也不会把名额泄漏掉。
#[derive(Debug)]
pub struct BrowserDeviceSlot {
    counts: Arc<Mutex<HashMap<String, usize>>>,
    device_id: String,
}

impl Drop for BrowserDeviceSlot {
    fn drop(&mut self) {
        let mut counts = self
            .counts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(count) = counts.get_mut(&self.device_id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                counts.remove(&self.device_id);
            }
        }
    }
}

impl AppState {
    pub fn new(pool: SqlitePool, identity: Identity, config: Config) -> Self {
        let executor = Arc::new(SimulatedExecutor::new(
            config.approval_ttl_ms,
            config.artifacts_dir(),
        ));

        // 模型配置与密钥都收进 hub：切换模型时只换它的快照，不需要重建 AppState。
        // 一个客户端实例同时供对话（流式）与任务（非流式）使用：连接池与密钥只有一份。
        let models = ModelHub::new(&config);
        let completion_model = models.completion();
        let responder: Arc<dyn Responder> = Arc::new(HubResponder::new(models.clone()));

        // 任务侧预算跟着配置走；未启用模型时桥仍然存在，只是返回 `model_disabled`，
        // worker 据此整段降级为确定性执行，而不是让任务失败。
        let model_bridge = Arc::new(ModelBridge::new(
            completion_model.clone(),
            config.task.clone(),
            std::time::Duration::from_millis(config.task_timeout_ms.max(1_000) as u64),
            pool.clone(),
        ));

        // 校验会在启动前拒绝 0，但测试与直接构造 AppState 的路径不该因此死锁。
        let ssh_slots = Arc::new(tokio::sync::Semaphore::new(config.ssh.max_sessions.max(1)));

        // 浏览器隧道按"连接"限流：一个页面同时开多条，上限要留够。
        // 校验会在启动前拒绝 0，这里同样兜一层。
        let browser_slots = Arc::new(tokio::sync::Semaphore::new(
            config.browser.max_tunnels.max(1),
        ));

        // 转写 provider 在装配时一次性建好：密钥、端点与并发数都从这里定，
        // 请求路径上不再重复读环境变量。
        let transcription = crate::recording::job::TranscriptionJobs::new(pool.clone(), &config);
        let summary = crate::recording::summary::SummaryJobs::new(pool.clone(), &config);
        let summary_audio =
            crate::recording::audio_jobs::SummaryAudioJobs::new(pool.clone(), &config);

        // 记忆用非流式模型：抽取与实体重算都不需要流式，且非流式能直接拿 usage 记账。
        let memory =
            crate::memory::MemoryService::new(pool.clone(), &config, completion_model.clone());

        // 压缩同样由后台触发，也自己持有一份模型。
        let compaction = crate::compaction::Jobs::new(pool.clone(), &config);

        // 录音总结与上下文压缩自己持有一份模型：它们由后台任务消费，没有请求
        // 上下文可以借用。启动时先按 hub 的当前快照对齐一次，之后换模型由
        // `apply_llm` 扇出。
        let active_model = models.active();
        summary.set_model(completion_model.clone(), &active_model.model);
        compaction.set_model(completion_model.clone(), &active_model.model);

        // 媒体后端在装配时一次性建好：它持有 HTTP 客户端与密钥。
        // 两节都关或缺少密钥时为 None —— 对话里就看不到生成工具。
        let media: Option<Arc<dyn crate::media::MediaBackend>> =
            match crate::media::MediaGenerator::from_config(&config) {
                Ok(generator) => Some(Arc::new(generator)),
                Err(err) => {
                    tracing::debug!(%err, "媒体生成未启用");
                    None
                }
            };

        Self {
            pool,
            identity: Arc::new(identity),
            config: Arc::new(config),
            challenges: Arc::new(Mutex::new(ChallengeStore::default())),
            limiter: Arc::new(Mutex::new(RateLimiter::default())),
            responder,
            executor,
            models,
            // 生产路径下这两个注入通道恒为 None，模型一律从 `models` 取。
            chat_model: None,
            completion_model: None,
            model_bridge,
            tool_gateway: Arc::new(DisabledToolGateway),
            skills: Arc::new(RwLock::new(Vec::new())),
            worker: WorkerHandle::new(),
            // TLS 在 `app::run` 里按配置装配：测试默认走明文，不需要证书。
            tls: None,
            // 编码代理同样在 `app::run` 里装配：它需要绑定端口，测试不该被动起监听。
            code_proxy: None,
            // 联网工具代理：需要付费上游且配了密钥才起，测试默认没有。
            tool_proxy: None,
            // 预览站同理：绑定端口是副作用，测试按需自己起。
            web_preview: None,
            ssh_slots,
            browser_slots,
            browser_devices: Arc::new(Mutex::new(HashMap::new())),
            transcription,
            summary,
            compaction,
            summary_audio,
            memory,
            chat_stops: Arc::new(Mutex::new(HashMap::new())),
            shutdown: Arc::new(ShutdownNotice::new()),
            media,
        }
    }

    /// 当前生效的模型快照（含不可用原因）。
    pub fn active_model(&self) -> ActiveModel {
        self.models.active()
    }

    /// 流式对话模型。未配置、无密钥或配置不可用时为 `None`。
    pub fn chat_model(&self) -> Option<Arc<dyn ChatModel>> {
        self.chat_model.clone().or_else(|| self.models.chat())
    }

    /// 带本轮推理等级的流式对话模型。
    ///
    /// 档位是随消息走的会话级选择，不写回任何快照；`None` 与 [`Self::chat_model`]
    /// 完全等价。测试注入的假模型拿不到档位——它本来也不关心。
    pub fn chat_model_with(&self, effort: Option<&str>) -> Option<Arc<dyn ChatModel>> {
        match self.chat_model.clone() {
            Some(model) => Some(model),
            None => self.models.chat_with(effort),
        }
    }

    /// 非流式模型：任务步骤、标题、记忆抽取、录音摘要共用同一个实例。
    pub fn completion_model(&self) -> Option<Arc<dyn CompletionModel>> {
        self.completion_model
            .clone()
            .or_else(|| self.models.completion())
    }

    /// 换一份 `llm` 配置并让所有依赖模型的能力一起切换。
    ///
    /// 扇出点只有一个：`model_bridge`（worker 任务步骤）、`memory`（抽取与实体重算）、
    /// `summary`（录音总结）。对话与标题走 [`Self::chat_model`] / [`Self::completion_model`]
    /// 每轮现取，不需要额外通知。在途的生成持有自己的快照，不会被中途换掉。
    ///
    /// 调用方必须先落盘再调这里：写盘失败就当没切过，避免"这次能用、重启就没了"。
    pub fn apply_llm(&self, llm: crate::config::LlmConfig) -> ActiveModel {
        let active = self.models.install(llm);
        let completion = active.completion();
        self.model_bridge.set_model(completion.clone());
        self.memory.set_model(completion.clone());
        self.compaction.set_model(completion.clone(), &active.model);
        self.summary.set_model(completion, &active.model);
        active
    }

    /// 登记一轮生成，返回停止信号与自动摘除的 guard。
    ///
    /// 停止请求可能在首个分片之前就到了，所以键用客户端给的 `client_msg_id`
    /// 而不是服务端定的 `message_id`。
    pub fn register_chat_stop(&self, key: String) -> (Arc<StopSignal>, ChatStopGuard) {
        let signal = Arc::new(StopSignal::default());
        self.chat_stops
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(key.clone(), signal.clone());
        (
            signal,
            ChatStopGuard {
                stops: self.chat_stops.clone(),
                key,
            },
        )
    }

    /// 置位某一轮的停止信号。返回是否命中：没命中说明这一轮已经结束了。
    pub fn request_chat_stop(&self, key: &str) -> bool {
        let signal = self
            .chat_stops
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(key)
            .cloned();
        match signal {
            Some(signal) => {
                signal.request();
                true
            }
            None => false,
        }
    }

    /// 占用一台设备的一个浏览器隧道名额；超限返回 `None`。
    ///
    /// 先占名额再连目标：否则并发检查统计的是"正在握手的请求"，
    /// 而不是"活着的连接"，一次突发就能把上限冲穿。
    pub fn acquire_browser_device(&self, device_id: &str) -> Option<BrowserDeviceSlot> {
        let limit = self.config.browser.max_tunnels_per_device.max(1);
        let mut counts = self
            .browser_devices
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let count = counts.entry(device_id.to_string()).or_insert(0);
        if *count >= limit {
            return None;
        }
        *count += 1;
        drop(counts);

        Some(BrowserDeviceSlot {
            counts: self.browser_devices.clone(),
            device_id: device_id.to_string(),
        })
    }
}
