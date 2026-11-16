//! 服务配置。
//!
//! 优先级：命令行参数 > 配置文件 > 内置默认值。
//! 配置文件格式固定为 JSON（M0 从简，M1 若有需要再评估 TOML）。

use std::path::{Path, PathBuf};

use protocol::SummaryStyle;
use serde::{Deserialize, Serialize};

/// `/api/*` 的默认监听地址。
///
/// 与客户端 `kDefaultServerUrl`（`http://127.0.0.1:8787`）保持一致：
/// 两边各自写死一个默认值却不一样，是这个项目已经踩过的坑。
pub const DEFAULT_API_BIND: &str = "127.0.0.1:8787";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// 管理面端口。仅 Windows 回退路径使用；0 交给系统分配。
    ///
    /// 刻意不用 8787：那个端口留给 `/api/*`，两个监听撞在一起会导致服务起不来。
    pub port: u16,
    /// `/api/*` 的监听地址。v1 走直连 HTTP，默认只绑回环。
    ///
    /// 默认固定 8787 而不是让系统分配：客户端默认就连这个端口，
    /// 随机端口会让"服务起来了但客户端连不上"变成一个必踩的坑。
    pub api_bind: String,
    /// 数据目录：SQLite、身份密钥、产物与凭据库都放这里。
    pub data_dir: PathBuf,
    /// 审批有效期，默认 10 分钟。集成测试会注入 1 秒以避免长时间等待。
    pub approval_ttl_ms: i64,
    /// 组装上下文时保留的最大消息条数（含两侧）。
    pub context_messages: usize,
    /// 后台扫描周期（审批过期、悬空任务回收）。
    pub tick_interval_ms: u64,
    /// 单任务最长执行时间，超过即视为悬空并回收。
    pub task_timeout_ms: i64,
    /// 文本生成模型。默认关闭，用确定性回答兜底。
    pub llm: LlmConfig,
    /// 任务执行的模型预算。
    pub task: TaskConfig,
    /// 对话工具调用（只读）的边界。
    pub tool: ToolConfig,
    /// 编码任务（本机 CLI）的能力与预算。
    pub code: CodeConfig,
    /// 项目：可浏览/可挂载的目录范围与默认文档目录。
    ///
    /// 旧配置文件里这一节叫 `workspace`：这里用 serde alias 继续接受旧键，
    /// 否则老部署升级后项目列表会静默变空。
    #[serde(alias = "workspace")]
    pub project: ProjectConfig,
    /// 对外 API 的传输层加密策略。
    pub tls: TlsConfig,
    /// SSH 隧道：客户端经 `/api/ssh` 连到本机 sshd。
    pub ssh: SshTunnelConfig,
    /// 浏览器隧道：客户端经 `/api/browser/tunnel` 连到本机回环端口。
    pub browser: BrowserConfig,
    /// 录音转写：只由 service 调用云 ASR，客户端永不持有厂商密钥。
    pub asr: AsrConfig,
    /// 语音合成：模型与音色先落配置，功能尚未接入。
    pub tts: TtsConfig,
    /// 实时双工语音：WebSocket 地址与 VAD 参数先落配置，功能尚未接入。
    pub realtime: RealtimeConfig,
    /// 媒体生成：百炼文生图与文生视频。默认关闭，产物落 `data/artifacts`。
    pub media: MediaConfig,
    /// 录音总结：模型沿用 `llm`，这里只控制长度与并发。
    pub summary: SummaryConfig,
    /// 会话上下文压缩：把更早的对话归纳成摘要，替代"直接截断"。
    ///
    /// 关掉它等于回到只留最近 `context_messages` 条的旧行为；没有模型时它什么也不做。
    pub compaction: CompactionConfig,
    /// 录音归档的配额与分段上限。
    pub recording: RecordingConfig,
    /// 输入框附件（用户上传的文件 / 图片）的上限与摘录预算。
    pub attachment: AttachmentConfig,
    /// 记忆系统（贾维斯一期）：常驻摘要、召回、抽取、心跳。
    ///
    /// **默认 `enabled=false`**：不打开就既不注入也不抽取，升级不会被静默改变行为。
    pub memory: MemoryConfig,
    /// 是否启用独立的 `jarvis-worker` 执行进程。Windows 尚未实现 named pipe，默认关闭。
    pub worker_enabled: bool,
    /// worker 二进制路径。为空时取当前可执行文件同目录下的 `jarvis-worker`。
    pub worker_path: Option<PathBuf>,
    /// 连续启动失败多少次后停止重试。
    pub worker_max_restarts: u32,
    /// 超过该时长没有心跳即判定僵死。
    pub worker_heartbeat_timeout_ms: u64,
    /// 这份配置是从哪个文件读出来的。
    ///
    /// 不参与序列化：它是运行期事实，不是配置项。客户端改模型配置后要把
    /// `llm` 节写回**同一个文件**，没有它就只能瞎猜路径。
    /// `None` 表示未传 `--config`（内置默认值），此时不落盘。
    #[serde(skip)]
    pub source_path: Option<PathBuf>,
}

/// 默认档配置的固定 id。
///
/// 用户新增的配置各有自己的 id；这一份来自配置文件里的 `llm` 节本身，
/// 升级前的老部署只有它，因此必须有一个不会与用户 id 相撞的名字。
pub const DEFAULT_PROFILE_ID: &str = "default";

/// OpenAI 兼容路径前缀的默认值：百炼的兼容端点在它下面。
pub const DEFAULT_API_PATH: &str = "/compatible-mode/v1";

/// 上下文窗口的兜底值（tokens）。
///
/// 用户新增第三方配置时用它：128K 是当前主流 OpenAI 兼容模型的常见下限，
/// 按真实值调大只会让输入栏的占比更宽松，不会误导。
pub const DEFAULT_CONTEXT_WINDOW: u32 = 128_000;

/// 默认档 `deepseek-v4.1-flash` 的最大上下文（tokens）。
///
/// 只用于客户端输入栏的"上下文已用"占比，不参与请求拼装与预算判定。
pub const BUILTIN_CONTEXT_WINDOW: u32 = 1_000_000;

/// 文本生成模型的配置。
///
/// **密钥不写在这里**：只记录从哪个环境变量读取，避免配置文件和仓库里出现明文 Key。
///
/// 本节同时也是"默认档"——`base_url` / `model` 等字段就是默认档的内容，
/// 用户通过客户端新增的配置放在 [`LlmConfig::profiles`] 里。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct LlmConfig {
    pub enabled: bool,
    /// OpenAI 兼容网关地址（不带路径）。
    pub base_url: String,
    /// 发给上游的模型 ID（`chat/completions` 的 `model` 字段）。
    pub model: String,
    /// 人可读的模型名（例如「DeepSeek V3.2 Flash」）：只给界面展示用，
    /// 留空时界面回退 [`Self::model`]。与 `profiles[].name`（配置名）不是一回事。
    pub model_name: String,
    /// 读取密钥的环境变量名。
    pub api_key_env: String,
    /// OpenAI 兼容路径前缀（不含 `/chat/completions`）。
    ///
    /// 默认 [`DEFAULT_API_PATH`]，保持接入第三方模型之前的百炼行为不变。
    /// 换 OpenAI / DeepSeek / Moonshot / Ollama 时改成 `/v1`。
    pub api_path: String,
    /// 当前生效的配置 id。空串或 [`DEFAULT_PROFILE_ID`] 表示生效的是本节。
    pub active: String,
    /// 用户新增的命名配置。
    pub profiles: Vec<ModelProfile>,
    /// 一次**非流式**请求的往返上限（标题、任务步骤、录音摘要走这条）。
    pub timeout_ms: u64,
    /// 流式两帧之间的最长静默，超过即判定上游卡住。
    ///
    /// 与 `timeout_ms` 是两件事：那个是"一次非流式请求最多花多久"，
    /// 这个是"流式里多久没有新数据算卡死"。生成大段内容时总时长可能
    /// 远超两分钟，但帧间隔通常只有几十毫秒——用总时长去掐，等于
    /// 禁止长回答。
    pub stream_idle_timeout_ms: u64,
    /// 模型能不能读图：开启后用户附的图片会以 `image_url` 多模态片段送上去。
    ///
    /// **默认关闭**：当前默认模型是纯文本模型，硬送图片只会换回一个 400，
    /// 用户看到的是"生成中断"而不是"这个模型不支持读图"。关闭时图片仍然
    /// 落库、仍然在气泡里可看，只是会以一句文字说明代替图像内容。
    pub vision: bool,
    /// 上游认不认 `reasoning_effort`（把用户的「推理等级」发给模型）。
    ///
    /// **默认档默认开启**：默认模型实测支持该参数，白名单之外的值直接 400。
    /// 用户新增的第三方配置默认关闭——多数 OpenAI 兼容网关不认这个字段，
    /// 硬发只会让整轮对话失败。
    pub reasoning: bool,
    /// 模型最大上下文窗口（tokens）。只用于输入栏的上下文占比，不参与请求。
    pub context_window: u32,
}

impl Default for LlmConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: "https://api.deepseek.com".to_string(),
            model: "deepseek-v4.1-flash".to_string(),
            model_name: String::new(),
            api_key_env: "PERSONAL_AGENT_LLM_API_KEY".to_string(),
            api_path: DEFAULT_API_PATH.to_string(),
            active: String::new(),
            profiles: Vec::new(),
            timeout_ms: 120_000,
            // 60 秒没有任何字节才叫卡死；正常生成两帧之间只有几十毫秒。
            stream_idle_timeout_ms: 60_000,
            vision: false,
            reasoning: true,
            // 默认档是 deepseek-v4.1-flash，上下文窗口 1M。
            context_window: BUILTIN_CONTEXT_WINDOW,
        }
    }
}

impl LlmConfig {
    /// 本节对应的"默认档"。
    pub fn builtin_profile(&self) -> ModelProfile {
        ModelProfile {
            id: DEFAULT_PROFILE_ID.to_string(),
            name: "默认".to_string(),
            enabled: self.enabled,
            base_url: self.base_url.clone(),
            api_path: self.api_path.clone(),
            model: self.model.clone(),
            model_name: self.model_name.clone(),
            api_key_env: self.api_key_env.clone(),
            timeout_ms: self.timeout_ms,
            stream_idle_timeout_ms: self.stream_idle_timeout_ms,
            vision: self.vision,
            reasoning: self.reasoning,
            context_window: self.context_window,
        }
    }

    /// 全部配置（默认档在前）。
    ///
    /// 默认档永远排第一：它由配置文件主体决定，不能被删除；列表页的行序
    /// 与"新增项追加在后面"的直觉一致。
    pub fn all_profiles(&self) -> Vec<ModelProfile> {
        let mut all = Vec::with_capacity(self.profiles.len() + 1);
        all.push(self.builtin_profile());
        all.extend(self.profiles.iter().cloned());
        all
    }

    /// 当前生效的配置。
    ///
    /// `active` 为空/等于默认档 id → 本节；命中某条 profile → 该条；
    /// 指向不存在的 id → 回落本节并告警（配置文件被手改坏时不该让服务起不来，
    /// 但必须留痕，否则用户会以为切换生效了）。
    pub fn active_profile(&self) -> ModelProfile {
        let id = self.active.trim();
        if id.is_empty() || id == DEFAULT_PROFILE_ID {
            return self.builtin_profile();
        }
        match self.profiles.iter().find(|profile| profile.id == id) {
            Some(profile) => profile.clone(),
            None => {
                tracing::warn!(
                    active = id,
                    "llm.active 指向不存在的配置，回落到默认档；请在客户端重新选择"
                );
                self.builtin_profile()
            }
        }
    }

    /// 当前生效配置的 id（解析过回落之后的真实值）。
    pub fn active_id(&self) -> String {
        self.active_profile().id
    }

    /// 默认档的完整请求地址：`{base_url}{api_path}/chat/completions`。
    pub fn chat_endpoint(&self) -> String {
        self.builtin_profile().chat_endpoint()
    }
}

/// 一份命名模型配置。
///
/// 与 [`LlmConfig`] 的默认档同构，字段含义一一对应；`id` 是稳定标识（客户端
/// 用它做增删改与生效标记），`name` 只是给人看的名字。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelProfile {
    /// 稳定 id。只允许 `[a-z0-9-_]`，由服务端生成或用户填写。
    pub id: String,
    /// 配置名（列表标题）。可重名，仅用于界面。
    pub name: String,
    pub enabled: bool,
    /// OpenAI 兼容网关地址（不带路径）。
    pub base_url: String,
    /// 路径前缀，空视为 [`DEFAULT_API_PATH`]。
    pub api_path: String,
    /// 发给上游的模型 ID（`chat/completions` 的 `model` 字段）。
    pub model: String,
    /// 人可读的模型名（例如「DeepSeek V3.2 Flash」），可空；空时界面回退 `model`。
    pub model_name: String,
    /// 读取密钥的环境变量名（客户端也会把密钥写进 `model-secrets.json`）。
    pub api_key_env: String,
    pub timeout_ms: u64,
    pub stream_idle_timeout_ms: u64,
    pub vision: bool,
    /// 上游认不认 `reasoning_effort`。含义见 [`LlmConfig::reasoning`]。
    pub reasoning: bool,
    /// 模型最大上下文窗口（tokens），客户端据此算输入栏的上下文占比。
    ///
    /// 只做展示口径：不改请求拼装、不参与预算判定。缺省走
    /// [`DEFAULT_CONTEXT_WINDOW`]，默认档走 [`BUILTIN_CONTEXT_WINDOW`]。
    pub context_window: u32,
}

impl Default for ModelProfile {
    fn default() -> Self {
        // 新增配置默认是"启用、走 /v1"：用户填完地址和密钥就能用，
        // 不必再回来打开一个开关。默认档的 `/compatible-mode/v1` 由
        // [`LlmConfig::builtin_profile`] 带入，与这里无关。
        Self {
            id: String::new(),
            name: String::new(),
            enabled: true,
            base_url: String::new(),
            api_path: "/v1".to_string(),
            model: String::new(),
            model_name: String::new(),
            api_key_env: String::new(),
            timeout_ms: 120_000,
            stream_idle_timeout_ms: 60_000,
            vision: false,
            // 第三方网关不认这个参数的居多，默认不发；要用就在配置里勾上。
            reasoning: false,
            // 用户多半不知道自己模型的窗口：先给 128K 的保守值，
            // 设置页可以改成实际值（只影响占比的分母）。
            context_window: DEFAULT_CONTEXT_WINDOW,
        }
    }
}

impl ModelProfile {
    /// 路径前缀规整：去尾部 `/`；空值走默认。
    pub fn normalized_api_path(&self) -> String {
        let raw = self.api_path.trim().trim_end_matches('/');
        if raw.is_empty() {
            return DEFAULT_API_PATH.to_string();
        }
        if raw.starts_with('/') {
            raw.to_string()
        } else {
            format!("/{raw}")
        }
    }

    /// 完整请求地址：`{base_url}{api_path}/chat/completions`。
    ///
    /// 地址里已经带了同样的前缀时不再重复拼：用户把 `https://api.deepseek.com/v1`
    /// 整段贴进网关地址栏是常见填法，拼成 `/v1/v1/...` 只会换回一个 404。
    pub fn chat_endpoint(&self) -> String {
        let base = self.base_url.trim().trim_end_matches('/');
        let path = self.normalized_api_path();
        if base.ends_with(&path) {
            format!("{base}/chat/completions")
        } else {
            format!("{base}{path}/chat/completions")
        }
    }

    /// 是否可用来发请求：启用、地址与模型名都不为空。
    ///
    /// 密钥是另一半判据，但它要读文件/环境变量，放在 [`crate::model_profiles`] 里合并判断。
    pub fn is_configured(&self) -> bool {
        self.enabled && !self.base_url.trim().is_empty() && !self.model.trim().is_empty()
    }
}

/// 单任务执行的模型预算。
///
/// 与 [`ToolConfig`] 的 `turn_budget_ms` 是两件事：那个管"一轮对话最多花多久查证"，
/// 这里管"一个任务最多花多少次调用、多少 token"。接模型后两者都必须有硬上限，
/// 否则一次跑偏的技能可以安静地烧掉一整天的额度。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct TaskConfig {
    /// 单任务最多模型调用次数（含最后的产品归纳）。
    pub max_model_calls: u32,
    /// 单任务 prompt + completion 的 token 合计上限。
    ///
    /// 用 u64 而不是 u32：这是唯一会跨多次调用累加的量，宁可宽一点。
    pub max_tokens: u64,
    /// 单次模型调用的等待上限。
    ///
    /// 必须小于 `llm.timeout_ms`，否则先被 HTTP 客户端超时截断，
    /// 真实原因（网关慢还是网络断）会分不清。
    pub model_call_timeout_ms: u64,
    /// 单个步骤允许生成的最大 token 数。
    pub step_max_tokens: u32,
    /// 归纳产物时允许的最大 token 数。
    pub synthesis_max_tokens: u32,
}

impl Default for TaskConfig {
    fn default() -> Self {
        Self {
            max_model_calls: 12,
            max_tokens: 60_000,
            model_call_timeout_ms: 90_000,
            step_max_tokens: 1_200,
            synthesis_max_tokens: 3_000,
        }
    }
}

/// 对话工具调用的边界。
///
/// 不再有域名白名单：`web.fetch` 的准入改成"只放行公网地址"（回环、内网、
/// 链路本地地址仍拒绝），规则唯一实现在 `jarvis-worker` 的 `tools::net_guard`。
/// 这里只留预算——它决定"一轮问答最多查证几次、花多久"。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ToolConfig {
    /// 单轮最多调用次数（只算外部工具：网页、天气）。
    ///
    /// 这是"防跑飞"的保险，不是日常约束：正常任务根本撞不到，
    /// 撞到就说明模型在原地打转。个人 Agent 没有按次计费的成本基础，
    /// 所以数值不需要省——但每次外部调用都有真实网络延迟与上下文占用，
    /// 完全取消就等于允许"一轮抓二十个网页"，仍要给个上限。
    pub max_calls_per_turn: usize,
    /// 单轮本地文件工具（读、列目录、搜索）的调用上限。
    ///
    /// 本地工具没有外部成本，真正该管的是上下文大小与轮数，
    /// 所以给到事实上撞不到的量级——留着只为拦住"同一个文件读几十遍"
    /// 那种死循环。写入（`write_file`）不占任何额度，见 `is_output_tool`。
    pub max_local_calls_per_turn: usize,
    /// 最多工具往返轮数。
    ///
    /// **唯一真正必须存在的次数限制**：模型"调工具 → 看结果 → 再调"
    /// 是它自己决定循环多少次的，只有这里能兜住。其余额度都只是保险。
    pub max_rounds: usize,
    /// 单次调用超时。防止一个挂起的 HTTP 把整轮拖死。
    pub call_timeout_ms: u64,
    /// 整轮对话耗时上限（含所有模型调用）。
    pub turn_budget_ms: u64,
    /// 单次媒体生成（含轮询与下载）的上限。
    ///
    /// 与 `call_timeout_ms` 分开：那个是十秒级的"别挂住"，而一次出片
    /// 实测就要两分钟，用同一个数会把所有视频请求都判成超时。
    pub media_call_timeout_ms: u64,
    /// 一轮对话里媒体生成总共能占用多久。
    ///
    /// 媒体耗时从 `turn_budget_ms` 里扣除，但仍受这个硬顶约束——
    /// 否则"再生成一段"可以无限续命。
    pub media_turn_budget_ms: u64,
    /// 一轮对话最多生成几次媒体。每次都是真实付费请求，默认两次。
    pub max_media_calls_per_turn: usize,
    /// 联网查证工具的上游选择（搜索走谁、抓取是否兜底）。
    ///
    /// 与额度分开：额度决定"查几次"，这里决定"问谁"。默认仍是
    /// 零密钥零成本的 Bing + 本机抓取，换上游是显式选择。
    pub web: WebToolsConfig,
}

