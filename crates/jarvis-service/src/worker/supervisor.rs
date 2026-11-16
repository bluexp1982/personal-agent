//! worker 进程监督。
//!
//! 生命周期：绑定本地套接字 → 拉起子进程 → 等待连接 → 读事件直到断开 →
//! 清理子进程 → 按退避重试。连续 `worker_max_restarts` 次失败后停止并告警。
//!
//! 只在 unix 上实现：Windows 的 named pipe 尚未接入，配置默认关闭（见 `config.rs`）。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use protocol::IpcMessage;
use tokio::sync::oneshot;

/// 重启退避序列（秒）。与开发方案一致：1 / 2 / 5 / 30。
pub(crate) const BACKOFF_SECONDS: [u64; 4] = [1, 2, 5, 30];

/// 建立连接的最长等待时间。超过视为本次启动失败。
pub(crate) const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerPhase {
    /// 配置关闭，或平台不支持。
    Disabled,
    /// 进程已拉起，尚未收到 hello。
    Starting,
    /// 已握手，可下发任务。
    Connected,
    /// 断线后等待重启。
    Restarting,
    /// 连续失败达到上限，不再重试。
    Stopped,
}

impl WorkerPhase {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Starting => "starting",
            Self::Connected => "connected",
            Self::Restarting => "restarting",
            Self::Stopped => "stopped",
        }
    }
}

/// 管理面展示的 worker 状态快照。
#[derive(Debug, Clone)]
pub struct WorkerView {
    pub phase: &'static str,
    pub pid: Option<u32>,
    pub last_heartbeat_ms: Option<i64>,
    pub restarts: u32,
    pub last_error: Option<String>,
    pub skills: Vec<String>,
    /// worker 自报的活跃任务。
    pub active_tasks: Vec<String>,
}

/// 工具调用的应答（worker → service）。
#[derive(Debug, Clone)]
pub struct ToolReply {
    pub ok: bool,
    pub summary: String,
    pub source_url: Option<String>,
    pub fetched_at: Option<i64>,
    pub size: i64,
    pub error: Option<String>,
}

#[derive(Debug)]
struct Shared {
    phase: WorkerPhase,
    pid: Option<u32>,
    last_heartbeat_ms: Option<i64>,
    restarts: u32,
    last_error: Option<String>,
    skills: Vec<String>,
    /// worker 心跳里上报的活跃任务（它自己认为在跑的那些）。
    ///
    /// 用途只有一个：清理现场前判断"CLI 是不是还在写这棵目录"。
    /// 取消之后 worker 需要几百毫秒到几秒才会把它从活跃列表里移除。
    active_tasks: Vec<String>,
    commands: Option<tokio::sync::mpsc::Sender<IpcMessage>>,
    shutting_down: bool,
    /// 等待中的工具调用：`call_id` → 应答通道。
    tool_waiters: HashMap<String, oneshot::Sender<ToolReply>>,
    /// 已请求重载：`serve_once` 返回后**不按失败处理**，直接进入下一轮。
    ///
    /// 与 `shutting_down` 分开是必须的：那个会让 `supervise` 直接 `break`，
    /// 拿它做"重启"会把整个监督循环连同后续任务一起终结。
    reload_requested: bool,
    /// 想重载但有任务在跑，等心跳把活跃任务清空后再触发。
    reload_pending: bool,
}

/// 对外句柄：克隆廉价，可在执行器与 supervisor 之间共享。
#[derive(Clone, Debug)]
pub struct WorkerHandle {
    shared: Arc<Mutex<Shared>>,
}

impl Default for WorkerHandle {
    fn default() -> Self {
        Self::new()
    }
}

