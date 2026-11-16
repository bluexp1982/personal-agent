//! 记忆系统。
//!
//! 权威数据全部在 SQLite（见 `migrations/0013_memory_core.sql` 起）。本模块只做
//! "读、写、判"三件事，不发起任何网络请求，也不进 `jarvis-worker`（IPC 不变）。
//!
//! 分层约定：
//! - `tokenize`：**纯函数**，写入与查询共用同一份分词口径；
//! - `digest`：**纯函数**（分区选择 + 渲染），不碰数据库；
//! - `gates` / `privacy`：**纯函数**，准入判定与敏感度分级；
//! - `store`：SQL 读写，不写业务判定；
//! - `mod.rs`：对外门面 `MemoryService`，不写 SQL。
//!
//! **门面在 `enabled=false` 时照样存在**：写接口统一返回 [`MemoryError::Disabled`]，
//! 读接口返回空摘要。这样调用点不需要到处 `if enabled`，也不会因为忘了判断而半残。

pub mod digest;
pub mod entity;
pub mod explicit;
pub mod export;
pub mod extract;
pub mod gates;
pub mod maintenance;
pub mod privacy;
pub mod recall_tool;
pub mod retrieve;
pub mod settings;
pub mod store;
pub mod tokenize;

use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use protocol::{
    DigestSummary, EvidenceSource, ExtractQuota, HeartbeatView, MemoryCounts, MemoryCreateRequest,
    MemoryDetail, MemoryPipeline, MemoryScope, MemorySensitivity, MemorySource, MemoryStateView,
    MemoryStatus,
};
use sqlx::SqlitePool;

use crate::audit::AuditEntry;
use crate::clock::now_ms;
use crate::config::{Config, MemoryConfig};
use crate::model::CompletionModel;

use self::digest::{Digest, DigestBudget, DigestContext, DigestMode};
use self::gates::{Decision, GateConfig, RawCandidate, RejectReason};
use self::store::{EvidenceDraft, MemoryDraft, MemoryStore};

/// 记忆模块的统一错误。
///
/// 每个变体都能映射到一个稳定错误码（见 `api::error`）：`Disabled` /
/// `ModelUnavailable` → `memory_unavailable`，`NotFound` → `not_found`，
/// `Invalid` → `invalid_request`，`Conflict` → `conflict`，其余 → `internal_error`。
#[derive(Debug, thiserror::Error)]
pub enum MemoryError {
    #[error("记忆功能未启用")]
    Disabled,
    #[error("模型未配置")]
    ModelUnavailable,
    #[error("记录不存在")]
    NotFound,
    #[error("参数不合法: {0}")]
    Invalid(String),
    #[error("状态冲突: {0}")]
    Conflict(String),
    /// 库里的枚举值无法解析：说明数据被外部改过，属于内部错误。
    #[error("存储内容无法解析: {0}")]
    Corrupt(String),
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
}

/// 记忆服务的唯一入口。字段全是 `Arc` 或连接池，克隆廉价。
#[derive(Clone)]
pub struct MemoryService {
    pool: SqlitePool,
    config: Arc<MemoryConfig>,
    /// 抽取与实体重算要用的非流式模型。`None` 时抽取不可用，读写不受影响。
    ///
    /// 用 `RwLock` 而不是裸字段：切换到另一份模型配置后，下一轮抽取就该用新模型，
    /// 而记忆服务是常驻对象，不会因为换模型重建。读多写少，代价可忽略。
    model: Arc<std::sync::RwLock<Option<Arc<dyn CompletionModel>>>>,
    /// 抽取队列：限并发 + 防重入。不启用时也不会被用到。
    queue: Arc<extract::ExtractQueue>,
    /// 整理闸门：心跳与手动触发共用，保证同一时刻只有一轮整理在跑。
    organizing: Arc<AtomicBool>,
}

impl std::fmt::Debug for MemoryService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryService")
            .field("enabled", &self.config.enabled)
            .field("model", &self.model().is_some())
            .finish()
    }
}