/// 联网查证工具的上游配置。
///
/// 两种能力各自可切换，但**默认都不切**：`bing` + 本机抓取不需要任何密钥，
/// 是"装了就能用"的那条路径。接 DeepSeek 官方 Search / Fetch 属于可选增强。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct WebToolsConfig {
    /// 搜索上游：`bing`（默认，抓结果页、无需密钥）或 `deepseek`（官方 Search）。
    ///
    /// 配成 `deepseek` 但环境里没有密钥时不会拦启动，而是**降级回 `bing`**
    /// 并打一条 warn——查证是锦上添花，不该让服务因为少一把钥匙起不来。
    pub search_provider: String,
    /// 本机抓取失败时是否回落到 DeepSeek Fetch。
    ///
    /// 只兜底"取不到内容"这类失败（超时、非 2xx、无正文、编码不可用）；
    /// 被准入规则拒绝的地址（非 https、内网、回环、带账号密码）永不外发。
    pub fetch_fallback: bool,
    /// 上游根地址。默认 `https://api.deepseek.com`。
    ///
    /// 只允许 https；测试可以指向回环 http（`Config::validate` 单独放行）。
    pub base_url: String,
    /// 密钥所在的环境变量名。配置里只写名字，**密钥本身永不落盘**。
    pub api_key_env: String,
    /// 单次上游请求超时，必须小于 `tool.call_timeout_ms`。
    pub timeout_ms: u64,
    /// 是否让 Search 直接返回网页正文（对应上游 `need_content`）。
    ///
    /// 默认 `false`：正文交给 `web_fetch`，搜索结果只回标题、摘要与时间，
    /// 否则一次搜索就能把上下文撑爆。
    pub need_content: bool,
    /// 回环代理的监听地址。**只允许回环**：它代持付费密钥。
    pub proxy_bind: String,
}

impl Default for WebToolsConfig {
    fn default() -> Self {
        Self {
            search_provider: "bing".to_string(),
            // 默认关闭：兜底会多一次往返与一次计费，要用再开。
            fetch_fallback: false,
            base_url: WEB_TOOLS_DEFAULT_BASE_URL.to_string(),
            api_key_env: WEB_TOOLS_DEFAULT_API_KEY_ENV.to_string(),
            // 比 call_timeout_ms（10 秒）短 4 秒：worker 侧还要再减 2 秒，
            // 代理这一跳才有余量把上游的真实状态码带回来。
            timeout_ms: 6_000,
            need_content: false,
            proxy_bind: "127.0.0.1:0".to_string(),
        }
    }
}

/// DeepSeek 官方工具的默认根地址。
pub const WEB_TOOLS_DEFAULT_BASE_URL: &str = "https://api.deepseek.com";
/// 联网工具密钥的默认环境变量名。与对话的 `llm.api_key_env` **刻意不同**：
/// 对话与联网工具可能接不同的上游，两枚 key 不一定通用。
pub const WEB_TOOLS_DEFAULT_API_KEY_ENV: &str = "DEEPSEEK_API_KEY";
/// 已实现的搜索上游。
pub const SUPPORTED_SEARCH_PROVIDERS: &[&str] = &["bing", "deepseek"];

impl Default for ToolConfig {
    fn default() -> Self {
        Self {
            // 实测：查一个陌生设计规范时，模型会一口气并发发 2 搜 + 3 抓，
            // 5 次当场用满，之后想补一次核对就没额度了。12 的容量允许
            // "两轮完整检索"，正常任务用不到一半；再多就是模型在打转。
            max_calls_per_turn: 12,
            // 正常"读目录 + 读三四个文件 + 搜索"最多 8 次，100 事实上等于
            // 不限制。取整数而不是 `usize::MAX`：它要序列化进 JSON 配置。
            max_local_calls_per_turn: 100,
            // "检索 → 读文件 → 写文件 → 收尾"刚好四轮；再少会把写截在半路，
            // 再多就接近放任模型自己循环。
            max_rounds: 4,
            call_timeout_ms: 10_000,
            // 写一个几十 KB 的网页，光生成就要一分钟上下；再叠加检索与读文件，
            // 三分钟对"产出型"回答才够用。个人 Agent 等几分钟是可接受的，
            // 要防的是"永远不结束"，不是"等了三分钟"。
            turn_budget_ms: 300_000,
            // 出片实测约两分钟；1080P 更久。给到 15 分钟是止损线，不是预期耗时。
            media_call_timeout_ms: 900_000,
            // 一轮里媒体最多吃 30 分钟（默认只允许两次调用，撞不到这个顶）。
            media_turn_budget_ms: 1_800_000,
            // 两次：够"先出一张，看到不太对再调一次"，再多就是模型在反复试。
            max_media_calls_per_turn: 2,
            web: WebToolsConfig::default(),
        }
    }
}

/// 编码任务（调用本机 opencode 之类的 CLI）的配置。
///
/// 安全默认与工具侧同口径：**没配就是全关**。
/// 编码任务会在真实仓库里读写文件，宁可多配一次，也不要默认放开。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeConfig {
    /// 关闭时 worker 不加载 `code-task`，也不启动代理。
    pub enabled: bool,
    /// 自动路由的首选编码 CLI（单值）。`routing.preferred` 为空时它就是唯一候选，
    /// 用于"我就想固定用这一个"的场景。
    ///
    /// 用户在某次任务里显式点名别的 CLI 时**不经过**这一项——那是用户的明确选择，
    /// 不该被一个默认值盖掉。
    pub provider: String,
    /// 允许执行编码任务的仓库根目录；空表示全部拒绝。
    pub allow_roots: Vec<PathBuf>,
    /// 每个任务的 worktree 落在哪里；为空取 `{data_dir}/worktrees`。
    pub worktree_dir: Option<PathBuf>,
    /// 编码任务整体墙钟上限；为空取 `task_timeout_ms - 2000`。
    pub timeout_ms: Option<i64>,
    /// 同时执行的编码任务数。CLI 很重，默认一次一个。
    pub max_concurrent: usize,
    /// CLI 可执行文件；为空走 PATH。
    pub bin: Option<PathBuf>,
    /// 代理监听地址。**只允许回环**：它会代持模型密钥，绝不能跟着 `api_bind` 暴露。
    pub proxy_bind: String,
    pub upstream: CodeUpstreamConfig,
    pub budget: CodeBudgetConfig,
    /// 工具级审批：某个工具调用执行前是否要人放行。
    pub tool_approval: CodeToolApprovalConfig,
    /// 每个 CLI 的开关与可执行文件覆盖。缺省视为**全部启用**，只有显式
    /// `enabled: false` 才禁用——自动路由不受影响，但用户能在编码任务里选择
    /// 本机已装的任何一个 CLI。
    pub providers: std::collections::BTreeMap<String, CodeProviderConfig>,
    /// 任务路由：按形态选 CLI 与模型档位。整节省略时行为等价于"只配一个 provider"。
    pub routing: CodeRoutingConfig,
}

/// 单个 provider 的覆盖项。默认 `enabled = true`；未登记同样按启用处理，
/// 所以这一项真正的作用是"显式关掉某个 CLI"。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeProviderConfig {
    /// 可执行文件；为空走 PATH。worker 不读配置文件，路径由 service 解析后随任务下发。
    pub bin: Option<PathBuf>,
    pub enabled: bool,
}

impl Default for CodeProviderConfig {
    fn default() -> Self {
        Self {
            bin: None,
            enabled: true,
        }
    }
}

/// 任务路由配置（方案 10.2 / 10.5）。
///
/// 判据阈值可配，但**规则形态固定**：单文件脚本 → 快档、多文件 → 强档、
/// 大仓 → 强档。没有"按历史成功率自动换 provider"这一档——那要两周数据之后再说。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeRoutingConfig {
    /// 首选顺序。为空时退化为 `[code.provider]`。
    pub preferred: Vec<String>,
    /// 首选全部不可用时的次选顺序。
    pub fallback: Vec<String>,
    pub tiers: CodeTiers,
    /// 单文件脚本的文件数上限。
    pub single_file_max: usize,
    /// 单文件脚本的需求字数上限。
    pub short_instruction_max: usize,
    /// 大仓重构的文件数门槛。
    pub large_repo_min: usize,
}

impl Default for CodeRoutingConfig {
    fn default() -> Self {
        Self {
            preferred: Vec::new(),
            fallback: Vec::new(),
            tiers: CodeTiers::default(),
            single_file_max: 3,
            short_instruction_max: 200,
            large_repo_min: 200,
        }
    }
}

/// 档位名 → 模型名。留空的档位回退到 `upstream.model`。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeTiers {
    pub fast: Option<String>,
    pub strong: Option<String>,
}

/// 工具级审批的开关与时限。
///
/// 只有支持「工具执行前拦截点」的 provider（当前是 `codebuddy`）会真正生效；
/// 其它 provider 上这几个值只是配置项，行为仍是"跑完再确认合并"。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeToolApprovalConfig {
    pub enabled: bool,
    /// 等人决策的上限。比全局 `approval_ttl_ms` 短得多：工具级等待发生在 CLI 进程
    /// 内部，占着并发位与工作树，等 10 分钟成本太高。
    pub ttl_ms: i64,
    /// 自动放行的风险档。只允许 `read` / `reversible_write`。
    pub auto_allow: Vec<String>,
    /// 必须人工的风险档；目前固定包含 `irreversible_write`，配置只能加不能减。
    pub always_ask: Vec<String>,
    /// 追加的风险规则。只能加严：命中后取 `max(内置档, rule.risk)`，
    /// 因此 `risk = read` 的条目会在启动校验被拒绝。
    pub extra_rules: Vec<protocol::RiskRule>,
}

impl Default for CodeToolApprovalConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            ttl_ms: 120_000,
            auto_allow: vec!["read".to_string()],
            always_ask: vec!["irreversible_write".to_string()],
            extra_rules: Vec::new(),
        }
    }
}

/// 编码任务的模型上游。
///
/// 三个 `Option` 字段为空时回退到 `llm` 的同名项：默认「跟对话用同一个网关」，
/// 但编码任务想单独换模型或换网关时只改这一节，不影响对话。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeUpstreamConfig {
    pub base_url: Option<String>,
    pub model: Option<String>,
    /// 真 key 所在的环境变量名；**只由 service 读取，不下发给 worker**。
    pub api_key_env: Option<String>,
    /// 允许调用的模型；空表示只允许上面那一个。
    pub allowed_models: Vec<String>,
    /// 单次模型请求上限。必须小于 `code.timeout_ms`。
    pub timeout_ms: u64,
}

impl Default for CodeUpstreamConfig {
    fn default() -> Self {
        Self {
            base_url: None,
            model: None,
            api_key_env: None,
            allowed_models: Vec::new(),
            timeout_ms: 120_000,
        }
    }
}

/// 单个编码任务的模型预算。计数发生在代理侧，因为 CLI 自报的用量不完整。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeBudgetConfig {
    pub max_model_calls: u32,
    pub max_tokens: u64,
}

impl Default for CodeBudgetConfig {
    fn default() -> Self {
        Self {
            max_model_calls: 80,
            // 编码 CLI 每一轮都会把**全量上下文**重发一次，累计用量因此是 O(轮数²)：
            // 实测一个「写个计算器网页」的任务，第 1 轮 1.1 万 token、每轮 +1.2 万，
            // 18 轮累计就到 42 万。40 万的门槛意味着十几轮就结束，正常任务根本跑不完。
            // 放宽到 200 万（≈40 轮）仍是一条能兜住失控循环的硬线，成本由 `max_model_calls` 再卡一道。
            max_tokens: 2_000_000,
        }
    }
}

impl Default for CodeConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            provider: "opencode".to_string(),
            allow_roots: Vec::new(),
            worktree_dir: None,
            timeout_ms: None,
            max_concurrent: 1,
            bin: None,
            proxy_bind: "127.0.0.1:0".to_string(),
            upstream: CodeUpstreamConfig::default(),
            budget: CodeBudgetConfig::default(),
            tool_approval: CodeToolApprovalConfig::default(),
            providers: std::collections::BTreeMap::new(),
            routing: CodeRoutingConfig::default(),
        }
    }
}

/// 已实现的编码 provider。
///
/// **只有一份**：注册表在 `protocol`，worker 的 `from_name` 与这里的启动校验同源，
/// 免得出现"服务端允许、worker 造不出来"的两张表。
pub const SUPPORTED_CODE_PROVIDERS: &[&str] = protocol::SUPPORTED_CODE_PROVIDERS;

/// 项目配置。
///
/// 项目绑定的是**服务端这台电脑**上的真实目录，客户端（尤其手机）看不到文件系统，
/// 因此"能浏览到哪些目录"必须由服务端显式限定，不能让客户端传任意路径进来。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ProjectConfig {
    /// 允许浏览与创建项目的根目录；为空时取「用户主目录 + 数据目录」。
    ///
    /// 数据目录始终会被加入（默认项目就落在它下面），不必手写。
    pub browse_roots: Vec<PathBuf>,
    /// 「默认项目」的文档目录；为空取 `{data_dir}/documents`。
    pub documents_dir: Option<PathBuf>,
}

/// `/api/*` 的传输层加密策略。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum TlsMode {
    /// 回环绑定走明文、非回环绑定自动启用 TLS（默认）。
    #[default]
    Auto,
    /// 始终启用 TLS（绑回环也加密，测试用它验证 TLS 路径）。
    On,
    /// 始终明文。非回环绑定必须同时把 `allow_insecure_plaintext` 设成 true。
    Off,
}

/// TLS 配置。
///
/// 默认 `auto`：本机开发与既有测试仍是明文 HTTP，一旦把 `api_bind` 改成
/// `0.0.0.0:8787` 就自动加密，不需要用户再记一个开关。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TlsConfig {
    pub mode: TlsMode,
    /// 非回环绑定 + `mode=off` 时必须显式为 true，否则拒绝启动。
    /// 存在这个开关是为了让"我就想在局域网里跑明文"成为一次显式决定，而不是默认。
    pub allow_insecure_plaintext: bool,
}

/// SSH 隧道的默认终点：服务端本机的 sshd。
pub const DEFAULT_SSH_TARGET: &str = "127.0.0.1:22";

/// SSH 隧道配置。
///
/// 客户端**不直接拨 22 端口**，而是经 `/api/ssh` 的 WebSocket 隧道走到 `target`。
/// 这么做的好处是"能连上的条件"与 `/api/*` 完全一致（同一套鉴权与 TLS 指纹），
/// 不需要为 SSH 额外暴露端口或做端口映射。
///
/// `target` 只允许回环——否则这个端点等于一个"任何已配对设备都能用的任意主机跳板"，
/// 而配对本身并不意味着一台设备可以被允许扫内网。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SshTunnelConfig {
    /// 关闭后 `/api/ssh` 直接返回 `ssh_unavailable`，`/api/ssh/info` 如实报告 false。
    pub enabled: bool,
    /// 隧道终点，必须是回环地址（`127.0.0.1:22` / `[::1]:22` / `localhost:22`）。
    pub target: String,
    /// 同时允许的终端数。超出后直接拒绝：每条隧道都是一个真实 shell 进程。
    pub max_sessions: usize,
}

impl Default for SshTunnelConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            target: DEFAULT_SSH_TARGET.to_string(),
            max_sessions: 4,
        }
    }
}

/// 浏览器隧道默认放行的端口：常见前端 / 后端开发服务器。
///
/// 不放开"任意回环端口"：很多本地管理页信任回环地址、没有密码，
/// 已配对不等于可以扫本机所有服务。用户要加端口就在配置里显式写。
pub const DEFAULT_BROWSER_PORTS: [u16; 10] =
    [3000, 3001, 4173, 5000, 5173, 8000, 8080, 8081, 8888, 9000];

/// 浏览器隧道配置。
///
/// 与 SSH 隧道同构：客户端经 `/api/*` 的 WebSocket 走到服务端本机端口，
/// 鉴权、TLS 指纹与可达性完全复用。差别是目标由客户端按需指定，
/// 所以必须用端口白名单把"任意端口"收窄成"用户显式允许的那几个"。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct BrowserConfig {
    /// 关闭后 `/api/browser/tunnel` 返回 `browser_unavailable`。
    pub enabled: bool,
    /// 允许访问的回环端口白名单。
    pub allowed_ports: Vec<u16>,
    /// 域名白名单。本版只支持回环目标，字段留作扩展位；非空会拒绝启动。
    pub allowed_hosts: Vec<String>,
    /// 全局并发隧道上限（按 TCP 连接计：一个页面通常同时开 6 到 10 条）。
    pub max_tunnels: usize,
    /// 单设备并发隧道上限。必须不大于全局上限。
    pub max_tunnels_per_device: usize,
    /// 连接目标端口的超时。回环连接要么立刻成功要么立刻失败。
    pub connect_timeout_ms: u64,
    /// 双向都没有字节多久后关闭，避免关掉标签后留下悬挂连接。
    pub idle_timeout_ms: u64,
}

impl Default for BrowserConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            allowed_ports: DEFAULT_BROWSER_PORTS.to_vec(),
            allowed_hosts: Vec::new(),
            max_tunnels: 64,
            max_tunnels_per_device: 24,
            connect_timeout_ms: 3_000,
            idle_timeout_ms: 120_000,
        }
    }
}

/// 已实现的转写协议形态。
///
/// - `multimodal`：百炼原生 multimodal-generation（默认，`qwen-audio-3.1-asr-flash`）；
/// - `chat_audio`：OpenAI 兼容 chat completions，音频以 data URL 放进 `input_audio`；
/// - `transcriptions`：OpenAI 兼容 `/audio/transcriptions` 的 multipart；
/// - `mock`：只用于测试与本地验收，不访问网络。
pub const SUPPORTED_ASR_PROVIDERS: &[&str] =
    &["multimodal", "chat_audio", "transcriptions", "mock"];