impl WorkerHandle {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(Mutex::new(Shared {
                phase: WorkerPhase::Disabled,
                pid: None,
                last_heartbeat_ms: None,
                restarts: 0,
                last_error: None,
                skills: Vec::new(),
                active_tasks: Vec::new(),
                commands: None,
                shutting_down: false,
                tool_waiters: HashMap::new(),
                reload_requested: false,
                reload_pending: false,
            })),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Shared> {
        // 监督状态只是展示与路由用途，锁中毒时继续用内部数据即可。
        self.shared
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn view(&self) -> WorkerView {
        let shared = self.lock();
        WorkerView {
            phase: shared.phase.as_str(),
            pid: shared.pid,
            last_heartbeat_ms: shared.last_heartbeat_ms,
            restarts: shared.restarts,
            last_error: shared.last_error.clone(),
            skills: shared.skills.clone(),
            active_tasks: shared.active_tasks.clone(),
        }
    }

    /// 这个任务在 worker 侧是否仍被认为在跑。
    ///
    /// 只用于"删现场"的前置判断：worker 断开时一律返回 false（此时 CLI 也随进程组没了）。
    pub fn is_task_active(&self, task_id: &str) -> bool {
        let shared = self.lock();
        shared.phase == WorkerPhase::Connected && shared.active_tasks.iter().any(|id| id == task_id)
    }

    pub fn is_connected(&self) -> bool {
        self.lock().phase == WorkerPhase::Connected
    }

    pub fn is_shutting_down(&self) -> bool {
        self.lock().shutting_down
    }

    /// 向 worker 发一条命令。未连接时返回 false，由调用方决定任务如何收场。
    pub async fn send(&self, message: IpcMessage) -> bool {
        let sender = self.lock().commands.clone();
        match sender {
            Some(sender) => sender.send(message).await.is_ok(),
            None => false,
        }
    }

    /// 请求停止：置标志并发送 shutdown。真正的进程回收由 supervisor 完成。
    pub async fn shutdown(&self) {
        {
            let mut shared = self.lock();
            shared.shutting_down = true;
        }
        let _ = self.send(IpcMessage::Shutdown).await;
    }

    /// 请求重载执行进程（技能清单变了）。
    ///
    /// **不能用 [`Self::shutdown`]**：那条路会让 `supervise` 直接退出循环。
    /// 这里只置 `reload_requested`，循环看到它就不累加失败、不退避、直接重起一轮。
    ///
    /// 有任务在跑时只标记「待生效」，等心跳把活跃任务清空后再真正重载——
    /// 重启会中断正在跑的任务，而装个插件不该让人丢一次跑了十分钟的活。
    pub async fn request_reload(&self) {
        let send_now = {
            let mut shared = self.lock();

            if shared.phase == WorkerPhase::Connected && !shared.active_tasks.is_empty() {
                shared.reload_pending = true;
                return;
            }

            shared.reload_pending = false;
            shared.reload_requested = true;
            shared.commands.is_some()
        };

        if send_now {
            let _ = self.send(IpcMessage::Shutdown).await;
        }
    }

    /// 是否处于「已请求、等空闲」状态。客户端据此提示「当前任务结束后生效」。
    pub fn is_reload_pending(&self) -> bool {
        self.lock().reload_pending
    }

    /// 取走重载请求。只有监督循环该调用。
    fn take_reload_request(&self) -> bool {
        let mut shared = self.lock();
        std::mem::take(&mut shared.reload_requested)
    }

    /// 发起一次工具调用并等待结果。
    ///
    /// 超时或断线都会返回 `Err`：调用方据此让模型写“未核实”，而不是挂住会话。
    pub async fn call_tool(
        &self,
        tool: &str,
        args: serde_json::Value,
        timeout: std::time::Duration,
    ) -> Result<ToolReply, String> {
        if !self.is_connected() {
            return Err("worker 未连接".to_string());
        }

        let call_id = crate::ids::new_id("call");
        let (tx, rx) = oneshot::channel();

        {
            let mut shared = self.lock();
            shared.tool_waiters.insert(call_id.clone(), tx);
        }

        let sent = self
            .send(IpcMessage::ToolCall {
                call_id: call_id.clone(),
                tool: tool.to_string(),
                args,
            })
            .await;

        if !sent {
            self.lock().tool_waiters.remove(&call_id);
            return Err("worker 未连接".to_string());
        }

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => Err("worker 连接已断开".to_string()),
            Err(_) => {
                self.lock().tool_waiters.remove(&call_id);
                tracing::warn!(
                    tool,
                    timeout_ms = timeout.as_millis() as u64,
                    "工具调用等待超时，已放弃"
                );
                Err("工具调用超时".to_string())
            }
        }
    }

