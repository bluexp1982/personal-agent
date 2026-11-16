//! 编码 CLI 适配层（门面）。
//!
//! 一个 provider 只允许在两件事上有差异：**怎么拼命令/配置**、**怎么解析输出行**。
//! worktree、进程、日志、产物一律共用，否则新增一个 CLI 就要复制一遍编排逻辑。
//!
//! 已实现 `opencode` / `codebuddy` / `codex` / `claude`，各家都做完真实 spike：
//!
//! opencode（v2.1.4）：
//! - 必须带 `--standalone`：不带会连本机常驻服务，per-task 配置不生效；
//! - 配置只能通过配置文件 + `OPENCODE_CONFIG_DIR` 注入，`OPENCODE_CONFIG*` 环境变量无效；
//! - `baseURL` 之后 opencode 自己拼 `/chat/completions`，并带 `Authorization: Bearer`。
//!
//! codebuddy（v2.177.1，实测结论）：
//! - `models.json` 只认 `<cwd>/.codebuddy/models.json` 与 `~/.codebuddy/models.json`，
//!   `CODEBUDDY_PROJECT_CONFIG_DIR` 不会重定向它 —— 所以模型配置只能写进工作树，
//!   跑完必须删掉（`cleanup`），否则会进 diff；
//! - **不要**设 `CODEBUDDY_API_KEY`：设了它 CLI 会拿它去官方端点校验，401 直接失败；
//!   令牌只从 `models.json` 的 `apiKey`（`${ENV}` 引用）走；
//! - 无头模式下 `Bash`/`Write`/`Edit` 默认被权限系统拒绝，`PreToolUse` 钩子返回
//!   `permissionDecision: allow` 是唯一的放行通道；`deny` 只阻断本次调用，会话继续；
//! - `-p` 单发模式不支持后台任务，必须注入 `CODEBUDDY_CODE_DISABLE_BACKGROUND_TASKS=1`；
//! - `--strict-mcp-config --mcp-config '{}'` 屏蔽用户级 MCP，避免绕过钩子的工具面。
//!
//! codex / claude 的实测结论写在各自文件的头部注释里（见 `codex.rs` / `claude.rs`）。

use std::path::{Path, PathBuf};

mod claude;
mod codebuddy;
mod codex;
mod opencode;
mod shared;

pub(crate) use self::claude::Claude;
pub(crate) use self::codebuddy::Codebuddy;
pub(crate) use self::codex::Codex;
pub(crate) use self::opencode::Opencode;

/// 一次执行的输入。`token` 是本次任务的一次性代理令牌。
#[derive(Debug, Clone)]
pub(crate) struct RunRequest {
    pub(crate) model: String,
    pub(crate) worktree: PathBuf,
    pub(crate) config_dir: PathBuf,
    pub(crate) proxy_url: String,
    pub(crate) token: String,
    pub(crate) prompt: String,
    /// 钩子注入参数。只有支持"工具执行前拦截"的 provider 用得上，
    /// 其它 provider 忽略即可（`hook_env` 默认空实现）。
    pub(crate) hook: Option<HookSpec>,
}

/// 钩子（决策端点 + shim）的落点。
#[derive(Debug, Clone)]
pub(crate) struct HookSpec {
    /// 本任务的 unix socket 路径。shim 连它问"这一次能不能执行"。
    pub(crate) socket: PathBuf,
    /// shim 可执行文件：就是 worker 自己（`hook-shim` 隐藏子命令）。
    pub(crate) shim: PathBuf,
    /// 钩子自身的最长阻塞时间（秒），必须小于 service 侧的审批 TTL。
    pub(crate) timeout_secs: u64,
}

