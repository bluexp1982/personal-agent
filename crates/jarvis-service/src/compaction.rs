//! 会话上下文压缩。
//!
//! 装配上下文时，服务端只留最近 `context_messages` 条消息，更早的那些会被一句
//! 「（更早的 N 条消息已省略）」打发掉——长会话真正的前情就丢了。本模块把这些
//! 更早的对话交给模型归纳成一段摘要，下一次提问时用「摘要 + 最近若干条」装配。
//!
//! 三条硬边界：
//! - **原文不丢**：压缩只改变"送进模型的内容"，`messages` 一条不删、不隐藏。
//! - **失败可降级**：没模型、超时、报错都退回原来的确定性截断，回答照常完成。
//! - **不阻塞对话**：常规压缩在回答落库**之后**后台跑（与 [`crate::title`] 同一套
//!   写法）；唯一的同步等待点是"上游报上下文超长"——那时用户已经在等一个失败，
//!   压完再试一次比直接报错强（见 [`is_context_overflow`]）。
//!
//! 记录表每**次尝试一行**，失败的也留着（`conversation_compactions`）：失败的
//! 覆盖成功的会让"摘要为什么消失"无从排查，成功的覆盖失败的又会丢证据。

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use sqlx::SqlitePool;
use tokio::sync::Semaphore;

use protocol::{Compaction, CompactionFailure, CompactionTokens};

use crate::audit::{self, AuditEntry};
use crate::clock::now_ms;
use crate::config::{CompactionConfig, Config};
use crate::conversation;
use crate::ids::new_id;
use crate::model::CompletionModel;

/// 交给摘要模型的任务说明。
///
/// 要点是"不要丢硬性要求"：用户说过的偏好、确认过的事实、还没做完的事，
/// 一旦被摘要抹掉，后面几轮就会开始跑偏；而寒暄与重复占的正是上下文预算。
const SYSTEM_PROMPT: &str =
    "你是会话摘要助手。把用户提供的更早对话归纳成一段可以直接当作背景使用的摘要：\n\
     1. 保留用户的偏好与硬性要求（例如「不要用 Markdown」「必须周五前给结论」）；\n\
     2. 保留已经确认的事实、结论与做过的决定；\n\
     3. 保留还没完成的待办与进行到哪一步；\n\
     4. 去掉寒暄、重复与已被推翻的内容；\n\
     5. 用要点列表（3~6 条，每条一句话），不要编造对话里没有的内容。\n\
     只输出摘要正文，不超过 300 字；信息不足时如实写「信息不足」。\n\
     不要回显输入里的任何小节标题或【…】标记，也不要说「以下是摘要」这类过场话。";

/// 一次可装配的压缩结果。
#[derive(Debug, Clone)]
pub struct Active {
    /// 折叠到的消息 `seq`（含）：装配只取 `seq > upto_seq` 的消息。
    pub upto_seq: i64,
    pub summary: String,
    pub source_messages: u32,
    pub model: String,
    pub updated_at: i64,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub tokens_estimated: bool,
    pub elapsed_ms: Option<i64>,
}

/// 一次失败的尝试，只用于展示。
#[derive(Debug, Clone)]
pub struct Failure {
    pub error: String,
    pub at: i64,
    pub model: String,
}

/// 压缩任务的两种失败：调用方据此决定状态码。
#[derive(Debug, thiserror::Error)]
pub enum CompactError {
    #[error("模型未就绪")]
    Unavailable,
    #[error("这个会话正在整理上下文")]
    Busy,
    #[error("会话不存在")]
    NotFound,
}

/// 一次同步执行的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Outcome {
    /// 是否真的产出了新的可用摘要。`false` 表示这次没东西可压或失败。
    pub ready: bool,
}

#[derive(Debug)]
pub struct Jobs {
    pool: SqlitePool,
    /// 后台任务自己持有一份模型：它没有请求上下文可以借用。
    ///
    /// 用 `RwLock` 而不是裸字段，是为了切模型时不重启服务——下一轮就用新模型。
    model: std::sync::RwLock<Option<Arc<dyn CompletionModel>>>,
    /// 写进压缩记录的模型名，与模型同一个快照更新。
    model_name: std::sync::RwLock<String>,
    /// 全局并发 1：压缩是额外的一次模型调用，并发跑既浪费配额也让边界互相覆盖。
    slots: Arc<Semaphore>,
    /// 正在跑的会话。同一会话同时只允许一个，否则两次压缩会抢同一个边界。
    running: Arc<Mutex<HashSet<String>>>,
    enabled: bool,
    keep_messages: usize,
    /// 装配条数上限，与 `Config::context_messages` 同源。
    ///
    /// 复制一份而不是持整份 Config：触发判定要和装配用同一个数，
    /// 分散成两个来源迟早对不上。
    context_messages: usize,
    trigger_ratio: f64,
    max_input_chars: usize,
    max_tokens: u32,
    timeout: Duration,
    max_failure_rows: usize,
    retry_on_overflow: bool,
    /// 一次失败后多久内不再自动整理。
    ///
    /// 没有这道冷却时，失败会在每轮回答后原样重试——每轮烧一次模型调用，
    /// 而且用户只会反复看到同一条错误。手动「重新整理」不受它限制。
    failure_cooldown: Duration,
}