/// 录音转写配置。
///
/// **密钥只从环境变量读**，与 `llm` 同一条纪律：配置文件里只写变量名。
/// `enabled` 默认为 false：音频要离开本机去厂商，必须由用户显式打开。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AsrConfig {
    pub enabled: bool,
    /// 见 [`SUPPORTED_ASR_PROVIDERS`]。
    pub provider: String,
    /// 兼容根（不含路径）；为空时沿用 `llm.base_url` 的 `/compatible-mode/v1`。
    pub base_url: Option<String>,
    /// 厂商路径；为空时按 provider 取默认值。
    pub path: Option<String>,
    pub model: String,
    /// 读取密钥的环境变量名；为空时沿用 `llm.api_key_env`。
    pub api_key_env: Option<String>,
    /// 识别语言提示；`None` 表示不传，由厂商自动判断。
    pub language: Option<String>,
    /// `chat_audio` 的系统提示词；`multimodal` / `transcriptions` 不使用。
    ///
    /// 只有在退回"通用音频对话模型"（如 `qwen3.8-omni-flash`）时才需要它：
    /// 把模型约束成"只转写、不回答"。真正的 ASR 端点留空即可。
    pub prompt: Option<String>,
    pub timeout_ms: u64,
    /// 同时在跑的转写调用数。上游通常按 RPM 限流，默认 2。
    pub max_concurrency: usize,
}

/// 把通用音频对话模型约束成转写器。换模型时留意它是否遵循 system 提示。
pub const DEFAULT_ASR_PROMPT: &str = "你是语音转写器。只输出音频里实际说出的原话，逐字转写；\
不要回答、不要总结、不要解释、不要翻译，也不要添加引号或前后缀。\
没有语音或听不清时输出空内容。";

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            provider: "multimodal".to_string(),
            base_url: None,
            path: None,
            // 与参考项目一致：百炼原生 ASR 走 multimodal-generation。
            model: "qwen-audio-3.1-asr-flash".to_string(),
            api_key_env: None,
            language: Some("zh".to_string()),
            prompt: None,
            timeout_ms: 60_000,
            max_concurrency: 2,
        }
    }
}

/// 语音合成配置。
///
/// 与 ASR 一样走百炼原生接口，不是 OpenAI 兼容层的 `/audio/speech`。
/// 当前用于录音总结的按需朗读；`enabled` 默认 false，开启后才产生语音文件。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct TtsConfig {
    pub enabled: bool,
    /// 上游 host 根；为空时沿用 `llm.base_url`。
    pub base_url: Option<String>,
    pub path: String,
    pub model: String,
    /// 读取密钥的环境变量名；为空时沿用 `llm.api_key_env`。
    pub api_key_env: Option<String>,
    pub voice: String,
    /// 下发音频格式。三端可播放优先 `mp3`，体积约为 wav 的 42%。
    pub format: String,
    pub sample_rate: u32,
    pub timeout_ms: u64,
    /// 下载临时音频地址的超时。
    pub download_timeout_ms: u64,
    /// 单次合成文本上限；超限按句末截断。
    pub max_text_chars: usize,
    pub max_audio_bytes: i64,
}

impl Default for TtsConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: None,
            path: "/api/v1/services/audio/tts/SpeechSynthesizer".to_string(),
            model: "qwen-audio-3.1-tts-flash".to_string(),
            api_key_env: None,
            voice: "longanhuan_v3.1".to_string(),
            format: "mp3".to_string(),
            sample_rate: 24_000,
            timeout_ms: 120_000,
            download_timeout_ms: 30_000,
            max_text_chars: 2_000,
            max_audio_bytes: 12 * 1024 * 1024,
        }
    }
}

/// 实时双工语音配置。
///
/// 当前只落配置，`jarvis-service` 还没有 WebSocket 桥接，`enabled` 默认 false。
/// 注意 `base_url` 是 https、`ws_base_url` 是 wss，两个 scheme 不能互相替换。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct RealtimeConfig {
    pub enabled: bool,
    /// HTTP(S) host 根；为空时沿用 `llm.base_url`。
    pub base_url: Option<String>,
    /// WebSocket host 根；为空时按 `base_url` 的 scheme 自动换成 ws(s)。
    pub ws_base_url: Option<String>,
    pub ws_path: String,
    /// 专属域名握手失败时的一次性回退地址。
    pub ws_fallback_base_url: Option<String>,
    /// 读取密钥的环境变量名；为空时沿用 `llm.api_key_env`。
    pub api_key_env: Option<String>,
    pub model: String,
    pub voice: String,
    /// `server_vad` / `smart_turn` / `push_to_talk`。
    pub turn_detection: String,
    pub vad_threshold: f32,
    /// 中文句读处容易误切，默认 800ms 而不是 500ms。
    pub vad_silence_ms: u64,
    pub max_history_turns: usize,
    pub instructions: String,
}

impl Default for RealtimeConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: None,
            ws_base_url: None,
            ws_path: "/api-ws/v1/realtime".to_string(),
            ws_fallback_base_url: Some("wss://dashscope.aliyuncs.com".to_string()),
            api_key_env: None,
            model: "qwen-audio-3.0-realtime-flash".to_string(),
            voice: "longanqian".to_string(),
            turn_detection: "server_vad".to_string(),
            vad_threshold: 0.5,
            vad_silence_ms: 800,
            max_history_turns: 20,
            instructions: String::new(),
        }
    }
}

/// 百炼原生端点的默认 host 根。
///
/// 图像与视频只挂在这个域名上，与对话用的专属 MaaS 网关不是同一个 host。
pub const DASHSCOPE_BASE_URL: &str = "https://dashscope.aliyuncs.com";

/// 媒体生成配置：文生图 + 文生视频。
///
/// **不继承 `llm.base_url`**：对话/转写跑在专属 MaaS 网关上，那里没有图像与
/// 视频端点，混用只会得到看不懂的 404。默认关闭，不写这一节不改变任何现有行为。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaConfig {
    pub image: ImageGenConfig,
    pub video: VideoGenConfig,
}

/// 文生图配置。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ImageGenConfig {
    pub enabled: bool,
    /// 上游 host 根（不带路径）。
    pub base_url: String,
    /// 生成路径。`qwen-image-3.0` 挂在 multimodal-generation 上，
    /// **不能**用 `text2image/image-synthesis`：实测那个端点对该模型回 `url error`。
    pub path: String,
    pub model: String,
    /// 读取密钥的环境变量名。密钥不落盘、不进日志。
    pub api_key_env: String,
    /// 出图尺寸，格式 `宽*高`。`1328*1328` 是该模型支持的方形档。
    ///
    /// **这是尺寸的唯一权威**：模型在 `generate_image` 里给不出 `size`，
    /// 只有用户本人在原话里点名（`1024x1024` 之类）时才会按用户的来。
    /// 配置是启动期快照，改完要重启服务才生效（cargo-watch 只监听 `crates/`）。
    pub size: String,
    /// 一次生成调用的往返上限。
    pub timeout_ms: u64,
    /// 下载成图的超时：上游给的是 OSS 签名地址，与生成不是同一条连接。
    pub download_timeout_ms: u64,
    /// 单张图字节上限，超过即放弃落盘。
    pub max_bytes: i64,
}

impl Default for ImageGenConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: DASHSCOPE_BASE_URL.to_string(),
            path: "/api/v1/services/aigc/multimodal-generation/generation".to_string(),
            model: "qwen-image-3.0".to_string(),
            api_key_env: "BAILIAN_API_KEY".to_string(),
            size: "1328*1328".to_string(),
            timeout_ms: 180_000,
            download_timeout_ms: 60_000,
            max_bytes: 20 * 1024 * 1024,
        }
    }
}

/// 文生视频配置。
///
/// 与文生图最大的差别是异步：提交只拿到 `task_id`，成片要轮询任务状态。
/// 因此这里多出轮询间隔与总等待上限，且上限必须大于最长出片时间。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct VideoGenConfig {
    pub enabled: bool,
    /// 上游 host 根（不带路径）。
    pub base_url: String,
    /// 提交异步任务的路径。
    pub path: String,
    /// 任务查询前缀，后面直接拼 `task_id`。
    pub task_path: String,
    pub model: String,
    pub api_key_env: String,
    /// 分辨率档：`480P` / `720P` / `1080P`（上游只认这三个值）。
    ///
    /// **不要写成 `size`**：老协议用 `size` 指定像素，新协议改为 `resolution` +
    /// `ratio`；实测 `size` 会被静默忽略，成片仍是默认的 1080P（多花钱且更难分辨）。
    pub resolution: String,
    /// 宽高比，与分辨率档共同决定输出像素，如 `16:9` / `9:16` / `1:1`。
    pub ratio: String,
    /// 成片时长（秒），上游允许 2–15。
    pub duration_s: u32,
    /// 提交请求的往返上限。
    pub timeout_ms: u64,
    /// 两次轮询之间的间隔。
    pub poll_interval_ms: u64,
    /// 从提交到成片的总等待上限；超时按失败处理并附最后状态。
    pub max_wait_ms: u64,
    /// 下载成片的超时：分钟级任务产出的文件可有几十 MB。
    pub download_timeout_ms: u64,
    /// 单个视频字节上限。
    pub max_bytes: i64,
}

impl Default for VideoGenConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: DASHSCOPE_BASE_URL.to_string(),
            path: "/api/v1/services/aigc/video-generation/video-synthesis".to_string(),
            task_path: "/api/v1/tasks/".to_string(),
            model: "wan3.0-video-prime".to_string(),
            api_key_env: "BAILIAN_API_KEY".to_string(),
            resolution: "480P".to_string(),
            ratio: "16:9".to_string(),
            duration_s: 5,
            timeout_ms: 60_000,
            poll_interval_ms: 5_000,
            max_wait_ms: 15 * 60 * 1000,
            download_timeout_ms: 300_000,
            max_bytes: 300 * 1024 * 1024,
        }
    }
}

/// 录音总结配置。
///
/// 模型与密钥沿用 `llm`：总结和对话走同一个网关，没必要再配一份 Key。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SummaryConfig {
    pub enabled: bool,
    /// 送给模型的转写稿上限；超出按句末截断，避免长录音撑爆上下文。
    pub max_input_chars: usize,
    /// 总结输出上限（token）。
    pub max_tokens: u32,
    /// 同时在跑的总结任务数。
    pub max_concurrency: usize,
    /// 新录音自动生成总结的默认形式。
    pub default_style: SummaryStyle,
}

impl Default for SummaryConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_input_chars: 48_000,
            max_tokens: 1_200,
            max_concurrency: 1,
            default_style: SummaryStyle::Brief,
        }
    }
}

/// 会话上下文压缩配置。
///
/// 模型与密钥沿用 `llm`：整理和对话走同一个网关，没必要再配一份 Key。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CompactionConfig {
    /// 关掉它 = 回到「最近 N 条 + 省略提示」的旧行为。
    pub enabled: bool,
    /// 压缩时保留多少条最新消息不动。
    ///
    /// 必须小于 `context_messages`：否则"触发时保留的条数"就够装配了，
    /// 压缩永远压不出东西来。
    pub keep_messages: usize,
    /// 按窗口占比触发的阈值；分母是模型的 `context_window`。
    pub trigger_ratio: f64,
    /// 送给摘要模型的对话文本上限（字符），避免长会话把一次整理撑成天价请求。
    pub max_input_chars: usize,
    /// 摘要输出上限（token）。
    pub max_tokens: u32,
    /// 单次整理的等待上限。
    pub timeout_ms: u64,
    /// 每个会话保留多少条失败记录（更旧的删掉）。
    pub max_failure_rows: usize,
    /// 上游报「上下文超长」时，是否先压缩再重试一次。
    pub retry_on_overflow: bool,
    /// 一次失败之后多久内不再自动整理（毫秒）。`0` 表示不冷却。
    ///
    /// 自动触发是在每次回答之后判断的：没有冷却时，一个失败的条件会原样
    /// 每轮重试一次，既烧模型调用，也让用户反复看到同一条错误。
    /// 手动「重新整理」不受它限制。
    pub failure_cooldown_ms: u64,
}

impl Default for CompactionConfig {
    fn default() -> Self {
        Self {
            // 只在有模型时生效，所以默认打开：没有模型时它什么也不做。
            enabled: true,
            keep_messages: 8,
            trigger_ratio: 0.75,
            max_input_chars: 24_000,
            // 与录音总结同档：300 字摘要 + 少量余量，800 在中文里偏紧。
            max_tokens: 1_200,
            timeout_ms: 30_000,
            max_failure_rows: 5,
            retry_on_overflow: true,
            failure_cooldown_ms: 600_000,
        }
    }
}

/// 录音归档配额。
///
/// 上限存在的意义是"服务端磁盘不被一次长录悄悄吃满"：客户端会在上传前
/// 按同一组数值提示，超限则返回 `recording_quota_exceeded` 而不是半途失败。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct RecordingConfig {
    /// 单个分段的请求体上限（WAV 字节数）。
    pub max_segment_bytes: i64,
    /// 单条录音的时长上限。
    pub max_duration_ms: i64,
    /// 单条录音的音频总量上限；也是整段下载的拼接上限。
    pub max_total_bytes: i64,
}

impl Default for RecordingConfig {
    fn default() -> Self {
        Self {
            // 30 秒 16k 单声道 PCM16 约 960KB；32MB 留出足够余量给长分段。
            max_segment_bytes: 32 * 1024 * 1024,
            // 4 小时：超过这个长度的"随手录音"已经不属于笔记场景。
            max_duration_ms: 4 * 60 * 60 * 1000,
            // 4 小时 WAV 约 460MB，留到 1GB。
            max_total_bytes: 1024 * 1024 * 1024,
        }
    }
}

/// 允许的检索分词方案。P0 实测锁定 `bigram`（见开发方案 4.3），
/// 另两个保留为可切换的观测口径。
pub const SUPPORTED_MEMORY_TOKENIZERS: &[&str] = &["bigram", "trigram", "unicode61"];

/// 输入框附件（用户粘贴 / 拖入 / 选中的文件与图片）的边界。
///
/// 上限存在的意义与录音配额相同：磁盘与上游请求体都不能被一次误操作吃满。
/// 客户端按同一组数值在本地先拦一次，服务端再判一次——只信客户端等于没边界。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AttachmentConfig {
    /// 单个附件的字节上限。也是上传端点的请求体上限（另加 1MB 余量）。
    pub max_bytes: i64,
    /// 一条消息最多带几个附件。
    pub max_count: usize,
    /// 未发送的附件保留多久（小时）。用户删掉 chip 却没发，文件不该永久留在盘上。
    pub orphan_ttl_hours: u32,
    /// 文本类附件内联进上下文的字节上限（单文件）。
    pub text_excerpt_bytes: usize,
    /// 一轮对话里所有附件摘录的字符总量上限。
    pub prompt_budget_chars: usize,
    /// 单张图片内联成 data URL 的字节上限。超过就只给文件名说明。
    ///
    /// 20MB 的图 base64 之后接近 27MB，远超多数网关的单请求上限；
    /// 真要看清大图，用户该发的是缩放后的截图。
    pub inline_image_max_bytes: i64,
}

impl Default for AttachmentConfig {
    fn default() -> Self {
        Self {
            // 20MB：够放一张原分辨率截图或一份 PDF，再大就不该走聊天输入框。
            max_bytes: 20 * 1024 * 1024,
            // 8 枚：再多就是"把整个文件夹拖进来"，上下文会爆。
            max_count: 8,
            // 24 小时：跨夜还在的草稿该由用户重新选，而不是无限占盘。
            orphan_ttl_hours: 24,
            // 8KB：够看一段配置或一个函数，再多就是在拿附件当知识库。
            text_excerpt_bytes: 8 * 1024,
            // 32K 字符：四五个中等文本文件的量级，已接近一轮上下文的一半。
            prompt_budget_chars: 32 * 1024,
            // 4MB：视觉模型对超大图会自己降采样，传更大的只是白花带宽。
            inline_image_max_bytes: 4 * 1024 * 1024,
        }
    }
}

/// 记忆系统配置（开发方案附录 B.1）。
///
/// 全部有默认值，且 `enabled=false`：升级后不主动注入、不抽取、不打扰。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryConfig {
    /// 总开关。关掉时 `MemoryService` 仍然存在，读写返回 `memory_unavailable`。
    pub enabled: bool,
    pub digest: MemoryDigestConfig,
    pub recall: MemoryRecallConfig,
    pub extract: MemoryExtractConfig,
    pub entity: MemoryEntityConfig,
    pub privacy: MemoryPrivacyConfig,
    pub heartbeat: MemoryHeartbeatConfig,
    pub index: MemoryIndexConfig,
}

/// 常驻摘要的四段预算。四段之和可以大于 `budget_chars`，超出部分按
/// "项目 → 近期 → 画像/偏好"的顺序从尾部截断（置顶永不截断）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryDigestConfig {
    pub enabled: bool,
    pub budget_chars: usize,
    pub profile_chars: usize,
    pub pinned_chars: usize,
    pub recent_chars: usize,
    pub project_chars: usize,
    /// "近期"的时间窗（天）。
    pub recent_days: i64,
}

impl Default for MemoryDigestConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            budget_chars: 1000,
            profile_chars: 400,
            pinned_chars: 300,
            recent_chars: 300,
            project_chars: 200,
            recent_days: 30,
        }
    }
}

/// 召回（P3 的 `memory_recall` 工具）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryRecallConfig {
    pub enabled: bool,
    pub max_results: u32,
    pub max_chars: usize,
    pub weights: MemoryRecallWeights,
}

impl Default for MemoryRecallConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_results: 8,
            max_chars: 2000,
            weights: MemoryRecallWeights::default(),
        }
    }
}

/// 五维打分权重，之和必须是 1.0。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryRecallWeights {
    pub text: f32,
    pub recency: f32,
    pub importance: f32,
    pub scope: f32,
    pub feedback: f32,
}

impl Default for MemoryRecallWeights {
    fn default() -> Self {
        Self {
            text: 0.45,
            recency: 0.20,
            importance: 0.15,
            scope: 0.10,
            feedback: 0.10,
        }
    }
}

impl MemoryRecallWeights {
    pub fn sum(&self) -> f32 {
        self.text + self.recency + self.importance + self.scope + self.feedback
    }
}

/// 自动抽取（P2）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryExtractConfig {
    pub enabled: bool,
    /// 每日最多调用多少次模型。
    pub daily_calls: u32,
    pub max_concurrency: usize,
    pub max_input_chars: usize,
    pub max_candidates_per_turn: usize,
    /// 候选积压上限，超了直接不抽。
    pub pending_limit: usize,
    /// 单条记忆正文的硬上限。
    pub max_content_chars: usize,
    pub confidence_threshold: f32,
}

impl Default for MemoryExtractConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            daily_calls: 50,
            max_concurrency: 1,
            max_input_chars: 12_000,
            max_candidates_per_turn: 5,
            pending_limit: 200,
            max_content_chars: 500,
            confidence_threshold: 0.6,
        }
    }
}

/// 实体（P3）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryEntityConfig {
    pub nightly_limit: usize,
    pub weak_match_threshold: f32,
}

impl Default for MemoryEntityConfig {
    fn default() -> Self {
        Self {
            nightly_limit: 50,
            weak_match_threshold: 0.7,
        }
    }
}

/// 隐私闸。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryPrivacyConfig {
    /// 是否允许项目层记忆进入编码任务。个人层永远禁止。
    pub allow_in_code_tasks: bool,
}

