//! 技能读项目文件的客户端。
//!
//! 方向与 [`crate::tools::ToolRegistry`] 相反：那边是 worker 自己读外部世界，
//! 这边是 **worker 请 service 读本地磁盘**。
//!
//! 为什么必须绕回服务端：路径准入（项目根、软链接不越界、密钥类文件拦截）
//! 只实现在 `jarvis-service` 的 `path_guard`，而 worker 既不查库、
//! 也不知道这个任务属于哪个目录。让 worker 自己拼路径等于把准入规则抄一份，
//! 两份规则迟早会不一致。
//!
//! 等待必须能被三件事打断：收到应答、超时、连接断开。任何一条缺失，
//! 任务会挂在一个永远不会再来的应答上。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use protocol::IpcMessage;
use tokio::sync::oneshot;

use crate::ipc::Client;

/// 一次本地工具调用的应答。
///
/// `ok=false` 不是程序错误，而是"这次读不到"：调用方据此写「未获取 + 原因」，
/// 不中断任务。
#[derive(Debug, Clone)]
pub(crate) struct LocalToolReply {
    pub(crate) content: String,
    pub(crate) error: Option<String>,
}

impl LocalToolReply {
    pub(crate) fn is_ok(&self) -> bool {
        self.error.is_none()
    }
}

#[derive(Debug)]
pub(crate) struct LocalToolClient {
    waiters: Mutex<HashMap<String, oneshot::Sender<LocalToolReply>>>,
    seq: AtomicU64,
    timeout: Duration,
}

impl LocalToolClient {
    pub(crate) fn new(timeout: Duration) -> Self {
        Self {
            waiters: Mutex::new(HashMap::new()),
            seq: AtomicU64::new(0),
            timeout,
        }
    }

    /// 发一条 `LocalToolCall` 并等待结果。
    ///
    /// 超时上限比服务端小（supervisor 下发时已减 2 秒）：
    /// 让"service 判超时"晚于"worker 拿到真实失败原因"，否则原因会被吞掉。
    pub(crate) async fn call(
        &self,
        connection: &Client,
        task_id: &str,
        tool: &str,
        args: serde_json::Value,
    ) -> Result<LocalToolReply, String> {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        // 带任务前缀：并发任务共用一条连接，排障时一眼能看出是谁的调用。
        let call_id = format!("local-{task_id}-{seq}");
        let (tx, rx) = oneshot::channel();

        {
            let mut waiters = self
                .waiters
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            waiters.insert(call_id.clone(), tx);
        }

        let sent = connection
            .send(IpcMessage::LocalToolCall {
                call_id: call_id.clone(),
                task_id: task_id.to_string(),
                tool: tool.to_string(),
                args,
            })
            .await;

        if !sent {
            self.remove(&call_id);
            return Err("与服务端的连接已断开".to_string());
        }

        match tokio::time::timeout(self.timeout, rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => Err("与服务端的连接已断开".to_string()),
            Err(_) => {
                self.remove(&call_id);
                tracing::warn!(
                    task_id,
                    tool,
                    timeout_ms = self.timeout.as_millis() as u64,
                    "等待本地工具结果超时"
                );
                Err("读项目文件等待超时".to_string())
            }
        }
    }

    /// 收到 `LocalToolResult` 时投递给等待方。已超时的调用找不到等待方，直接丢弃。
    pub(crate) fn deliver(&self, call_id: &str, reply: LocalToolReply) {
        let waiter = {
            let mut waiters = self
                .waiters
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            waiters.remove(call_id)
        };
        if let Some(waiter) = waiter {
            let _ = waiter.send(reply);
        }
    }

    /// 连接结束时唤醒所有等待方：丢弃 sender 会让接收端立刻收到 `Err`。
    pub(crate) fn fail_all(&self) {
        let waiters = {
            let mut waiters = self
                .waiters
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            std::mem::take(&mut *waiters)
        };
        drop(waiters);
    }

    fn remove(&self, call_id: &str) {
        let mut waiters = self
            .waiters
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        waiters.remove(call_id);
    }
}

/// 单次本地工具调用的等待上限，由 service 通过环境变量下发。
///
/// 与工具调用共用同一个超时：它们都是"读一次外部资料"，
/// 慢到需要区分的那一天再拆开也不迟。
pub(crate) fn timeout_from_env() -> Duration {
    let millis = std::env::var("PERSONAL_AGENT_TOOL_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value >= 500)
        .unwrap_or(8_000);

    Duration::from_millis(millis.saturating_sub(1_000).max(500))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn deliver_wakes_waiter_and_ignores_unknown_ids() {
        let client = LocalToolClient::new(Duration::from_millis(50));
        let (tx, rx) = oneshot::channel();
        client
            .waiters
            .lock()
            .unwrap()
            .insert("local-1".to_string(), tx);

        client.deliver(
            "local-1",
            LocalToolReply {
                content: "文件内容".to_string(),
                error: None,
            },
        );
        let reply = rx.await.expect("应收到应答");
        assert!(reply.is_ok());
        assert_eq!(reply.content, "文件内容");

        // 重复投递不该 panic。
        client.deliver(
            "local-1",
            LocalToolReply {
                content: String::new(),
                error: Some("ignored".to_string()),
            },
        );
    }

    #[tokio::test]
    async fn fail_all_wakes_pending_calls() {
        let client = LocalToolClient::new(Duration::from_millis(50));
        let (tx, rx) = oneshot::channel::<LocalToolReply>();
        client
            .waiters
            .lock()
            .unwrap()
            .insert("local-2".to_string(), tx);

        client.fail_all();
        assert!(rx.await.is_err(), "丢弃 sender 后接收端应立即出错");
    }

    #[test]
    fn failure_reply_is_visible() {
        let reply = LocalToolReply {
            content: String::new(),
            error: Some("路径越界".to_string()),
        };
        assert!(!reply.is_ok());
    }
}
