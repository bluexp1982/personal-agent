//! `jarvis-service` 入口。
//!
//! **必须是同步 `main`**：`daemon-kit` 的 `start()` 在 Unix 上调用 `fork()`，
//! 而 fork 之后只有调用线程存活——若此时 Tokio 运行时已启动（多线程），
//! 子进程里的 worker 线程全部消失，服务会静默卡死。
//! 因此顺序固定为：解析参数 → 初始化日志 → daemonize → 在闭包内创建 runtime。

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use daemon_kit::{Daemon, DaemonConfig};

use jarvis_service::app;
use jarvis_service::config::Config;
use jarvis_service::logging;

/// 服务标识：同时用于 launchd 的 plist 名、systemd unit 名与 pid 文件名。
///
/// 注意：`daemon-kit` 会在内部再拼一层 `com.` 前缀（launchd 标签与 plist 文件名都是
/// `com.{name}`），所以这里**不能**自带 `com.`，否则会注册成 `com.com.xxx`。
const SERVICE_NAME: &str = "personalagent.jarvis-service";

#[derive(Debug, Parser)]
#[command(name = "jarvis-service", version, about = "personal-agent 常驻服务")]
struct Args {
    /// 前台运行，不 fork。系统服务管理器启动时使用。
    #[arg(long)]
    foreground: bool,

    /// 管理面端口，仅 Windows 回退路径使用；0 表示由系统分配。
    #[arg(long)]
    port: Option<u16>,

    /// 配置文件路径（JSON）。缺省时使用内置默认值。
    #[arg(long)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// 注册开机自启服务（macOS launchd / Linux systemd user unit / Windows SCM）
    Install,
    /// 移除开机自启服务
    Uninstall,
    /// 查看当前运行状态
    Status,
    /// 启动服务（已注册自启时经 launchd / systemd 启动，否则后台 fork）
    Start,
    /// 停止服务（已注册自启时卸载 job，避免 KeepAlive 立刻拉起）
    Stop,
    /// 重启服务（已注册自启时走 launchctl kickstart -k / systemctl restart）
    Restart,
    /// 配对：无参数生成配对码；--list 看待确认；--approve / --reject 处理；--reset 吊销全部设备
    Pair {
        /// 列出待确认的配对请求
        #[arg(long)]
        list: bool,
        /// 批准指定的配对请求
        #[arg(long, value_name = "REQUEST_ID")]
        approve: Option<String>,
        /// 拒绝指定的配对请求
        #[arg(long, value_name = "REQUEST_ID")]
        reject: Option<String>,
        /// 吊销全部已配对设备（默认只打印清单，需配合 --yes 执行）
        #[arg(long)]
        reset: bool,
        /// 确认执行 --reset
        #[arg(long)]
        yes: bool,
    },
    /// 管理技能包：安装 zip、列表、启停、卸载
    Plugin {
        #[command(subcommand)]
        action: PluginAction,
    },
}

#[derive(Debug, Subcommand)]
enum PluginAction {
    /// 从 zip 安装技能包（符合 Agent Skills 规范的包都能装）
    Install {
        /// zip 文件路径
        path: PathBuf,
    },
    /// 列出已安装的技能包
    List,
    /// 卸载
    Remove {
        /// 插件 id（`plugin list` 的第一列）
        id: String,
    },
    /// 启用
    Enable { id: String },
    /// 停用
    Disable { id: String },
    /// 恢复随应用分发的预置技能（卸载过也能装回来）
    Restore {
        /// 插件 id 或技能目录名；省略时恢复全部预置技能
        id: Option<String>,
    },
}

