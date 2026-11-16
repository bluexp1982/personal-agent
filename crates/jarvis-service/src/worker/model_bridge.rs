//! 任务侧模型调用的桥：worker 发起请求，service 代调模型。
//!
//! 为什么不让 worker 自己调：
//! - 密钥只落在 service 进程（worker 的环境变量里没有 API Key）；
//! - 预算是"一个任务跨多次调用"的聚合量，只能有一个权威计数；
//! - 用量审计必须与任务状态写在同一处，否则排障要拼两个进程的日志。
//!
//! 代价是多一次本地 IPC 往返（毫秒级），相对模型延迟可忽略。
//!
//! 记账口径：**先扣次数、后记账 token**。失败与超时也计一次调用——
//! 它们同样消耗了一次往返与一次配额，不计会让"最多 12 次"变成橡皮尺。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use sqlx::SqlitePool;

use crate::audit::{self, AuditEntry};
use crate::config::TaskConfig;
use crate::model::CompletionModel;

/// 一次模型调用的应答，字段与 `protocol::IpcMessage::ModelResult` 一一对应。
#[derive(Debug, Clone)]
pub struct ModelReply {
    pub ok: bool,
    pub text: String,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub tokens_estimated: bool,
    pub error: Option<String>,
}

impl ModelReply {
    fn failure(code: impl Into<String>) -> Self {
        Self {
            ok: false,
            text: String::new(),
            prompt_tokens: 0,
            completion_tokens: 0,
            tokens_estimated: false,
            error: Some(code.into()),
        }
    }
}

/// 单个任务的累计用量。
#[derive(Debug, Default, Clone, Copy)]
struct Usage {
    calls: u32,
    tokens: u64,
    /// 第一次调用发生的时间。用它判"任务跑了多久"，而不是置信 worker 的自我计时。
    started_ms: i64,
}

#[derive(Debug)]
pub struct ModelBridge {
    /// 未启用模型或缺少密钥时为 `None`：worker 收到 `model_disabled` 后自行降级。
    ///
    /// 用 `RwLock` 而不是裸字段：集成测试要在 `AppState` 建好之后注入假模型，
    /// 而生产路径只在启动时写一次，读多写少，代价可忽略。
    model: std::sync::RwLock<Option<Arc<dyn CompletionModel>>>,
    limits: TaskConfig,
    /// 任务总时长预算。与 `Config::task_timeout_ms` 是同一个值，
    /// 但这里由服务端判定：worker 挂住时它自己不会主动认输。
    task_timeout: std::time::Duration,
    usage: Mutex<HashMap<String, Usage>>,
    pool: SqlitePool,
}

impl ModelBridge {
    pub fn new(
        model: Option<Arc<dyn CompletionModel>>,
        limits: TaskConfig,
        task_timeout: std::time::Duration,
        pool: SqlitePool,
    ) -> Self {
        Self {
            model: std::sync::RwLock::new(model),
            limits,
            task_timeout,
            usage: Mutex::new(HashMap::new()),
            pool,
        }
    }

    /// 替换模型实现。生产路径不用，集成测试用它注入假模型。
    pub fn set_model(&self, model: Option<Arc<dyn CompletionModel>>) {
        let mut slot = self
            .model
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *slot = model;
    }

    pub fn is_enabled(&self) -> bool {
        self.model
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_some()
    }

    /// 任务结束时清理计数。人工重试是一次新的预算，因此不在重试时保留旧值。
    pub fn forget(&self, task_id: &str) {
        self.usage
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(task_id);
    }

    /// 当前任务的累计用量，供管理面与日志排查使用。
    pub fn usage_of(&self, task_id: &str) -> Option<(u32, u64)> {
        let usage = self
            .usage
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(task_id)
            .copied()?;
        Some((usage.calls, usage.tokens))
    }