/// 心跳（P4）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryHeartbeatConfig {
    pub enabled: bool,
    pub scan_interval_ms: u64,
    pub nightly_after_hour: u32,
    pub daily_limit: u32,
    /// 静音的通知类别：`due` / `todo` / `digest_report`。
    pub mute: Vec<String>,
    /// 多少天没用过就可以被夜间衰减归档（默认 180 天）。
    ///
    /// 默认值必须让老配置直接生效：升级后不该出现"必须配这一项才能用"。
    pub decay_after_days: u32,
    /// 重要度低于该阈值才归档（默认 0.2）。置顶记忆永不归档。
    pub decay_max_importance: f32,
}

impl Default for MemoryHeartbeatConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            scan_interval_ms: 900_000,
            nightly_after_hour: 3,
            daily_limit: 2,
            mute: Vec::new(),
            decay_after_days: 180,
            decay_max_importance: 0.2,
        }
    }
}

/// 索引方案。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryIndexConfig {
    /// 只允许 `bigram` / `trigram` / `unicode61`；默认 bigram（P0 实测选定）。
    pub tokenizer: String,
}

impl Default for MemoryIndexConfig {
    fn default() -> Self {
        Self {
            tokenizer: "bigram".to_string(),
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: 8790,
            api_bind: DEFAULT_API_BIND.to_string(),
            data_dir: default_data_dir(),
            approval_ttl_ms: 10 * 60 * 1000,
            context_messages: 20,
            tick_interval_ms: 5_000,
            // 与 task 预算对齐：逐步跑模型后，一个任务 15 分钟还没结束就该回收。
            task_timeout_ms: 15 * 60 * 1000,
            llm: LlmConfig::default(),
            task: TaskConfig::default(),
            tool: ToolConfig::default(),
            code: CodeConfig::default(),
            project: ProjectConfig::default(),
            tls: TlsConfig::default(),
            ssh: SshTunnelConfig::default(),
            browser: BrowserConfig::default(),
            asr: AsrConfig::default(),
            tts: TtsConfig::default(),
            realtime: RealtimeConfig::default(),
            media: MediaConfig::default(),
            summary: SummaryConfig::default(),
            compaction: CompactionConfig::default(),
            recording: RecordingConfig::default(),
            attachment: AttachmentConfig::default(),
            memory: MemoryConfig::default(),
            worker_enabled: cfg!(unix),
            worker_path: None,
            worker_max_restarts: 5,
            worker_heartbeat_timeout_ms: 15_000,
            source_path: None,
        }
    }
}

/// 默认数据目录，遵循各平台约定，避免写进仓库目录。
fn default_data_dir() -> PathBuf {
    if cfg!(target_os = "windows") {
        if let Some(base) = std::env::var_os("LOCALAPPDATA") {
            return PathBuf::from(base).join("personal-agent");
        }
    } else if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home)
            .join(".local")
            .join("share")
            .join("personal-agent");
    }
    PathBuf::from(".personal-agent")
}