    /// 收到 `ToolResult` 时投递给等待方。找不到对应调用（已超时）时丢弃。
    pub(crate) fn complete_tool(&self, call_id: &str, reply: ToolReply) {
        let waiter = self.lock().tool_waiters.remove(call_id);
        if let Some(waiter) = waiter {
            let _ = waiter.send(reply);
        }
    }

    /// 连接结束时唤醒所有等待方：不能让对话因为 worker 消失而挂起。
    fn fail_pending_tools(&self) {
        let waiters = {
            let mut shared = self.lock();
            std::mem::take(&mut shared.tool_waiters)
        };
        // 丢弃 sender 会让接收端立刻收到 `Err`。
        drop(waiters);
    }

    pub(crate) fn set_phase(&self, phase: WorkerPhase) {
        self.lock().phase = phase;
    }

    pub(crate) fn set_pid(&self, pid: Option<u32>) {
        self.lock().pid = pid;
    }

    pub(crate) fn set_error(&self, error: impl Into<String>) {
        self.lock().last_error = Some(error.into());
    }

    pub(crate) fn note_restart(&self) {
        self.lock().restarts += 1;
    }

    pub(crate) fn on_hello(&self, skills: Vec<String>) {
        let mut shared = self.lock();
        shared.phase = WorkerPhase::Connected;
        shared.skills = skills;
        shared.last_heartbeat_ms = Some(crate::clock::now_ms());
        shared.last_error = None;
    }

    pub(crate) fn on_heartbeat(&self, active_tasks: Vec<String>) {
        let mut trigger_reload = false;
        {
            let mut shared = self.lock();
            shared.last_heartbeat_ms = Some(crate::clock::now_ms());
            shared.active_tasks = active_tasks;

            // 任务跑完了：把「待生效」兑现成一次真正的重载。
            if shared.reload_pending && shared.active_tasks.is_empty() {
                shared.reload_pending = false;
                shared.reload_requested = true;
                if let Some(sender) = &shared.commands {
                    // 心跳处理不能 await：用 try_send，队列满就等下一次心跳。
                    let _ = sender.try_send(IpcMessage::Shutdown);
                }
                trigger_reload = true;
            }
        }

        if trigger_reload {
            tracing::info!("worker 已空闲，开始重载技能清单");
        }
    }

    pub(crate) fn clear_connection(&self) {
        {
            let mut shared = self.lock();
            shared.commands = None;
            shared.last_heartbeat_ms = None;
            shared.active_tasks.clear();
            if shared.phase == WorkerPhase::Connected {
                shared.phase = WorkerPhase::Restarting;
            }
        }
        self.fail_pending_tools();
    }

    pub(crate) fn set_commands(&self, sender: Option<tokio::sync::mpsc::Sender<IpcMessage>>) {
        self.lock().commands = sender;
    }
}

/// 计算第 `attempt` 次失败后的等待时长。
pub(crate) fn backoff_for(attempt: u32) -> std::time::Duration {
    let index = (attempt as usize).min(BACKOFF_SECONDS.len() - 1);
    std::time::Duration::from_secs(BACKOFF_SECONDS[index])
}

#[cfg(unix)]
mod imp {
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::time::Duration;

    use protocol::{Envelope, IpcError, IpcMessage};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::{UnixListener, UnixStream};
    use tokio::process::{Child, Command};
    use tokio::sync::mpsc;