impl MemoryService {
    pub fn new(
        pool: SqlitePool,
        config: &Config,
        model: Option<Arc<dyn CompletionModel>>,
    ) -> Arc<Self> {
        if config.memory.enabled {
            tracing::info!(
                extract = config.memory.extract.enabled,
                heartbeat = config.memory.heartbeat.enabled,
                "记忆系统已启用"
            );
        }
        Arc::new(Self {
            pool,
            config: Arc::new(config.memory.clone()),
            model: Arc::new(std::sync::RwLock::new(model)),
            queue: Arc::new(extract::ExtractQueue::new(
                config.memory.extract.max_concurrency,
            )),
            organizing: Arc::new(AtomicBool::new(false)),
        })
    }

    /// 换掉抽取用的模型。切换模型配置时由 `AppState::apply_llm` 调用。
    pub fn set_model(&self, model: Option<Arc<dyn CompletionModel>>) {
        let had = self.model().is_some();
        *self
            .model
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = model;
        let has = self.model().is_some();
        if had != has {
            // 只在可用性翻转时打日志：每次启动都对一遍会变成噪音。
            tracing::info!(available = has, "记忆抽取模型已更新");
        }
    }

    pub fn enabled(&self) -> bool {
        self.config.enabled
    }

    /// 自动抽取是否可用：开关打开 **且** 有模型。
    ///
    /// 每次现取模型槽：切到一份没有密钥的配置时，抽取要立刻安静下来，
    /// 而不是继续拿旧模型跑。
    pub fn extract_enabled(&self) -> bool {
        self.config.enabled && self.config.extract.enabled && self.model().is_some()
    }

    pub fn config(&self) -> &MemoryConfig {
        &self.config
    }

