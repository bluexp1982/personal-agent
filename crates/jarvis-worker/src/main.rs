//! `jarvis-worker` 入口。
//!
//! 由 `jarvis-service` 以子进程方式拉起，通过本地套接字接收任务。它：
//! - **不监听任何对外端口**，不参与配对与鉴权；
//! - **不持有 API Key、不写数据库**，只执行任务并上报事件；
//! - 断线后自动重连，退出由服务端下发 `shutdown` 或进程被终止。

#[cfg(unix)]
mod code;
#[cfg(unix)]
mod hook_shim;
#[cfg(unix)]
mod ipc;
#[cfg(unix)]
mod local_tool;
mod logging;
#[cfg(unix)]
mod model;
#[cfg(unix)]
mod runner;
mod skills;
mod tools;

use std::path::PathBuf;

use clap::Parser;

/// 任务执行进程。
#[derive(Debug, Parser)]
#[command(name = "jarvis-worker", version, about = "personal-agent 任务执行进程")]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// 前台运行，不 fork。由 jarvis-service 拉起时使用。
    #[arg(long)]
    foreground: bool,

    /// 服务端的本地套接字路径。单独启动时必须提供。
    #[arg(long = "socket", alias = "ipc-path")]
    socket: Option<PathBuf>,
}

/// 隐藏子命令。目前只有"编码 CLI 的钩子客户端"这一个用途：
/// 它会阻塞等一次人工决策，绝不能走正常的 worker 启动流程（连 IPC / 建日志）。
#[derive(Debug, clap::Subcommand)]
enum Command {
    /// 给编码 CLI 的 PreToolUse 钩子用：问 worker 这一次能不能执行。
    #[command(hide = true, name = "hook-shim")]
    HookShim {
        /// 本任务决策端点的 unix socket 路径。
        #[arg(long)]
        socket: PathBuf,
    },
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    // 钩子路径必须在任何初始化之前分流：它要的是"快、静、只输出一行 JSON"。
    #[cfg(unix)]
    if let Some(Command::HookShim { socket }) = &args.command {
        std::process::exit(hook_shim::run(socket));
    }

    logging::init();

    tracing::info!(
        version = protocol::VERSION,
        ipc_contract = protocol::IPC_CONTRACT_VERSION,
        "jarvis-worker 启动"
    );

    #[cfg(unix)]
    {
        let Some(socket) = args.socket.clone() else {
            tracing::error!("缺少 --socket：worker 应由 jarvis-service 拉起，不应单独启动");
            return Ok(());
        };
        run_loop(socket).await;
    }

    #[cfg(not(unix))]
    {
        let _ = &args;
        tracing::warn!("jarvis-worker 目前只支持 unix；Windows 的 named pipe 待补齐");
    }

    Ok(())
}

#[cfg(unix)]
async fn run_loop(socket: PathBuf) {
    use std::sync::Arc;

    use crate::tools::ToolRegistry;

    let tools = Arc::new(ToolRegistry::new());
    let code = Arc::new(code::Runtime::from_env());

    // 插件安装目录由 service 下发（worker 不读配置文件）。
    // 没配或没装过插件时是 `None`，只加载内置技能。
    let plugin_dir = std::env::var("PERSONAL_AGENT_PLUGIN_DIR")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);

    let skills = Arc::new(skills::load_all(
        &tools,
        code.enabled(),
        plugin_dir.as_deref(),
    ));
    // 模型调用跨连接复用：等待表本身不存连接状态，断线时统一唤醒。
    let model = Arc::new(model::ModelClient::new(model::timeout_from_env()));
    // 读项目文件的客户端：与模型调用同样的等待语义，同样跨连接复用。
    let local = Arc::new(local_tool::LocalToolClient::new(
        local_tool::timeout_from_env(),
    ));

    if code.enabled() {
        tracing::info!(
            provider = code.provider_id(),
            "编码任务已启用（模型请求经 service 代理，令牌逐任务下发）"
        );
    } else {
        tracing::info!("编码任务未启用（code-task 技能不会加载）");
    }

    if skills.is_empty() {
        tracing::error!("没有任何可用技能，worker 仍会连接但无法执行任务");
    } else {
        tracing::info!(count = skills.len(), "技能已加载（内置 + 插件）");
    }

    loop {
        match ipc::Connection::connect(&socket).await {
            Ok(connection) => {
                let exit = session(
                    connection,
                    skills.clone(),
                    tools.clone(),
                    model.clone(),
                    local.clone(),
                    code.clone(),
                )
                .await;
                // 连接结束：让还在等应答的任务立刻收到"连接已断开"，
                // 而不是干等到超时。
                model.fail_all();
                local.fail_all();
                if exit {
                    tracing::info!("收到 shutdown，worker 退出");
                    return;
                }
                tracing::warn!("与服务端连接结束，准备重连");
            }
            Err(err) => {
                tracing::warn!(%err, path = %socket.display(), "连接服务端失败，1 秒后重试");
            }
        }

        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
}