impl Jobs {
    pub fn new(pool: SqlitePool, config: &Config) -> Arc<Self> {
        Self::with_optional_model(pool, config, None)
    }

    /// 测试注入假模型用；生产路径走 [`Self::new`] 再由 `AppState::new` 注入。
    pub fn with_model(
        pool: SqlitePool,
        config: &Config,
        model: Arc<dyn CompletionModel>,
    ) -> Arc<Self> {
        Self::with_optional_model(pool, config, Some(model))
    }

    fn with_optional_model(
        pool: SqlitePool,
        config: &Config,
        model: Option<Arc<dyn CompletionModel>>,
    ) -> Arc<Self> {
        let compaction: &CompactionConfig = &config.compaction;
        Arc::new(Self {
            pool,
            model: std::sync::RwLock::new(model),
            model_name: std::sync::RwLock::new(config.llm.model.clone()),
            slots: Arc::new(Semaphore::new(1)),
            running: Arc::new(Mutex::new(HashSet::new())),
            enabled: compaction.enabled,
            keep_messages: compaction.keep_messages.max(1),
            context_messages: config.context_messages.max(1),
            trigger_ratio: compaction.trigger_ratio,
            max_input_chars: compaction.max_input_chars.max(1_000),
            // 下限 600：300 字摘要本身就要四五百 token，再小必然截断。
            // 配置里写小了不拒绝启动（那是用户机器上的既有配置），在运行期兜住。
            max_tokens: compaction.max_tokens.max(600),
            timeout: Duration::from_millis(compaction.timeout_ms.max(1_000)),
            max_failure_rows: compaction.max_failure_rows.max(1),
            retry_on_overflow: compaction.retry_on_overflow,
            failure_cooldown: Duration::from_millis(compaction.failure_cooldown_ms),
        })
    }

    /// 换掉整理用的模型。切换模型配置时由 `AppState::apply_llm` 调用。
    pub fn set_model(&self, model: Option<Arc<dyn CompletionModel>>, name: &str) {
        *self
            .model
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = model;
        *self
            .model_name
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = name.to_string();
    }

