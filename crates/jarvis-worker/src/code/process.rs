//! CLI 子进程的生命周期。
//!
//! 三条硬要求，每一条都对应一次真实事故：
//! 1. **独立进程组**：取消时对整组发信号，否则 CLI 拉起的子进程会变孤儿；
//! 2. **stdin 置空**：无 TTY 时若 CLI 试图读 stdin，会静默挂住整个任务；
//! 3. **stdout 按行消费 + stderr 环形尾巴**：把管道读干净，避免缓冲区满导致 CLI 阻塞。

use std::collections::VecDeque;
use std::process::Stdio;
use std::time::Duration;

use nix::sys::signal::Signal;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::mpsc;

use crate::runner::Control;

use super::hooks::{self, ToolDecisions};

/// 保留多少行 stderr：足够定位启动失败，又不至于把日志撑爆。
const STDERR_TAIL_LINES: usize = 40;
/// SIGTERM 之后等多久再 SIGKILL。
const REAP_GRACE: Duration = Duration::from_secs(5);

/// 一次执行的结局。三种"没跑完"要分开报，否则用户不知道能不能重试。
#[derive(Debug, Default)]
pub(crate) struct ProcessRun {
    pub(crate) exit_code: Option<i32>,
    pub(crate) timed_out: bool,
    pub(crate) canceled: bool,
    pub(crate) stderr_tail: Vec<String>,
}

impl ProcessRun {
    pub(crate) fn success(&self) -> bool {
        self.exit_code == Some(0) && !self.timed_out && !self.canceled
    }
}

/// 跑一个 CLI 进程，把 stdout 的每一行交给 `on_line`。
pub(crate) async fn run(
    mut command: tokio::process::Command,
    timeout: Duration,
    control: &mut mpsc::Receiver<Control>,
    decisions: &ToolDecisions,
    mut on_line: impl FnMut(&str),
) -> std::io::Result<ProcessRun> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // 在这里统一设进程组，而不是让每个 provider 自己记得设：
    // 漏设的后果是取消时杀不到孙进程，测试与生产行为还会不一致。
    #[cfg(unix)]
    command.process_group(0);

    let mut child = command.spawn()?;
    let pgid = child.id();
    tracing::info!(pid = pgid, "编码 CLI 已启动");

    // stderr 单独读：不读就会填满管道，CLI 卡在写 stderr 上，看起来像"任务不动了"。
    let stderr_task = child.stderr.take().map(|stderr| {
        tokio::spawn(async move {
            let mut tail: VecDeque<String> = VecDeque::new();
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if tail.len() == STDERR_TAIL_LINES {
                    tail.pop_front();
                }
                tail.push_back(line);
            }
            tail
        })
    });

    let mut result = ProcessRun::default();
    let deadline = tokio::time::sleep(timeout);
    tokio::pin!(deadline);

    match child.stdout.take() {
        Some(stdout) => {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                tokio::select! {
                    () = &mut deadline => {
                        tracing::warn!(pid = pgid, "编码 CLI 超时，终止进程组");
                        result.timed_out = true;
                        signal_group(pgid, Signal::SIGTERM);
                        break;
                    }
                    incoming = control.recv() => {
                        match incoming {
                            Some(Control::Cancel) | None => {
                                tracing::info!(pid = pgid, "收到取消，终止进程组");
                                result.canceled = true;
                                signal_group(pgid, Signal::SIGTERM);
                                break;
                            }
                            // 审批恢复对正在运行的任务没有意义：忽略而不是当成取消。
                            Some(Control::Resume) => {}
                            Some(Control::ToolDecision {
                                call_id,
                                approved,
                                reason,
                                remember,
                            }) => {
                                // 工具级裁决的唯一消费者：钩子端点正在等这个。
                                if !hooks::resolve_control(
                                    decisions,
                                    &call_id,
                                    approved,
                                    remember,
                                    reason.as_deref(),
                                ) {
                                    tracing::debug!(%call_id, "工具裁决没有等待者（可能已超时）");
                                }
                            }
                        }
                    }
                    line = lines.next_line() => {
                        match line {
                            Ok(Some(line)) => on_line(&line),
                            Ok(None) => break,
                            Err(err) => {
                                tracing::warn!(%err, "读取 CLI 输出失败，按进程结束处理");
                                break;
                            }
                        }
                    }
                }
            }
        }
        None => {
            tracing::warn!("CLI 没有可读的 stdout，仅等待退出");
            let _ = tokio::time::timeout(timeout, child.wait()).await;
        }
    }

    // 先礼后兵：SIGTERM 已发过，若 5 秒内不退出就整组 SIGKILL。
    match tokio::time::timeout(REAP_GRACE, child.wait()).await {
        Ok(Ok(status)) => result.exit_code = status.code(),
        Ok(Err(err)) => tracing::warn!(%err, "等待 CLI 退出失败"),
        Err(_) => {
            tracing::warn!(pid = pgid, "CLI 未在宽限期内退出，强制终止进程组");
            signal_group(pgid, Signal::SIGKILL);
            let _ = child.wait().await;
        }
    }

    if let Some(task) = stderr_task {
        if let Ok(tail) = task.await {
            result.stderr_tail = tail.into_iter().collect();
        }
    }

    Ok(result)
}

