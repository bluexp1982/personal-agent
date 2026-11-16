//! 退出信号。管理面与对外 API 共用同一套语义。
//!
//! 系统服务管理器停止服务时发 SIGTERM（macOS launchd、systemd 都是），
//! 终端调试时用 Ctrl-C 发 SIGINT，两者都应当优雅关闭。

use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::Notify;

/// 进程内广播的关闭通知。
///
/// 为什么不用 `shutdown_signal()` 直接 select：它只能被 await 一次（多路复用时
/// 每个消费者都要注册一遍系统信号），而长连接（SSH 隧道）需要在收到信号后
/// **主动**收尾，否则优雅关闭会一直等到超时。
///
/// 用「标志位 + Notify」而不是 `Notify::notify_waiters()` 单发：通知可能在某个
/// 长连接注册之前发生，只保留 flag 才能保证后来者立刻看到"已经该关了"。
#[derive(Debug, Default)]
pub struct ShutdownNotice {
    flag: AtomicBool,
    notify: Notify,
}

impl ShutdownNotice {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_shutdown(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    /// 标记关闭并唤醒所有等待者。
    pub fn notify(&self) {
        self.flag.store(true, Ordering::SeqCst);
        self.notify.notify_waiters();
    }

    /// 已关闭时立即返回；否则等到 [`Self::notify`]。
    pub async fn wait(&self) {
        if self.is_shutdown() {
            return;
        }
        // `notified()` 先注册再复查，避免"通知发生在两次检查之间"的丢唤醒。
        let notified = self.notify.notified();
        if self.is_shutdown() {
            return;
        }
        notified.await;
    }
}

/// 等到 Ctrl-C 或 SIGTERM 后返回，调用方据此停止接受新连接。
pub async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(err) => {
                tracing::warn!(%err, "无法注册 SIGTERM 处理，仅响应 Ctrl-C");
                std::future::pending::<()>().await;
            }
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("收到 Ctrl-C"),
        _ = terminate => tracing::info!("收到 SIGTERM"),
    }
    tracing::info!("正在优雅关闭");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn wait_returns_immediately_after_notify() {
        let notice = ShutdownNotice::new();
        notice.notify();
        // 已经通知过：后来注册的等待者也要立刻返回，不能一直挂着。
        tokio::time::timeout(Duration::from_millis(100), notice.wait())
            .await
            .expect("已通知时不应等待");
        assert!(notice.is_shutdown());
    }

    #[tokio::test]
    async fn wait_resolves_when_notified() {
        let notice = std::sync::Arc::new(ShutdownNotice::new());
        let waiter = notice.clone();
        let task = tokio::spawn(async move { waiter.wait().await });

        tokio::time::sleep(Duration::from_millis(10)).await;
        notice.notify();

        tokio::time::timeout(Duration::from_millis(200), task)
            .await
            .expect("通知后应当结束")
            .expect("任务不应 panic");
    }
}