/// 读一个环境变量里的密钥。未设置、全是空白都算没有。
fn read_env_key(env: &str) -> Option<String> {
    std::env::var(env)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// `host:port` 的主机部分是否指向本机。
///
/// 与 `api_bind` 的判定同口径：能按 `SocketAddr` 解析就信 IP（`127.0.0.0/8`、`::1`），
/// 否则只认 `localhost`。空主机（`:8787`）与 `0.0.0.0` 都按"对外"处理——
/// SSH 隧道与监听地址是两件事，但"是不是本机"必须只有一套判断。
fn is_loopback_host(raw: &str) -> bool {
    let raw = raw.trim();
    if let Ok(addr) = raw.parse::<std::net::SocketAddr>() {
        return addr.ip().is_loopback();
    }
    match raw.rsplit_once(':') {
        Some((host, _)) => host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .eq_ignore_ascii_case("localhost"),
        None => false,
    }
}

/// 从 `host:port` 取端口。解析失败返回 `None`：调用方各自决定怎么报错。
fn bind_port(raw: &str) -> Option<u16> {
    let raw = raw.trim();
    if let Ok(addr) = raw.parse::<std::net::SocketAddr>() {
        return Some(addr.port());
    }
    raw.rsplit_once(':')
        .and_then(|(_, port)| port.parse::<u16>().ok())
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("读取配置文件失败: {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("解析配置文件失败: {path}: {source}")]
    Parse {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
}

impl Config {
    /// SQLite 数据库文件路径。
    pub fn db_path(&self) -> PathBuf {
        self.data_dir.join("agent.db")
    }

    /// 后台运行时的日志文件（daemon-kit 把 stdout/stderr 重定向到这里）。
    pub fn log_path(&self) -> PathBuf {
        self.data_dir.join("service.log")
    }

    /// 管理面本地套接字路径（unix domain socket）。
    #[cfg(unix)]
    pub fn admin_socket_path(&self) -> PathBuf {
        self.data_dir.join("admin.sock")
    }

    /// 管理面令牌文件。仅 Windows 回退路径使用；unix 下保留定义供面板与文档引用。
    #[cfg_attr(unix, allow(dead_code))]
    pub fn admin_token_path(&self) -> PathBuf {
        self.data_dir.join("admin.token")
    }

    /// 服务端身份私钥（Ed25519 种子，base32）。
    pub fn identity_path(&self) -> PathBuf {
        self.data_dir.join("identity.key")
    }

    /// `/api/*` 实际监听端口。绑定端口为 0 时由系统分配，写此文件供客户端发现。
    pub fn api_port_path(&self) -> PathBuf {
        self.data_dir.join("api.port")
    }

    /// 自签 TLS 证书（DER，权威副本）。删除它会在下次启动时换一个新指纹。
    pub fn tls_cert_path(&self) -> PathBuf {
        self.data_dir.join("tls-cert.der")
    }

    /// 同一张证书的 PEM 副本，供 `curl --cacert` 与排障使用（每次启动重写）。
    pub fn tls_cert_pem_path(&self) -> PathBuf {
        self.data_dir.join("tls-cert.pem")
    }

    /// 自签证书的私钥（PKCS#8 DER，0600）。与证书同生共死，不可单独删除。
    pub fn tls_key_path(&self) -> PathBuf {
        self.data_dir.join("tls-key.der")
    }

    /// 产物目录根。产物随数据目录一起保留/清除，不单独管理生命周期。
    pub fn artifacts_dir(&self) -> PathBuf {
        self.data_dir.join(crate::artifact_store::ARTIFACTS_DIR)
    }

    /// 会话草稿目录根：`{data_dir}/drafts/{conversation_id}/`。
    ///
    /// 没有绑定项目的会话把生成的文件放这里。刻意不放进产物目录：
    /// 产物是"一次任务的附件"，草稿是"用户能继续编辑的文件"，两者的清理与
    /// 展示方式不同，混在一起迟早要按前缀猜类型。
    pub fn drafts_dir(&self) -> PathBuf {
        self.data_dir.join(crate::write_store::DRAFTS_DIR)
    }

    /// 覆盖前的备份根：`{data_dir}/file-backups/{conversation_id}/{request_id}/`。
    ///
    /// 备份不能放进项目：那会在用户仓库里凭空出现一批文件，
    /// `git status` 与文件搜索都会把它们当成用户自己的内容。
    pub fn file_backups_dir(&self) -> PathBuf {
        self.data_dir.join(crate::write_store::BACKUPS_DIR)
    }

    /// 录音归档目录根：`{data_dir}/recordings/{recording_id}/seg_XXXXX.wav`。
    pub fn recordings_dir(&self) -> PathBuf {
        self.data_dir.join("recordings")
    }

    /// 输入框附件目录根：`{data_dir}/attachments/{attachment_id}.{ext}`。
    ///
    /// 放在数据目录而不是临时目录：附件要跟会话一起活到用户删会话，
    /// 系统临时目录会被清掉，历史消息里就只剩一颗点不开的 chip。
    pub fn attachments_dir(&self) -> PathBuf {
        self.data_dir.join(crate::attachment::ATTACHMENTS_DIR)
    }

    /// 技能包安装根：`{data_dir}/plugins/{id}/{version}/`。
    ///
    /// 必须放数据目录，不能放 `.app` 里面：macOS 上往已签名 bundle 里加文件会
    /// 破坏签名与公证，沙箱内也不可写。
    pub fn plugins_dir(&self) -> PathBuf {
        self.data_dir.join(crate::plugin::PLUGINS_DIR)
    }

    /// 安装过程中的临时目录：`{data_dir}/plugins/.tmp/`。
    ///
    /// 解压与校验都在这里做，全部通过后才 `rename` 到 [`Self::plugins_dir`] 下的
    /// 正式位置——中途失败只需删掉这个目录，不会留下半截安装。
    pub fn plugin_tmp_dir(&self) -> PathBuf {
        self.plugins_dir().join(crate::plugin::PLUGIN_TMP_DIR)
    }

    /// 主题包安装根：`{data_dir}/themes/<id>/`。
    ///
    /// 与技能包同理必须放数据目录：主题包是用户数据，不能塞进 `.app` 里，
    /// 也不该跟着安装包一起被覆盖。
    pub fn themes_dir(&self) -> PathBuf {
        self.data_dir.join(crate::theme::THEMES_DIR)
    }

    /// 主题包安装过程中的临时目录：`{data_dir}/themes/.tmp/`。
    ///
    /// 解压与校验都在这里做，全部通过后才 `rename` 到正式位置。
    pub fn theme_tmp_dir(&self) -> PathBuf {
        self.themes_dir().join(crate::theme::THEME_TMP_DIR)
    }

    /// 转写上游的兼容根（**不含**具体路径）。
    ///
    /// 默认与对话共用同一个网关的 `/compatible-mode/v1`：录音转写没理由
    /// 再要用户配一份地址与密钥。要换厂商时只改 `asr.base_url`。
    pub fn asr_upstream_base_url(&self) -> String {
        match self.asr.base_url.as_deref() {
            Some(url) => url.trim_end_matches('/').to_string(),
            None => {
                let root = self.llm.base_url.trim_end_matches('/');
                if self.asr.provider == "multimodal" {
                    // 原生接口在 host 根上，不带 `/compatible-mode/v1`。
                    root.to_string()
                } else {
                    format!("{root}/compatible-mode/v1")
                }
            }
        }
    }

    /// 转写路径。三种 provider 的默认端点各不相同。
    pub fn asr_path(&self) -> &str {
        if let Some(path) = self.asr.path.as_deref() {
            return path;
        }
        match self.asr.provider.as_str() {
            "transcriptions" => "/audio/transcriptions",
            "multimodal" => "/api/v1/services/aigc/multimodal-generation/generation",
            _ => "/chat/completions",
        }
    }

    /// 转写密钥所在的环境变量名（默认沿用对话的）。
    pub fn asr_api_key_env(&self) -> &str {
        self.asr
            .api_key_env
            .as_deref()
            .unwrap_or(&self.llm.api_key_env)
    }

    /// 读取转写密钥；未设置或为空返回 None。
    pub fn asr_api_key(&self) -> Option<String> {
        std::env::var(self.asr_api_key_env())
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    /// TTS 上游 host 根。语音合成与 ASR 一样走原生接口，不带兼容前缀。
    pub fn tts_upstream_base_url(&self) -> String {
        self.tts
            .base_url
            .as_deref()
            .map(|url| url.trim_end_matches('/').to_string())
            .unwrap_or_else(|| self.llm.base_url.trim_end_matches('/').to_string())
    }

    /// TTS 密钥所在的环境变量名（默认沿用对话的）。
    pub fn tts_api_key_env(&self) -> &str {
        self.tts
            .api_key_env
            .as_deref()
            .unwrap_or(&self.llm.api_key_env)
    }

    /// 读取 TTS 密钥；未设置或为空返回 None。
    pub fn tts_api_key(&self) -> Option<String> {
        std::env::var(self.tts_api_key_env())
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    /// 文生图上游 host 根（去掉尾部斜杠，便于直接拼 path）。
    pub fn media_image_upstream_base_url(&self) -> &str {
        self.media.image.base_url.trim_end_matches('/')
    }

    /// 文生图密钥所在的环境变量名。
    pub fn media_image_api_key_env(&self) -> &str {
        &self.media.image.api_key_env
    }

    /// 读取文生图密钥；未设置或为空返回 None。
    pub fn media_image_api_key(&self) -> Option<String> {
        read_env_key(self.media_image_api_key_env())
    }

    /// 文生视频上游 host 根（去掉尾部斜杠）。
    pub fn media_video_upstream_base_url(&self) -> &str {
        self.media.video.base_url.trim_end_matches('/')
    }

    /// 文生视频密钥所在的环境变量名。
    pub fn media_video_api_key_env(&self) -> &str {
        &self.media.video.api_key_env
    }

    /// 读取文生视频密钥；未设置或为空返回 None。
    pub fn media_video_api_key(&self) -> Option<String> {
        read_env_key(self.media_video_api_key_env())
    }

    /// 实时语音 HTTP(S) host 根。只用于信息查询等非 WebSocket 调用。
    pub fn realtime_upstream_base_url(&self) -> String {
        self.realtime
            .base_url
            .as_deref()
            .map(|url| url.trim_end_matches('/').to_string())
            .unwrap_or_else(|| self.llm.base_url.trim_end_matches('/').to_string())
    }

    /// 实时语音 WebSocket host 根。
    ///
    /// 显式配置优先；否则把 HTTP(S) 根换成 ws(s)——
    /// `https://host` → `wss://host`、`http://host` → `ws://host`。
    /// 已经是 ws/wss 的原样保留。
    pub fn realtime_ws_base_url(&self) -> String {
        if let Some(url) = self.realtime.ws_base_url.as_deref() {
            return url.trim_end_matches('/').to_string();
        }
        let base = self.realtime_upstream_base_url();
        if let Some(rest) = base.strip_prefix("https://") {
            format!("wss://{rest}")
        } else if let Some(rest) = base.strip_prefix("http://") {
            format!("ws://{rest}")
        } else {
            base
        }
    }

    /// 实时语音密钥所在的环境变量名（默认沿用对话的）。
    pub fn realtime_api_key_env(&self) -> &str {
        self.realtime
            .api_key_env
            .as_deref()
            .unwrap_or(&self.llm.api_key_env)
    }

    /// 读取实时语音密钥；未设置或为空返回 None。
    pub fn realtime_api_key(&self) -> Option<String> {
        std::env::var(self.realtime_api_key_env())
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    /// 编码任务的 worktree 根目录。
    ///
    /// 放在数据目录下而不是仓库旁边：任务失败时整套现场（worktree + 分支 + meta）
    /// 都在一个可整体删除的位置，不会散落进用户的代码目录。
    pub fn code_worktree_dir(&self) -> PathBuf {
        self.code
            .worktree_dir
            .clone()
            .unwrap_or_else(|| self.data_dir.join("worktrees"))
    }

    /// 编码任务整体墙钟上限。
    ///
    /// 默认比 `task_timeout_ms` 少 2 秒：沿用「执行侧必须先于服务侧超时」的既有约定，
    /// 否则真实失败原因会被上游超时吞掉。
    pub fn code_timeout_ms(&self) -> i64 {
        self.code
            .timeout_ms
            .unwrap_or_else(|| (self.task_timeout_ms - 2_000).max(1_000))
    }

    /// 默认项目的文档目录（升级时把历史会话归入这里）。
    pub fn project_documents_dir(&self) -> PathBuf {
        self.project
            .documents_dir
            .clone()
            .unwrap_or_else(|| self.data_dir.join("documents"))
    }

    /// 普通模式可浏览的根目录。
    ///
    /// 未配置时取「用户主目录 + 数据目录」：前者是办公与生活文档的默认位置，
    /// 后者保证默认项目一定在范围内。数据目录永远包含，不依赖用户记得写。
    pub fn project_browse_roots(&self) -> Vec<PathBuf> {
        self.browse_roots_with(&self.project.browse_roots)
    }

    /// Git 模式可浏览的根目录。
    ///
    /// 直接复用 `code.allow_roots`：编码任务的仓库白名单与"能建成 Git 项目的目录"
    /// 必须是同一份清单，否则会出现"能建项目但派不了任务"的错配。
    pub fn project_code_roots(&self) -> Vec<PathBuf> {
        self.browse_roots_with(&self.code.allow_roots)
    }

    /// 规范化并去重根目录：同一目录写两种形式（软链接/相对路径）不该被当成两个根。
    fn browse_roots_with(&self, configured: &[PathBuf]) -> Vec<PathBuf> {
        let mut raw: Vec<PathBuf> = if configured.is_empty() {
            let mut defaults = Vec::new();
            if let Some(home) = std::env::var_os("HOME") {
                defaults.push(PathBuf::from(home));
            }
            defaults
        } else {
            configured.to_vec()
        };
        raw.push(self.data_dir.clone());

        let mut roots: Vec<PathBuf> = Vec::new();
        for candidate in raw {
            let Ok(canonical) = candidate.canonicalize() else {
                continue;
            };
            if !canonical.is_dir() || roots.contains(&canonical) {
                continue;
            }
            roots.push(canonical);
        }
        roots
    }

    /// 该模式下允许浏览与创建项目的根目录。
    pub fn project_roots_for(&self, mode: protocol::ProjectMode) -> Vec<PathBuf> {
        match mode {
            protocol::ProjectMode::Code => self.project_code_roots(),
            protocol::ProjectMode::Work => self.project_browse_roots(),
        }
    }

    /// 编码任务实际使用的上游网关（未单独配置时沿用 `llm.base_url`）。
    /// 上游的 OpenAI 兼容根（**不含** `/chat/completions`）。
    ///
    /// 默认沿用对话网关的路径前缀：`llm.base_url` 只是主机名，真正的兼容端点在
    /// 它的 `/compatible-mode/v1` 下（`llm.rs` 也是这么拼的）。这里曾经直接返回
    /// `llm.base_url`，结果代理把请求发到 `/chat/completions`，网关回 404 ——
    /// "配了 key 却 404" 就是这么来的。
    ///
    /// 显式配置 `code.upstream.base_url` 时请给到兼容根（通常以 `/v1` 结尾），
    /// 代理只会在后面补 `/chat/completions`。
    pub fn code_upstream_base_url(&self) -> String {
        match self.code.upstream.base_url.as_deref() {
            Some(url) => url.trim_end_matches('/').to_string(),
            // 路径前缀跟默认档走：用户把对话模型换成 `/v1` 的第三方网关后，
            // 编码代理不该还在往 `compatible-mode` 上打。
            None => format!(
                "{}{}",
                self.llm.base_url.trim_end_matches('/'),
                self.llm.builtin_profile().normalized_api_path()
            ),
        }
    }

    /// 编码任务实际使用的模型（同时是 opencode 的 `-m personal-agent/<model>`）。
    pub fn code_upstream_model(&self) -> &str {
        self.code
            .upstream
            .model
            .as_deref()
            .unwrap_or(&self.llm.model)
    }

    /// 档位名 → 模型名。未配置档位时回退 `code.upstream.model`（与升级前一致）。
    pub fn code_tier_model(&self, tier: &str) -> String {
        let configured = match tier {
            "fast" => self.code.routing.tiers.fast.as_deref(),
            "strong" => self.code.routing.tiers.strong.as_deref(),
            _ => None,
        };
        configured
            .map(str::to_string)
            .unwrap_or_else(|| self.code_upstream_model().to_string())
    }

    /// 某个 provider 的可执行文件覆盖。
    ///
    /// 优先 `code.providers.<id>.bin`，其次（仅当它就是 `code.provider` 时）`code.bin`：
    /// 老配置只写了 `code.bin`，路由不能因为少了新字段就判它不可用。
    pub fn code_provider_bin(&self, id: &str) -> Option<PathBuf> {
        self.code
            .providers
            .get(id)
            .and_then(|provider| provider.bin.clone())
            .or_else(|| {
                if self.code.provider == id {
                    self.code.bin.clone()
                } else {
                    None
                }
            })
    }

    /// 某个 provider 是否被启用（可用性判据的一半，另一半是可执行文件能解析）。
    ///
    /// **默认启用**：未出现在 `code.providers` 里也视为启用，只有显式
    /// `enabled: false` 才禁用。
    ///
    /// 早期语义是"未登记时只有 `code.provider` 才算启用"，结果用户装了四个 CLI
    /// 却只有一个能被选中，编码任务的执行方式选择器成了假开关。放宽默认值不影响
    /// 自动路由——`router::pick_provider` 仍只按 `routing.preferred` →
    /// `routing.fallback` → `code.provider` 的顺序挑，列表变宽只是让"用户显式
    /// 点名"能生效。
    pub fn code_provider_enabled(&self, id: &str) -> bool {
        self.code
            .providers
            .get(id)
            .map(|provider| provider.enabled)
            .unwrap_or(true)
    }

    /// 编码任务上游密钥所在的环境变量名。
    pub fn code_upstream_api_key_env(&self) -> &str {
        self.code
            .upstream
            .api_key_env
            .as_deref()
            .unwrap_or(&self.llm.api_key_env)
    }

    /// 读取编码任务的上游密钥。只由 service 使用，**不下发给 worker**。
    pub fn code_upstream_api_key(&self) -> Option<String> {
        std::env::var(self.code_upstream_api_key_env())
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    /// 联网查证工具的密钥所在环境变量名。
    pub fn web_tools_api_key_env(&self) -> &str {
        let raw = self.tool.web.api_key_env.trim();
        if raw.is_empty() {
            WEB_TOOLS_DEFAULT_API_KEY_ENV
        } else {
            raw
        }
    }

    /// 读取联网工具的密钥。只由 service 的代理使用，**不下发给 worker**。
    pub fn web_tools_api_key(&self) -> Option<String> {
        std::env::var(self.web_tools_api_key_env())
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    /// 联网工具的实际上游根地址（去掉尾部 `/`）。
    pub fn web_tools_base_url(&self) -> String {
        let raw = self.tool.web.base_url.trim();
        let raw = if raw.is_empty() {
            WEB_TOOLS_DEFAULT_BASE_URL
        } else {
            raw
        };
        raw.trim_end_matches('/').to_string()
    }

    /// **实际生效**的搜索上游。
    ///
    /// 配了 `deepseek` 却没有密钥时降级成 `bing`：这不是启动错误，
    /// 只是"这次没法用付费上游"。降级点只有这一处，worker 拿到的是结果。
    pub fn web_search_provider(&self) -> &str {
        let configured = self.tool.web.search_provider.trim();
        if configured == "deepseek" && self.web_tools_api_key().is_none() {
            return "bing";
        }
        configured
    }

    /// **实际生效**的抓取兜底开关：没密钥时即使配了 true 也关掉。
    pub fn web_fetch_fallback(&self) -> bool {
        self.tool.web.fetch_fallback && self.web_tools_api_key().is_some()
    }

    /// 是否需要启动回环工具代理：只有真正会用付费上游时才起，不白占一个端口。
    pub fn web_tools_proxy_needed(&self) -> bool {
        self.web_search_provider() == "deepseek" || self.web_fetch_fallback()
    }

    /// service 与 worker 之间的本地套接字。权限 0600，不监听网络。
    pub fn worker_socket_path(&self) -> PathBuf {
        self.data_dir.join("worker.sock")
    }

    /// worker 二进制路径：配置优先，其次取当前可执行文件同目录。
    pub fn worker_binary(&self) -> PathBuf {
        if let Some(path) = &self.worker_path {
            return path.clone();
        }
        let name = if cfg!(windows) {
            "jarvis-worker.exe"
        } else {
            "jarvis-worker"
        };
        std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|dir| dir.join(name)))
            .unwrap_or_else(|| PathBuf::from(name))
    }

    /// 绑定地址是否只对本机可见。
    ///
    /// 判定顺序：能按 `SocketAddr` 解析就信 IP（`127.0.0.0/8`、`::1` 都算回环），
    /// 否则只认 `localhost`。空主机（`:8787`）与 `0.0.0.0` 一律按"对外"处理——
    /// 宁可多要一次 TLS，也不要默认把端口暴露到局域网上。
    pub fn is_loopback_bind(&self) -> bool {
        is_loopback_host(&self.api_bind)
    }

    /// 本次启动是否需要 TLS：`on` 总是；`auto` 看绑定地址是否非回环。
    pub fn tls_required(&self) -> bool {
        match self.tls.mode {
            TlsMode::On => true,
            TlsMode::Off => false,
            TlsMode::Auto => !self.is_loopback_bind(),
        }
    }

    /// 启动前的配置自检。
    ///
    /// 返回的字符串会直接打印给用户，所以写成"出了什么问题 + 该怎么改"，
    /// 不要只说"配置非法"。
    pub fn validate(&self) -> Result<(), String> {
        let raw = self.api_bind.trim();
        if raw.is_empty() {
            return Err("api_bind 不能为空；本机使用请填 \"127.0.0.1:8787\"".to_string());
        }
        if !raw.contains(':') {
            return Err(format!(
                "api_bind 格式应为 host:port，当前是 \"{raw}\"；例如 \"127.0.0.1:8787\" 或 \"0.0.0.0:8787\""
            ));
        }
        if !self.is_loopback_bind() && !self.tls_required() && !self.tls.allow_insecure_plaintext {
            return Err(format!(
                "api_bind={raw} 会监听非本机地址，但 tls.mode=off：拒绝以明文对外暴露。\
                 去掉 tls 配置（auto 会自动生成自签证书），\
                 或确需明文时显式设置 \"tls\": {{\"mode\":\"off\",\"allow_insecure_plaintext\":true}}"
            ));
        }
        self.validate_models()?;
        self.validate_code()?;
        self.validate_web_tools()?;
        self.validate_project()?;
        self.validate_ssh()?;
        self.validate_browser()?;
        self.validate_asr()?;
        self.validate_tts()?;
        self.validate_media()?;
        self.validate_realtime()?;
        self.validate_summary()?;
        self.validate_compaction()?;
        self.validate_memory()?;
        self.validate_recording()
    }

    /// 联网查证工具自检。
    ///
    /// 只拦"结构性错误"：写错的上游名、会暴露密钥的绑定地址、倒过来的超时。
    /// **缺密钥不拦启动**——查证是可选能力，少一把钥匙不该让整个服务起不来，
    /// 降级逻辑见 [`Self::web_search_provider`] / [`Self::web_fetch_fallback`]。
    fn validate_web_tools(&self) -> Result<(), String> {
        let provider = self.tool.web.search_provider.trim();
        if !SUPPORTED_SEARCH_PROVIDERS.contains(&provider) {
            return Err(format!(
                "tool.web.search_provider=\"{provider}\" 未实现；当前只支持 {}",
                SUPPORTED_SEARCH_PROVIDERS.join(" / ")
            ));
        }

        let raw = self.tool.web.proxy_bind.trim();
        let addr = raw.parse::<std::net::SocketAddr>().map_err(|_| {
            format!("tool.web.proxy_bind=\"{raw}\" 不是合法的 host:port；应形如 \"127.0.0.1:0\"")
        })?;
        if !addr.ip().is_loopback() {
            return Err(format!(
                "tool.web.proxy_bind={raw} 不是回环地址：代理会代持联网工具的密钥，\
                 只能监听 127.0.0.1"
            ));
        }

        let timeout = self.tool.web.timeout_ms;
        let ceiling = self.tool.call_timeout_ms.saturating_sub(1_000);
        if timeout == 0 || timeout > ceiling {
            return Err(format!(
                "tool.web.timeout_ms={timeout} 必须大于 0 且至少比 tool.call_timeout_ms={} \
                 小 1 秒：外层先超时会把真实失败原因吞掉",
                self.tool.call_timeout_ms
            ));
        }

        let base = self.web_tools_base_url();
        if !base.starts_with("https://") && !base.starts_with("http://") {
            return Err(format!(
                "tool.web.base_url=\"{base}\" 应以 https:// 开头（默认 {WEB_TOOLS_DEFAULT_BASE_URL}）"
            ));
        }
        if base.starts_with("http://") {
            let host = base
                .trim_start_matches("http://")
                .split(['/', ':'])
                .next()
                .unwrap_or("");
            if host != "127.0.0.1" && host != "localhost" {
                return Err(format!(
                    "tool.web.base_url={base} 用明文 http 时只能是回环地址（本地测试用）；\
                     正式环境请用 https://"
                ));
            }
        }

        if self.tool.web.search_provider.trim() == "deepseek" && self.web_tools_api_key().is_none() {
            tracing::warn!(
                env = self.web_tools_api_key_env(),
                "tool.web.search_provider=deepseek 但密钥为空：本次运行降级为 Bing 搜索"
            );
        }
        if self.tool.web.fetch_fallback && self.web_tools_api_key().is_none() {
            tracing::warn!(
                env = self.web_tools_api_key_env(),
                "tool.web.fetch_fallback=true 但密钥为空：本次运行不启用兜底抓取"
            );
        }

        Ok(())
    }

    /// 模型配置自检。
    ///
    /// 只查"结构性错误"：id 缺失/重复/占了默认档的名字。地址写错、密钥没填
    /// 都不拦启动——那是运行期可恢复的不可用，把服务卡在启动失败上只会更糟。
    fn validate_models(&self) -> Result<(), String> {
        let mut seen = std::collections::HashSet::new();
        for profile in &self.llm.profiles {
            let id = profile.id.trim();
            if id.is_empty() {
                return Err(
                    "llm.profiles 里有空的 id：每份模型配置都要有稳定标识，请用客户端重新保存"
                        .to_string(),
                );
            }
            if id == DEFAULT_PROFILE_ID {
                return Err(format!(
                    "llm.profiles 里的 id 不能是 \"{DEFAULT_PROFILE_ID}\"：那是配置文件主节（默认档）的保留 id"
                ));
            }
            if !id
                .chars()
                .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-' || ch == '_')
            {
                return Err(format!(
                    "llm.profiles 里的 id \"{id}\" 只能包含小写字母、数字、`-` 与 `_`"
                ));
            }
            if !seen.insert(id.to_string()) {
                return Err(format!("llm.profiles 里的 id \"{id}\" 重复"));
            }
        }
        Ok(())
    }

    /// 记忆配置自检。`enabled=false` 时整节跳过：没启用不该拦住启动。
    ///
    /// 与其它节的区别：这里有两类问题只**警告**不报错——一类是代码本身能安全处理
    /// 的（分区之和超过总预算 → 从尾部截断），一类是用户明确打开的能力
    /// （项目记忆进编码任务）。把能跑的情况做成启动失败，只会让人去关掉整个功能。
    fn validate_memory(&self) -> Result<(), String> {
        if !self.memory.enabled {
            return Ok(());
        }

        let digest = &self.memory.digest;
        if !(400..=2000).contains(&digest.budget_chars) {
            return Err(format!(
                "memory.digest.budget_chars={} 应为 400–2000",
                digest.budget_chars
            ));
        }
        let sections =
            digest.profile_chars + digest.pinned_chars + digest.recent_chars + digest.project_chars;
        if sections > digest.budget_chars {
            tracing::warn!(
                sections,
                budget = digest.budget_chars,
                "记忆摘要的四个分区之和超过总预算，超出部分会按「项目 → 近期 → 画像/偏好」截断"
            );
        }
        if digest.recent_days <= 0 {
            return Err("memory.digest.recent_days 必须大于 0".to_string());
        }

        let recall = &self.memory.recall;
        if !(1..=8).contains(&recall.max_results) {
            return Err(format!(
                "memory.recall.max_results={} 最大 8：再多会挤占推理空间",
                recall.max_results
            ));
        }
        if !(200..=2000).contains(&recall.max_chars) {
            return Err(format!(
                "memory.recall.max_chars={} 应为 200–2000",
                recall.max_chars
            ));
        }
        let sum = recall.weights.sum();
        if !(0.99..=1.01).contains(&sum) {
            return Err(format!(
                "memory.recall.weights 五项之和应为 1.0，当前 {sum:.3}"
            ));
        }

        let extract = &self.memory.extract;
        if !(1..=200).contains(&extract.daily_calls) {
            return Err(format!(
                "memory.extract.daily_calls={} 应为 1–200",
                extract.daily_calls
            ));
        }
        if !(1000..=32_000).contains(&extract.max_input_chars) {
            return Err(format!(
                "memory.extract.max_input_chars={} 应为 1000–32000",
                extract.max_input_chars
            ));
        }
        if !(0.0..=1.0).contains(&extract.confidence_threshold) {
            return Err(format!(
                "memory.extract.confidence_threshold={} 应为 0.0–1.0",
                extract.confidence_threshold
            ));
        }
        if extract.max_content_chars == 0 || extract.max_content_chars > 2000 {
            return Err(format!(
                "memory.extract.max_content_chars={} 应为 1–2000",
                extract.max_content_chars
            ));
        }
        if extract.max_concurrency == 0 {
            return Err("memory.extract.max_concurrency 不能为 0".to_string());
        }

        if !(1..=200).contains(&self.memory.entity.nightly_limit) {
            return Err(format!(
                "memory.entity.nightly_limit={} 应为 1–200",
                self.memory.entity.nightly_limit
            ));
        }

        let heartbeat = &self.memory.heartbeat;
        if heartbeat.scan_interval_ms < 60_000 {
            return Err(format!(
                "memory.heartbeat.scan_interval_ms={} 不建议低于 60000：\
                 心跳不是安全网，快没有意义",
                heartbeat.scan_interval_ms
            ));
        }
        if heartbeat.daily_limit > 10 {
            return Err(format!(
                "memory.heartbeat.daily_limit={} 应为 0–10",
                heartbeat.daily_limit
            ));
        }

        let tokenizer = self.memory.index.tokenizer.trim();
        if !SUPPORTED_MEMORY_TOKENIZERS.contains(&tokenizer) {
            return Err(format!(
                "memory.index.tokenizer=\"{tokenizer}\" 只支持 {}",
                SUPPORTED_MEMORY_TOKENIZERS.join(" / ")
            ));
        }

        if self.memory.privacy.allow_in_code_tasks {
            tracing::warn!(
                "已允许项目层记忆进入编码任务；个人层记忆仍然禁止进入编码任务的 guidance"
            );
        }

        Ok(())
    }

    /// 转写配置自检。`enabled=false` 时跳过：没启用不该拦住启动。
    fn validate_asr(&self) -> Result<(), String> {
        if !self.asr.enabled {
            return Ok(());
        }
        if !SUPPORTED_ASR_PROVIDERS.contains(&self.asr.provider.as_str()) {
            return Err(format!(
                "asr.provider=\"{}\" 未实现；当前只支持 {}",
                self.asr.provider,
                SUPPORTED_ASR_PROVIDERS.join(" / ")
            ));
        }
        if self.asr.provider != "mock" && self.asr_api_key().is_none() {
            return Err(format!(
                "asr.enabled=true 但环境变量 {} 为空：转写要访问模型厂商，\
                 请提供密钥，或把 asr.enabled 关掉（此时录音只归档、不出文本）",
                self.asr_api_key_env()
            ));
        }
        if self.asr.model.trim().is_empty() {
            return Err("asr.model 不能为空；例如 \"qwen-audio-3.1-asr-flash\"".to_string());
        }
        if self.asr.timeout_ms == 0 {
            return Err("asr.timeout_ms 不能为 0".to_string());
        }
        if self.asr.max_concurrency == 0 {
            return Err("asr.max_concurrency 不能为 0；至少留 1，否则转写永远排队".to_string());
        }
        if self.asr.max_concurrency > 8 {
            return Err(format!(
                "asr.max_concurrency={} 过大：上游通常按 RPM 限流，请控制在 8 以内",
                self.asr.max_concurrency
            ));
        }
        let path = self.asr_path();
        if path.trim().is_empty() || !path.starts_with('/') {
            return Err(format!(
                "asr.path=\"{path}\" 应以 / 开头（拼在 asr.base_url 之后）"
            ));
        }
        Ok(())
    }

    /// 语音合成配置自检。`enabled=false` 时跳过。
    fn validate_tts(&self) -> Result<(), String> {
        if !self.tts.enabled {
            return Ok(());
        }
        if self.tts.model.trim().is_empty() {
            return Err("tts.model 不能为空；例如 \"qwen-audio-3.1-tts-flash\"".to_string());
        }
        if !self.tts.path.starts_with('/') {
            return Err(format!(
                "tts.path=\"{}\" 应以 / 开头（拼在 tts.base_url 之后）",
                self.tts.path
            ));
        }
        if self.tts.voice.trim().is_empty() {
            return Err("tts.voice 不能为空".to_string());
        }
        if self.tts.format.trim().is_empty() {
            return Err("tts.format 不能为空（常用 mp3 / wav）".to_string());
        }
        if self.tts.sample_rate == 0 {
            return Err("tts.sample_rate 必须大于 0".to_string());
        }
        if self.tts.timeout_ms == 0 || self.tts.download_timeout_ms == 0 {
            return Err("tts.timeout_ms / download_timeout_ms 不能为 0".to_string());
        }
        if self.tts.max_text_chars == 0 {
            return Err("tts.max_text_chars 不能为 0".to_string());
        }
        if self.tts.max_audio_bytes <= 0 {
            return Err("tts.max_audio_bytes 必须大于 0".to_string());
        }
        if self.tts_api_key().is_none() {
            return Err(format!(
                "tts.enabled=true 但环境变量 {} 为空：语音合成要访问模型厂商",
                self.tts_api_key_env()
            ));
        }
        Ok(())
    }

    /// 媒体生成配置自检。两节各自按 `enabled` 跳过。
    ///
    /// 这里校验的是"跑起来会立刻失败"的那几项：模型名、路径前缀、密钥。
    /// 尺寸档位不在这里拦——上游接受哪些档会变，硬编码一份白名单只会
    /// 把新的可用档一起拒掉。
    fn validate_media(&self) -> Result<(), String> {
        if !self.media.image.enabled && !self.media.video.enabled {
            return Ok(());
        }

        // 额度先校验：它不依赖密钥，且一旦为 0 等于"打开了一个可以无限花钱的功能"。
        if self.tool.max_media_calls_per_turn == 0 {
            return Err(
                "tool.max_media_calls_per_turn 不能为 0：媒体生成是付费请求，必须限额".to_string(),
            );
        }
        if self.tool.media_call_timeout_ms == 0 || self.tool.media_turn_budget_ms == 0 {
            return Err("tool.media_call_timeout_ms / media_turn_budget_ms 不能为 0".to_string());
        }
        if self.tool.media_turn_budget_ms < self.tool.media_call_timeout_ms {
            return Err(
                "tool.media_turn_budget_ms 不能小于 media_call_timeout_ms（单次都等不完）"
                    .to_string(),
            );
        }

        if self.media.image.enabled {
            let image = &self.media.image;
            if image.model.trim().is_empty() {
                return Err("media.image.model 不能为空；例如 \"qwen-image-3.0\"".to_string());
            }
            if !image.path.starts_with('/') {
                return Err(format!(
                    "media.image.path=\"{}\" 应以 / 开头（拼在 base_url 之后）",
                    image.path
                ));
            }
            if image.size.trim().is_empty() {
                return Err("media.image.size 不能为空；例如 \"1328*1328\"".to_string());
            }
            if image.timeout_ms == 0 || image.download_timeout_ms == 0 {
                return Err("media.image.timeout_ms / download_timeout_ms 不能为 0".to_string());
            }
            if image.max_bytes <= 0 {
                return Err("media.image.max_bytes 必须大于 0".to_string());
            }
            if self.media_image_api_key().is_none() {
                return Err(format!(
                    "media.image.enabled=true 但环境变量 {} 为空：出图要访问百炼",
                    self.media_image_api_key_env()
                ));
            }
        }

        if self.media.video.enabled {
            let video = &self.media.video;
            if video.model.trim().is_empty() {
                return Err("media.video.model 不能为空；例如 \"wan3.0-video-prime\"".to_string());
            }
            if !video.path.starts_with('/') {
                return Err(format!(
                    "media.video.path=\"{}\" 应以 / 开头（拼在 base_url 之后）",
                    video.path
                ));
            }
            if !video.task_path.starts_with('/') {
                return Err(format!(
                    "media.video.task_path=\"{}\" 应以 / 开头（拼上 task_id 用于轮询）",
                    video.task_path
                ));
            }
            if video.resolution.trim().is_empty() {
                return Err("media.video.resolution 不能为空；例如 \"480P\"".to_string());
            }
            if video.ratio.trim().is_empty() {
                return Err("media.video.ratio 不能为空；例如 \"16:9\"".to_string());
            }
            if video.duration_s == 0 {
                return Err("media.video.duration_s 必须大于 0".to_string());
            }
            if video.timeout_ms == 0 || video.download_timeout_ms == 0 {
                return Err("media.video.timeout_ms / download_timeout_ms 不能为 0".to_string());
            }
            if video.poll_interval_ms == 0 {
                return Err("media.video.poll_interval_ms 不能为 0".to_string());
            }
            if video.max_wait_ms < video.poll_interval_ms {
                return Err("media.video.max_wait_ms 不能小于 poll_interval_ms".to_string());
            }
            if video.max_bytes <= 0 {
                return Err("media.video.max_bytes 必须大于 0".to_string());
            }
            if self.media_video_api_key().is_none() {
                return Err(format!(
                    "media.video.enabled=true 但环境变量 {} 为空：出片要访问百炼",
                    self.media_video_api_key_env()
                ));
            }
        }

        Ok(())
    }

    /// 实时语音配置自检。`enabled=false` 时跳过。
    fn validate_realtime(&self) -> Result<(), String> {
        if !self.realtime.enabled {
            return Ok(());
        }
        if self.realtime.model.trim().is_empty() {
            return Err(
                "realtime.model 不能为空；例如 \"qwen-audio-3.0-realtime-flash\"".to_string(),
            );
        }
        if !self.realtime.ws_path.starts_with('/') {
            return Err(format!(
                "realtime.ws_path=\"{}\" 应以 / 开头",
                self.realtime.ws_path
            ));
        }
        let ws_base = self.realtime_ws_base_url();
        if !(ws_base.starts_with("ws://") || ws_base.starts_with("wss://")) {
            return Err(format!(
                "realtime WebSocket 地址必须使用 ws:// 或 wss://，当前是 {ws_base}"
            ));
        }
        if self.realtime.voice.trim().is_empty() {
            return Err("realtime.voice 不能为空".to_string());
        }
        if !matches!(
            self.realtime.turn_detection.as_str(),
            "server_vad" | "smart_turn" | "push_to_talk"
        ) {
            return Err(format!(
                "realtime.turn_detection=\"{}\" 不支持；可选 server_vad / smart_turn / push_to_talk",
                self.realtime.turn_detection
            ));
        }
        if !self.realtime.vad_threshold.is_finite()
            || !(0.0..=1.0).contains(&self.realtime.vad_threshold)
        {
            return Err("realtime.vad_threshold 必须在 0..=1 之间".to_string());
        }
        if self.realtime.vad_silence_ms == 0 {
            return Err("realtime.vad_silence_ms 不能为 0".to_string());
        }
        if self.realtime.max_history_turns == 0 {
            return Err("realtime.max_history_turns 不能为 0".to_string());
        }
        if self.realtime_api_key().is_none() {
            return Err(format!(
                "realtime.enabled=true 但环境变量 {} 为空：实时语音要访问模型厂商",
                self.realtime_api_key_env()
            ));
        }
        Ok(())
    }

    /// 录音总结配置自检。`enabled=false` 时跳过。
    fn validate_summary(&self) -> Result<(), String> {
        if !self.summary.enabled {
            return Ok(());
        }
        if self.summary.max_input_chars < 1_000 {
            return Err("summary.max_input_chars 过小：至少留 1000 字上下文".to_string());
        }
        if self.summary.max_tokens == 0 {
            return Err("summary.max_tokens 不能为 0".to_string());
        }
        if self.summary.max_concurrency == 0 {
            return Err("summary.max_concurrency 不能为 0".to_string());
        }
        if self.summary.max_concurrency > 4 {
            return Err("summary.max_concurrency 过大：请控制在 4 以内".to_string());
        }
        Ok(())
    }

    /// 上下文压缩配置自检。`enabled=false` 时跳过：关掉之后这些数值没有意义。
    fn validate_compaction(&self) -> Result<(), String> {
        let compaction = &self.compaction;
        if !compaction.enabled {
            return Ok(());
        }
        if compaction.keep_messages < 2 {
            return Err(
                "compaction.keep_messages 过小：至少保留 2 条最近消息，否则模型接不上话"
                    .to_string(),
            );
        }
        if compaction.keep_messages >= self.context_messages {
            return Err(format!(
                "compaction.keep_messages={} 必须小于 context_messages={}：\
                 否则触发压缩时保留的条数已经够装配，永远压不出东西来",
                compaction.keep_messages, self.context_messages
            ));
        }
        if !(compaction.trigger_ratio > 0.0 && compaction.trigger_ratio <= 1.0) {
            return Err(format!(
                "compaction.trigger_ratio={} 不在 (0, 1] 之间：它是窗口占比，1.0 表示用满才压",
                compaction.trigger_ratio
            ));
        }
        if compaction.max_input_chars < 1_000 {
            return Err("compaction.max_input_chars 过小：至少留 1000 字给摘要输入".to_string());
        }
        if compaction.max_tokens == 0 {
            return Err("compaction.max_tokens 不能为 0".to_string());
        }
        if compaction.max_failure_rows == 0 {
            return Err("compaction.max_failure_rows 不能为 0：至少要留一条失败记录".to_string());
        }
        if !(1_000..=300_000).contains(&compaction.timeout_ms) {
            return Err(format!(
                "compaction.timeout_ms={} 不在 1000~300000 之间：单次整理是秒级操作",
                compaction.timeout_ms
            ));
        }
        // 0 = 不冷却；上限一天，避免手滑写出一个"再也不会自动整理"的值。
        if compaction.failure_cooldown_ms > 86_400_000 {
            return Err(format!(
                "compaction.failure_cooldown_ms={} 超过 24 小时：冷却太久等于关掉自动整理，\
                 想关请用 compaction.enabled=false",
                compaction.failure_cooldown_ms
            ));
        }
        Ok(())
    }

    /// 录音配额自检。即使没开转写也要检查：归档本身就会写磁盘。
    fn validate_recording(&self) -> Result<(), String> {
        let recording = &self.recording;
        if recording.max_segment_bytes < 1024 {
            return Err(
                "recording.max_segment_bytes 过小（< 1024）：至少能放下一个 WAV 头".to_string(),
            );
        }
        if recording.max_total_bytes < recording.max_segment_bytes {
            return Err(format!(
                "recording.max_total_bytes={} 不能小于 max_segment_bytes={}",
                recording.max_total_bytes, recording.max_segment_bytes
            ));
        }
        if recording.max_duration_ms <= 0 {
            return Err("recording.max_duration_ms 必须大于 0".to_string());
        }
        Ok(())
    }

    /// 浏览器隧道必须拒绝的端口：SSH、`/api` 自身、编码代理。
    ///
    /// 这些端口不是"网页"：放进来要么绕过 SSH 的专属限流，要么让浏览器面板
    /// 直接打到内部接口上。即使白名单里写了也不放行。
    pub fn browser_reserved_ports(&self) -> Vec<u16> {
        let mut ports = vec![22u16];
        if let Some(port) = bind_port(&self.api_bind) {
            if port != 0 {
                ports.push(port);
            }
        }
        if self.code.enabled {
            if let Some(port) = bind_port(&self.code.proxy_bind) {
                if port != 0 {
                    ports.push(port);
                }
            }
        }
        ports.sort_unstable();
        ports.dedup();
        ports
    }

    /// 浏览器隧道自检。`enabled=false` 时一律跳过——没启用就不该拦住启动。
    fn validate_browser(&self) -> Result<(), String> {
        if !self.browser.enabled {
            return Ok(());
        }

        if !self.browser.allowed_hosts.is_empty() {
            return Err(
                "browser.allowed_hosts 本版不支持：浏览器隧道只允许回环目标，请清空该字段"
                    .to_string(),
            );
        }

        if self.browser.allowed_ports.is_empty() {
            return Err(
                "browser.allowed_ports 不能为空：至少列出一个允许访问的回环端口（如 3000 / 5173）"
                    .to_string(),
            );
        }

        let reserved = self.browser_reserved_ports();
        for port in &self.browser.allowed_ports {
            if *port == 0 {
                return Err("browser.allowed_ports 不能包含 0：请填写真实监听端口".to_string());
            }
            if reserved.contains(port) {
                return Err(format!(
                    "browser.allowed_ports 不能包含 {port}：22、/api 自身端口与编码代理端口不对浏览器开放"
                ));
            }
        }

        if self.browser.max_tunnels == 0 {
            return Err(
                "browser.max_tunnels 不能为 0；想彻底关掉浏览器隧道请设 \"browser\": {\"enabled\": false}"
                    .to_string(),
            );
        }
        if self.browser.max_tunnels > 128 {
            return Err(format!(
                "browser.max_tunnels={} 过大：一个页面通常同时开 6 到 10 条连接，请控制在 128 以内",
                self.browser.max_tunnels
            ));
        }
        if self.browser.max_tunnels_per_device == 0 {
            return Err("browser.max_tunnels_per_device 不能为 0".to_string());
        }
        if self.browser.max_tunnels_per_device > self.browser.max_tunnels {
            return Err(format!(
                "browser.max_tunnels_per_device={} 不能大于 browser.max_tunnels={}",
                self.browser.max_tunnels_per_device, self.browser.max_tunnels
            ));
        }
        if self.browser.connect_timeout_ms == 0 {
            return Err("browser.connect_timeout_ms 不能为 0".to_string());
        }
        if self.browser.idle_timeout_ms == 0 {
            return Err("browser.idle_timeout_ms 不能为 0".to_string());
        }
        Ok(())
    }

    /// SSH 隧道自检。
    ///
    /// 只允许回环终点：隧道把"已配对设备"直接接到一台机器的 shell 上，
    /// 如果终点可以是任意地址，它就成了一个免审计的内网跳板。
    /// `enabled=false` 时不做任何检查——没启用就不该拦住启动。
    fn validate_ssh(&self) -> Result<(), String> {
        if !self.ssh.enabled {
            return Ok(());
        }

        let target = self.ssh.target.trim();
        if target.is_empty() {
            return Err("ssh.target 不能为空；本机 sshd 请填 \"127.0.0.1:22\"".to_string());
        }
        if !target.contains(':') {
            return Err(format!(
                "ssh.target 格式应为 host:port，当前是 \"{target}\"；例如 \"127.0.0.1:22\""
            ));
        }
        if !is_loopback_host(target) {
            return Err(format!(
                "ssh.target={target} 不是回环地址：SSH 隧道只允许连本机 sshd，\
                 否则这台机器会变成任意主机的跳板。请改成 \"{DEFAULT_SSH_TARGET}\""
            ));
        }
        if self.ssh.max_sessions == 0 {
            return Err(
                "ssh.max_sessions 不能为 0；想彻底关掉 SSH 隧道请设 \"ssh\": {\"enabled\": false}"
                    .to_string(),
            );
        }
        if self.ssh.max_sessions > 16 {
            return Err(format!(
                "ssh.max_sessions={} 过大：每条隧道都是一个真实 shell 进程，请控制在 16 以内",
                self.ssh.max_sessions
            ));
        }
        Ok(())
    }

    /// 项目配置自检。
    ///
    /// `browse_roots` 为空是合法的（回退到主目录 + 数据目录），但**显式写了的根目录必须存在**：
    /// 配错了还照常启动，用户会看到"项目列表是空的"，而不会知道是路径写错了。
    fn validate_project(&self) -> Result<(), String> {
        for root in &self.project.browse_roots {
            let canonical = root.canonicalize().map_err(|err| {
                format!(
                    "project.browse_roots 里的 \"{}\" 无法访问：{err}；请填写真实存在的目录",
                    root.display()
                )
            })?;
            if !canonical.is_dir() {
                return Err(format!(
                    "project.browse_roots 里的 \"{}\" 不是目录",
                    root.display()
                ));
            }
        }
        Ok(())
    }

    /// 编码任务的配置自检。`code.enabled=false` 时一律跳过——没启用就不该拦住启动。
    fn validate_code(&self) -> Result<(), String> {
        if !self.code.enabled {
            return Ok(());
        }

        if !SUPPORTED_CODE_PROVIDERS.contains(&self.code.provider.as_str()) {
            return Err(format!(
                "code.provider=\"{}\" 未实现；当前只支持 {}。\
                 新增 provider 需要在 protocol 的 SUPPORTED_CODE_PROVIDERS 注册，\
                 并在 jarvis-worker/src/code/provider/ 下加实现",
                self.code.provider,
                SUPPORTED_CODE_PROVIDERS.join(" / ")
            ));
        }

        // providers：只允许已注册的 id，配了 bin 就必须真实存在（否则任务会在运行时
        // 才发现"找不到可执行文件"，而那时工作树已经建好了）。
        for (id, provider) in &self.code.providers {
            if !SUPPORTED_CODE_PROVIDERS.contains(&id.as_str()) {
                return Err(format!(
                    "code.providers.\"{id}\" 未实现；当前只支持 {}",
                    SUPPORTED_CODE_PROVIDERS.join(" / ")
                ));
            }
            if let Some(bin) = &provider.bin {
                if !bin.is_file() {
                    return Err(format!(
                        "code.providers.{id}.bin=\"{}\" 不存在或不是文件",
                        bin.display()
                    ));
                }
            }
        }

        // routing：顺序表里的 id 必须已注册且不重复。
        for (label, ids) in [
            ("code.routing.preferred", &self.code.routing.preferred),
            ("code.routing.fallback", &self.code.routing.fallback),
        ] {
            let mut seen = std::collections::HashSet::new();
            for id in ids {
                if !SUPPORTED_CODE_PROVIDERS.contains(&id.as_str()) {
                    return Err(format!(
                        "{label} 里的 \"{id}\" 未实现；当前只支持 {}",
                        SUPPORTED_CODE_PROVIDERS.join(" / ")
                    ));
                }
                if !seen.insert(id) {
                    return Err(format!("{label} 里的 \"{id}\" 重复出现"));
                }
            }
        }
        // 档位模型的约束与 9.4 一致：配了 allowed_models 就必须显式列出，
        // 否则代理会以 `model_not_allowed` 400 拒绝，表现为"任务莫名失败"。
        for (tier, model) in [
            ("fast", self.code.routing.tiers.fast.as_deref()),
            ("strong", self.code.routing.tiers.strong.as_deref()),
        ] {
            let Some(model) = model else { continue };
            if model.trim().is_empty() {
                return Err(format!("code.routing.tiers.{tier} 不能是空字符串"));
            }
            if !self.code.upstream.allowed_models.is_empty()
                && !self
                    .code
                    .upstream
                    .allowed_models
                    .iter()
                    .any(|allowed| allowed == model)
            {
                return Err(format!(
                    "code.routing.tiers.{tier}=\"{model}\" 不在 code.upstream.allowed_models 里：\
                     代理会以 model_not_allowed 拒绝，请把两处写成同一个模型名"
                ));
            }
        }

        if self.code.allow_roots.is_empty() {
            return Err(
                "code.enabled=true 但 code.allow_roots 为空：编码任务会在真实仓库里读写文件，\
                 不允许默认放开。填上允许的仓库根目录，例如 [\"/Users/you/code\"]"
                    .to_string(),
            );
        }
        for root in &self.code.allow_roots {
            let canonical = root.canonicalize().map_err(|err| {
                format!(
                    "code.allow_roots 里的 \"{}\" 无法访问：{err}；请填写真实存在的目录",
                    root.display()
                )
            })?;
            if !canonical.is_dir() {
                return Err(format!(
                    "code.allow_roots 里的 \"{}\" 不是目录",
                    root.display()
                ));
            }
        }

        let raw = self.code.proxy_bind.trim();
        let addr = raw.parse::<std::net::SocketAddr>().map_err(|_| {
            format!("code.proxy_bind=\"{raw}\" 不是合法的 host:port；应形如 \"127.0.0.1:0\"")
        })?;
        if !addr.ip().is_loopback() {
            return Err(format!(
                "code.proxy_bind={raw} 不是回环地址：代理会代持模型密钥并转发模型请求，\
                 只能监听 127.0.0.1。远程访问请走 /api 的 TLS，不要让代理跟着暴露"
            ));
        }

        let code_timeout = self.code_timeout_ms();
        if code_timeout <= 0 || code_timeout >= self.task_timeout_ms {
            return Err(format!(
                "code.timeout_ms={code_timeout} 必须大于 0 且小于 task_timeout_ms={}：\
                 外层先超时会把真实失败原因吞掉",
                self.task_timeout_ms
            ));
        }
        let upstream_timeout = self.code.upstream.timeout_ms as i64;
        if upstream_timeout <= 0 || upstream_timeout >= code_timeout {
            return Err(format!(
                "code.upstream.timeout_ms={upstream_timeout} 必须大于 0 且小于 code.timeout_ms={code_timeout}"
            ));
        }

        if self.code.max_concurrent == 0 {
            return Err("code.max_concurrent 不能为 0；至少留 1，否则编码任务永远排队".to_string());
        }
        if self.code.budget.max_model_calls == 0 {
            return Err(
                "code.budget.max_model_calls 不能为 0：一次模型调用都不允许时任务无法完成"
                    .to_string(),
            );
        }
        if self.code.budget.max_tokens < 1_000 {
            return Err(
                "code.budget.max_tokens 过小（< 1000）：编码任务的上下文本身就有几千 token"
                    .to_string(),
            );
        }

        // 工具级审批：钩子侧 115 秒必须短于审批 TTL，审批 TTL 必须短于任务墙钟。
        let tool_ttl = self.code.tool_approval.ttl_ms;
        if self.code.tool_approval.enabled {
            if tool_ttl < 10_000 || tool_ttl >= code_timeout {
                return Err(format!(
                    "code.tool_approval.ttl_ms={tool_ttl} 必须 ≥ 10000 且小于 code.timeout_ms={code_timeout}：\
                     等一次工具决策不该占满整个任务时长"
                ));
            }
            for level in &self.code.tool_approval.auto_allow {
                if level == "irreversible_write" {
                    return Err(
                        "code.tool_approval.auto_allow 不允许包含 irreversible_write：\
                         不可逆操作必须人工确认，这一档不能靠配置放开"
                            .to_string(),
                    );
                }
                if !matches!(level.as_str(), "read" | "reversible_write") {
                    return Err(format!(
                        "code.tool_approval.auto_allow 里的 \"{level}\" 不是合法风险档；\
                         只能是 read / reversible_write"
                    ));
                }
            }
            for level in &self.code.tool_approval.always_ask {
                if !matches!(
                    level.as_str(),
                    "read" | "reversible_write" | "irreversible_write"
                ) {
                    return Err(format!(
                        "code.tool_approval.always_ask 里的 \"{level}\" 不是合法风险档"
                    ));
                }
            }
            if !self
                .code
                .tool_approval
                .always_ask
                .iter()
                .any(|level| level == "irreversible_write")
            {
                return Err(
                    "code.tool_approval.always_ask 必须包含 irreversible_write：\
                     删文件、git push、工作树外写入不允许默认放行"
                        .to_string(),
                );
            }
        }

        // 追加规则：只有"加严"这一种合法用途，`read` 档直接拒绝。
        let mut seen_rules = std::collections::HashSet::new();
        for rule in &self.code.tool_approval.extra_rules {
            if rule.name.trim().is_empty() {
                return Err("code.tool_approval.extra_rules 里有空的 name".to_string());
            }
            if !seen_rules.insert(rule.name.as_str()) {
                return Err(format!(
                    "code.tool_approval.extra_rules 里的规则名 \"{}\" 重复",
                    rule.name
                ));
            }
            if rule.risk == protocol::RiskLevel::Read {
                return Err(format!(
                    "code.tool_approval.extra_rules 里的 \"{}\" 用了 risk=read：\
                     追加规则只能把风险往上调，不能把操作降级成只读",
                    rule.name
                ));
            }
            if rule.contains.iter().all(|needle| needle.trim().is_empty()) {
                return Err(format!(
                    "code.tool_approval.extra_rules 里的 \"{}\" 没有 contains：\
                     一条永远不命中的规则只会让人误以为有保护",
                    rule.name
                ));
            }
            if let Some(tool) = &rule.tool {
                if tool.trim().is_empty() {
                    return Err(format!(
                        "code.tool_approval.extra_rules 里的 \"{}\" 给了空的 tool",
                        rule.name
                    ));
                }
            }
        }

        Ok(())
    }

    /// 从可选路径加载配置；路径为空时返回默认值。
    pub fn load(path: Option<&Path>) -> Result<Self, ConfigError> {
        let Some(path) = path else {
            return Ok(Self::default());
        };
        let raw = std::fs::read_to_string(path).map_err(|source| ConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        let mut config: Self = serde_json::from_str(&raw).map_err(|source| ConfigError::Parse {
            path: path.to_path_buf(),
            source,
        })?;
        // 记下来源文件：客户端改模型配置要写回同一个文件，而不是另建一份。
        config.source_path = Some(path.to_path_buf());
        Ok(config)
    }

    /// 把 `llm` 节写回原配置文件，其余键原样保留。
    ///
    /// 返回 `Ok(false)` 表示这份配置没有来源文件（未传 `--config`），
    /// 运行期改动照常生效，只是重启后会丢——调用方要把这一点告诉用户。
    ///
    /// 写回策略是"读原文件 → 只替换 `llm` 键 → 临时文件 + rename"：
    /// 用户手写的注释性字段（例如以后新增的节）不会被 serde 的默认值抹掉。
    pub fn save_llm_section(&self, llm: &LlmConfig) -> Result<bool, ConfigError> {
        let Some(path) = self.source_path.clone() else {
            tracing::warn!("配置没有来源文件（未传 --config）：模型配置只在本次运行内生效");
            return Ok(false);
        };

        // 原文件读不到不当作失败：首次部署可能只有 data_dir，没有配置文件。
        let mut root: serde_json::Value = match std::fs::read_to_string(&path) {
            Ok(raw) => serde_json::from_str(&raw).map_err(|source| ConfigError::Parse {
                path: path.clone(),
                source,
            })?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                serde_json::json!({})
            }
            Err(source) => {
                return Err(ConfigError::Io {
                    path: path.clone(),
                    source,
                })
            }
        };

        let Some(object) = root.as_object_mut() else {
            return Err(ConfigError::Io {
                path: path.clone(),
                source: std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "配置文件顶层不是对象，无法写回 llm 节",
                ),
            });
        };
        object.insert(
            "llm".to_string(),
            serde_json::to_value(llm).map_err(|source| ConfigError::Parse {
                path: path.clone(),
                source,
            })?,
        );

        let body = serde_json::to_string_pretty(&root).map_err(|source| ConfigError::Parse {
            path: path.clone(),
            source,
        })?;

        // 临时文件 + rename：直接覆写时，写到一半被杀会留下半截 JSON，
        // 下次启动连服务都起不来。
        let temp = path.with_extension("json.tmp");
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|source| ConfigError::Io {
                    path: parent.to_path_buf(),
                    source,
                })?;
            }
        }
        std::fs::write(&temp, body).map_err(|source| ConfigError::Io {
            path: temp.clone(),
            source,
        })?;
        std::fs::rename(&temp, &path).map_err(|source| ConfigError::Io {
            path: path.clone(),
            source,
        })?;
        Ok(true)
    }

    /// 模型配置的来源文件。`None` 表示未从文件加载。
    pub fn source_path(&self) -> Option<&Path> {
        self.source_path.as_deref()
    }

    /// 命令行端口覆盖配置文件；`None` 表示不覆盖。
    pub fn with_port(mut self, port: Option<u16>) -> Self {
        if let Some(port) = port {
            self.port = port;
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_usable() {
        let config = Config::default();
        assert_eq!(config.port, 8790, "管理面端口不能与 API 端口相同");
        assert!(!config.data_dir.as_os_str().is_empty());
    }

    #[test]
    fn llm_timeouts_separate_request_from_stream_idle() {
        let llm = LlmConfig::default();
        assert_eq!(
            llm.timeout_ms, 120_000,
            "非流式请求的上限：标题、任务步骤、摘要都靠它兜底"
        );
        assert_eq!(
            llm.stream_idle_timeout_ms, 60_000,
            "流式判据是帧间隔而不是总时长，否则长回答必然被掐"
        );
    }

    #[test]
    fn legacy_config_without_profiles_still_works() {
        // 升级前只有单个 llm 节：必须零迁移可用，默认档就是它本身。
        let raw = r#"{"llm":{"enabled":true,"base_url":"https://api.example.com","model":"m"}}"#;
        let config: Config = serde_json::from_str(raw).expect("老配置应能解析");

        assert_eq!(
            config.llm.api_path, DEFAULT_API_PATH,
            "缺 api_path 时保持百炼行为"
        );
        assert!(config.llm.active.is_empty(), "没有生效项就落回默认档");
        assert!(config.llm.profiles.is_empty());
        assert!(
            config.llm.reasoning,
            "默认档必须默认声明支持推理等级：实测网关认 reasoning_effort"
        );

        let active = config.llm.active_profile();
        assert_eq!(active.id, DEFAULT_PROFILE_ID);
        assert_eq!(active.base_url, "https://api.example.com");
        assert_eq!(
            config.llm.chat_endpoint(),
            "https://api.example.com/compatible-mode/v1/chat/completions"
        );
    }

    #[test]
    fn new_profiles_do_not_claim_reasoning_support() {
        // 老 profiles 条目没有这个键：按"不支持"处理。第三方网关多数不认
        // reasoning_effort，硬发换回来的是整轮 400。
        let raw = r#"{"llm":{"profiles":[{"id":"third","name":"第三方","base_url":"https://a.com","model":"m"}]}}"#;
        let config: Config = serde_json::from_str(raw).expect("应能解析");
        assert!(!config.llm.profiles[0].reasoning);
    }

    #[test]
    fn active_pointing_to_a_missing_profile_falls_back() {
        let llm = LlmConfig {
            active: "gone".to_string(),
            ..LlmConfig::default()
        };
        assert_eq!(
            llm.active_profile().id,
            DEFAULT_PROFILE_ID,
            "引用不存在的配置不能让服务起不来，但也必须回落"
        );
    }

    #[test]
    fn chat_endpoint_does_not_double_a_prefix_typed_into_base_url() {
        // 把 `https://api.deepseek.com/v1` 整段贴进地址栏是常见填法。
        let profile = ModelProfile {
            base_url: "https://api.deepseek.com/v1".to_string(),
            api_path: "/v1".to_string(),
            ..ModelProfile::default()
        };
        assert_eq!(
            profile.chat_endpoint(),
            "https://api.deepseek.com/v1/chat/completions"
        );
    }

    #[test]
    fn validate_rejects_reserved_and_duplicate_profile_ids() {
        let reserved = Config {
            llm: LlmConfig {
                profiles: vec![ModelProfile {
                    id: DEFAULT_PROFILE_ID.to_string(),
                    ..ModelProfile::default()
                }],
                ..LlmConfig::default()
            },
            ..Config::default()
        };
        assert!(
            reserved.validate().unwrap_err().contains("保留 id"),
            "默认档的 id 不能被用户占用"
        );

        let duplicated = Config {
            llm: LlmConfig {
                profiles: vec![
                    ModelProfile {
                        id: "dup".to_string(),
                        ..ModelProfile::default()
                    },
                    ModelProfile {
                        id: "dup".to_string(),
                        ..ModelProfile::default()
                    },
                ],
                ..LlmConfig::default()
            },
            ..Config::default()
        };
        assert!(duplicated.validate().unwrap_err().contains("重复"));
    }

    #[test]
    fn saving_llm_section_keeps_other_keys_untouched() {
        let dir = tempfile::tempdir().expect("创建临时目录失败");
        let path = dir.path().join("config.json");
        std::fs::write(
            &path,
            r#"{"api_bind":"127.0.0.1:8787","memory":{"enabled":true},"llm":{"enabled":false}}"#,
        )
        .expect("写入初始配置失败");

        let config = Config::load(Some(&path)).expect("加载配置失败");
        let mut llm = config.llm.clone();
        llm.model = "qwen-max".to_string();
        llm.active = DEFAULT_PROFILE_ID.to_string();
        assert!(config.save_llm_section(&llm).expect("写回应成功"));

        let raw = std::fs::read_to_string(&path).expect("读取写回结果失败");
        let parsed: serde_json::Value = serde_json::from_str(&raw).expect("写回的不是 JSON");
        assert_eq!(parsed["memory"]["enabled"], true, "别的节必须原样保留");
        assert_eq!(parsed["llm"]["model"], "qwen-max");
        assert_eq!(parsed["llm"]["active"], DEFAULT_PROFILE_ID);
        assert!(
            parsed.get("source_path").is_none(),
            "来源路径是运行期事实，不能写进文件"
        );
    }

    #[test]
    fn saving_without_source_file_is_a_noop() {
        let config = Config::default();
        assert!(
            !config.save_llm_section(&config.llm).expect("不该报错"),
            "没有来源文件时跳过落盘，运行期改动仍然生效"
        );
    }

    #[test]
    fn tool_budget_defaults_fit_two_hop_lookup() {
        let tool = ToolConfig::default();
        assert_eq!(
            tool.max_calls_per_turn, 12,
            "外部检索是保险不是成本控制：一轮 2 搜 + 3 抓用不满，再多就是在打转"
        );
        assert_eq!(
            tool.turn_budget_ms, 300_000,
            "写一个几十 KB 的网页光生成就要一分钟，三分钟才是产出型回答的实际耗时"
        );
        assert_eq!(
            tool.max_rounds, 4,
            "唯一必须存在的次数限制：检索 → 读 → 写 → 收尾刚好四轮"
        );
        assert_eq!(
            tool.max_local_calls_per_turn, 100,
            "本地读没有外部成本，这个量级事实上等于不限制，只拦死循环"
        );
    }

    #[test]
    fn legacy_allow_hosts_key_is_ignored_not_fatal() {
        // 升级后旧配置里仍可能留着 tool.allow_hosts：必须照常启动，
        // 而不是因为一个已废弃的键就拒绝服务。
        let raw = r#"{"tool":{"allow_hosts":["example.com"],"max_calls_per_turn":6}}"#;
        let config: Config = serde_json::from_str(raw).expect("旧键应被忽略");
        assert_eq!(config.tool.max_calls_per_turn, 6);
        assert_eq!(config.tool.turn_budget_ms, 300_000, "缺省字段用新默认值");
    }

    #[test]
    fn web_tools_default_to_bing_without_any_key() {
        let config = Config::default();
        assert_eq!(config.tool.web.search_provider, "bing");
        assert!(
            !config.tool.web.fetch_fallback,
            "兜底要多一次往返与一次计费，默认关"
        );
        assert_eq!(config.tool.web.base_url, WEB_TOOLS_DEFAULT_BASE_URL);
        assert_eq!(config.web_search_provider(), "bing");
        assert!(
            !config.web_tools_proxy_needed(),
            "默认配置不该启动代持密钥的回环代理"
        );
        assert!(config.validate().is_ok(), "默认必须能启动");
    }

    #[test]
    fn missing_key_degrades_to_bing_instead_of_blocking_startup() {
        std::env::remove_var("PERSONAL_AGENT_TEST_WEB_KEY_ABSENT");
        let mut config = Config::default();
        config.tool.web.search_provider = "deepseek".to_string();
        config.tool.web.fetch_fallback = true;
        config.tool.web.api_key_env = "PERSONAL_AGENT_TEST_WEB_KEY_ABSENT".to_string();

        assert!(config.validate().is_ok(), "缺密钥不该拦启动");
        assert_eq!(config.web_search_provider(), "bing", "应降级回 Bing");
        assert!(!config.web_fetch_fallback(), "没密钥时兜底也要关掉");
        assert!(!config.web_tools_proxy_needed());
    }

    #[test]
    fn web_tools_reject_unknown_provider_and_external_bind() {
        let mut config = Config::default();
        config.tool.web.search_provider = "google".to_string();
        let err = config.validate().expect_err("未实现的上游必须拒绝");
        assert!(err.contains("search_provider"), "{err}");

        let mut config = Config::default();
        config.tool.web.proxy_bind = "0.0.0.0:0".to_string();
        let err = config.validate().expect_err("代理不得监听外部地址");
        assert!(err.contains("回环"), "{err}");
    }

    #[test]
    fn web_tools_require_layered_timeout_and_safe_base_url() {
        let mut config = Config::default();
        config.tool.web.timeout_ms = config.tool.call_timeout_ms;
        let err = config.validate().expect_err("内层超时不能等于外层");
        assert!(err.contains("call_timeout_ms"), "{err}");

        let mut config = Config::default();
        config.tool.web.base_url = "http://api.deepseek.com".to_string();
        let err = config.validate().expect_err("明文只能给回环");
        assert!(err.contains("https://"), "{err}");

        let mut config = Config::default();
        config.tool.web.base_url = "http://127.0.0.1:9/".to_string();
        assert!(config.validate().is_ok(), "回环 http 是本地测试通道");
    }

    #[test]
    fn api_bind_defaults_to_client_port() {
        // 客户端默认连 8787；这里固定同一个值，避免"服务随机端口、客户端写死端口"
        assert_eq!(Config::default().api_bind, "127.0.0.1:8787");
    }

    #[test]
    fn command_line_port_wins() {
        let config = Config::default().with_port(Some(0));
        assert_eq!(config.port, 0);
    }

    #[test]
    fn missing_file_reports_io_error() {
        let err = Config::load(Some(Path::new("/nonexistent/personal-agent.json")))
            .expect_err("不存在的路径应当报错");
        assert!(matches!(err, ConfigError::Io { .. }));
    }

    fn bind_config(bind: &str, mode: TlsMode) -> Config {
        Config {
            api_bind: bind.to_string(),
            tls: TlsConfig {
                mode,
                ..TlsConfig::default()
            },
            ..Config::default()
        }
    }

    #[test]
    fn tls_defaults_to_auto_with_plaintext_loopback() {
        let config = Config::default();
        assert_eq!(config.tls.mode, TlsMode::Auto);
        assert!(!config.tls.allow_insecure_plaintext);
        // 0.2.0 的默认行为必须保持：本机开发是明文。
        assert!(!config.tls_required(), "回环绑定不应强制 TLS");
        assert!(config.validate().is_ok());
    }

    #[test]
    fn loopback_detection_covers_common_forms() {
        for bind in [
            "127.0.0.1:8787",
            "127.5.6.7:1",
            "[::1]:8787",
            "localhost:8787",
        ] {
            assert!(
                bind_config(bind, TlsMode::Auto).is_loopback_bind(),
                "{bind} 应视为回环"
            );
        }
        for bind in ["0.0.0.0:8787", "[::]:8787", ":8787", "192.168.1.5:8787"] {
            assert!(
                !bind_config(bind, TlsMode::Auto).is_loopback_bind(),
                "{bind} 不应视为回环"
            );
        }
    }

    #[test]
    fn non_loopback_auto_requires_tls() {
        let config = bind_config("0.0.0.0:8787", TlsMode::Auto);
        assert!(config.tls_required());
        assert!(config.validate().is_ok(), "auto 会自动开 TLS，不应报错");
    }

    #[test]
    fn non_loopback_off_is_rejected_without_explicit_override() {
        let config = bind_config("0.0.0.0:8787", TlsMode::Off);
        let err = config.validate().expect_err("默认不允许明文对外暴露");
        assert!(
            err.contains("allow_insecure_plaintext"),
            "提示要给出改法：{err}"
        );

        let mut allowed = config.clone();
        allowed.tls.allow_insecure_plaintext = true;
        assert!(allowed.validate().is_ok(), "显式开关应当放行");
    }

    #[test]
    fn loopback_off_is_fine() {
        let config = bind_config("127.0.0.1:8787", TlsMode::Off);
        assert!(!config.tls_required());
        assert!(config.validate().is_ok());
    }

    #[test]
    fn malformed_bind_is_rejected_before_listening() {
        let config = bind_config("8787", TlsMode::Auto);
        assert!(config.validate().is_err());

        let empty = bind_config("   ", TlsMode::Auto);
        assert!(empty.validate().is_err());
    }

    /// 构造一个「已启用编码任务」的配置，仓库根用系统临时目录。
    fn enabled_code_config() -> Config {
        let mut config = Config::default();
        config.code.enabled = true;
        config.code.allow_roots = vec![std::env::temp_dir()];
        config
    }

    #[test]
    fn code_is_disabled_by_default_and_never_blocks_startup() {
        let config = Config::default();
        assert!(!config.code.enabled);
        // 关闭时即使 allow_roots 为空也必须能启动：否则升级即失败。
        assert!(config.validate().is_ok());
        assert_eq!(config.code.provider, "opencode");
        assert_eq!(config.code.proxy_bind, "127.0.0.1:0");
    }

    #[test]
    fn code_enabled_requires_allow_roots() {
        let mut config = enabled_code_config();
        config.code.allow_roots.clear();
        let err = config.validate().expect_err("空白名单必须拒绝");
        assert!(err.contains("allow_roots"), "提示要指出字段：{err}");
        assert!(err.contains("不允许默认放开"), "提示要给出理由：{err}");
    }

    #[test]
    fn code_enabled_accepts_existing_root() {
        assert!(enabled_code_config().validate().is_ok());
    }

    #[test]
    fn code_rejects_missing_allow_root() {
        let mut config = enabled_code_config();
        config.code.allow_roots = vec![PathBuf::from("/nonexistent/personal-agent-repo")];
        let err = config.validate().expect_err("不存在的根目录必须拒绝");
        assert!(err.contains("无法访问"), "{err}");
    }

    #[test]
    fn code_rejects_unimplemented_provider() {
        let mut config = enabled_code_config();
        config.code.provider = "gemini".to_string();
        let err = config
            .validate()
            .expect_err("未实现的 provider 必须拒绝启动");
        assert!(err.contains("opencode"), "提示要列出已支持项：{err}");
    }

    #[test]
    fn code_accepts_every_registered_provider() {
        // 注册表里有的都该被接受：漂移会让"文档说支持、启动就失败"。
        for id in protocol::SUPPORTED_CODE_PROVIDERS {
            let mut config = enabled_code_config();
            config.code.provider = (*id).to_string();
            assert!(config.validate().is_ok(), "{id}: {:?}", config.validate());
        }
    }

    #[test]
    fn providers_must_be_registered_and_existing() {
        let mut config = enabled_code_config();
        config
            .code
            .providers
            .insert("gemini".to_string(), CodeProviderConfig::default());
        let err = config.validate().expect_err("未注册的 id 必须拒绝");
        assert!(err.contains("code.providers"), "{err}");

        let mut config = enabled_code_config();
        config.code.providers.insert(
            "codex".to_string(),
            CodeProviderConfig {
                bin: Some(PathBuf::from("/nonexistent/codex")),
                enabled: true,
            },
        );
        let err = config.validate().expect_err("不存在的 bin 必须拒绝");
        assert!(err.contains("不存在"), "{err}");
    }

    #[test]
    fn routing_ids_and_tiers_are_validated() {
        let mut config = enabled_code_config();
        config.code.routing.preferred = vec!["codebuddy".to_string()];
        config.code.routing.fallback = vec!["codex".to_string()];
        assert!(config.validate().is_ok(), "{:?}", config.validate());

        config.code.routing.preferred = vec!["gemini".to_string()];
        let err = config.validate().expect_err("未注册的 id 必须拒绝");
        assert!(err.contains("code.routing.preferred"), "{err}");

        // 档位模型必须在白名单里，否则代理会 400。
        let mut config = enabled_code_config();
        config.code.upstream.allowed_models = vec!["only-this".to_string()];
        config.code.routing.tiers.fast = Some("another".to_string());
        let err = config.validate().expect_err("越界档位必须拒绝");
        assert!(err.contains("allowed_models"), "{err}");
    }

    #[test]
    fn extra_rules_can_only_escalate() {
        let mut config = enabled_code_config();
        config.code.tool_approval.extra_rules = vec![protocol::RiskRule {
            name: "touch_legacy".to_string(),
            tool: Some("Bash".to_string()),
            contains: vec!["legacy/".to_string()],
            risk: protocol::RiskLevel::IrreversibleWrite,
        }];
        assert!(config.validate().is_ok(), "{:?}", config.validate());

        // read 档等于"用配置把操作降级"，必须拒绝。
        config.code.tool_approval.extra_rules[0].risk = protocol::RiskLevel::Read;
        let err = config.validate().expect_err("read 档必须拒绝");
        assert!(err.contains("只能把风险往上调"), "{err}");

        // 永远不命中的规则也不行：它只会让人误以为有保护。
        config.code.tool_approval.extra_rules[0].risk = protocol::RiskLevel::ReversibleWrite;
        config.code.tool_approval.extra_rules[0].contains = vec![String::new()];
        let err = config.validate().expect_err("空 contains 必须拒绝");
        assert!(err.contains("没有 contains"), "{err}");
    }

    #[test]
    fn providers_are_enabled_unless_explicitly_disabled() {
        // 未登记 = 启用：装了哪个 CLI 就能选哪个，选择器不会只有一个选项。
        let mut config = Config::default();
        config.code.provider = "codebuddy".to_string();
        assert!(config.code_provider_enabled("codebuddy"));
        assert!(config.code_provider_enabled("opencode"));

        // 显式关掉才是关掉，且只影响被关掉的那一个。
        config.code.providers.insert(
            "opencode".to_string(),
            CodeProviderConfig {
                enabled: false,
                ..CodeProviderConfig::default()
            },
        );
        assert!(!config.code_provider_enabled("opencode"));
        assert!(config.code_provider_enabled("codex"));
    }

    #[test]
    fn tool_approval_ttl_must_fit_inside_the_code_timeout() {
        let mut config = enabled_code_config();
        config.code.timeout_ms = Some(60_000);
        config.code.upstream.timeout_ms = 20_000;
        // 默认 120s 的审批 TTL 放不进 60s 的任务里：必须在启动时拦住。
        let err = config
            .validate()
            .expect_err("工具审批 TTL 必须小于任务墙钟");
        assert!(err.contains("tool_approval.ttl_ms"), "{err}");

        config.code.tool_approval.ttl_ms = 30_000;
        assert!(config.validate().is_ok());
    }

    #[test]
    fn auto_allow_cannot_release_irreversible_writes() {
        let mut config = enabled_code_config();
        config.code.tool_approval.auto_allow = vec!["irreversible_write".to_string()];
        let err = config.validate().expect_err("不可逆档不允许自动放行");
        assert!(err.contains("irreversible_write"), "{err}");
    }

    #[test]
    fn code_proxy_must_stay_on_loopback() {
        let mut config = enabled_code_config();
        config.code.proxy_bind = "0.0.0.0:0".to_string();
        let err = config.validate().expect_err("代理不得监听外部地址");
        assert!(err.contains("回环"), "{err}");

        config.code.proxy_bind = "not-an-addr".to_string();
        assert!(config.validate().is_err(), "非法地址必须拒绝");
    }

    #[test]
    fn code_timeouts_must_be_layered() {
        let mut config = enabled_code_config();
        config.task_timeout_ms = 60_000;
        config.code.timeout_ms = Some(60_000);
        let err = config.validate().expect_err("code timeout 不能等于外层");
        assert!(err.contains("task_timeout_ms"), "{err}");

        config.code.timeout_ms = Some(30_000);
        config.code.upstream.timeout_ms = 30_000;
        let err = config
            .validate()
            .expect_err("upstream timeout 必须小于 code timeout");
        assert!(err.contains("code.upstream.timeout_ms"), "{err}");

        config.code.upstream.timeout_ms = 20_000;
        // 30s 的任务装不下默认 120s 的工具审批 TTL，测试里缩到合法范围。
        config.code.tool_approval.ttl_ms = 10_000;
        assert!(config.validate().is_ok());
    }

    #[test]
    fn code_upstream_inherits_llm_by_default() {
        let config = Config::default();
        assert_eq!(
            config.code_upstream_base_url(),
            format!("{}/compatible-mode/v1", config.llm.base_url),
            "默认必须带上兼容模式前缀，否则网关回 404"
        );
        assert_eq!(config.code_upstream_model(), config.llm.model);
        assert_eq!(
            config.code_upstream_api_key_env(),
            config.llm.api_key_env,
            "默认与对话共用同一个密钥变量"
        );

        let mut overridden = config.clone();
        overridden.code.upstream.base_url = Some("http://127.0.0.1:9000/v1".to_string());
        overridden.code.upstream.model = Some("other-model".to_string());
        assert_eq!(
            overridden.code_upstream_base_url(),
            "http://127.0.0.1:9000/v1"
        );
        assert_eq!(overridden.code_upstream_model(), "other-model");
        assert_eq!(
            overridden.llm.model, config.llm.model,
            "覆盖编码上游不得改动对话配置"
        );
    }

    #[test]
    fn code_worktree_dir_defaults_under_data_dir() {
        let config = Config::default();
        assert_eq!(
            config.code_worktree_dir(),
            config.data_dir.join("worktrees")
        );
        assert_eq!(config.code_timeout_ms(), config.task_timeout_ms - 2_000);
    }

    #[test]
    fn ssh_tunnel_is_enabled_by_default_and_targets_local_sshd() {
        let config = Config::default();
        assert!(config.ssh.enabled);
        assert_eq!(config.ssh.target, "127.0.0.1:22");
        assert_eq!(config.ssh.max_sessions, 4);
        assert!(config.validate().is_ok(), "默认配置必须能启动");
    }

    #[test]
    fn ssh_target_must_stay_on_loopback() {
        let mut config = Config::default();
        config.ssh.target = "192.168.1.10:22".to_string();
        let err = config
            .validate()
            .expect_err("隧道不得连到其它主机，否则就是跳板");
        assert!(err.contains("回环"), "提示要给出理由：{err}");
        assert!(err.contains("ssh.target"), "提示要指出字段：{err}");

        config.ssh.target = "127.0.0.1".to_string();
        assert!(
            config.validate().is_err(),
            "缺少端口必须拒绝，而不是默认 22"
        );
        config.ssh.target = "[::1]:22".to_string();
        assert!(config.validate().is_ok(), "IPv6 回环同样合法");
    }

    #[test]
    fn ssh_disabled_skips_validation() {
        let mut config = Config::default();
        config.ssh.enabled = false;
        config.ssh.target = "10.0.0.5:22".to_string();
        config.ssh.max_sessions = 0;
        assert!(config.validate().is_ok(), "未启用时不该拦住启动");
    }

    #[test]
    fn ssh_max_sessions_has_bounds() {
        let mut config = Config::default();
        config.ssh.max_sessions = 0;
        let err = config.validate().expect_err("0 个会话等于永远连不上");
        assert!(err.contains("max_sessions"), "{err}");

        config.ssh.max_sessions = 64;
        let err = config.validate().expect_err("上限过高会拖垮服务");
        assert!(err.contains("16"), "{err}");
    }

    #[test]
    fn browser_tunnel_defaults_to_common_dev_ports() {
        let config = Config::default();
        assert!(config.browser.enabled);
        assert!(config.browser.allowed_ports.contains(&5173));
        assert!(config.browser.allowed_ports.contains(&3000));
        assert!(
            config.browser.allowed_ports.iter().all(|port| *port != 22),
            "SSH 端口不能进白名单"
        );
        assert!(config.validate().is_ok(), "默认配置必须能启动");
    }

    #[test]
    fn browser_requires_at_least_one_port() {
        let mut config = Config::default();
        config.browser.allowed_ports.clear();
        let err = config.validate().expect_err("空白名单等于功能不可用");
        assert!(err.contains("allowed_ports"), "提示要指出字段：{err}");
    }

    #[test]
    fn browser_rejects_reserved_ports() {
        let mut config = Config::default();
        config.browser.allowed_ports = vec![22];
        let err = config.validate().expect_err("22 必须拒绝");
        assert!(err.contains("22"), "{err}");

        // `/api` 自己占用的端口也不该对浏览器开放。
        config.browser.allowed_ports = vec![8787];
        let err = config.validate().expect_err("API 端口必须拒绝");
        assert!(err.contains("8787"), "{err}");
    }

    #[test]
    fn browser_rejects_non_loopback_hosts_field() {
        let mut config = Config::default();
        config.browser.allowed_hosts = vec!["example.com".to_string()];
        let err = config
            .validate()
            .expect_err("本版不支持域名目标，必须显式拒绝");
        assert!(err.contains("allowed_hosts"), "{err}");
    }

    #[test]
    fn browser_limits_must_be_layered() {
        let mut config = Config::default();
        config.browser.max_tunnels = 0;
        assert!(config.validate().is_err(), "0 条隧道等于功能不可用");

        config.browser.max_tunnels = 64;
        config.browser.max_tunnels_per_device = 128;
        let err = config.validate().expect_err("单设备上限不能超过全局上限");
        assert!(err.contains("max_tunnels_per_device"), "{err}");

        config.browser.max_tunnels_per_device = 24;
        config.browser.max_tunnels = 256;
        assert!(config.validate().is_err(), "全局上限也要有硬顶");
    }

    #[test]
    fn browser_disabled_skips_validation() {
        let mut config = Config::default();
        config.browser.enabled = false;
        config.browser.allowed_ports.clear();
        config.browser.allowed_hosts = vec!["example.com".to_string()];
        assert!(config.validate().is_ok(), "未启用时不该拦住启动");
    }

    #[test]
    fn multimodal_asr_uses_host_root_and_native_path() {
        let config = Config::default();
        assert_eq!(config.asr.provider, "multimodal");
        assert_eq!(config.asr.model, "qwen-audio-3.1-asr-flash");
        assert_eq!(
            config.asr_upstream_base_url(),
            config.llm.base_url.trim_end_matches('/')
        );
        assert_eq!(
            config.asr_path(),
            "/api/v1/services/aigc/multimodal-generation/generation"
        );
    }

    #[test]
    fn chat_audio_asr_keeps_compatible_path() {
        let mut config = Config::default();
        config.asr.provider = "chat_audio".to_string();
        assert_eq!(
            config.asr_upstream_base_url(),
            format!(
                "{}/compatible-mode/v1",
                config.llm.base_url.trim_end_matches('/')
            )
        );
        assert_eq!(config.asr_path(), "/chat/completions");
    }

    #[test]
    fn summary_default_style_is_brief() {
        assert_eq!(
            Config::default().summary.default_style,
            protocol::SummaryStyle::Brief
        );
    }

    #[test]
    fn tts_and_realtime_defaults_match_reference() {
        let config = Config::default();
        assert!(
            !config.tts.enabled,
            "TTS 默认关闭，避免未经用户开启就生成语音"
        );
        assert_eq!(config.tts.model, "qwen-audio-3.1-tts-flash");
        assert_eq!(
            config.tts.path,
            "/api/v1/services/audio/tts/SpeechSynthesizer"
        );
        assert_eq!(config.tts.voice, "longanhuan_v3.1");
        assert_eq!(config.tts_upstream_base_url(), config.llm.base_url);

        assert!(!config.realtime.enabled, "realtime 尚未实现，默认必须关闭");
        assert_eq!(config.realtime.model, "qwen-audio-3.0-realtime-flash");
        assert_eq!(config.realtime.ws_path, "/api-ws/v1/realtime");
        assert_eq!(config.realtime.turn_detection, "server_vad");
        assert_eq!(config.realtime.vad_silence_ms, 800);
        assert_eq!(
            config.realtime_ws_base_url(),
            config
                .llm
                .base_url
                .replacen("https://", "wss://", 1)
                .trim_end_matches('/')
        );
    }

    #[test]
    fn realtime_ws_base_url_can_be_overridden() {
        let mut config = Config::default();
        config.realtime.ws_base_url = Some("wss://example.com/".to_string());
        assert_eq!(config.realtime_ws_base_url(), "wss://example.com");
    }

    #[test]
    fn disabled_voice_features_skip_validation() {
        let mut config = Config::default();
        config.tts.model.clear();
        config.realtime.model.clear();
        assert!(
            config.validate().is_ok(),
            "未启用时不应因为模型为空拦住启动"
        );
    }

    #[test]
    fn media_defaults_are_off_and_do_not_inherit_llm_gateway() {
        let config = Config::default();
        assert!(!config.media.image.enabled, "出图默认关闭");
        assert!(!config.media.video.enabled, "出片默认关闭");
        assert_eq!(config.media.image.model, "qwen-image-3.0");
        assert_eq!(config.media.video.model, "wan3.0-video-prime");
        assert_eq!(
            config.media.image.path,
            "/api/v1/services/aigc/multimodal-generation/generation"
        );
        assert_eq!(
            config.media.video.path,
            "/api/v1/services/aigc/video-generation/video-synthesis"
        );
        assert_eq!(config.media.video.task_path, "/api/v1/tasks/");
        assert_eq!(config.media.video.duration_s, 5);
        assert_eq!(config.media.image.api_key_env, "BAILIAN_API_KEY");
        assert_eq!(
            config.media_image_upstream_base_url(),
            DASHSCOPE_BASE_URL,
            "媒体端点不能跟着 llm.base_url 走"
        );
        assert_eq!(config.media_video_upstream_base_url(), DASHSCOPE_BASE_URL);
    }

    #[test]
    fn media_tool_budget_defaults_are_sane() {
        let tool = Config::default().tool;
        assert!(tool.max_media_calls_per_turn > 0, "付费请求必须有次数上限");
        assert!(
            tool.media_call_timeout_ms >= 120_000,
            "出片实测约两分钟，超时不能比它短：{}",
            tool.media_call_timeout_ms
        );
        assert!(
            tool.media_turn_budget_ms >= tool.media_call_timeout_ms,
            "单次上限不能超过整轮上限"
        );
    }

    #[test]
    fn media_enabled_rejects_zero_budget() {
        let mut config = Config::default();
        config.media.image.enabled = true;
        config.tool.max_media_calls_per_turn = 0;
        let error = config.validate().unwrap_err();
        assert!(error.contains("max_media_calls_per_turn"), "{error}");

        config.tool.max_media_calls_per_turn = 2;
        config.tool.media_turn_budget_ms = config.tool.media_call_timeout_ms - 1;
        let error = config.validate().unwrap_err();
        assert!(error.contains("media_turn_budget_ms"), "{error}");
    }

    #[test]
    fn media_disabled_skips_validation() {
        let mut config = Config::default();
        config.media.image.model.clear();
        config.media.image.size.clear();
        config.media.video.model.clear();
        config.media.video.task_path = "tasks/".to_string();
        assert!(config.validate().is_ok(), "未启用媒体生成时不该拦住启动");
    }

    #[test]
    fn media_enabled_requires_model_and_absolute_path() {
        let mut config = Config::default();
        config.media.image.enabled = true;
        config.media.image.model.clear();
        let error = config.validate().unwrap_err();
        assert!(error.contains("media.image.model"), "{error}");

        config.media.image.model = "qwen-image-3.0".to_string();
        config.media.image.path = "services/generation".to_string();
        let error = config.validate().unwrap_err();
        assert!(error.contains("media.image.path"), "{error}");

        config.media.image.enabled = false;
        config.media.video.enabled = true;
        config.media.video.task_path = "tasks/".to_string();
        let error = config.validate().unwrap_err();
        assert!(error.contains("media.video.task_path"), "{error}");
    }
}