    fn current_model(&self) -> Option<Arc<dyn CompletionModel>> {
        self.model
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn current_model_name(&self) -> String {
        self.model_name
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// 现在能不能整理：开关打开 **且** 有模型。
    ///
    /// 每次现取：切到一份没有密钥的配置时立刻停止，而不是拿旧模型继续花钱。
    pub fn available(&self) -> bool {
        self.enabled && self.current_model().is_some()
    }

    pub fn retry_on_overflow(&self) -> bool {
        self.retry_on_overflow
    }

    /// 启动时回收上次进程遗留的 `pending`。
    ///
    /// 标记成 `failed` 而不是删掉：这样客户端能说清"上次为什么没有摘要"，
    /// 而不是让记录凭空消失（对齐 `task::recover_stale_running` 的做法）。
    pub fn start(self: &Arc<Self>) {
        let pool = self.pool.clone();
        tokio::spawn(async move {
            if let Err(err) = sqlx::query(
                "UPDATE conversation_compactions SET status = 'failed', \
                 error = '服务重启，本次整理被中断', updated_at = ? WHERE status = 'pending'",
            )
            .bind(now_ms())
            .execute(&pool)
            .await
            {
                tracing::warn!(%err, "回收中断的上下文压缩失败");
            }
        });
    }

    /// 回答落库之后的常规触发：超出装配上限、或窗口快满了，才后台压一次。
    ///
    /// 两条触发条件都表达同一件事——"现在送进去的上下文已经开始亏了"：
    /// - 条数超上限：装配已经开始丢内容，压了才能把前情找回来；
    /// - 窗口占比过高：小窗口模型（32K）下 20 条长消息可能直接溢出。
    pub async fn maybe_spawn(
        self: &Arc<Self>,
        conversation_id: &str,
        context_tokens: u32,
        context_window: u32,
    ) {
        if !self.available() {
            return;
        }
        // 刚才失败过就先停一会儿：每轮原样重试只会烧钱，并让用户反复看到同一条错误。
        if self.cooling_down(conversation_id).await {
            return;
        }
        let Some((uncompacted, _already)) = self.progress(conversation_id).await else {
            return;
        };
        let trigger = should_trigger(
            uncompacted,
            self.context_messages,
            context_tokens,
            context_window,
            self.trigger_ratio,
        );
        if !trigger {
            return;
        }
        if self.plan_source(uncompacted) == 0 {
            return;
        }
        self.spawn(conversation_id, "messages");
    }

    /// 手动整理：先清掉"用户关掉了压缩"的标记，再排队。
    ///
    /// 返回 `202` 语义——受理即返回，摘要就绪后由客户端回读详情。
    pub async fn spawn_manual(self: &Arc<Self>, conversation_id: &str) -> Result<(), CompactError> {
        if !self.available() {
            return Err(CompactError::Unavailable);
        }
        let exists: Option<i64> = sqlx::query_scalar(
            "SELECT compaction_disabled FROM conversations WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(conversation_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|err| {
            tracing::warn!(%err, conversation_id, "读取会话压缩开关失败");
            CompactError::NotFound
        })?;
        if exists.is_none() {
            return Err(CompactError::NotFound);
        }
        if self.is_running(conversation_id) {
            return Err(CompactError::Busy);
        }
        // 手动重算等于"我要这个会话重新开启压缩"。
        if let Err(err) =
            sqlx::query("UPDATE conversations SET compaction_disabled = 0 WHERE id = ?")
                .bind(conversation_id)
                .execute(&self.pool)
                .await
        {
            tracing::warn!(%err, conversation_id, "重新开启会话压缩失败");
        }
        self.spawn(conversation_id, "manual");
        Ok(())
    }

    /// 关掉某个会话的压缩（`DELETE /compaction`）。
    pub async fn disable(&self, conversation_id: &str) -> Result<(), CompactError> {
        let affected = sqlx::query(
            "UPDATE conversations SET compaction_disabled = 1 \
             WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(conversation_id)
        .execute(&self.pool)
        .await
        .map_err(|err| {
            tracing::warn!(%err, conversation_id, "关闭会话压缩失败");
            CompactError::NotFound
        })?
        .rows_affected();
        if affected == 0 {
            return Err(CompactError::NotFound);
        }
        Ok(())
    }

    /// 同步压一次，等结果。溢出重试用它——那时用户已经在等失败，等几秒压完更好。
    pub async fn compact_now(
        self: &Arc<Self>,
        conversation_id: &str,
        trigger: &'static str,
    ) -> Outcome {
        let Some(guard) = self.begin(conversation_id) else {
            return Outcome { ready: false };
        };
        let outcome = self.run(conversation_id, trigger).await;
        drop(guard);
        outcome
    }

    fn spawn(self: &Arc<Self>, conversation_id: &str, trigger: &'static str) {
        let Some(guard) = self.begin(conversation_id) else {
            return;
        };
        let this = Arc::clone(self);
        let id = conversation_id.to_string();
        tokio::spawn(async move {
            // 守卫随任务结束（含 panic）一起摘除，不会把会话永久卡在"正在整理"。
            let _guard = guard;
            this.run(&id, trigger).await;
        });
    }

    /// 占住这个会话的压缩位。已经在跑时返回 `None`（单飞）。
    fn begin(self: &Arc<Self>, conversation_id: &str) -> Option<FlightGuard> {
        let mut running = self
            .running
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !running.insert(conversation_id.to_string()) {
            return None;
        }
        Some(FlightGuard {
            running: self.running.clone(),
            conversation_id: conversation_id.to_string(),
        })
    }

    /// 冷却期内是否不该再自动整理。
    ///
    /// 判据是"最近一次失败比最近一次成功更晚，且距今不到冷却窗口"：
    /// 只看 failed 的话，一条旧失败会永久挡住后续所有自动整理。
    async fn cooling_down(&self, conversation_id: &str) -> bool {
        if self.failure_cooldown.is_zero() {
            return false;
        }
        let recent: Option<(Option<i64>, Option<i64>)> = sqlx::query_as(
            "SELECT MAX(CASE WHEN status = 'failed' THEN updated_at END), \
                    MAX(CASE WHEN status = 'ready' THEN updated_at END) \
             FROM conversation_compactions WHERE conversation_id = ?",
        )
        .bind(conversation_id)
        .fetch_optional(&self.pool)
        .await
        .unwrap_or(None);
        // 查询出错就不冷却：宁可多试一次，也不要因为读库失败把功能静默停掉。
        let Some((failed_at, ready_at)) = recent else {
            return false;
        };
        let Some(failed_at) = failed_at else {
            return false;
        };
        if ready_at.is_some_and(|ready| ready >= failed_at) {
            return false;
        }
        let age = now_ms().saturating_sub(failed_at);
        age >= 0 && (age as u64) < self.failure_cooldown.as_millis() as u64
    }

    fn is_running(&self, conversation_id: &str) -> bool {
        self.running
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(conversation_id)
    }

    /// 未压缩的可重放消息数，以及"已经折叠到哪"。
    ///
    /// 返回 `None` 表示会话不存在、已删除，或被用户关掉了压缩。
    async fn progress(&self, conversation_id: &str) -> Option<(usize, i64)> {
        let disabled: Option<i64> = sqlx::query_scalar(
            "SELECT compaction_disabled FROM conversations WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(conversation_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|err| tracing::warn!(%err, conversation_id, "读取会话压缩开关失败"))
        .ok()?;
        let disabled = disabled?;
        if disabled != 0 {
            return None;
        }

        let active = load_active(&self.pool, conversation_id)
            .await
            .ok()
            .flatten();
        let already = active.map(|active| active.upto_seq).unwrap_or(0);
        let uncompacted =
            conversation::count_replayable_after(&self.pool, conversation_id, already)
                .await
                .ok()?;
        Some((uncompacted, already))
    }

    /// 这次能折叠多少条；0 表示没东西可压。
    ///
    /// 只在这里用一次算术：`keep_messages` 条是不动的尾巴，其余都能压。
    fn plan_source(&self, uncompacted: usize) -> usize {
        uncompacted.saturating_sub(self.keep_messages)
    }

    async fn run(&self, conversation_id: &str, trigger: &'static str) -> Outcome {
        let Some(model) = self.current_model() else {
            return Outcome { ready: false };
        };
        let model_name = self.current_model_name();
        let started = std::time::Instant::now();

        // 占住全局并发：压缩是额外的一次模型调用，串行就够，也避免抢占对话的上游配额。
        let _permit = match self.slots.acquire().await {
            Ok(permit) => permit,
            Err(_) => return Outcome { ready: false },
        };

        let (uncompacted, already) = match self.progress(conversation_id).await {
            Some(value) => value,
            None => return Outcome { ready: false },
        };
        if self.plan_source(uncompacted) == 0 {
            return Outcome { ready: false };
        }

        let boundary = match conversation::boundary_seq(
            &self.pool,
            conversation_id,
            already,
            self.keep_messages,
        )
        .await
        {
            Ok(Some(seq)) => seq,
            Ok(None) => return Outcome { ready: false },
            Err(err) => {
                tracing::warn!(%err, conversation_id, "计算压缩边界失败");
                return Outcome { ready: false };
            }
        };

        let messages =
            match conversation::replayable_between(&self.pool, conversation_id, already, boundary)
                .await
            {
                Ok(messages) => messages,
                Err(err) => {
                    tracing::warn!(%err, conversation_id, "读取待压缩消息失败");
                    return Outcome { ready: false };
                }
            };
        if messages.is_empty() {
            return Outcome { ready: false };
        }
        let source_messages = u32::try_from(messages.len()).unwrap_or(u32::MAX);

        let previous = load_active(&self.pool, conversation_id)
            .await
            .ok()
            .flatten();
        let prompt = build_prompt(previous.as_ref(), &messages, self.max_input_chars);

        let record_id = new_id("cmp");
        if let Err(err) = insert_pending(
            &self.pool,
            &record_id,
            conversation_id,
            source_messages,
            &model_name,
            self.max_tokens,
        )
        .await
        {
            tracing::error!(%err, conversation_id, "登记上下文压缩失败");
            return Outcome { ready: false };
        }

        // 最多两次：第一次用配置上限；正文为空或触到上限就翻倍再试一次。
        // 只对"空 / 截断"重试——上游报错与超时重试也是同一个错，白花钱。
        let mut attempts = 0u32;
        let mut limit = self.max_tokens;
        let mut used_limit = limit;
        let mut prompt_tokens = 0u32;
        let mut completion_tokens = 0u32;
        let mut tokens_estimated = false;
        let mut summary: Option<String> = None;
        let mut failure: Option<String> = None;
        let mut finish_reason: Option<String> = None;

        while attempts < 2 {
            attempts += 1;
            used_limit = limit;
            let result = tokio::time::timeout(
                self.timeout,
                // `none`：摘要不需要思考，而思考 token 与正文共用上限。
                model.complete_with_effort(SYSTEM_PROMPT, &prompt, Some(limit), Some("none")),
            )
            .await;
            match result {
                Ok(Ok(completion)) => {
                    prompt_tokens = prompt_tokens.saturating_add(completion.prompt_tokens);
                    completion_tokens =
                        completion_tokens.saturating_add(completion.completion_tokens);
                    tokens_estimated |= completion.tokens_estimated;
                    finish_reason = completion.finish_reason.clone();
                    let truncated = completion.finish_reason.as_deref() == Some("length");
                    let cleaned = strip_scaffolding(&completion.text);
                    if cleaned.is_empty() {
                        failure = Some(if truncated {
                            "输出被上限截断（思考占满了额度），没有留下正文".to_string()
                        } else {
                            "模型返回空内容".to_string()
                        });
                    } else if truncated {
                        // 有正文但不完整：加预算再试一次。第二次仍截断就判失败——
                        // 半截摘要会被当成背景注入后续每一轮，比没有摘要更糟。
                        failure = Some("输出被上限截断，摘要不完整".to_string());
                    } else {
                        summary = Some(cleaned);
                    }
                }
                Ok(Err(err)) => {
                    failure = Some(friendly_error(&err, self.timeout));
                    break;
                }
                Err(_) => {
                    failure = Some(format!(
                        "整理超时（超过 {} 秒）：模型没在时限内返回",
                        self.timeout.as_secs().max(1)
                    ));
                    break;
                }
            }
            if summary.is_some() {
                break;
            }
            limit = limit.saturating_mul(2).min(4_000);
        }

        let elapsed_ms = started.elapsed().as_millis() as i64;
        let truncated = finish_reason.as_deref() == Some("length");

        let Some(summary) = summary else {
            let reason = failure.unwrap_or_else(|| "模型返回空内容".to_string());
            self.fail(
                &record_id,
                conversation_id,
                trigger,
                &reason,
                &model_name,
                elapsed_ms,
            )
            .await;
            return Outcome { ready: false };
        };

        match finish_ready(
            &self.pool,
            &record_id,
            boundary,
            &summary,
            prompt_tokens,
            completion_tokens,
            tokens_estimated,
            elapsed_ms,
        )
        .await
        {
            Ok(()) => {
                self.prune_failures(conversation_id).await;
                audit::record(
                    &self.pool,
                    &AuditEntry::new(conversation_id, "system", "conversation.compacted", "ok")
                        .target(conversation_id)
                        .detail(serde_json::json!({
                            "trigger": trigger,
                            "source_messages": source_messages,
                            "summary_chars": summary.chars().count(),
                            "model": model_name,
                            "elapsed_ms": elapsed_ms,
                            "attempts": attempts,
                            "max_tokens_used": used_limit,
                            "prompt_tokens": prompt_tokens,
                            "completion_tokens": completion_tokens,
                            "tokens_estimated": tokens_estimated,
                            "truncated": truncated,
                        })),
                )
                .await;
                tracing::info!(
                    conversation_id,
                    source_messages,
                    elapsed_ms,
                    attempts,
                    "会话上下文已压缩"
                );
                Outcome { ready: true }
            }
            Err(err) => {
                tracing::error!(%err, conversation_id, "写入上下文摘要失败");
                let reason = "写入摘要失败";
                self.fail(
                    &record_id,
                    conversation_id,
                    trigger,
                    reason,
                    &model_name,
                    elapsed_ms,
                )
                .await;
                Outcome { ready: false }
            }
        }
    }

    /// 记一次失败：**只写自己这一行**，已有 `ready` 摘要一行都不碰。
    async fn fail(
        &self,
        record_id: &str,
        conversation_id: &str,
        trigger: &'static str,
        reason: &str,
        model_name: &str,
        elapsed_ms: i64,
    ) {
        if let Err(err) = finish_failed(&self.pool, record_id, reason, elapsed_ms).await {
            tracing::error!(%err, conversation_id, "写入上下文压缩失败原因失败");
        }
        self.prune_failures(conversation_id).await;
        audit::record(
            &self.pool,
            &AuditEntry::new(
                conversation_id,
                "system",
                "conversation.compaction_failed",
                "error",
            )
            .target(conversation_id)
            .detail(serde_json::json!({
                "trigger": trigger,
                "model": model_name,
                "elapsed_ms": elapsed_ms,
                "error": reason.chars().take(200).collect::<String>(),
            })),
        )
        .await;
        tracing::warn!(conversation_id, reason, "会话上下文压缩失败");
    }

    /// 每个会话只留最近 N 条失败记录，更旧的删掉：它们是给人看的证据，不是日志。
    async fn prune_failures(&self, conversation_id: &str) {
        if let Err(err) = sqlx::query(
            "DELETE FROM conversation_compactions \
             WHERE conversation_id = ? AND status = 'failed' AND id NOT IN ( \
                 SELECT id FROM conversation_compactions \
                 WHERE conversation_id = ? AND status = 'failed' \
                 ORDER BY created_at DESC LIMIT ?)",
        )
        .bind(conversation_id)
        .bind(conversation_id)
        .bind(self.max_failure_rows as i64)
        .execute(&self.pool)
        .await
        {
            tracing::warn!(%err, conversation_id, "清理历史压缩失败记录失败");
        }
    }
}

/// 单飞守卫：任务结束（含 panic）时把会话从"正在整理"里摘掉。
#[derive(Debug)]
struct FlightGuard {
    running: Arc<Mutex<HashSet<String>>>,
    conversation_id: String,
}

impl Drop for FlightGuard {
    fn drop(&mut self) {
        self.running
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&self.conversation_id);
    }
}

/// 常规触发判定。纯函数，便于单测把边界钉死。
///
/// `uncompacted` 是"还没被摘要覆盖的可重放消息数"，用法与装配的
/// `context_messages` 同一个口径——超了就等于"现在的装配已经开始丢内容"。
pub fn should_trigger(
    uncompacted: usize,
    context_messages: usize,
    context_tokens: u32,
    context_window: u32,
    trigger_ratio: f64,
) -> bool {
    if uncompacted > context_messages {
        return true;
    }
    if context_window == 0 || context_tokens == 0 {
        return false;
    }
    let ratio = f64::from(context_tokens) / f64::from(context_window);
    ratio >= trigger_ratio
}

/// 判断一条模型错误是不是"上下文超长"。
///
/// 上游没有统一错误码，只能看状态码 + 文案；命中不了就返回 `false`——
/// 宁可漏掉一次重试机会，也不要把普通 400（参数错、鉴权错）重试一遍。
pub fn is_context_overflow(error: &str) -> bool {
    let lowered = error.to_lowercase();
    let status = lowered.contains("模型返回 400") || lowered.contains("模型返回 413");
    if !status {
        return false;
    }
    const KEYWORDS: [&str; 9] = [
        "context length",
        "context_length_exceeded",
        "maximum context",
        "too many tokens",
        "input is too long",
        "prompt is too long",
        "range of input length",
        "exceed",
        "超过最大长度",
    ];
    KEYWORDS.iter().any(|keyword| lowered.contains(keyword))
}

/// 读当前可用的摘要。`upto_seq` 是位置锚点，不是区间端点。
pub async fn load_active(
    pool: &SqlitePool,
    conversation_id: &str,
) -> Result<Option<Active>, sqlx::Error> {
    let row = sqlx::query_as::<
        _,
        (
            i64,
            String,
            i64,
            String,
            i64,
            Option<i64>,
            Option<i64>,
            i64,
            Option<i64>,
        ),
    >(
        "SELECT c.upto_seq, c.summary, c.source_messages, c.model, c.updated_at, \
                c.prompt_tokens, c.completion_tokens, c.tokens_estimated, c.elapsed_ms \
         FROM conversation_compactions c \
         JOIN conversations v ON v.id = c.conversation_id \
         WHERE c.conversation_id = ? AND c.status = 'ready' \
           AND v.deleted_at IS NULL AND v.compaction_disabled = 0 \
         ORDER BY c.upto_seq DESC LIMIT 1",
    )
    .bind(conversation_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|row| Active {
        upto_seq: row.0,
        summary: row.1,
        source_messages: u32::try_from(row.2).unwrap_or(u32::MAX),
        model: row.3,
        updated_at: row.4,
        prompt_tokens: row
            .5
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(0),
        completion_tokens: row
            .6
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(0),
        tokens_estimated: row.7 != 0,
        elapsed_ms: row.8,
    }))
}

/// 最近一次失败。与 [`load_active`] 相互独立：上一次失败、这一次成功时两者都在。
pub async fn load_failure(
    pool: &SqlitePool,
    conversation_id: &str,
) -> Result<Option<Failure>, sqlx::Error> {
    let row = sqlx::query_as::<_, (String, i64, String)>(
        "SELECT error, created_at, model FROM conversation_compactions \
         WHERE conversation_id = ? AND status = 'failed' \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(conversation_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|row| Failure {
        error: row.0,
        at: row.1,
        model: row.2,
    }))
}

