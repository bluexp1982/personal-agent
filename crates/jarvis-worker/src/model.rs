//! 任务侧的模型调用客户端。
//!
//! worker **不持有 API Key、不实现模型协议**：这里只做三件事——
//! 生成 `call_id`、把 `model_call` 发出去、等 service 的 `model_result`。
//! 预算、密钥与用量审计全在服务端，worker 只负责"要用一段文本"。
//!
//! 等待必须能被三件事打断：收到应答、超时、连接断开。任何一条缺失，
//! 任务就会挂在一个永远不会再来的应答上，而 supervisor 只能等到心跳超时才收尸。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use protocol::IpcMessage;
use tokio::sync::oneshot;

use crate::ipc::Client;

/// 一次模型调用的应答。
///
/// `ok=false` 不是"程序错误"，而是"这次拿不到文本"：调用方据此降级，
/// 是否让任务失败由 `error` 的取值决定（如 `budget_exceeded`）。
#[derive(Debug, Clone)]
pub(crate) struct ModelReply {
    pub(crate) text: String,
    pub(crate) error: Option<String>,
}

impl ModelReply {
    pub(crate) fn is_ok(&self) -> bool {
        self.error.is_none()
    }

    /// 失败原因的稳定标识：服务端回的是 `model_disabled` / `budget_exceeded` /
    /// `model_timeout` / `model_error: ...`，这里只取前缀部分。
    pub(crate) fn code(&self) -> Option<&str> {
        self.error.as_deref().map(|error| {
            error
                .split_once(':')
                .map(|(code, _)| code.trim())
                .unwrap_or(error)
        })
    }
}

#[derive(Debug)]
pub(crate) struct ModelClient {
    waiters: Mutex<HashMap<String, oneshot::Sender<ModelReply>>>,
    seq: AtomicU64,
    timeout: Duration,
}

impl ModelClient {
    pub(crate) fn new(timeout: Duration) -> Self {
        Self {
            waiters: Mutex::new(HashMap::new()),
            seq: AtomicU64::new(0),
            timeout,
        }
    }

    /// 发起一次调用并等待结果。
    ///
    /// 超时上限比服务端小（由 supervisor 下发时已减 2 秒），
    /// 这样"service 判超时"不会先于"worker 拿到真实失败原因"发生。
    pub(crate) async fn call(
        &self,
        connection: &Client,
        task_id: &str,
        purpose: &str,
        system: &str,
        prompt: &str,
        max_tokens: Option<u32>,
    ) -> Result<ModelReply, String> {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        // 带任务前缀：并发任务共用一条连接，排障时一眼能看出是谁的调用。
        let call_id = format!("model-{task_id}-{seq}");
        let (tx, rx) = oneshot::channel();

        {
            let mut waiters = self
                .waiters
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            waiters.insert(call_id.clone(), tx);
        }

        let sent = connection
            .send(IpcMessage::ModelCall {
                call_id: call_id.clone(),
                task_id: task_id.to_string(),
                purpose: purpose.to_string(),
                system: system.to_string(),
                prompt: prompt.to_string(),
                max_tokens,
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
                    purpose,
                    timeout_ms = self.timeout.as_millis() as u64,
                    "等待模型结果超时"
                );
                Err("模型调用等待超时".to_string())
            }
        }
    }

    /// 收到 `model_result` 时投递给等待方。已超时的调用找不到等待方，直接丢弃。
    pub(crate) fn deliver(&self, call_id: &str, reply: ModelReply) {
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

/// 单次模型调用的等待上限，由 service 通过环境变量下发。
pub(crate) fn timeout_from_env() -> Duration {
    let millis = std::env::var("PERSONAL_AGENT_MODEL_CALL_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value >= 1_000)
        .unwrap_or(88_000);
    Duration::from_millis(millis)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reply_code_splits_on_first_colon() {
        let reply = ModelReply {
            text: String::new(),
            error: Some("model_error: 模型返回 500: boom".to_string()),
        };
        assert!(!reply.is_ok());
        assert_eq!(reply.code(), Some("model_error"));

        let disabled = ModelReply {
            text: String::new(),
            error: Some("model_disabled".to_string()),
        };
        assert_eq!(disabled.code(), Some("model_disabled"));
    }

    #[tokio::test]
    async fn deliver_wakes_waiter_and_is_ignored_when_absent() {
        let client = ModelClient::new(Duration::from_millis(50));
        let (tx, rx) = oneshot::channel();
        client
            .waiters
            .lock()
            .unwrap()
            .insert("call_1".to_string(), tx);

        client.deliver(
            "call_1",
            ModelReply {
                text: "结论".to_string(),
                error: None,
            },
        );
        let reply = rx.await.expect("应收到应答");
        assert_eq!(reply.text, "结论");

        // 重复投递不应 panic，也不应复活等待方。
        client.deliver(
            "call_1",
            ModelReply {
                text: String::new(),
                error: Some("ignored".to_string()),
            },
        );
    }

    #[tokio::test]
    async fn fail_all_wakes_pending_calls() {
        let client = ModelClient::new(Duration::from_millis(50));
        let (tx, rx) = oneshot::channel::<ModelReply>();
        client
            .waiters
            .lock()
            .unwrap()
            .insert("call_2".to_string(), tx);

        client.fail_all();
        assert!(rx.await.is_err(), "丢弃 sender 后接收端应立即出错");
    }
}