    use super::{backoff_for, WorkerHandle, WorkerPhase, CONNECT_TIMEOUT};
    use crate::state::AppState;

    /// 启动监督循环。返回句柄后可立即下发任务（未连上时会失败并说明原因）。
    pub fn spawn(state: AppState) -> WorkerHandle {
        let handle = WorkerHandle::new();

        if !state.config.worker_enabled {
            handle.set_phase(WorkerPhase::Disabled);
            handle.set_error("worker 未启用（配置或平台限制）");
            return handle;
        }

        let loop_handle = handle.clone();
        tokio::spawn(async move {
            supervise(state, loop_handle).await;
        });

        handle
    }

    async fn supervise(state: AppState, handle: WorkerHandle) {
        let socket = state.config.worker_socket_path();
        let mut failures: u32 = 0;

        loop {
            if handle.is_shutting_down() {
                break;
            }

            if failures >= state.config.worker_max_restarts {
                handle.set_phase(WorkerPhase::Stopped);
                handle.set_error(format!(
                    "连续 {failures} 次启动失败，已停止重试；请检查 worker 二进制与日志"
                ));
                tracing::error!(failures, "worker 连续启动失败，停止重试");
                break;
            }

            match serve_once(&state, &handle, &socket).await {
                Ok(()) => {
                    if handle.is_shutting_down() {
                        break;
                    }
                    if handle.take_reload_request() {
                        // 技能清单变更导致的主动退出：不是失败，不退避、不计数。
                        failures = 0;
                        handle.set_phase(WorkerPhase::Restarting);
                        tracing::info!("worker 因重载退出，立即重新拉起");
                        continue;
                    }
                    // 正常断开（进程退出或连接被关）：仍按失败计数退避，避免抖动时刷屏。
                    failures += 1;
                    handle.note_restart();
                    handle.set_phase(WorkerPhase::Restarting);
                    tracing::warn!(failures, "worker 连接结束，准备重启");
                }
                Err(err) => {
                    // 重载没成功也是失败，但要把标志消费掉，
                    // 否则下一次正常断开会被误判成"重载"而跳过退避。
                    let _ = handle.take_reload_request();
                    failures += 1;
                    handle.set_error(err.clone());
                    handle.set_phase(WorkerPhase::Restarting);
                    tracing::warn!(%err, failures, "worker 启动失败");
                }
            }

            let delay = backoff_for(failures.saturating_sub(1));
            tokio::time::sleep(delay).await;
        }

        let _ = std::fs::remove_file(&socket);
        handle.set_commands(None);
        tracing::info!("worker 监督循环已退出");
    }