/// 组装给客户端的压缩视图。没有可用摘要也没有失败时返回 `None`（整段省略）。
pub async fn view(
    pool: &SqlitePool,
    conversation_id: &str,
) -> Result<Option<Compaction>, sqlx::Error> {
    // 关掉压缩的会话不下发任何状态：界面回到"没有压缩"的样子，
    // 已有摘要仍留在库里，重新开启即可继续用。
    let enabled: Option<i64> = sqlx::query_scalar(
        "SELECT compaction_disabled FROM conversations WHERE id = ? AND deleted_at IS NULL",
    )
    .bind(conversation_id)
    .fetch_optional(pool)
    .await?;
    if enabled != Some(0) {
        return Ok(None);
    }

    let active = load_active(pool, conversation_id).await?;
    let failure = load_failure(pool, conversation_id).await?;
    let Some(active) = active else {
        // 没有可用摘要：只在有失败时给一个最小视图，让界面能解释"为什么没摘要"。
        let Some(failure) = failure else {
            return Ok(None);
        };
        return Ok(Some(Compaction {
            status: "failed".to_string(),
            summary: None,
            anchor_message_id: None,
            source_messages: 0,
            model: None,
            updated_at: None,
            tokens: None,
            elapsed_ms: None,
            last_failure: Some(CompactionFailure {
                error: failure.error,
                at: failure.at,
                model: Some(failure.model).filter(|value| !value.is_empty()),
            }),
        }));
    };

    let anchor = conversation::anchor_message_id(pool, conversation_id, active.upto_seq).await?;
    let tokens = CompactionTokens {
        prompt_tokens: active.prompt_tokens,
        completion_tokens: active.completion_tokens,
        tokens_estimated: active.tokens_estimated,
    };
    Ok(Some(Compaction {
        status: "ready".to_string(),
        summary: Some(active.summary),
        anchor_message_id: anchor,
        source_messages: active.source_messages,
        model: Some(active.model.clone()).filter(|value| !value.is_empty()),
        updated_at: Some(active.updated_at),
        tokens: (!tokens.is_empty()).then_some(tokens),
        elapsed_ms: active.elapsed_ms,
        last_failure: failure.map(|failure| CompactionFailure {
            error: failure.error,
            at: failure.at,
            model: Some(failure.model).filter(|value| !value.is_empty()),
        }),
    }))
}

