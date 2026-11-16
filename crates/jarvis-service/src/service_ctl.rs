//! `start` / `stop` / `restart` 子命令的实现。
//!
//! 判断依据是"是否注册了开机自启"：
//! - 已注册：必须经系统服务管理器操作。plist 带 `KeepAlive`，直接 kill 进程会被
//!   launchd 立刻拉回来，用户看到的现象是"停止失败"；
//! - 未注册：退回 pid 文件（`daemon-kit::Daemon::stop`），直接对进程发信号。
//!
//! 不引入 `nix` 只为拿一个 uid：`id -u` 足够，也避免为一条命令多一层 FFI。

/// launchd 标签。`daemon-kit` 会自动补 `com.` 前缀，所以这里写完整标签，
/// 与 `main.rs` 的 `SERVICE_NAME` 保持一致。
#[cfg(target_os = "macos")]
const LAUNCHD_LABEL: &str = "com.personalagent.jarvis-service";

/// systemd user unit 名。`daemon-kit` 直接用 service name 作 unit 名。
#[cfg(target_os = "linux")]
const SYSTEMD_UNIT: &str = "personalagent.jarvis-service";

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn run(command: &mut std::process::Command) -> Result<std::process::Output, String> {
    let program = command.get_program().to_string_lossy().into_owned();
    command
        .output()
        .map_err(|err| format!("无法执行 {program}: {err}"))
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn ensure_ok(output: std::process::Output, action: &str) -> Result<(), String> {
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = stderr.trim();
    if detail.is_empty() {
        Err(format!(
            "{action} 失败（退出码 {:?}）",
            output.status.code()
        ))
    } else {
        Err(format!("{action} 失败: {detail}"))
    }
}

// ---------------------------------------------------------------------------
// macOS — launchd（gui 域）
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
mod platform {
    use std::path::PathBuf;
    use std::process::Command;

    use super::{ensure_ok, run, LAUNCHD_LABEL};

    /// 当前用户的 uid：LaunchAgents 挂在 `gui/<uid>` 域下。
    fn uid() -> Result<u32, String> {
        let output = run(Command::new("id").arg("-u"))?;
        if !output.status.success() {
            return Err("无法获取当前用户 uid（id -u 失败）".to_string());
        }
        String::from_utf8_lossy(&output.stdout)
            .trim()
            .parse()
            .map_err(|_| "id -u 的输出不是数字，无法定位 launchd 域".to_string())
    }

    fn domain() -> Result<String, String> {
        Ok(format!("gui/{}", uid()?))
    }

    fn target() -> Result<String, String> {
        Ok(format!("gui/{}/{}", uid()?, LAUNCHD_LABEL))
    }

    fn plist_path() -> Result<PathBuf, String> {
        let home = std::env::var_os("HOME").ok_or("HOME 未设置，无法定位 LaunchAgents 目录")?;
        Ok(PathBuf::from(home)
            .join("Library")
            .join("LaunchAgents")
            .join(format!("{LAUNCHD_LABEL}.plist")))
    }

    /// job 是否已加载。`launchctl print` 成功即加载；
    /// 用 print 而不是 `list | grep`，避免解析人类可读输出。
    fn loaded(target: &str) -> Result<bool, String> {
        let output = run(Command::new("launchctl").args(["print", target]))?;
        Ok(output.status.success())
    }

    /// 启动已注册的服务：未加载走 `bootstrap`，已加载走 `kickstart`
    /// （对运行中的 job 是 no-op，因此重复执行安全）。
    pub fn start() -> Result<(), String> {
        let target = target()?;
        if loaded(&target)? {
            return ensure_ok(
                run(Command::new("launchctl").args(["kickstart", target.as_str()]))?,
                "launchctl kickstart",
            );
        }

        let plist = plist_path()?;
        if !plist.exists() {
            return Err(format!(
                "自启服务未安装（{} 不存在）；先执行 jarvis-service install",
                plist.display()
            ));
        }

        let domain = domain()?;
        let plist_arg = plist.to_string_lossy().into_owned();
        ensure_ok(
            run(Command::new("launchctl").args([
                "bootstrap",
                domain.as_str(),
                plist_arg.as_str(),
            ]))?,
            "launchctl bootstrap",
        )
    }

    /// 停止：`bootout` 卸载整个 job。只 kill 进程的话 `KeepAlive` 会立刻重启它。
    pub fn stop() -> Result<(), String> {
        let target = target()?;
        if !loaded(&target)? {
            return Ok(());
        }
        ensure_ok(
            run(Command::new("launchctl").args(["bootout", target.as_str()]))?,
            "launchctl bootout",
        )
    }

    /// 重启：`kickstart -k` 先杀再拉起；job 未加载（被 stop 过）时退化为 start。
    pub fn restart() -> Result<(), String> {
        let target = target()?;
        if !loaded(&target)? {
            return start();
        }
        ensure_ok(
            run(Command::new("launchctl").args(["kickstart", "-k", target.as_str()]))?,
            "launchctl kickstart -k",
        )
    }
}

// ---------------------------------------------------------------------------
// Linux — systemd user unit
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod platform {
    use std::process::Command;

    use super::{ensure_ok, run, SYSTEMD_UNIT};

    fn systemctl(action: &str) -> Result<(), String> {
        ensure_ok(
            run(Command::new("systemctl").args(["--user", action, SYSTEMD_UNIT]))?,
            &format!("systemctl --user {action}"),
        )
    }

    pub fn start() -> Result<(), String> {
        systemctl("start")
    }

    pub fn stop() -> Result<(), String> {
        systemctl("stop")
    }

    pub fn restart() -> Result<(), String> {
        systemctl("restart")
    }
}

// ---------------------------------------------------------------------------
// Windows 及其他平台
// ---------------------------------------------------------------------------

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    const UNSUPPORTED: &str =
        "start/stop/restart 暂只支持 macOS（launchd）与 Linux（systemd user）";

    pub fn start() -> Result<(), String> {
        Err(UNSUPPORTED.to_string())
    }

    pub fn stop() -> Result<(), String> {
        Err(UNSUPPORTED.to_string())
    }

    pub fn restart() -> Result<(), String> {
        Err(UNSUPPORTED.to_string())
    }
}

pub use platform::{restart, start, stop};