/// provider 无关的运行时事件。
///
/// 解析失败的行走 `None`（跳过），**不允许**因为一行看不懂就让整个任务失败：
/// CLI 的输出格式没有稳定契约，升级后多一个字段是常态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CliEvent {
    Started {
        session_id: Option<String>,
    },
    Text {
        text: String,
    },
    ToolUse {
        name: String,
        /// 一行展示用的摘要（opencode 优先用 `state.title`）。
        detail: String,
        /// 原始参数：风险规则要按它判定，不能只看工具名。
        input: Option<serde_json::Value>,
        /// CLI 自报的工具调用 id（codebuddy 的 `tool_use.id`）。
        /// **只用于观测**：钩子输入里拿不到它，工具级审批的 `call_id` 由 worker 分配。
        call_id: Option<String>,
    },
    ToolResult {
        ok: bool,
        summary: String,
    },
    /// CLI 的通知/权限提示。钩子没拦住时，这是最后一道观测信号。
    Notification {
        code: String,
        message: String,
    },
    /// CLI 自报的用量。只作为参考：实测最后一步不产生 `step_finish`，
    /// 因此权威计数仍在服务端代理侧。
    Usage {
        prompt_tokens: Option<u64>,
        completion_tokens: Option<u64>,
    },
    Failed {
        message: String,
    },
}

pub(crate) trait CodingProvider: Send + Sync + std::fmt::Debug {
    fn id(&self) -> &'static str;
    /// 解析可执行文件：配置覆盖优先，其次 PATH。找不到返回 `None`。
    fn resolve(&self, bin: Option<&Path>) -> Option<PathBuf>;
    /// 写该任务专用的 CLI 配置，返回配置文件路径（在仓库外）。
    fn write_config(&self, req: &RunRequest) -> std::io::Result<PathBuf>;
    /// 拼装命令：cwd 固定为 worktree，stdin 由调用方置 null。
    fn command(&self, exe: &Path, req: &RunRequest) -> tokio::process::Command;
    /// 解析一行输出；无法识别返回 `None`。
    fn parse(&self, line: &str) -> Option<CliEvent>;

    /// 静态能力。默认读 `protocol` 的注册表——那是 service 与 worker 的唯一事实源，
    /// 实现体不需要各写一份，也就不会出现"能力表说支持、实现造不出来"。
    ///
    /// 只有单测用它断言"默认实现与注册表同源"：运行时 worker 不需要这份能力表
    /// （要不要工具级审批由 service 随任务下发决定），所以不进生产构建。
    #[cfg(test)]
    fn capabilities(&self) -> protocol::Capabilities {
        protocol::provider_capabilities(self.id()).unwrap_or(protocol::Capabilities {
            tool_approval: protocol::ApprovalSupport::Unsupported,
            append_message: false,
            switch_model: false,
            stream_events: false,
        })
    }

    /// 是否会把 [`HookSpec`] 真正注入 CLI 的配置（从而每次工具调用都过钩子）。
    ///
    /// 只影响 `run_log`：为真时 stdout 侧的 `ToolUse` 不再入环，避免同一次调用
    /// 在事件里出现两条（钩子那条带风险与摘要）。
    fn injects_hook(&self) -> bool {
        false
    }

    /// 需要额外注入的环境变量（钩子配置目录、CLI 自己的模型档位等）。
    ///
    /// 默认空：该 CLI 不需要额外注入，或不支持工具级拦截。
    fn hook_env(&self, _req: &RunRequest) -> std::io::Result<Vec<(String, String)>> {
        Ok(Vec::new())
    }

    /// 任务结束（成功/失败/取消）后的清理钩子。
    ///
    /// codebuddy 需要：它的模型配置必须写在 `<worktree>/.codebuddy/`，
    /// 不删就会进 `git add -A` 的 diff。codex / claude 的配置都在仓库外，无需清理。
    fn cleanup(&self, _req: &RunRequest) {}
}

/// 按配置名构造 provider。新增实现时只需在这里加一个分支。
pub(crate) fn from_name(provider: &str) -> Option<Box<dyn CodingProvider>> {
    match provider {
        "opencode" => Some(Box::new(Opencode)),
        "codebuddy" => Some(Box::new(Codebuddy::default())),
        "codex" => Some(Box::new(Codex)),
        "claude" => Some(Box::new(Claude)),
        _ => None,
    }
}