#[cfg(unix)]
async fn session(
    mut connection: ipc::Connection,
    skills: std::sync::Arc<Vec<skills::LoadedSkill>>,
    tools: std::sync::Arc<tools::ToolRegistry>,
    model: std::sync::Arc<model::ModelClient>,
    local: std::sync::Arc<local_tool::LocalToolClient>,
    code: std::sync::Arc<code::Runtime>,
) -> bool {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    use protocol::{IpcMessage, IPC_VERSION};
    use tokio::sync::mpsc;

    use crate::runner::{self, Control, TaskJob};

    let client = connection.client.clone();
    let manifests: Vec<protocol::SkillManifest> =
        skills.iter().map(|skill| skill.manifest.clone()).collect();

    if !client
        .send(IpcMessage::Hello {
            version: protocol::VERSION.to_string(),
            ipc_version: IPC_VERSION,
            skills: manifests,
        })
        .await
    {
        return false;
    }

    let tasks: Arc<Mutex<HashMap<String, mpsc::Sender<Control>>>> =
        Arc::new(Mutex::new(HashMap::new()));

    // 取消可能比 Start 先到（服务端在 spawn 里异步下发 Start）：记下来，Start 时直接跳过。
    let cancelled = Arc::new(Mutex::new(runner::CancelledTasks::default()));

    // 心跳：5 秒一次，附带当前活跃任务，服务端据此判断僵死。
    let heartbeat = {
        let client = client.clone();
        let tasks = tasks.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
            loop {
                interval.tick().await;
                let active = {
                    let map = tasks
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    map.keys().cloned().collect()
                };
                if !client
                    .send(IpcMessage::Heartbeat {
                        active_tasks: active,
                    })
                    .await
                {
                    break;
                }
            }
        })
    };

    let mut exit = false;

    while let Some(message) = connection.next().await {
        match message {
            IpcMessage::Start {
                task_id,
                task_type,
                skill,
                input,
                token,
                provider,
                model: code_model,
                bin,
                route_reason,
            } => {
                // 先看有没有"提前到达的取消"。检查与插入之间不能有 await，
                // 否则与同一条连接上的 Cancel 处理会交错。
                let pre_cancelled = {
                    let mut guard = cancelled
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    guard.take(&task_id)
                };
                if pre_cancelled {
                    tracing::info!(%task_id, "任务在开始前已被取消，跳过执行");
                    continue;
                }

                let (tx, rx) = mpsc::channel(4);
                {
                    let mut map = tasks
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    map.insert(task_id.clone(), tx);
                }

                tracing::info!(%task_id, task_type = %task_type, "收到任务");

                let client = client.clone();
                let skills = skills.clone();
                let tools = tools.clone();
                let model = model.clone();
                let local = local.clone();
                let code = code.clone();
                let tasks_done = tasks.clone();
                let cancelled_done = cancelled.clone();
                let job = TaskJob {
                    task_id: task_id.clone(),
                    task_type,
                    skill,
                    input,
                    token,
                    code: crate::code::CodeOptions {
                        provider,
                        model: code_model,
                        bin: bin.map(std::path::PathBuf::from),
                        route_reason,
                    },
                };

                tokio::spawn(async move {
                    runner::run(client, skills, tools, model, local, code, job, rx).await;
                    let mut map = tasks_done
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    map.remove(&task_id);
                    // 收尾时清掉取消记录：重试会复用同一个 task_id，陈旧记录会误跳下一次执行。
                    let mut guard = cancelled_done
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    guard.forget(&task_id);
                });
            }
            IpcMessage::Resume {
                task_id,
                call_id,
                decision,
                remember,
            } => {
                // 带 call_id + decision 的是工具级裁决；否则仍是任务级的"继续"。
                let control = match (call_id, decision) {
                    (Some(call_id), Some(decision)) => Control::ToolDecision {
                        call_id,
                        approved: decision.approved(),
                        reason: None,
                        remember: remember.unwrap_or(false),
                    },
                    _ => Control::Resume,
                };
                forward(&tasks, &task_id, control).await;
            }
            IpcMessage::Cancel { task_id } => {
                if !forward(&tasks, &task_id, Control::Cancel).await {
                    // 任务还没开始（Start 还在调度里）：记下来，Start 到达时直接跳过。
                    let mut guard = cancelled
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    guard.mark(&task_id);
                }
            }
            IpcMessage::ToolCall {
                call_id,
                tool,
                args,
            } => {
                // 只读工具：失败也要回传，让模型据此写"未核实"，而不是让对话等待。
                tracing::info!(%call_id, tool = %tool, "收到工具调用");
                let client = client.clone();
                let tools = tools.clone();
                tokio::spawn(async move {
                    let message = match tools.call(&tool, &args).await {
                        Ok(output) => IpcMessage::ToolResult {
                            call_id,
                            ok: true,
                            summary: output.summary,
                            // 没有来源的调用（搜索）如实回 `None`：采集时间只在
                            // 真读过页面时才有意义，编一个出来就是伪造。
                            fetched_at: output.source_url.as_ref().map(|_| output.fetched_at),
                            source_url: output.source_url,
                            size: output.size,
                            error: None,
                        },
                        Err(err) => IpcMessage::ToolResult {
                            call_id,
                            ok: false,
                            summary: String::new(),
                            source_url: None,
                            fetched_at: None,
                            size: 0,
                            error: Some(err.to_string()),
                        },
                    };

                    tracing::info!(ok = message_ok(&message), "工具调用结束");
                    let _ = client.send(message).await;
                });
            }
            IpcMessage::ModelResult {
                call_id,
                ok,
                text,
                prompt_tokens,
                completion_tokens,
                tokens_estimated,
                error,
            } => {
                tracing::debug!(
                    %call_id,
                    ok,
                    prompt_tokens,
                    completion_tokens,
                    tokens_estimated,
                    "收到模型结果"
                );
                model.deliver(
                    &call_id,
                    model::ModelReply {
                        text,
                        error: if ok {
                            None
                        } else {
                            Some(error.unwrap_or_else(|| "model_error".to_string()))
                        },
                    },
                );
            }
            IpcMessage::LocalToolResult {
                call_id,
                ok,
                content,
                error,
            } => {
                tracing::debug!(%call_id, ok, "收到本地工具结果");
                local.deliver(
                    &call_id,
                    local_tool::LocalToolReply {
                        content,
                        error: if ok {
                            None
                        } else {
                            Some(error.unwrap_or_else(|| "本地工具执行失败".to_string()))
                        },
                    },
                );
            }
            IpcMessage::Shutdown => {
                exit = true;
                break;
            }
            other => tracing::warn!(?other, "worker 收到不适用于自己的消息"),
        }
    }

    heartbeat.abort();
    connection.close();
    exit
}

#[cfg(unix)]
fn message_ok(message: &protocol::IpcMessage) -> bool {
    matches!(message, protocol::IpcMessage::ToolResult { ok: true, .. })
}

#[cfg(unix)]
/// 把一个控制信号转给正在执行的任务。返回是否找到了该任务的执行实例。
#[cfg(unix)]
async fn forward(
    tasks: &std::sync::Arc<
        std::sync::Mutex<
            std::collections::HashMap<String, tokio::sync::mpsc::Sender<crate::runner::Control>>,
        >,
    >,
    task_id: &str,
    control: crate::runner::Control,
) -> bool {
    // 先克隆出发送端再 await，避免把 MutexGuard 跨 await 持有。
    let sender = {
        let map = tasks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        map.get(task_id).cloned()
    };

    match sender {
        Some(sender) => {
            let _ = sender.send(control).await;
            true
        }
        None => {
            tracing::debug!(task_id, "任务不在执行中，控制信号被忽略");
            false
        }
    }
}