    /// 处理一次 `model_call`。永远返回应答，不向上抛错——worker 在等。
    pub async fn handle(
        &self,
        task_id: &str,
        purpose: &str,
        system: &str,
        prompt: &str,
        max_tokens: Option<u32>,
    ) -> ModelReply {
        let model = self
            .model
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        let Some(model) = model else {
            return ModelReply::failure("model_disabled");
        };

        if let Err(code) = self.reserve_call(task_id) {
            self.audit(task_id, purpose, 0, 0, false, true, Some(code), 0)
                .await;
            tracing::warn!(%task_id, purpose, "任务模型用量超限，已拒绝本次调用");
            return ModelReply::failure(code);
        }

        // 生成长度上限按用途取配置：worker 只管"要一段文本"，
        // 具体多长属于预算范畴，只有服务端知道。
        let max_tokens = max_tokens.or(Some(match purpose {
            "synthesis" => self.limits.synthesis_max_tokens,
            _ => self.limits.step_max_tokens,
        }));

        let started = Instant::now();
        let timeout = Duration::from_millis(self.limits.model_call_timeout_ms.max(1_000));
        let outcome =
            tokio::time::timeout(timeout, model.complete(system, prompt, max_tokens)).await;
        let elapsed_ms = started.elapsed().as_millis() as u64;

        match outcome {
            Ok(Ok(completion)) => {
                self.add_tokens(
                    task_id,
                    completion.prompt_tokens,
                    completion.completion_tokens,
                );
                self.audit(
                    task_id,
                    purpose,
                    completion.prompt_tokens,
                    completion.completion_tokens,
                    true,
                    completion.tokens_estimated,
                    None,
                    elapsed_ms,
                )
                .await;

                ModelReply {
                    ok: true,
                    text: completion.text,
                    prompt_tokens: completion.prompt_tokens,
                    completion_tokens: completion.completion_tokens,
                    tokens_estimated: completion.tokens_estimated,
                    error: None,
                }
            }
            Ok(Err(err)) => {
                tracing::warn!(%task_id, purpose, %err, "模型调用失败");
                self.audit(task_id, purpose, 0, 0, false, false, Some(&err), elapsed_ms)
                    .await;
                ModelReply::failure(format!("model_error: {err}"))
            }
            Err(_) => {
                tracing::warn!(
                    %task_id,
                    purpose,
                    timeout_ms = timeout.as_millis() as u64,
                    "模型调用等待超时"
                );
                self.audit(
                    task_id,
                    purpose,
                    0,
                    0,
                    false,
                    false,
                    Some("model_timeout"),
                    elapsed_ms,
                )
                .await;
                ModelReply::failure("model_timeout")
            }
        }
    }

    /// 检查并占用一次调用配额。返回错误码而非字符串，便于 worker 分流。
    ///
    /// 三个上限任一命中都返回 `budget_exceeded`：对用户而言都是"这次任务花超了"，
    /// 分成三个错误码只会让客户端多写三个分支。
    fn reserve_call(&self, task_id: &str) -> Result<(), &'static str> {
        let now = crate::clock::now_ms();
        let mut usage = self
            .usage
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let entry = usage.entry(task_id.to_string()).or_default();
        if entry.started_ms == 0 {
            entry.started_ms = now;
        }

        let elapsed = now.saturating_sub(entry.started_ms).max(0) as u64;
        if elapsed > self.task_timeout.as_millis() as u64 {
            return Err("budget_exceeded");
        }
        if entry.calls >= self.limits.max_model_calls {
            return Err("budget_exceeded");
        }
        if entry.tokens >= self.limits.max_tokens {
            return Err("budget_exceeded");
        }

        entry.calls += 1;
        Ok(())
    }

    fn add_tokens(&self, task_id: &str, prompt_tokens: u32, completion_tokens: u32) {
        let mut usage = self
            .usage
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let entry = usage.entry(task_id.to_string()).or_default();
        entry.tokens += u64::from(prompt_tokens) + u64::from(completion_tokens);
    }

    /// 记一条 `task.model_call` 审计。
    ///
    /// 只记元信息：模型名、用途、耗时、token 数。**不记 prompt 与回答正文**——
    /// 那是用户数据，审计表不该成为第二份对话历史。
    #[allow(clippy::too_many_arguments)]
    async fn audit(
        &self,
        task_id: &str,
        purpose: &str,
        prompt_tokens: u32,
        completion_tokens: u32,
        ok: bool,
        tokens_estimated: bool,
        error: Option<&str>,
        elapsed_ms: u64,
    ) {
        let (calls, tokens) = self.usage_of(task_id).unwrap_or((0, 0));
        audit::record(
            &self.pool,
            &AuditEntry::new(
                task_id,
                "worker",
                "task.model_call",
                if ok { "ok" } else { "error" },
            )
            .target(task_id)
            .detail(serde_json::json!({
                "purpose": purpose,
                "elapsed_ms": elapsed_ms,
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "tokens_estimated": tokens_estimated,
                "calls_used": calls,
                "tokens_used": tokens,
                "error": error.map(|text| truncate(text, 120)),
            })),
        )
        .await;
    }
}