fn main() -> ExitCode {
    let args = Args::parse();
    logging::init();

    let config = match Config::load(args.config.as_deref()) {
        Ok(config) => config.with_port(args.port),
        Err(err) => {
            tracing::error!(%err, "配置加载失败，服务退出");
            return ExitCode::FAILURE;
        }
    };

    if let Err(err) = std::fs::create_dir_all(&config.data_dir) {
        tracing::error!(path = %config.data_dir.display(), %err, "创建数据目录失败");
        return ExitCode::FAILURE;
    }

    // 启动前自检：非回环 + 明文这类组合必须在监听之前拒绝。
    // 等到端口已经对外开放再报错，等于给了几分钟的明文窗口。
    let starting_service = matches!(
        &args.command,
        None | Some(Command::Start) | Some(Command::Restart)
    );
    if starting_service {
        if let Err(reason) = config.validate() {
            tracing::error!("{reason}");
            return ExitCode::FAILURE;
        }
    }

    // service_args 必须显式覆盖：daemon-kit 默认是 ["daemon", "--foreground"]，
    // 而本二进制没有 daemon 子命令，直接用默认值会导致服务启动即参数解析失败。
    let daemon = Daemon::new(
        DaemonConfig::new(SERVICE_NAME)
            .pid_dir(config.data_dir.clone())
            .log_file(config.log_path())
            .service_args(vec!["--foreground".to_string()])
            .description("personal-agent 常驻服务"),
    );

    let result: Result<(), String> = match args.command {
        Some(Command::Install) => {
            daemon
                .install_service()
                .map_err(|err| err.to_string())
                .map(|()| {
                    tracing::info!(service = SERVICE_NAME, "已注册开机自启服务");
                })
        }
        Some(Command::Uninstall) => daemon
            .uninstall_service()
            .map_err(|err| err.to_string())
            .map(|()| {
                tracing::info!(service = SERVICE_NAME, "已移除开机自启服务");
            }),
        Some(Command::Status) => {
            report_status(&daemon);
            Ok(())
        }
        Some(Command::Start) => start(&daemon, &config, args.foreground),
        Some(Command::Stop) => stop(&daemon),
        Some(Command::Restart) => restart(&daemon, &config),
        Some(Command::Pair {
            list,
            approve,
            reject,
            reset,
            yes,
        }) => run_pair(&config, list, approve, reject, reset, yes),
        Some(Command::Plugin { action }) => run_plugin(&config, action),
        None => {
            if !args.foreground {
                tracing::info!("未指定 --foreground，将后台运行（fork 由 daemon-kit 完成）");
            }
            let config = config.clone();
            daemon
                .start(args.foreground, move || run_blocking(config))
                .map_err(|err| err.to_string())
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            tracing::error!(%err, "jarvis-service 退出");
            ExitCode::FAILURE
        }
    }
}

/// 在 daemon 闭包内创建运行时并跑服务循环。
fn run_blocking(config: Config) -> daemon_kit::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|err| {
            daemon_kit::DaemonError::Daemonize(format!("创建 Tokio 运行时失败: {err}"))
        })?;

    runtime.block_on(async move {
        tracing::info!(
            version = protocol::VERSION,
            api = protocol::API_VERSION,
            ipc = protocol::IPC_CONTRACT_VERSION,
            data_dir = %config.data_dir.display(),
            "jarvis-service 启动"
        );

        if let Err(err) = app::run(config).await {
            tracing::error!(%err, "服务异常退出");
            return Err(daemon_kit::DaemonError::Daemonize(err.to_string()));
        }

        tracing::info!("jarvis-service 已退出");
        Ok(())
    })
}

/// `start`：已注册自启时交给系统服务管理器，未注册时退回原有的启动路径
/// （`foreground = false` 由 daemon-kit fork 到后台）。
fn start(daemon: &Daemon, config: &Config, foreground: bool) -> Result<(), String> {
    if daemon.is_service_installed() {
        return jarvis_service::service_ctl::start().map(|()| {
            tracing::info!(service = SERVICE_NAME, "已请求启动开机自启服务");
        });
    }

    let config = config.clone();
    daemon
        .start(foreground, move || run_blocking(config))
        .map_err(|err| err.to_string())
}

/// `stop`：先卸掉服务管理器里的 job（否则 `KeepAlive` 会立刻拉起），
/// 再用 pid 文件兜底处理绕过服务管理器手动起的实例。
fn stop(daemon: &Daemon) -> Result<(), String> {
    if daemon.is_service_installed() {
        jarvis_service::service_ctl::stop()?;
        tracing::info!(service = SERVICE_NAME, "已卸载 launchd / systemd job");
    }

    daemon.stop().map_err(|err| err.to_string())?;
    tracing::info!("服务已停止");
    Ok(())
}

/// `restart`：已注册时交给服务管理器；未注册时 stop + 后台 start。
fn restart(daemon: &Daemon, config: &Config) -> Result<(), String> {
    if daemon.is_service_installed() {
        return jarvis_service::service_ctl::restart().map(|()| {
            tracing::info!(service = SERVICE_NAME, "服务已重启");
        });
    }

    stop(daemon)?;
    // 端口释放与 SQLite 连接收尾不是瞬间完成的，给一小段缓冲再拉起。
    std::thread::sleep(std::time::Duration::from_millis(300));
    start(daemon, config, false)
}