/// 向进程组发信号。
///
/// 用 `kill(-pgid)` 而不是 `killpg`：两者语义相同，但前者在 nix 各版本里签名一致。
/// 负 pid 指向"以该 pid 为组长的整个进程组"——CLI 自己拉起的子进程也在此组内。
fn signal_group(pid: Option<u32>, signal: Signal) {
    let Some(pid) = pid else {
        return;
    };
    let group = nix::unistd::Pid::from_raw(-(pid as i32));
    if let Err(err) = nix::sys::signal::kill(group, signal) {
        tracing::warn!(%err, pid, "向进程组发送信号失败");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn channel() -> (mpsc::Sender<Control>, mpsc::Receiver<Control>) {
        mpsc::channel(4)
    }

    #[tokio::test]
    async fn collects_stdout_lines_and_exit_code() {
        // 必须保留发送端：`recv()` 返回 None 会被当作"连接已断"，那是取消语义，
        // 进程会在读完输出前就被终止。
        let (_tx, mut rx) = channel();

        let decisions = ToolDecisions::new();
        let mut command = tokio::process::Command::new("/bin/sh");
        command.arg("-c").arg("printf 'a\\nb\\n'");

        let mut seen = Vec::new();
        let run = run(
            command,
            Duration::from_secs(10),
            &mut rx,
            &decisions,
            |line| seen.push(line.to_string()),
        )
        .await
        .expect("进程执行失败");

        assert_eq!(seen, vec!["a".to_string(), "b".to_string()]);
        assert!(run.success(), "退出码应为 0: {run:?}");
    }

    #[tokio::test]
    async fn timeout_marks_run_and_kills_group() {
        let (_tx, mut rx) = channel();
        let decisions = ToolDecisions::new();
        let mut command = tokio::process::Command::new("/bin/sh");
        command.arg("-c").arg("sleep 30");

        let start = std::time::Instant::now();
        let run = run(
            command,
            Duration::from_millis(300),
            &mut rx,
            &decisions,
            |_| {},
        )
        .await
        .expect("进程执行失败");

        assert!(run.timed_out, "应标记超时");
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "超时后应尽快返回"
        );
    }

    #[tokio::test]
    async fn cancel_stops_the_process_group() {
        let (tx, mut rx) = channel();
        let decisions = ToolDecisions::new();
        let mut command = tokio::process::Command::new("/bin/sh");
        command.arg("-c").arg("sleep 30");

        let handle = tokio::spawn(async move {
            tx.send(Control::Cancel).await.ok();
        });

        let run = run(
            command,
            Duration::from_secs(30),
            &mut rx,
            &decisions,
            |_| {},
        )
        .await
        .expect("进程执行失败");
        handle.await.ok();

        assert!(run.canceled, "应标记取消");
        assert!(!run.timed_out);
    }

    #[tokio::test]
    async fn stderr_tail_is_kept() {
        let (_tx, mut rx) = channel();
        let decisions = ToolDecisions::new();
        let mut command = tokio::process::Command::new("/bin/sh");
        command.arg("-c").arg("echo boom >&2; exit 3");

        let run = run(
            command,
            Duration::from_secs(10),
            &mut rx,
            &decisions,
            |_| {},
        )
        .await
        .expect("进程执行失败");

        assert_eq!(run.exit_code, Some(3));
        assert!(!run.success());
        assert!(
            run.stderr_tail.iter().any(|line| line.contains("boom")),
            "应保留 stderr: {:?}",
            run.stderr_tail
        );
    }
}