    /// 抽取用的模型。`None` 表示没有可用的非流式模型。
    pub fn model(&self) -> Option<Arc<dyn CompletionModel>> {
        self.model
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub(crate) fn extract_queue(&self) -> &extract::ExtractQueue {
        &self.queue
    }

    pub fn store(&self) -> MemoryStore<'_> {
        MemoryStore::new(&self.pool)
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    fn digest_budget(&self) -> DigestBudget {
        let digest = &self.config.digest;
        DigestBudget {
            total_chars: digest.budget_chars,
            profile_chars: digest.profile_chars,
            pinned_chars: digest.pinned_chars,
            recent_chars: digest.recent_chars,
            project_chars: digest.project_chars,
            recent_days: digest.recent_days,
        }
    }

    fn gate_config(&self) -> GateConfig {
        let extract = &self.config.extract;
        GateConfig {
            confidence_threshold: extract.confidence_threshold,
            max_content_chars: extract.max_content_chars,
            max_input_chars: extract.max_input_chars,
            daily_calls: extract.daily_calls,
            pending_limit: extract.pending_limit,
        }
    }

    /// 取本轮要注入的常驻摘要。
    ///
    /// 返回 [`Digest::empty()`] 表示"不要追加消息"；置顶超预算会返回 `Conflict`，
    /// 由调用方降级为空摘要并在状态接口里提示用户取消置顶。
    pub async fn digest(&self, ctx: DigestContext) -> Result<Digest, MemoryError> {
        if !self.config.enabled || !self.config.digest.enabled {
            return Ok(Digest::empty());
        }

        // 用户能在设置里关掉常驻摘要。这一读必须真的发生——否则弹层里的开关
        // 只是把状态写进库里，下一轮照样注入（本轮修的就是这个）。
        if !settings::digest_enabled(&self.pool).await {
            return Ok(Digest::empty());
        }

        let entries = self.store().for_digest(200).await?;
        let digest =
            digest::select(&entries, &self.digest_budget(), &ctx).map_err(|err| match err {
                digest::DigestError::PinnedOverflow { chars, budget } => MemoryError::Conflict(
                    format!("置顶记忆共 {chars} 字，超过摘要预算 {budget} 字，请取消部分置顶"),
                ),
                digest::DigestError::OverBudget { chars, budget } => MemoryError::Conflict(
                    format!("摘要预算不足：置顶内容 {chars} 字已超过总预算 {budget} 字"),
                ),
            })?;

        // 截断是"有记忆但装不下"的信号：不报错，但要留痕，否则用户会以为
        // 自己写的记忆被吞了。审计只记字数，不记正文。
        if digest.truncated {
            audit_reject(
                &self.pool,
                "memory.digest.truncated",
                serde_json::json!({
                    "chars": digest.chars,
                    "budget": self.config.digest.budget_chars,
                    "items": digest.memory_ids.len(),
                }),
            )
            .await;
        }

        Ok(digest)
    }

    /// 显式写入。命中同主体同内容的既有记忆时**合并证据**而不是新增一行。
    pub async fn remember_explicit(
        &self,
        req: MemoryCreateRequest,
    ) -> Result<MemoryDetail, MemoryError> {
        if !self.config.enabled {
            return Err(MemoryError::Disabled);
        }

        let content = req.content.trim().to_string();
        if content.is_empty() {
            return Err(MemoryError::Invalid("content 不能为空".to_string()));
        }
        let max_chars = self.config.extract.max_content_chars;
        if content.chars().count() > max_chars {
            return Err(MemoryError::Invalid(format!(
                "content 超过 {max_chars} 字上限：一条记忆只该是一句话"
            )));
        }

        // 显式记忆也要留一句原话：没有依据的记忆和编造没有区别。
        let quote = req
            .evidence_quote
            .as_deref()
            .map(str::trim)
            .filter(|quote| !quote.is_empty())
            .ok_or_else(|| {
                MemoryError::Invalid(
                    "evidence_quote 是必填：显式记忆也要留一句原话作为依据".to_string(),
                )
            })?
            .to_string();

        // 走准入闸：证据（这里源就是用户那句原话，天然成立）、敏感度、置信度。
        // 用户亲口说的东西置信度按 1.0 计，因此不会被降级成候选。
        let raw = RawCandidate {
            assertion: content,
            subject: req.subject.clone(),
            predicate: req.predicate.clone(),
            evidence_quote: quote.clone(),
            support_span: Some(quote.clone()),
            confidence: 1.0,
        };
        let verdict = gates::evaluate(&raw, &quote, &self.gate_config());

        match (verdict.decision, verdict.reason) {
            (Decision::Reject, Some(RejectReason::Secret)) => {
                return Err(MemoryError::Invalid(
                    "内容里包含密钥、证件号一类的敏感信息，已拒绝写入".to_string(),
                ));
            }
            (Decision::Reject, reason) => {
                return Err(MemoryError::Invalid(format!(
                    "这条记忆没有通过准入校验：{}",
                    reason.map(RejectReason::code).unwrap_or("unknown")
                )));
            }
            _ => {}
        }

        let sensitivity = match req.sensitivity {
            Some(MemorySensitivity::Private) => MemorySensitivity::Private,
            Some(MemorySensitivity::Normal) => MemorySensitivity::Normal,
            None => match verdict.sensitivity {
                privacy::Classification::Private => MemorySensitivity::Private,
                _ => MemorySensitivity::Normal,
            },
        };

        let scope = req.scope.unwrap_or(MemoryScope::Global);
        let batch_id = crate::ids::new_id("bat");
        let now = now_ms();
        let store = self.store();

        let subject_norm = req
            .subject
            .as_deref()
            .map(tokenize::normalize_for_match)
            .filter(|norm| !norm.is_empty());

        // 去重：同主体 + 同内容 → 追加证据、返回既有条目（对幂等重放友好）。
        if let Some(existing) = store
            .find_duplicate(subject_norm.as_deref(), &verdict.assertion)
            .await?
        {
            store
                .add_evidence(
                    &existing.id,
                    explicit_evidence(&verdict.quote, &batch_id, now),
                )
                .await?;
            self.audit_created(&existing.id, &batch_id, &verdict.quote, true)
                .await;
            return store.get(&existing.id).await?.ok_or(MemoryError::NotFound);
        }

        if scope == MemoryScope::Project && req.project_id.as_deref().unwrap_or("").is_empty() {
            return Err(MemoryError::Invalid(
                "scope=project 时必须提供 project_id".to_string(),
            ));
        }
        if let Some(project_id) = req.project_id.as_deref() {
            let exists: Option<(String,)> =
                sqlx::query_as("SELECT id FROM projects WHERE id = ? AND deleted_at IS NULL")
                    .bind(project_id)
                    .fetch_optional(&self.pool)
                    .await?;
            if exists.is_none() {
                return Err(MemoryError::Invalid(format!(
                    "project_id={project_id} 不存在或已被删除"
                )));
            }
        }

        let kind = req.kind;
        let pinned = req.pinned.unwrap_or(false);
        let memory = store
            .insert(MemoryDraft {
                kind,
                pipeline: req.pipeline.unwrap_or(MemoryPipeline::Subjective),
                status: MemoryStatus::Active,
                scope,
                project_id: req.project_id.clone(),
                sensitivity,
                content: verdict.assertion.clone(),
                subject: req.subject.clone(),
                predicate: req.predicate.clone(),
                time_scope: req.time_scope.clone(),
                due_at: None,
                confidence: 1.0,
                importance: store::importance_for(kind, 1, pinned, 0),
                pinned,
                batch_id: Some(batch_id.clone()),
                source: MemorySource::Explicit,
                valid_from: now,
            })
            .await?;

        store
            .add_evidence(
                &memory.id,
                explicit_evidence(&verdict.quote, &batch_id, now),
            )
            .await?;

        self.audit_created(&memory.id, &batch_id, &verdict.quote, false)
            .await;

        store.get(&memory.id).await?.ok_or(MemoryError::NotFound)
    }

    /// 召回：`memory_recall` 工具的唯一入口。
    ///
    /// 未启用时返回空结果而不是报错——模型看到"没有命中"会说"我没有相关记忆"，
    /// 这正是未启用时该有的行为。
    pub async fn recall(&self, query: retrieve::RecallQuery) -> retrieve::RecallOutcome {
        if !self.config.enabled || !self.config.recall.enabled {
            return retrieve::RecallOutcome {
                hits: Vec::new(),
                fallback_used: false,
                candidates: 0,
            };
        }

        match retrieve::recall(&self.pool, &self.config.recall, query.clone()).await {
            Ok(outcome) => outcome,
            Err(err) => {
                tracing::warn!(%err, "记忆召回失败");
                retrieve::RecallOutcome {
                    hits: Vec::new(),
                    fallback_used: false,
                    candidates: 0,
                }
            }
        }
    }

    /// 本轮召回是否可用（用于决定是否把 `memory_recall` 注册进工具表）。
    pub fn recall_enabled(&self) -> bool {
        self.config.enabled && self.config.recall.enabled
    }

    /// 源对象被删除：依赖它的记忆转 `stale`（不再进摘要，但详情仍可看）。
    pub async fn mark_sources_stale(
        &self,
        kind: EvidenceSource,
        source_id: &str,
    ) -> Result<usize, MemoryError> {
        if !self.config.enabled {
            return Ok(0);
        }
        self.store().mark_stale_by_source(kind, source_id).await
    }

    /// 回答落库后回填"这条记忆被用过了"。
    ///
    /// 判据（方案 7.4）：归一化后的回答正文里出现了记忆正文的 **≥8 字连续片段**。
    /// 归一化必须与写入、证据校验同一口径，否则全角/半角、空白差异会让判定永远为假。
    /// 返回真正标记成功的条数（幂等：同一轮重复调用不会重复计数）。
    pub async fn touch_used(&self, memory_ids: &[String], answer: &str) -> usize {
        if !self.config.enabled {
            return 0;
        }

        let normalized_answer = tokenize::normalize_for_match(answer);
        if normalized_answer.chars().count() < USED_MIN_CHARS {
            return 0;
        }

        let mut unique: Vec<&str> = memory_ids.iter().map(String::as_str).collect();
        unique.sort_unstable();
        unique.dedup();
        if unique.is_empty() {
            return 0;
        }

        let store = self.store();
        let mut marked = 0usize;
        for id in unique {
            let content = match store.content_of(id).await {
                Ok(Some(content)) => content,
                Ok(None) => continue,
                Err(err) => {
                    tracing::warn!(%err, memory_id = id, "读取记忆正文失败，跳过回填");
                    continue;
                }
            };

            if !answer_uses_memory(&normalized_answer, &content) {
                continue;
            }

            match store.mark_used(id).await {
                Ok(true) => marked += 1,
                Ok(false) => {}
                Err(err) => tracing::warn!(%err, memory_id = id, "回填 used 失败"),
            }
        }

        marked
    }

    /// `GET /api/memories/state` 的快照。
    pub async fn state(&self) -> Result<MemoryStateView, MemoryError> {
        let counts = if self.config.enabled {
            self.store().counts().await?
        } else {
            MemoryCounts::default()
        };

        let (digest, warning) = if self.config.enabled && self.config.digest.enabled {
            match self.digest(DigestContext::new(None, None)).await {
                Ok(digest) => (digest, None),
                // 置顶超预算是"用户能修"的状态问题，不该让整个快照接口失败。
                Err(MemoryError::Conflict(reason)) => (Digest::empty(), Some(reason)),
                Err(err) => return Err(err),
            }
        } else {
            (Digest::empty(), None)
        };

        let used_today = self.extract_used_today().await?;

        Ok(MemoryStateView {
            enabled: self.config.enabled,
            counts,
            digest: DigestSummary {
                chars: digest.chars,
                memory_items: digest.memory_ids.len(),
                generated_at: now_ms(),
            },
            extract: ExtractQuota {
                enabled: self.extract_enabled(),
                daily_limit: self.config.extract.daily_calls,
                used_today,
            },
            heartbeat: HeartbeatView {
                enabled: self.config.heartbeat.enabled,
                last_scan_at: None,
                daily_limit: self.config.heartbeat.daily_limit,
                delivered_today: 0,
            },
            maintenance: self.maintenance_view().await,
            digest_warning: warning,
        })
    }

    /// 写一份摘要快照（6 小时节流 + 内容不变不写）。
    ///
    /// 由会话链路在后台调用：快照只服务于"回到上周三的状态"，不该拖慢回答。
    pub async fn snapshot_digest(&self, text: &str, memory_ids: &[String], ctx: &DigestContext) {
        if !self.enabled() || text.is_empty() {
            return;
        }
        if let Err(err) = self.try_snapshot(text, memory_ids, ctx).await {
            tracing::warn!(%err, "记忆摘要快照写入失败");
        }
    }

    async fn try_snapshot(
        &self,
        text: &str,
        memory_ids: &[String],
        ctx: &DigestContext,
    ) -> Result<(), MemoryError> {
        /// 6 小时最多一份：每轮都写库既没必要，也会让"最近 7 份"全是今天的。
        const SNAPSHOT_INTERVAL_MS: i64 = 6 * 3600 * 1000;
        const KEEP: i64 = 7;

        let now = now_ms();
        let last: Option<(i64, String)> = sqlx::query_as(
            "SELECT created_at, content FROM memory_digest_snapshots \
             ORDER BY created_at DESC LIMIT 1",
        )
        .fetch_optional(&self.pool)
        .await?;

        if let Some((created_at, content)) = last {
            if now - created_at < SNAPSHOT_INTERVAL_MS {
                return Ok(());
            }
            if content == text {
                return Ok(());
            }
        }

        let mode = match ctx.mode {
            Some(DigestMode::Code) => Some("code"),
            Some(DigestMode::Work) => Some("work"),
            None => None,
        };
        let memory_ids_json = serde_json::to_string(memory_ids)
            .map_err(|err| MemoryError::Invalid(format!("memory_ids 无法序列化: {err}")))?;

        sqlx::query(
            "INSERT INTO memory_digest_snapshots \
              (id, mode, project_id, content, chars, memory_ids_json, created_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(crate::ids::new_id("dgs"))
        .bind(mode)
        .bind(&ctx.project_id)
        .bind(text)
        .bind(text.chars().count() as i64)
        .bind(memory_ids_json)
        .bind(now)
        .execute(&self.pool)
        .await?;

        // 只留最近 KEEP 份：这份表的用途是"回看"，不是归档。
        sqlx::query(
            "DELETE FROM memory_digest_snapshots WHERE id NOT IN ( \
               SELECT id FROM memory_digest_snapshots ORDER BY created_at DESC LIMIT ?)",
        )
        .bind(KEEP)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn extract_used_today(&self) -> Result<u32, MemoryError> {
        let day = crate::clock::format_date_ms(now_ms());
        let calls: Option<i64> =
            sqlx::query_scalar("SELECT calls FROM memory_extract_daily WHERE day = ?")
                .bind(day)
                .fetch_optional(&self.pool)
                .await?;

        Ok(calls.unwrap_or(0) as u32)
    }

    async fn audit_created(&self, memory_id: &str, batch_id: &str, quote: &str, merged: bool) {
        // 只记元数据：正文与原文都不进审计。
        crate::audit::record(
            &self.pool,
            &AuditEntry::new(memory_id, "memory", "memory.created", "ok")
                .target(memory_id)
                .detail(serde_json::json!({
                    "batch_id": batch_id,
                    "quote_chars": quote.chars().count(),
                    "merged": merged,
                })),
        )
        .await;
    }
}

/// 记一条记忆相关的审计。`detail` 只放元数据，**永不写正文或证据原文**。
pub(crate) async fn audit_reject(pool: &SqlitePool, action: &str, detail: serde_json::Value) {
    crate::audit::record(
        pool,
        &AuditEntry::new("memory", "memory", action, "ok").detail(detail),
    )
    .await;
}

/// 判定"用过"的最小连续片段长度。8 字能滤掉"好的""可以"这类短语，
/// 又不会要求模型逐字复述整条记忆。
const USED_MIN_CHARS: usize = 8;

/// 归一化后的回答里是否出现了记忆正文的连续片段。
///
/// 记忆本身短于阈值时退化为"整条包含"：一条 4 个字的偏好在回答里原样出现，
/// 同样是"用过"的强信号。
fn answer_uses_memory(normalized_answer: &str, content: &str) -> bool {
    let normalized = tokenize::normalize_for_match(content);
    let chars: Vec<char> = normalized
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .collect();
    if chars.is_empty() {
        return false;
    }

    if chars.len() < USED_MIN_CHARS {
        let needle: String = chars.iter().collect();
        let haystack: String = normalized_answer
            .chars()
            .filter(|ch| !ch.is_whitespace())
            .collect();
        return haystack.contains(&needle);
    }

    let haystack: String = normalized_answer
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .collect();
    chars
        .windows(USED_MIN_CHARS)
        .any(|window| haystack.contains(&window.iter().collect::<String>()))
}

/// 显式写入的证据：源就是用户那句原话，用批次 id 当 `source_id`，
/// 这样"撤销这批"能沿证据找到它。
fn explicit_evidence(quote: &str, batch_id: &str, created_at: i64) -> EvidenceDraft {
    EvidenceDraft {
        source_kind: EvidenceSource::Explicit,
        source_id: batch_id.to_string(),
        quote: quote.to_string(),
        support_span: Some(quote.to_string()),
        created_at,
    }
}