    async fn serve_once(
        state: &AppState,
        handle: &WorkerHandle,
        socket: &Path,
    ) -> Result<(), String> {
        // 上一轮可能留下 socket 文件。
        let _ = std::fs::remove_file(socket);
        if let Some(parent) = socket.parent() {
            std::fs::create_dir_all(parent).map_err(|err| format!("创建数据目录失败: {err}"))?;
        }

        let listener =
            UnixListener::bind(socket).map_err(|err| format!("绑定 worker 套接字失败: {err}"))?;
        std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))
            .map_err(|err| format!("设置套接字权限失败: {err}"))?;

        let mut child = spawn_process(state, socket)?;
        let pid = child.id();
        handle.set_pid(pid);
        handle.set_phase(WorkerPhase::Starting);
        tracing::info!(pid, socket = %socket.display(), "worker 已拉起，等待连接");

        let accepted = tokio::time::timeout(CONNECT_TIMEOUT, listener.accept()).await;
        let (stream, _) = match accepted {
            Ok(Ok(pair)) => pair,
            Ok(Err(err)) => {
                kill_child(&mut child).await;
                return Err(format!("接受 worker 连接失败: {err}"));
            }
            Err(_) => {
                kill_child(&mut child).await;
                return Err(format!(
                    "等待 worker 连接超时（{} 秒），请确认二进制存在且可执行",
                    CONNECT_TIMEOUT.as_secs()
                ));
            }
        };

        let result = run_connection(state, handle, stream).await;
        kill_child(&mut child).await;
        handle.set_pid(None);
        handle.clear_connection();

        if !handle.is_shutting_down() {
            let requeued =
                crate::worker::events::requeue_on_disconnect(state, "worker 连接断开").await;
            if requeued > 0 {
                tracing::warn!(requeued, "worker 断开，运行中的任务已排回队列");
            }
        }

        result
    }

    fn spawn_process(state: &AppState, socket: &Path) -> Result<Child, String> {
        let binary = state.config.worker_binary();
        if !binary.exists() {
            return Err(format!(
                "找不到 worker 二进制：{}（先执行 cargo build，或用 worker_path 指定）",
                binary.display()
            ));
        }

        let mut command = Command::new(&binary);
        command
            .arg("--socket")
            .arg(socket)
            .arg("--foreground")
            // worker 自己先超时：留 2 秒余量，让真实失败原因能回传。
            .env(
                "PERSONAL_AGENT_TOOL_TIMEOUT_MS",
                state
                    .config
                    .tool
                    .call_timeout_ms
                    .saturating_sub(2_000)
                    .max(1_000)
                    .to_string(),
            )
            // 联网工具的上游选择：这里下发的是**实际生效值**（缺密钥时已降级），
            // worker 不再自己判断"有没有钥匙"——它本来就看不到密钥。
            .env(
                "PERSONAL_AGENT_WEB_SEARCH_PROVIDER",
                state.config.web_search_provider(),
            )
            .env(
                "PERSONAL_AGENT_WEB_FETCH_FALLBACK",
                if state.config.web_fetch_fallback() {
                    "1"
                } else {
                    "0"
                },
            )
            .env(
                "PERSONAL_AGENT_WEB_NEED_CONTENT",
                if state.config.tool.web.need_content {
                    "1"
                } else {
                    "0"
                },
            )
            // 同样的"worker 先超时"策略：让 service 的超时成为最后一道闸，
            // 否则 worker 抢先把等待掐断，真实原因（网关慢还是超预算）就丢了。
            .env(
                "PERSONAL_AGENT_MODEL_CALL_TIMEOUT_MS",
                state
                    .config
                    .task
                    .model_call_timeout_ms
                    .saturating_sub(2_000)
                    .max(1_000)
                    .to_string(),
            )
            // 任务总时限由服务端 ticker 权威回收，worker 侧只用来"别再开新步骤"。
            .env(
                "PERSONAL_AGENT_TASK_DEADLINE_MS",
                state.config.task_timeout_ms.to_string(),
            )
            // 技能包的安装目录。worker 启动时扫这里的 skills/*/.pa-skill.json。
            //
            // 与其它策略一样由 service 下发：worker 不读配置文件，
            // 否则"配置里改了数据目录、worker 还在看老路径"会变成一类难查的问题。
            .env(
                "PERSONAL_AGENT_PLUGIN_DIR",
                state.config.plugins_dir().to_string_lossy().to_string(),
            )
            // 编码任务的策略下发。**密钥不在这里**：真 key 只在 service，
            // worker 拿到的是每个任务一枚的一次性代理令牌（随 Start 下发）。
            .env(
                "PERSONAL_AGENT_CODE_ENABLED",
                if state.config.code.enabled { "1" } else { "0" },
            )
            .env("PERSONAL_AGENT_CODE_PROVIDER", &state.config.code.provider)
            .env(
                "PERSONAL_AGENT_CODE_MODEL",
                state.config.code_upstream_model(),
            )
            .env(
                "PERSONAL_AGENT_CODE_WORKTREE_DIR",
                state.config.code_worktree_dir(),
            )
            .env(
                "PERSONAL_AGENT_CODE_TIMEOUT_MS",
                state.config.code_timeout_ms().to_string(),
            )
            .env(
                "PERSONAL_AGENT_CODE_MAX_CONCURRENT",
                state.config.code.max_concurrent.to_string(),
            )
            // 工具级审批：开关、TTL 与自动放行档都从 service 下发，
            // worker 不读配置文件（策略只有一个来源）。
            .env(
                "PERSONAL_AGENT_CODE_TOOL_APPROVAL",
                if state.config.code.tool_approval.enabled {
                    "1"
                } else {
                    "0"
                },
            )
            .env(
                "PERSONAL_AGENT_CODE_TOOL_APPROVAL_TTL_MS",
                state.config.code.tool_approval.ttl_ms.to_string(),
            )
            .env(
                "PERSONAL_AGENT_CODE_AUTO_ALLOW",
                state.config.code.tool_approval.auto_allow.join(","),
            )
            .env(
                "PERSONAL_AGENT_CODE_ALWAYS_ASK",
                state.config.code.tool_approval.always_ask.join(","),
            )
            // 追加的风险规则：JSON 数组。worker 只做匹配，规则名进审计。
            .env(
                "PERSONAL_AGENT_CODE_EXTRA_RULES",
                serde_json::to_string(&state.config.code.tool_approval.extra_rules)
                    .unwrap_or_else(|_| "[]".to_string()),
            )
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .kill_on_drop(true);

        // CLI 路径是可选覆盖：不配就让 worker 走 PATH，避免多机部署时写死绝对路径。
        if let Some(bin) = &state.config.code.bin {
            command.env("PERSONAL_AGENT_CODE_BIN", bin);
        }

        // 代理地址随进程启动下发：端口是运行时分配的，不能写进配置文件。
        if let Some(proxy) = &state.code_proxy {
            command.env("PERSONAL_AGENT_CODE_PROXY_URL", proxy.base_url());
        }

        // 联网工具代理同理：地址与进程令牌都是运行期的，且**真密钥不在这里**。
        if let Some(proxy) = &state.tool_proxy {
            command
                .env("PERSONAL_AGENT_TOOL_PROXY_URL", proxy.base_url())
                .env("PERSONAL_AGENT_TOOL_PROXY_TOKEN", proxy.token());
        }

        command
            .spawn()
            .map_err(|err| format!("启动 {} 失败: {err}", binary.display()))
    }

    async fn kill_child(child: &mut Child) {
        // 先请求退出再强杀：worker 收到 shutdown 后应该自己走完清理。
        match tokio::time::timeout(Duration::from_secs(3), child.wait()).await {
            Ok(_) => {}
            Err(_) => {
                let _ = child.kill().await;
            }
        }
    }

    async fn run_connection(
        state: &AppState,
        handle: &WorkerHandle,
        stream: UnixStream,
    ) -> Result<(), String> {
        let (read_half, write_half) = stream.into_split();
        let (tx, rx) = mpsc::channel::<IpcMessage>(64);
        handle.set_commands(Some(tx));

        let writer = tokio::spawn(write_loop(write_half, rx));
        let result = read_loop(state, handle, read_half).await;
        writer.abort();

        result
    }

    async fn write_loop(
        mut write_half: tokio::net::unix::OwnedWriteHalf,
        mut rx: mpsc::Receiver<IpcMessage>,
    ) {
        while let Some(message) = rx.recv().await {
            let envelope = Envelope::new(message);
            let line = match envelope.to_line() {
                Ok(line) => line,
                Err(err) => {
                    tracing::error!(%err, "IPC 消息序列化失败");
                    continue;
                }
            };

            if write_half.write_all(line.as_bytes()).await.is_err()
                || write_half.write_all(b"\n").await.is_err()
                || write_half.flush().await.is_err()
            {
                tracing::warn!("worker 连接已断开，停止写命令");
                return;
            }
        }
    }

    async fn read_loop(
        state: &AppState,
        handle: &WorkerHandle,
        read_half: tokio::net::unix::OwnedReadHalf,
    ) -> Result<(), String> {
        let mut lines = BufReader::new(read_half).lines();
        let timeout = Duration::from_millis(state.config.worker_heartbeat_timeout_ms.max(1_000));

        loop {
            let next = tokio::time::timeout(timeout, lines.next_line()).await;

            let line = match next {
                Ok(Ok(Some(line))) => line,
                Ok(Ok(None)) => return Ok(()),
                Ok(Err(err)) => return Err(format!("读取 worker 消息失败: {err}")),
                Err(_) => return Err("worker 心跳超时，判定僵死".to_string()),
            };

            if line.trim().is_empty() {
                continue;
            }

            let envelope = match Envelope::from_line(&line) {
                Ok(envelope) => envelope,
                Err(IpcError::VersionMismatch { found, expected }) => {
                    return Err(format!(
                        "IPC 版本不兼容：worker v{found}，服务端 v{expected}"
                    ));
                }
                Err(err) => {
                    tracing::warn!(%err, "丢弃无法解析的 IPC 消息");
                    continue;
                }
            };

            match envelope.message {
                IpcMessage::Hello { skills, .. } => {
                    let names = skills.iter().map(|skill| skill.name.clone()).collect();
                    handle.on_hello(names);

                    let mut registry = state
                        .skills
                        .write()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    *registry = skills;
                    tracing::info!("worker 已连接并上报技能");
                }
                IpcMessage::Heartbeat { active_tasks } => handle.on_heartbeat(active_tasks),
                IpcMessage::ModelCall {
                    call_id,
                    task_id,
                    purpose,
                    system,
                    prompt,
                    max_tokens,
                } => {
                    // 模型调用可能持续几十秒：必须 spawn，否则读循环停摆，
                    // 心跳也会被堵在同一处，最终被误判僵死。
                    let bridge = state.model_bridge.clone();
                    let handle = handle.clone();
                    tokio::spawn(async move {
                        let reply = bridge
                            .handle(&task_id, &purpose, &system, &prompt, max_tokens)
                            .await;
                        let _ = handle
                            .send(IpcMessage::ModelResult {
                                call_id,
                                ok: reply.ok,
                                text: reply.text,
                                prompt_tokens: reply.prompt_tokens,
                                completion_tokens: reply.completion_tokens,
                                tokens_estimated: reply.tokens_estimated,
                                error: reply.error,
                            })
                            .await;
                    });
                }
                IpcMessage::ToolResult {
                    call_id,
                    ok,
                    summary,
                    source_url,
                    fetched_at,
                    size,
                    error,
                } => handle.complete_tool(
                    &call_id,
                    super::ToolReply {
                        ok,
                        summary,
                        source_url,
                        fetched_at,
                        size,
                        error,
                    },
                ),
                other => {
                    crate::worker::events::apply(state, other).await;
                }
            }
        }
    }
}

#[cfg(not(unix))]
mod imp {
    use super::{WorkerHandle, WorkerPhase};
    use crate::state::AppState;

    /// Windows 上 worker 尚未支持（named pipe 待补齐），返回禁用状态。
    pub fn spawn(_state: AppState) -> WorkerHandle {
        let handle = WorkerHandle::new();
        handle.set_phase(WorkerPhase::Disabled);
        handle.set_error("worker 仅支持 unix（Windows 的 named pipe 待补齐）");
        handle
    }
}

pub use imp::spawn;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_then_caps() {
        assert_eq!(backoff_for(0).as_secs(), 1);
        assert_eq!(backoff_for(1).as_secs(), 2);
        assert_eq!(backoff_for(2).as_secs(), 5);
        assert_eq!(backoff_for(3).as_secs(), 30);
        assert_eq!(backoff_for(99).as_secs(), 30);
    }

    #[test]
    fn new_handle_is_disconnected() {
        let handle = WorkerHandle::new();
        assert!(!handle.is_connected());
        assert_eq!(handle.view().phase, "disabled");
    }
}