fn truncate(text: &str, max: usize) -> String {
    let compact = text.replace(['\n', '\r'], " ");
    if compact.chars().count() <= max {
        return compact;
    }
    compact.chars().take(max).collect::<String>() + "…"
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Completion, CompletionFuture};

    #[derive(Debug)]
    struct FixedModel {
        reply: Result<Completion, String>,
        delay: Duration,
    }

    impl CompletionModel for FixedModel {
        fn complete(
            &self,
            _system: &str,
            _prompt: &str,
            _max_tokens: Option<u32>,
        ) -> CompletionFuture<'_> {
            let reply = self.reply.clone();
            let delay = self.delay;
            Box::pin(async move {
                tokio::time::sleep(delay).await;
                reply
            })
        }
    }

    /// 每个用例一个临时库：审计写入需要真实表结构。
    async fn bridge_pool() -> SqlitePool {
        let pool = crate::db::connect(&std::env::temp_dir().join(format!(
            "pa-model-bridge-{}-{}.db",
            std::process::id(),
            crate::ids::new_id("t")
        )))
        .await
        .expect("建池失败");
        crate::db::migrate(&pool).await.expect("迁移失败");
        pool
    }

    async fn bridge_with(
        model: Option<Arc<dyn CompletionModel>>,
        max_calls: u32,
        max_tokens: u64,
    ) -> ModelBridge {
        ModelBridge::new(
            model,
            TaskConfig {
                max_model_calls: max_calls,
                max_tokens,
                model_call_timeout_ms: 2_000,
                ..TaskConfig::default()
            },
            Duration::from_secs(900),
            bridge_pool().await,
        )
    }

    #[tokio::test]
    async fn disabled_model_returns_marker() {
        let bridge = bridge_with(None, 12, 60_000).await;
        let reply = bridge.handle("task_1", "step", "s", "p", None).await;
        assert!(!reply.ok);
        assert_eq!(reply.error.as_deref(), Some("model_disabled"));
        assert!(bridge.usage_of("task_1").is_none(), "不应占用配额");
    }

    #[tokio::test]
    async fn budget_limits_calls_and_counts_failures() {
        let model = Arc::new(FixedModel {
            reply: Err("gateway down".to_string()),
            delay: Duration::ZERO,
        });
        let bridge = bridge_with(Some(model), 2, 60_000).await;

        assert!(!bridge.handle("task_1", "step", "s", "p", None).await.ok);
        assert!(!bridge.handle("task_1", "step", "s", "p", None).await.ok);

        let third = bridge.handle("task_1", "step", "s", "p", None).await;
        assert_eq!(third.error.as_deref(), Some("budget_exceeded"));
        assert_eq!(bridge.usage_of("task_1").map(|usage| usage.0), Some(2));
    }

    #[tokio::test]
    async fn budget_limits_tokens() {
        let model = Arc::new(FixedModel {
            reply: Ok(Completion {
                text: "结论".to_string(),
                prompt_tokens: 30,
                completion_tokens: 10,
                tokens_estimated: false,
                finish_reason: None,
            }),
            delay: Duration::ZERO,
        });
        let bridge = bridge_with(Some(model), 12, 30).await;

        assert!(bridge.handle("task_1", "step", "s", "p", None).await.ok);
        let blocked = bridge.handle("task_1", "step", "s", "p", None).await;
        assert_eq!(blocked.error.as_deref(), Some("budget_exceeded"));
    }

    #[tokio::test]
    async fn timeout_is_reported_and_still_counted() {
        let model = Arc::new(FixedModel {
            reply: Ok(Completion::default()),
            delay: Duration::from_secs(5),
        });
        let mut bridge = bridge_with(Some(model), 12, 60_000).await;
        bridge.limits.model_call_timeout_ms = 50;

        let reply = bridge.handle("task_1", "step", "s", "p", None).await;
        assert_eq!(reply.error.as_deref(), Some("model_timeout"));
        assert_eq!(bridge.usage_of("task_1").map(|usage| usage.0), Some(1));
    }

    #[tokio::test]
    async fn budget_limits_elapsed_time() {
        let model = Arc::new(FixedModel {
            reply: Ok(Completion::default()),
            delay: Duration::ZERO,
        });
        // 用毫秒级总时长验证时长上限，避免真等 15 分钟。
        let bridge = ModelBridge::new(
            Some(model),
            TaskConfig {
                model_call_timeout_ms: 2_000,
                ..TaskConfig::default()
            },
            Duration::from_millis(50),
            bridge_pool().await,
        );

        assert!(bridge.handle("task_1", "step", "s", "p", None).await.ok);
        tokio::time::sleep(Duration::from_millis(60)).await;

        let blocked = bridge.handle("task_1", "step", "s", "p", None).await;
        assert_eq!(blocked.error.as_deref(), Some("budget_exceeded"));
    }

    #[tokio::test]
    async fn forget_clears_usage_for_retry() {
        let model = Arc::new(FixedModel {
            reply: Ok(Completion::default()),
            delay: Duration::ZERO,
        });
        let bridge = bridge_with(Some(model), 12, 60_000).await;
        assert!(bridge.handle("task_1", "step", "s", "p", None).await.ok);
        bridge.forget("task_1");
        assert!(bridge.usage_of("task_1").is_none());
    }
}