/// 拼给摘要模型的正文：上一次摘要（如果有）＋ 这段新增消息。
///
/// 滚雪球而不是每次重读全史：输入规模恒定为 `max_input_chars`，
/// 不会随会话长度线性膨胀。
fn build_prompt(
    previous: Option<&Active>,
    messages: &[protocol::Message],
    max_input_chars: usize,
) -> String {
    let mut parts = Vec::with_capacity(messages.len() + 2);
    if let Some(previous) = previous {
        parts.push(format!("【已有摘要（更早的内容）】\n{}", previous.summary));
    }
    parts.push("【新增对话】".to_string());
    for message in messages {
        let label = match message.role {
            protocol::MessageRole::User => "用户",
            protocol::MessageRole::Assistant => "助理",
            _ => continue,
        };
        parts.push(format!("{label}：{}", message.content));
    }

    let joined = parts.join("\n\n");
    if joined.chars().count() <= max_input_chars {
        joined
    } else {
        // 超长时保留开头：摘要要的是"这段对话讲了什么"，从最早的诉求开始才连贯。
        let trimmed: String = joined.chars().take(max_input_chars).collect();
        format!("{trimmed}\n\n（后文过长已截断）")
    }
}

async fn insert_pending(
    pool: &SqlitePool,
    record_id: &str,
    conversation_id: &str,
    source_messages: u32,
    model: &str,
    max_tokens: u32,
) -> Result<(), sqlx::Error> {
    let now = now_ms();
    sqlx::query(
        "INSERT INTO conversation_compactions \
         (id, conversation_id, status, source_messages, model, max_tokens, created_at, updated_at) \
         VALUES (?, ?, 'pending', ?, ?, ?, ?, ?)",
    )
    .bind(record_id)
    .bind(conversation_id)
    .bind(i64::from(source_messages))
    .bind(model)
    .bind(i64::from(max_tokens))
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn finish_ready(
    pool: &SqlitePool,
    record_id: &str,
    upto_seq: i64,
    summary: &str,
    prompt_tokens: u32,
    completion_tokens: u32,
    tokens_estimated: bool,
    elapsed_ms: i64,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE conversation_compactions SET status = 'ready', upto_seq = ?, summary = ?, \
         prompt_tokens = ?, completion_tokens = ?, tokens_estimated = ?, elapsed_ms = ?, \
         updated_at = ? WHERE id = ? AND status = 'pending'",
    )
    .bind(upto_seq)
    .bind(summary)
    .bind(i64::from(prompt_tokens))
    .bind(i64::from(completion_tokens))
    .bind(i64::from(tokens_estimated))
    .bind(elapsed_ms)
    .bind(now_ms())
    .bind(record_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn finish_failed(
    pool: &SqlitePool,
    record_id: &str,
    error: &str,
    elapsed_ms: i64,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE conversation_compactions SET status = 'failed', error = ?, elapsed_ms = ?, \
         updated_at = ? WHERE id = ? AND status = 'pending'",
    )
    .bind(error)
    .bind(elapsed_ms)
    .bind(now_ms())
    .bind(record_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// 去掉模型抄回来的脚手架行。
///
/// 输入里用 `【已有摘要（更早的内容）】`、`【新增对话】` 分节，模型偶尔会把
/// 这些标题当正文写出来。它们对读者没有任何信息量，还会污染下一次的摘要输入。
fn strip_scaffolding(text: &str) -> String {
    let kept: Vec<&str> = text
        .lines()
        .filter(|line| {
            let trimmed = line.trim();
            !trimmed.starts_with("【已有摘要")
                && !trimmed.starts_with("【新增对话")
                && !trimmed.starts_with("【新增")
                && trimmed != "以下是摘要："
                && trimmed != "以下是摘要"
        })
        .collect();
    kept.join("\n").trim().to_string()
}

/// 把模型错误翻成用户能看懂的一句话，并且**分档**——不同原因要给不同建议。
fn friendly_error(error: &str, timeout: Duration) -> String {
    // 上限截断与"模型不说话"是两件事：前者调大 max_tokens 能好，后者不能。
    if error.contains("截断") {
        return "摘要被输出上限截断：把 compaction.max_tokens 调大，\
                或让一次折叠的消息少一些"
            .to_string();
    }
    if error.contains("模型返回") {
        return format!("上游报错：{}", error.chars().take(160).collect::<String>());
    }
    if error.contains("没有返回内容") {
        return "模型没有返回摘要内容".to_string();
    }
    if error.contains("超过时限") || error.contains("没有输出") {
        return format!(
            "整理超时（超过 {} 秒）：模型没在时限内返回",
            timeout.as_secs().max(1)
        );
    }
    if error.contains("连不上") {
        return "连不上模型网关：检查网络与 base_url".to_string();
    }
    format!("整理失败：{}", error.chars().take(160).collect::<String>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_prompt_scaffolding_lines() {
        let raw = "【已有摘要（更早的内容）】\n- 旧要点\n\n【新增对话】\n- 新要点\n";
        assert_eq!(strip_scaffolding(raw), "- 旧要点\n\n- 新要点");

        // 全是脚手架 = 没有摘要，交给上层走重试
        assert_eq!(strip_scaffolding("【新增对话】\n"), "");
        // 正文里正常出现的方括号不受影响
        assert_eq!(
            strip_scaffolding("- 用 [链接] 注明来源"),
            "- 用 [链接] 注明来源"
        );
    }

    fn message(role: protocol::MessageRole, content: &str) -> protocol::Message {
        protocol::Message {
            id: "m".into(),
            conversation_id: "c".into(),
            role,
            content: content.into(),
            sources: Vec::new(),
            task_suggestions: Vec::new(),
            file_writes: Vec::new(),
            steps: Vec::new(),
            media: Vec::new(),
            attachments: Vec::new(),
            task_id: None,
            created_at: 0,
            elapsed_ms: None,
            usage: None,
            finish_reason: None,
        }
    }

    #[test]
    fn overflow_matches_provider_wordings() {
        assert!(is_context_overflow(
            "模型返回 400: {\"error\":{\"message\":\"context length exceeded\"}}"
        ));
        assert!(is_context_overflow(
            "模型返回 400: Range of input length should be [1, 131072]"
        ));
        assert!(is_context_overflow(
            "模型返回 413: Request entity too large: too many tokens"
        ));
        assert!(is_context_overflow("模型返回 400: prompt is too long"));
    }

    #[test]
    fn overflow_ignores_other_400s() {
        // 参数错、鉴权错不该被当成窗口溢出：重试只会再花一次钱。
        assert!(!is_context_overflow(
            "模型返回 400: invalid_request_error: model not found"
        ));
        assert!(!is_context_overflow("模型返回 401: invalid api key"));
        assert!(!is_context_overflow("连不上模型网关"));
        // 没有状态码的文案可能是别的层报的，宁可不动。
        assert!(!is_context_overflow("context length exceeded"));
    }

    #[test]
    fn trigger_by_count_and_pressure() {
        // 超过装配上限：触发。
        assert!(should_trigger(21, 20, 0, 1_000_000, 0.75));
        assert!(!should_trigger(20, 20, 0, 1_000_000, 0.75));
        // 窗口占比：小窗口模型兜底。
        assert!(should_trigger(4, 20, 24_000, 32_000, 0.75));
        assert!(!should_trigger(4, 20, 20_000, 32_000, 0.75));
        // 窗口未知时不按比例判，只看条数。
        assert!(!should_trigger(4, 20, 20_000, 0, 0.75));
    }

    #[test]
    fn prompt_keeps_previous_summary_and_marks_truncation() {
        let previous = Active {
            upto_seq: 10,
            summary: "用户在做 Rust 项目".into(),
            source_messages: 10,
            model: "m".into(),
            updated_at: 0,
            prompt_tokens: 0,
            completion_tokens: 0,
            tokens_estimated: false,
            elapsed_ms: None,
        };
        let messages = vec![
            message(protocol::MessageRole::User, "帮我看下测试"),
            message(protocol::MessageRole::Assistant, "跑过了"),
        ];
        let prompt = build_prompt(Some(&previous), &messages, 10_000);
        assert!(prompt.contains("用户在做 Rust 项目"));
        assert!(prompt.contains("用户：帮我看下测试"));
        assert!(prompt.contains("助理：跑过了"));

        let short = build_prompt(None, &messages, 11);
        assert!(short.contains("已截断"), "超长时要有明确标记：{short}");
    }

    #[test]
    fn friendly_error_tells_apart() {
        assert!(friendly_error("模型返回 500: boom", Duration::from_secs(30)).contains("上游报错"));
        assert!(
            friendly_error("模型没有返回内容", Duration::from_secs(30)).contains("没有返回摘要")
        );
        assert!(friendly_error("连不上网关", Duration::from_secs(30)).contains("连不上"));
        assert!(friendly_error("随便什么错误", Duration::from_secs(30)).contains("整理失败"));
    }
}