fn report_status(daemon: &Daemon) {
    if daemon.is_service_installed() {
        tracing::info!("开机自启：已注册（由 launchd / systemd 托管）");
    } else {
        tracing::info!("开机自启：未注册（进程由 pid 文件管理，可执行 install 注册）");
    }

    match daemon.running_pid() {
        Some(pid) => tracing::info!(pid, "服务运行中"),
        None => tracing::info!("服务未运行"),
    }
}

/// `pair` 子命令：经管理面操作配对票据，不直接读写数据库。
/// 读取服务实际监听的端口（`api.port`）。
///
/// 配对输出要打印"客户端该填哪个地址"：`api_bind` 被配置成 `:0` 时端口是运行期分配的，
/// 只有这个文件知道答案。读不到就当未知，让 `pair` 退回只打印配对码。
#[cfg(unix)]
fn read_api_port(config: &Config) -> Option<u16> {
    std::fs::read_to_string(config.api_port_path())
        .ok()?
        .trim()
        .parse()
        .ok()
}

/// `plugin` 子命令：直接读写库与插件目录，不依赖运行中的服务。
///
/// 服务可能没起来（刚装好还没 `install`，或者用户故意停着），
/// 所以这里不复用管理面套接字。
fn run_plugin(config: &Config, action: PluginAction) -> Result<(), String> {
    use jarvis_service::plugin::cli::{self, CliAction};

    let action = match action {
        PluginAction::Install { path } => CliAction::Install(path),
        PluginAction::List => CliAction::List,
        PluginAction::Remove { id } => CliAction::Remove(id),
        PluginAction::Enable { id } => CliAction::Enable(id),
        PluginAction::Disable { id } => CliAction::Disable(id),
        PluginAction::Restore { id } => CliAction::Restore(id),
    };

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|err| err.to_string())?;

    let lines = runtime.block_on(cli::run(config, action))?;
    for line in lines {
        tracing::info!("{line}");
    }
    Ok(())
}

fn run_pair(
    config: &Config,
    list: bool,
    approve: Option<String>,
    reject: Option<String>,
    reset: bool,
    yes: bool,
) -> Result<(), String> {
    if approve.is_some() && reject.is_some() {
        return Err("--approve 与 --reject 不能同时使用".to_string());
    }
    // --reset 是"全体掉线"级别的操作，参数组合一律从严：宁可报错，也不猜用户想干什么。
    if reset && (list || approve.is_some() || reject.is_some()) {
        return Err("--reset 不能与 --list / --approve / --reject 同时使用".to_string());
    }
    if yes && !reset {
        return Err("--yes 只用于 --reset".to_string());
    }

    #[cfg(unix)]
    {
        let socket = config.admin_socket_path();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|err| err.to_string())?;

        // 地址信息来自两处：端口取运行中的服务（`api.port`），
        // scheme 与"是否对外"取启动配置——客户端据此决定用 http 还是 https。
        let address = read_api_port(config).map(|port| jarvis_service::cli::PairAddress {
            scheme: if config.tls_required() {
                "https"
            } else {
                "http"
            },
            port,
            lan_ip: if config.is_loopback_bind() {
                None
            } else {
                jarvis_service::tls::detect_lan_ip()
            },
        });

        runtime.block_on(async {
            let outcome = match (approve, reject, list, reset) {
                // --reset 排在最前：否则 (None, None, false, true) 会掉进"生成配对码"兜底。
                (None, None, false, true) => jarvis_service::cli::reset_devices(&socket, yes).await,
                (Some(id), None, _, _) => jarvis_service::cli::approve(&socket, &id).await,
                (None, Some(id), _, _) => jarvis_service::cli::reject(&socket, &id).await,
                (None, None, true, _) => jarvis_service::cli::list_pending(&socket).await,
                // 兜底即"生成配对码"：`--approve` 与 `--reject` 同时出现的情况
                // 已在上方提前返回错误，不会走到这里。
                _ => jarvis_service::cli::start_pairing(&socket, address).await,
            };
            outcome.map_err(|err| err.to_string())
        })
    }

    #[cfg(windows)]
    {
        let _ = (config, list, approve, reject, reset, yes);
        Err("pair 子命令暂只支持 unix 管理面；Windows 的回环回退在 v1.2 补齐".to_string())
    }
}
