//! 记忆与证据的读写、去重、软删、分词落地。
//!
//! 这一层只做 SQL 与行映射，不做"该不该记"的判定（那是 `gates`）与"要不要注入"
//! 的判定（那是 `digest`）。
//!
//! 三条硬规则：
//! 1. **读取层硬过滤**：`deleted_at IS NULL AND status != 'deleted'` 写在这里的
//!    每一个读函数里，不允许调用方各自拼条件——漏一处就是"删了还出现"。
//! 2. **分词只有一份**：`content_tokens` 由 `tokenize::tokenize_fields` 算，
//!    查询侧用 `tokenize::match_expression`，两边漂移会让召回率静默归零。
//! 3. **写入与证据同事务**：记忆落库成功但证据失败，会留下无法追溯的正文。

use protocol::{
    Cursor, EntityBrief, Evidence, EvidenceSource, Memory, MemoryCounts, MemoryDetail, MemoryKind,
    MemoryPipeline, MemoryScope, MemorySensitivity, MemorySource, MemoryStatus, TimeScope,
};
use sqlx::SqlitePool;

use super::digest::{DigestEntry, DigestKind, DigestSource};
use super::{tokenize, MemoryError};

/// 单条记忆最多保留的证据条数；超了丢最旧的（见开发方案 4.7）。
const MAX_EVIDENCE_PER_MEMORY: i64 = 20;

/// digest 一次最多取多少条候选。摘要本身有字数预算，这里只是防止全表扫。
const DIGEST_CANDIDATE_LIMIT: usize = 200;

/// 搜索候选集上限：FTS 命中不够时才走 LIKE 兜底（见开发方案 4.3）。
const SEARCH_LIMIT: usize = 100;

/// 写入一条记忆所需的全部字段（已过闸）。
#[derive(Debug, Clone)]
pub struct MemoryDraft {
    pub kind: MemoryKind,
    pub pipeline: MemoryPipeline,
    pub status: MemoryStatus,
    pub scope: MemoryScope,
    pub project_id: Option<String>,
    pub sensitivity: MemorySensitivity,
    pub content: String,
    pub subject: Option<String>,
    pub predicate: Option<String>,
    pub time_scope: Option<TimeScope>,
    /// 心跳扫描用的绝对时间（毫秒）；`time_scope` 给人看，这个给机器算。
    pub due_at: Option<i64>,
    pub confidence: f32,
    pub importance: f32,
    pub pinned: bool,
    pub batch_id: Option<String>,
    pub source: MemorySource,
    pub valid_from: i64,
}

/// 写入一条证据。
#[derive(Debug, Clone)]
pub struct EvidenceDraft {
    pub source_kind: EvidenceSource,
    pub source_id: String,
    pub quote: String,
    pub support_span: Option<String>,
    pub created_at: i64,
}

/// 局部更新。`None` 表示"不动这个字段"。
#[derive(Debug, Clone, Default)]
pub struct MemoryPatch {
    pub content: Option<String>,
    pub pinned: Option<bool>,
    pub sensitivity: Option<MemorySensitivity>,
    pub kind: Option<MemoryKind>,
    pub status: Option<MemoryStatus>,
    pub time_scope: Option<TimeScope>,
    pub source: Option<MemorySource>,
    pub importance: Option<f32>,
}

/// 列表过滤条件。全部可选，`None` 表示不过滤。
#[derive(Debug, Clone, Default)]
pub struct MemoryFilter {
    pub kind: Option<MemoryKind>,
    pub status: Option<MemoryStatus>,
    pub scope: Option<MemoryScope>,
    pub project_id: Option<String>,
    pub entity_id: Option<String>,
    pub batch_id: Option<String>,
    /// 关键词搜索。命中走 FTS，不够再走 LIKE 兜底。
    pub q: Option<String>,
    /// 遗忘条件：来源管道。列表查询不用它。
    pub source: Option<MemorySource>,
    /// 遗忘条件：早于该时刻（Unix 毫秒）。列表查询不用它。
    pub before: Option<i64>,
}

#[derive(Debug)]
pub struct MemoryStore<'a> {
    pool: &'a SqlitePool,
}

impl<'a> MemoryStore<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    // ---------- 写入 ----------

    /// 插入一条记忆。FTS 索引由触发器在同一事务里维护。
    pub async fn insert(&self, draft: MemoryDraft) -> Result<Memory, MemoryError> {
        let id = crate::ids::new_id("mem");
        let content_tokens = tokenize::tokenize_fields(
            &draft.content,
            draft.subject.as_deref(),
            draft.predicate.as_deref(),
        );
        let subject_norm = draft
            .subject
            .as_deref()
            .map(tokenize::normalize_for_match)
            .filter(|norm| !norm.is_empty());
        let time_scope_json = draft
            .time_scope
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|err| MemoryError::Invalid(format!("time_scope 无法序列化: {err}")))?;
        let now = crate::clock::now_ms();

        sqlx::query(
            "INSERT INTO memories (id, kind, pipeline, status, scope, project_id, sensitivity, \
              content, content_tokens, subject, subject_norm, predicate, time_scope_json, due_at, \
              confidence, importance, pinned, batch_id, source, valid_from, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&id)
        .bind(draft.kind.as_str())
        .bind(draft.pipeline.as_str())
        .bind(draft.status.as_str())
        .bind(draft.scope.as_str())
        .bind(&draft.project_id)
        .bind(draft.sensitivity.as_str())
        .bind(&draft.content)
        .bind(&content_tokens)
        .bind(&draft.subject)
        .bind(&subject_norm)
        .bind(&draft.predicate)
        .bind(&time_scope_json)
        .bind(draft.due_at)
        .bind(f64::from(draft.confidence))
        .bind(f64::from(draft.importance))
        .bind(i64::from(draft.pinned))
        .bind(&draft.batch_id)
        .bind(draft.source.as_str())
        .bind(draft.valid_from)
        .bind(now)
        .bind(now)
        .execute(self.pool)
        .await?;

        self.get(&id)
            .await?
            .map(|detail| detail.memory)
            .ok_or_else(|| {
                MemoryError::Corrupt("刚写入的记忆读不回来，检查 memories 读路径".to_string())
            })
    }

    /// 追加一条证据。超过上限时丢最旧的一条，不报错。
    pub async fn add_evidence(
        &self,
        memory_id: &str,
        draft: EvidenceDraft,
    ) -> Result<(), MemoryError> {
        let existing: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM memory_evidence WHERE memory_id = ?")
                .bind(memory_id)
                .fetch_one(self.pool)
                .await?;

        if existing >= MAX_EVIDENCE_PER_MEMORY {
            sqlx::query(
                "DELETE FROM memory_evidence WHERE id = ( \
                   SELECT id FROM memory_evidence WHERE memory_id = ? \
                   ORDER BY created_at ASC, id ASC LIMIT 1)",
            )
            .bind(memory_id)
            .execute(self.pool)
            .await?;
        }

        sqlx::query(
            "INSERT INTO memory_evidence \
              (id, memory_id, source_kind, source_id, quote, support_span, created_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(crate::ids::new_id("ev"))
        .bind(memory_id)
        .bind(draft.source_kind.as_str())
        .bind(&draft.source_id)
        .bind(&draft.quote)
        .bind(&draft.support_span)
        .bind(draft.created_at)
        .execute(self.pool)
        .await?;

        Ok(())
    }

    /// 局部更新。改正文会重算分词串（触发器随之重建 FTS 行）。
    pub async fn update(&self, id: &str, patch: MemoryPatch) -> Result<Memory, MemoryError> {
        let current = self.get(id).await?.ok_or(MemoryError::NotFound)?;

        let content_tokens = patch.content.as_ref().map(|content| {
            tokenize::tokenize_fields(
                content,
                current.memory.subject.as_deref(),
                current.memory.predicate.as_deref(),
            )
        });
        let time_scope_json = match &patch.time_scope {
            Some(time_scope) => Some(
                serde_json::to_string(time_scope)
                    .map_err(|err| MemoryError::Invalid(format!("time_scope 无法序列化: {err}")))?,
            ),
            None => None,
        };

        sqlx::query(
            "UPDATE memories SET \
               content = COALESCE(?, content), \
               content_tokens = COALESCE(?, content_tokens), \
               pinned = COALESCE(?, pinned), \
               sensitivity = COALESCE(?, sensitivity), \
               kind = COALESCE(?, kind), \
               status = COALESCE(?, status), \
               time_scope_json = COALESCE(?, time_scope_json), \
               source = COALESCE(?, source), \
               importance = COALESCE(?, importance), \
               updated_at = ? \
             WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(&patch.content)
        .bind(&content_tokens)
        .bind(patch.pinned.map(i64::from))
        .bind(patch.sensitivity.map(MemorySensitivity::as_str))
        .bind(patch.kind.map(MemoryKind::as_str))
        .bind(patch.status.map(MemoryStatus::as_str))
        .bind(&time_scope_json)
        .bind(patch.source.map(MemorySource::as_str))
        .bind(patch.importance.map(f64::from))
        .bind(crate::clock::now_ms())
        .bind(id)
        .execute(self.pool)
        .await?;

        self.get(id)
            .await?
            .map(|detail| detail.memory)
            .ok_or(MemoryError::NotFound)
    }

    pub async fn set_status(&self, id: &str, status: MemoryStatus) -> Result<(), MemoryError> {
        let now = crate::clock::now_ms();
        let deleted_at = (status == MemoryStatus::Deleted).then_some(now);
        let affected = sqlx::query(
            "UPDATE memories SET status = ?, updated_at = ?, \
                    deleted_at = COALESCE(?, deleted_at) \
             WHERE id = ?",
        )
        .bind(status.as_str())
        .bind(now)
        .bind(deleted_at)
        .bind(id)
        .execute(self.pool)
        .await?
        .rows_affected();

        if affected == 0 {
            return Err(MemoryError::NotFound);
        }
        Ok(())
    }

    /// 软删：行保留，读路径立即排除。重复删除不报错（幂等）。
    pub async fn soft_delete(&self, id: &str) -> Result<(), MemoryError> {
        let now = crate::clock::now_ms();
        let affected = sqlx::query(
            "UPDATE memories SET status = 'deleted', deleted_at = ?, updated_at = ? \
             WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(now)
        .bind(now)
        .bind(id)
        .execute(self.pool)
        .await?
        .rows_affected();

        if affected == 0 {
            // 已经删过就当成功；真正不存在才报 NotFound。
            let exists: Option<(String,)> = sqlx::query_as("SELECT id FROM memories WHERE id = ?")
                .bind(id)
                .fetch_optional(self.pool)
                .await?;
            if exists.is_none() {
                return Err(MemoryError::NotFound);
            }
        }
        Ok(())
    }

    /// 清空归档：把 `status='archived'` 的行批量软删（转 `deleted`），可选按类别收窄。
    ///
    /// 归档只是"不再作数的历史存档"，清空它不影响任何读路径的行为（归档本就不进
    /// 摘要/检索/查重）；仍走软删而不是物理删除，与单条删除语义一致。返回清除条数。
    pub async fn purge_archived(&self, kind: Option<MemoryKind>) -> Result<usize, MemoryError> {
        let now = crate::clock::now_ms();
        let affected = sqlx::query(
            "UPDATE memories SET status = 'deleted', deleted_at = ?, updated_at = ? \
             WHERE status = 'archived' AND deleted_at IS NULL \
               AND (? IS NULL OR kind = ?)",
        )
        .bind(now)
        .bind(now)
        .bind(kind.map(MemoryKind::as_str))
        .bind(kind.map(MemoryKind::as_str))
        .execute(self.pool)
        .await?
        .rows_affected();

        Ok(affected as usize)
    }

    /// 整批撤销：转 `archived`，不硬删，时间线仍可追溯。
    pub async fn revoke_batch(&self, batch_id: &str) -> Result<usize, MemoryError> {
        let affected = sqlx::query(
            "UPDATE memories SET status = 'archived', updated_at = ? \
             WHERE batch_id = ? AND status IN ('active', 'candidate')",
        )
        .bind(crate::clock::now_ms())
        .bind(batch_id)
        .execute(self.pool)
        .await?
        .rows_affected();

        Ok(affected as usize)
    }

    /// 源被删除时把依赖它的记忆转 `stale`（不删数据，只是不再注入）。
    pub async fn mark_stale_by_source(
        &self,
        kind: EvidenceSource,
        source_id: &str,
    ) -> Result<usize, MemoryError> {
        let affected = sqlx::query(
            "UPDATE memories SET status = 'stale', updated_at = ? \
             WHERE status = 'active' AND id IN ( \
               SELECT memory_id FROM memory_evidence WHERE source_kind = ? AND source_id = ?)",
        )
        .bind(crate::clock::now_ms())
        .bind(kind.as_str())
        .bind(source_id)
        .execute(self.pool)
        .await?
        .rows_affected();

        Ok(affected as usize)
    }

    // ---------- 去重 ----------

    /// 同主体 + 同内容（归一化后）的既有记忆。
    pub async fn find_duplicate(
        &self,
        subject_norm: Option<&str>,
        content: &str,
    ) -> Result<Option<Memory>, MemoryError> {
        let tokens = tokenize::tokenize_for_index(content);
        let row: Option<MemoryRow> = sqlx::query_as(
            "SELECT * FROM memories \
             WHERE subject_norm IS ? AND content_tokens = ? \
               AND deleted_at IS NULL AND status IN ('active', 'candidate') \
             ORDER BY updated_at DESC LIMIT 1",
        )
        .bind(subject_norm)
        .bind(tokens)
        .fetch_optional(self.pool)
        .await?;

        if let Some(row) = row {
            return row.into_memory().map(Some);
        }

        // 兜底：标点/空格/引号差异会让 `content_tokens` 不相等，
        // 但它们在语义上是同一句话（`用户出生于1982年` vs `用户出生于 1982 年`）。
        // 只在同主体范围内比较，避免把"别人的同一句话"合并进来。
        let target = tokenize::normalize_content(content);
        if target.is_empty() {
            return Ok(None);
        }

        let candidates: Vec<MemoryRow> = sqlx::query_as(
            "SELECT * FROM memories \
             WHERE subject_norm IS ? AND deleted_at IS NULL \
               AND status IN ('active', 'candidate') \
             ORDER BY updated_at DESC LIMIT 50",
        )
        .bind(subject_norm)
        .fetch_all(self.pool)
        .await?;

        for row in candidates {
            if tokenize::normalize_content(&row.content) == target {
                return row.into_memory().map(Some);
            }
        }

        Ok(None)
    }

    /// 同一主体、**同一谓词**下内容不同的其它 active 记忆条数（用于 `conflicting` 标记）。
    ///
    /// 必须带谓词：只看主体的话，一个人名下的"生日""称呼""籍贯"会互相判成"存在分歧"，
    /// 于是每一条关于自己的记忆都顶着一条吓人的提示。谓词为空时不判定——
    /// 没有谓词就没有"同一件事"的判据。
    async fn conflicting_count(&self, memory: &Memory) -> Result<u32, MemoryError> {
        let (Some(subject), Some(predicate)) =
            (memory.subject.as_deref(), memory.predicate.as_deref())
        else {
            return Ok(0);
        };
        let predicate = predicate.trim();
        if predicate.is_empty() {
            return Ok(0);
        }

        let subject_norm = tokenize::normalize_for_match(subject);
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM memories \
             WHERE subject_norm = ? AND predicate = ? AND id != ? AND content != ? \
               AND status = 'active' AND deleted_at IS NULL",
        )
        .bind(&subject_norm)
        .bind(predicate)
        .bind(&memory.id)
        .bind(&memory.content)
        .fetch_one(self.pool)
        .await?;

        Ok(count as u32)
    }

    // ---------- 读取 ----------

    pub async fn get(&self, id: &str) -> Result<Option<MemoryDetail>, MemoryError> {
        let row: Option<MemoryRow> = sqlx::query_as(
            "SELECT * FROM memories WHERE id = ? AND deleted_at IS NULL AND status != 'deleted'",
        )
        .bind(id)
        .fetch_optional(self.pool)
        .await?;

        let Some(row) = row else {
            return Ok(None);
        };
        let mut memory = row.into_memory()?;
        memory.conflicting = self.conflicting_count(&memory).await? > 0;

        let evidence = self.evidence_of(&memory.id).await?;
        let recall_count = self.recall_count(&memory.id).await?;
        let entity = self.entity_brief(memory.entity_id.as_deref()).await?;

        Ok(Some(MemoryDetail {
            memory,
            evidence,
            entity,
            recall_count,
        }))
    }

    async fn evidence_of(&self, memory_id: &str) -> Result<Vec<Evidence>, MemoryError> {
        let rows: Vec<(String, String, String, String, Option<String>, i64)> = sqlx::query_as(
            "SELECT id, source_kind, source_id, quote, support_span, created_at \
             FROM memory_evidence WHERE memory_id = ? ORDER BY created_at ASC, id ASC",
        )
        .bind(memory_id)
        .fetch_all(self.pool)
        .await?;

        rows.into_iter()
            .map(|(id, kind, source_id, quote, span, created_at)| {
                let source_kind = EvidenceSource::parse(&kind)
                    .ok_or_else(|| MemoryError::Corrupt(format!("evidence.source_kind={kind}")))?;
                Ok(Evidence {
                    id,
                    source_kind,
                    source_id,
                    quote,
                    support_span: span,
                    created_at,
                })
            })
            .collect()
    }

    /// 被召回过的次数（`memory_recall_log` 的条数）。
    pub async fn recall_count(&self, memory_id: &str) -> Result<u32, MemoryError> {
        let count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM memory_recall_log WHERE memory_id = ?")
                .bind(memory_id)
                .fetch_one(self.pool)
                .await?;
        Ok(count as u32)
    }

    /// 实体摘要：详情页顶部那行"这个人是谁"。
    ///
    /// 直接查 `memory_entities` 而不是转调 `entity` 模块：`entity` 已经依赖
    /// `store` 的行映射，反向依赖会绕成环。
    async fn entity_brief(
        &self,
        entity_id: Option<&str>,
    ) -> Result<Option<EntityBrief>, MemoryError> {
        let Some(entity_id) = entity_id else {
            return Ok(None);
        };
        let row: Option<(String, String, String)> = sqlx::query_as(
            "SELECT id, name, entity_type FROM memory_entities WHERE id = ? AND status != 'merged'",
        )
        .bind(entity_id)
        .fetch_optional(self.pool)
        .await?;

        let Some((id, name, entity_type)) = row else {
            return Ok(None);
        };
        let entity_type = protocol::EntityType::parse(&entity_type)
            .ok_or_else(|| MemoryError::Corrupt(format!("entity_type={entity_type}")))?;

        Ok(Some(EntityBrief {
            id,
            name,
            entity_type,
        }))
    }

    /// 列表：无关键词时按 `(updated_at DESC, id DESC)` 游标翻页；
    /// 有关键词时按相关度排序且**不分页**（相关度没法用它做游标）。
    pub async fn list(
        &self,
        filter: MemoryFilter,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<(Vec<Memory>, Option<Cursor>), MemoryError> {
        let limit = clamp_limit(limit)?;

        if let Some(query) = filter.q.as_deref().map(str::trim).filter(|q| !q.is_empty()) {
            return self
                .search(query, &filter, limit)
                .await
                .map(|items| (items, None));
        }

        let fetch = i64::from(limit) + 1;
        let cursor = match cursor {
            Some(raw) => Some(Cursor::decode(raw).ok_or_else(|| {
                MemoryError::Invalid("cursor 无法解析，应原样回传上一页的 next_cursor".to_string())
            })?),
            None => None,
        };

        let rows: Vec<MemoryRow> = sqlx::query_as(
            "SELECT * FROM memories \
             WHERE deleted_at IS NULL AND status != 'deleted' \
               AND (? IS NULL OR kind = ?) \
               AND (? IS NULL OR status = ?) \
               AND (? IS NULL OR scope = ?) \
               AND (? IS NULL OR project_id = ?) \
               AND (? IS NULL OR entity_id = ?) \
               AND (? IS NULL OR batch_id = ?) \
               AND (? IS NULL OR updated_at < ? OR (updated_at = ? AND id < ?)) \
             ORDER BY updated_at DESC, id DESC LIMIT ?",
        )
        .bind(filter.kind.map(MemoryKind::as_str))
        .bind(filter.kind.map(MemoryKind::as_str))
        .bind(filter.status.map(MemoryStatus::as_str))
        .bind(filter.status.map(MemoryStatus::as_str))
        .bind(filter.scope.map(MemoryScope::as_str))
        .bind(filter.scope.map(MemoryScope::as_str))
        .bind(filter.project_id.as_deref())
        .bind(filter.project_id.as_deref())
        .bind(filter.entity_id.as_deref())
        .bind(filter.entity_id.as_deref())
        .bind(filter.batch_id.as_deref())
        .bind(filter.batch_id.as_deref())
        .bind(cursor.as_ref().map(|c| c.updated_at))
        .bind(cursor.as_ref().map(|c| c.updated_at))
        .bind(cursor.as_ref().map(|c| c.updated_at))
        .bind(cursor.as_ref().map(|c| c.id.clone()))
        .bind(fetch)
        .fetch_all(self.pool)
        .await?;

        split_page(rows, limit)
    }

    /// 关键词检索：先 FTS（bigram 预分词 + bm25），命中不足再 LIKE 兜底。
    async fn search(
        &self,
        query: &str,
        filter: &MemoryFilter,
        limit: u32,
    ) -> Result<Vec<Memory>, MemoryError> {
        let expression = tokenize::match_expression(query);
        let mut items: Vec<Memory> = Vec::new();

        if !expression.is_empty() {
            let rows: Vec<MemoryRow> = sqlx::query_as(
                "SELECT m.* FROM memories_fts JOIN memories m ON m.rowid = memories_fts.rowid \
                 WHERE memories_fts MATCH ? \
                   AND m.deleted_at IS NULL AND m.status != 'deleted' \
                   AND (? IS NULL OR m.kind = ?) \
                   AND (? IS NULL OR m.status = ?) \
                   AND (? IS NULL OR m.scope = ?) \
                   AND (? IS NULL OR m.project_id = ?) \
                   AND (? IS NULL OR m.entity_id = ?) \
                   AND (? IS NULL OR m.batch_id = ?) \
                 ORDER BY bm25(memories_fts) LIMIT ?",
            )
            .bind(&expression)
            .bind(filter.kind.map(MemoryKind::as_str))
            .bind(filter.kind.map(MemoryKind::as_str))
            .bind(filter.status.map(MemoryStatus::as_str))
            .bind(filter.status.map(MemoryStatus::as_str))
            .bind(filter.scope.map(MemoryScope::as_str))
            .bind(filter.scope.map(MemoryScope::as_str))
            .bind(filter.project_id.as_deref())
            .bind(filter.project_id.as_deref())
            .bind(filter.entity_id.as_deref())
            .bind(filter.entity_id.as_deref())
            .bind(filter.batch_id.as_deref())
            .bind(filter.batch_id.as_deref())
            .bind(i64::from(limit))
            .fetch_all(self.pool)
            .await?;

            for row in rows {
                items.push(row.into_memory()?);
            }
        }

        if items.len() as u32 >= limit {
            items.truncate(limit as usize);
            return Ok(items);
        }

        // 兜底：FTS 在中文下可能是空集（"不可用"而非"降级"）。带结构化过滤与上限，
        // 不做无界全表扫。
        let pattern = format!("%{}%", tokenize::normalize_for_match(query));
        let rows: Vec<MemoryRow> = sqlx::query_as(
            "SELECT * FROM memories \
             WHERE deleted_at IS NULL AND status != 'deleted' \
               AND (content LIKE ? OR subject LIKE ?) \
               AND (? IS NULL OR kind = ?) \
               AND (? IS NULL OR status = ?) \
               AND (? IS NULL OR scope = ?) \
               AND (? IS NULL OR project_id = ?) \
               AND (? IS NULL OR entity_id = ?) \
               AND (? IS NULL OR batch_id = ?) \
             ORDER BY updated_at DESC, id DESC LIMIT ?",
        )
        .bind(&pattern)
        .bind(&pattern)
        .bind(filter.kind.map(MemoryKind::as_str))
        .bind(filter.kind.map(MemoryKind::as_str))
        .bind(filter.status.map(MemoryStatus::as_str))
        .bind(filter.status.map(MemoryStatus::as_str))
        .bind(filter.scope.map(MemoryScope::as_str))
        .bind(filter.scope.map(MemoryScope::as_str))
        .bind(filter.project_id.as_deref())
        .bind(filter.project_id.as_deref())
        .bind(filter.entity_id.as_deref())
        .bind(filter.entity_id.as_deref())
        .bind(filter.batch_id.as_deref())
        .bind(filter.batch_id.as_deref())
        .bind(SEARCH_LIMIT as i64)
        .fetch_all(self.pool)
        .await?;

        for row in rows {
            let memory = row.into_memory()?;
            if items.iter().any(|existing| existing.id == memory.id) {
                continue;
            }
            items.push(memory);
            if items.len() as u32 >= limit {
                break;
            }
        }

        Ok(items)
    }

    /// digest 取数：只取"可进摘要"的（active、未删除、非私密），按置顶与重要度排序。
    ///
    /// 模式与项目过滤在 `digest::select` 里做——那一层是纯函数，可以脱离数据库单测。
    pub async fn for_digest(&self, limit: usize) -> Result<Vec<DigestEntry>, MemoryError> {
        let rows: Vec<MemoryRow> = sqlx::query_as(
            "SELECT * FROM memories \
             WHERE status = 'active' AND deleted_at IS NULL AND sensitivity = 'normal' \
             ORDER BY pinned DESC, importance DESC, updated_at DESC LIMIT ?",
        )
        .bind(limit.min(DIGEST_CANDIDATE_LIMIT) as i64)
        .fetch_all(self.pool)
        .await?;

        let mut entries = Vec::with_capacity(rows.len());
        for row in rows {
            let memory = row.into_memory()?;
            let Some(kind) = digest_kind(memory.kind) else {
                // 未知类型不进摘要（宁可少一条，也不让模型看到解释不了的块）。
                continue;
            };
            entries.push(DigestEntry {
                id: memory.id.clone(),
                kind,
                content: memory.content.clone(),
                source: digest_source(memory.source),
                at: memory.created_at,
                pinned: memory.pinned,
                importance: memory.importance,
                project_id: memory.project_id.clone(),
                private: memory.sensitivity == MemorySensitivity::Private,
            });
        }

        Ok(entries)
    }

    pub async fn counts(&self) -> Result<MemoryCounts, MemoryError> {
        let rows: Vec<(String, i64)> = sqlx::query_as(
            "SELECT status, COUNT(*) FROM memories WHERE deleted_at IS NULL GROUP BY status",
        )
        .fetch_all(self.pool)
        .await?;

        let mut counts = MemoryCounts::default();
        for (status, count) in rows {
            let count = count as u32;
            match status.as_str() {
                "candidate" => counts.candidate = count,
                "active" => counts.active = count,
                "stale" => counts.stale = count,
                "archived" => counts.archived = count,
                _ => {}
            }
        }
        Ok(counts)
    }

    /// 候选列表（按批次分组用）。
    pub async fn candidates(
        &self,
        batch_id: Option<&str>,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<(Vec<Memory>, Option<Cursor>), MemoryError> {
        self.list(
            MemoryFilter {
                status: Some(MemoryStatus::Candidate),
                batch_id: batch_id.map(str::to_string),
                ..MemoryFilter::default()
            },
            cursor,
            limit,
        )
        .await
    }
}

/// 重要度公式（初值，可调）：基础值 + 证据数 + 置顶 + 使用次数。
pub fn importance_for(
    kind: MemoryKind,
    evidence_count: usize,
    pinned: bool,
    use_count: u32,
) -> f32 {
    let base = match kind {
        MemoryKind::Profile | MemoryKind::Preference => 0.6,
        MemoryKind::Event => 0.3,
        MemoryKind::Project => 0.5,
    };
    let evidence_bonus = 0.15 * (evidence_count.saturating_sub(1) as f32);
    let pinned_bonus = if pinned { 0.25 } else { 0.0 };
    let use_bonus = 0.05 * use_count.min(4) as f32;

    (base + evidence_bonus + pinned_bonus + use_bonus).clamp(0.0, 1.0)
}

fn digest_kind(kind: MemoryKind) -> Option<DigestKind> {
    match kind {
        MemoryKind::Profile => Some(DigestKind::Profile),
        MemoryKind::Preference => Some(DigestKind::Preference),
        MemoryKind::Event => Some(DigestKind::Event),
        MemoryKind::Project => Some(DigestKind::Project),
    }
}

fn digest_source(source: MemorySource) -> DigestSource {
    match source {
        MemorySource::Explicit => DigestSource::Explicit,
        MemorySource::Session => DigestSource::Session,
        MemorySource::Task => DigestSource::Task,
        MemorySource::Recording => DigestSource::Recording,
        MemorySource::CodeTask => DigestSource::CodeTask,
        MemorySource::Heartbeat => DigestSource::Heartbeat,
        MemorySource::UserCorrected => DigestSource::UserCorrected,
    }
}

fn clamp_limit(limit: u32) -> Result<u32, MemoryError> {
    match limit {
        0 => Ok(20),
        value if value > 100 => Ok(100),
        value => Ok(value),
    }
}

fn split_page(
    rows: Vec<MemoryRow>,
    limit: u32,
) -> Result<(Vec<Memory>, Option<Cursor>), MemoryError> {
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        items.push(row.into_memory()?);
    }

    let next_cursor = if items.len() > limit as usize {
        items.truncate(limit as usize);
        items
            .last()
            .map(|memory| Cursor::new(memory.updated_at, memory.id.clone()))
    } else {
        None
    };

    Ok((items, next_cursor))
}

/// 行映射。列多，集中在这里，避免每个查询各写一遍下标。
///
/// `pub(crate)`：`retrieve` 要用同一份映射做打分，两处各写一遍下标迟早会错列。
#[derive(Debug, sqlx::FromRow)]
pub(crate) struct MemoryRow {
    pub(crate) id: String,
    kind: String,
    pipeline: String,
    status: String,
    scope: String,
    project_id: Option<String>,
    sensitivity: String,
    content: String,
    subject: Option<String>,
    entity_id: Option<String>,
    predicate: Option<String>,
    time_scope_json: Option<String>,
    confidence: f64,
    pub(crate) importance: f64,
    pinned: i64,
    batch_id: Option<String>,
    source: String,
    valid_from: i64,
    valid_to: Option<i64>,
    superseded_by: Option<String>,
    use_count: i64,
    /// 召回反馈。不对外暴露（`Memory` 里没有这两个字段），只参与召回打分。
    pub(crate) useful_count: i64,
    pub(crate) useless_count: i64,
    pub(crate) created_at: i64,
    updated_at: i64,
}

impl MemoryRow {
    pub(crate) fn into_memory(self) -> Result<Memory, MemoryError> {
        let kind = MemoryKind::parse(&self.kind)
            .ok_or_else(|| MemoryError::Corrupt(format!("memories.kind={}", self.kind)))?;
        let pipeline = MemoryPipeline::parse(&self.pipeline)
            .ok_or_else(|| MemoryError::Corrupt(format!("memories.pipeline={}", self.pipeline)))?;
        let status = MemoryStatus::parse(&self.status)
            .ok_or_else(|| MemoryError::Corrupt(format!("memories.status={}", self.status)))?;
        let scope = MemoryScope::parse(&self.scope)
            .ok_or_else(|| MemoryError::Corrupt(format!("memories.scope={}", self.scope)))?;
        let sensitivity = MemorySensitivity::parse(&self.sensitivity).ok_or_else(|| {
            MemoryError::Corrupt(format!("memories.sensitivity={}", self.sensitivity))
        })?;
        let source = MemorySource::parse(&self.source)
            .ok_or_else(|| MemoryError::Corrupt(format!("memories.source={}", self.source)))?;
        let time_scope = match self.time_scope_json.as_deref() {
            None => None,
            Some(raw) => Some(
                serde_json::from_str::<TimeScope>(raw)
                    .map_err(|err| MemoryError::Corrupt(format!("time_scope_json: {err}")))?,
            ),
        };

        Ok(Memory {
            id: self.id,
            kind,
            pipeline,
            status,
            scope,
            project_id: self.project_id,
            sensitivity,
            content: self.content,
            subject: self.subject,
            entity_id: self.entity_id,
            predicate: self.predicate,
            time_scope,
            confidence: self.confidence as f32,
            importance: self.importance as f32,
            pinned: self.pinned != 0,
            batch_id: self.batch_id,
            source,
            valid_from: self.valid_from,
            valid_to: self.valid_to,
            superseded_by: self.superseded_by,
            use_count: self.use_count as u32,
            conflicting: false,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

// ---------------------------------------------------------------------------
// 候选、反馈、批量遗忘（P2/P4）
// ---------------------------------------------------------------------------

impl MemoryStore<'_> {
    /// 反馈：`useful_count` / `useless_count` 只增不减，召回打分用差值。
    pub async fn feedback(&self, id: &str, useful: bool) -> Result<Memory, MemoryError> {
        // 两条静态 SQL 而不是拼列名：sqlx 0.9 拒绝运行时拼接的 SQL 字符串。
        const USEFUL: &str = "UPDATE memories SET useful_count = useful_count + 1, updated_at = ? \
             WHERE id = ? AND deleted_at IS NULL AND status != 'deleted'";
        const USELESS: &str =
            "UPDATE memories SET useless_count = useless_count + 1, updated_at = ? \
             WHERE id = ? AND deleted_at IS NULL AND status != 'deleted'";
        let sql = if useful { USEFUL } else { USELESS };
        let affected = sqlx::query(sql)
            .bind(crate::clock::now_ms())
            .bind(id)
            .execute(self.pool)
            .await?
            .rows_affected();

        if affected == 0 {
            return Err(MemoryError::NotFound);
        }

        let row: MemoryRow = sqlx::query_as("SELECT * FROM memories WHERE id = ?")
            .bind(id)
            .fetch_one(self.pool)
            .await?;
        row.into_memory()
    }

    /// 候选决策：接受 = 转 active 并重算重要度；拒绝 = 转 archived（记录仍可查）。
    pub async fn decide(
        &self,
        ids: &[String],
        accept: bool,
    ) -> Result<(usize, usize, Vec<String>), MemoryError> {
        let now = crate::clock::now_ms();
        let mut done = 0usize;
        let mut skipped = Vec::new();

        for id in ids {
            let row: Option<MemoryRow> = sqlx::query_as("SELECT * FROM memories WHERE id = ?")
                .bind(id)
                .fetch_optional(self.pool)
                .await?;

            let Some(row) = row else {
                skipped.push(id.clone());
                continue;
            };
            if row.status != "candidate" {
                skipped.push(id.clone());
                continue;
            }

            if accept {
                let kind = MemoryKind::parse(&row.kind)
                    .ok_or_else(|| MemoryError::Corrupt(format!("memories.kind={}", row.kind)))?;
                let pinned = row.pinned != 0;
                let importance = importance_for(kind, 1, pinned, row.useful_count.max(0) as u32);
                sqlx::query(
                    "UPDATE memories SET status = 'active', importance = ?, updated_at = ? WHERE id = ?",
                )
                .bind(f64::from(importance))
                .bind(now)
                .bind(id)
                .execute(self.pool)
                .await?;
            } else {
                sqlx::query("UPDATE memories SET status = 'archived', updated_at = ? WHERE id = ?")
                    .bind(now)
                    .bind(id)
                    .execute(self.pool)
                    .await?;
            }
            done += 1;
        }

        Ok(if accept {
            (done, 0, skipped)
        } else {
            (0, done, skipped)
        })
    }

    /// 按条件统计（遗忘预览用）。
    pub async fn count_matching(&self, filter: &MemoryFilter) -> Result<usize, MemoryError> {
        let row: (i64,) = sqlx::query_as(FORGET_WHERE_COUNT)
            .bind(filter.entity_id.as_deref())
            .bind(filter.entity_id.as_deref())
            .bind(filter.kind.map(MemoryKind::as_str))
            .bind(filter.kind.map(MemoryKind::as_str))
            .bind(filter.source.map(MemorySource::as_str))
            .bind(filter.source.map(MemorySource::as_str))
            .bind(filter.before)
            .bind(filter.before)
            .bind(filter.batch_id.as_deref())
            .bind(filter.batch_id.as_deref())
            .bind(filter.scope.map(MemoryScope::as_str))
            .bind(filter.scope.map(MemoryScope::as_str))
            .bind(filter.project_id.as_deref())
            .bind(filter.project_id.as_deref())
            .fetch_one(self.pool)
            .await?;
        Ok(row.0.max(0) as usize)
    }

    /// 批量遗忘：软删（`status=deleted` + `deleted_at`），行保留。
    pub async fn forget_matching(&self, filter: &MemoryFilter) -> Result<usize, MemoryError> {
        let now = crate::clock::now_ms();
        let affected = sqlx::query(FORGET_WHERE_UPDATE)
            .bind(now)
            .bind(now)
            .bind(filter.entity_id.as_deref())
            .bind(filter.entity_id.as_deref())
            .bind(filter.kind.map(MemoryKind::as_str))
            .bind(filter.kind.map(MemoryKind::as_str))
            .bind(filter.source.map(MemorySource::as_str))
            .bind(filter.source.map(MemorySource::as_str))
            .bind(filter.before)
            .bind(filter.before)
            .bind(filter.batch_id.as_deref())
            .bind(filter.batch_id.as_deref())
            .bind(filter.scope.map(MemoryScope::as_str))
            .bind(filter.scope.map(MemoryScope::as_str))
            .bind(filter.project_id.as_deref())
            .bind(filter.project_id.as_deref())
            .execute(self.pool)
            .await?
            .rows_affected();
        Ok(affected as usize)
    }
}

/// `(? IS NULL OR 列 = ?)` 的成对写法：`None` 表示不过滤。
const FORGET_WHERE_COUNT: &str = "SELECT COUNT(*) FROM memories \
     WHERE deleted_at IS NULL AND status != 'deleted' \
       AND (? IS NULL OR entity_id = ?) \
       AND (? IS NULL OR kind = ?) \
       AND (? IS NULL OR source = ?) \
       AND (? IS NULL OR created_at < ?) \
       AND (? IS NULL OR batch_id = ?) \
       AND (? IS NULL OR scope = ?) \
       AND (? IS NULL OR project_id = ?)";

const FORGET_WHERE_UPDATE: &str =
    "UPDATE memories SET status = 'deleted', deleted_at = ?, updated_at = ? \
     WHERE deleted_at IS NULL AND status != 'deleted' \
       AND (? IS NULL OR entity_id = ?) \
       AND (? IS NULL OR kind = ?) \
       AND (? IS NULL OR source = ?) \
       AND (? IS NULL OR created_at < ?) \
       AND (? IS NULL OR batch_id = ?) \
       AND (? IS NULL OR scope = ?) \
       AND (? IS NULL OR project_id = ?)";

impl MemoryStore<'_> {
    /// 记"这条记忆被用过了"。
    ///
    /// 只标记**最近一条未标记**的召回日志，且 `WHERE used = 0`：同一轮里重复调用
    /// 不会把 `use_count` 刷高（权重受它影响，被刷高会自我强化）。
    pub async fn mark_used(&self, memory_id: &str) -> Result<bool, MemoryError> {
        let now = crate::clock::now_ms();
        let affected = sqlx::query(
            "UPDATE memory_recall_log SET used = 1 WHERE id = ( \
               SELECT id FROM memory_recall_log \
               WHERE memory_id = ? AND used = 0 \
               ORDER BY created_at DESC LIMIT 1)",
        )
        .bind(memory_id)
        .execute(self.pool)
        .await?
        .rows_affected();

        if affected == 0 {
            return Ok(false);
        }

        sqlx::query("UPDATE memories SET use_count = use_count + 1, last_used_at = ? WHERE id = ?")
            .bind(now)
            .bind(memory_id)
            .execute(self.pool)
            .await?;

        Ok(true)
    }

    /// 取一条记忆的正文（`touch_used` 判断"回答里有没有用到它"）。
    pub async fn content_of(&self, id: &str) -> Result<Option<String>, MemoryError> {
        let row: Option<(String,)> = sqlx::query_as(
            "SELECT content FROM memories WHERE id = ? AND deleted_at IS NULL AND status != 'deleted'",
        )
        .bind(id)
        .fetch_optional(self.pool)
        .await?;
        Ok(row.map(|(content,)| content))
    }
}

impl MemoryStore<'_> {
    /// 夜间衰减归档：长期没用、又不重要、也没被置顶的记忆退出日常对话。
    ///
    /// 只改 `status`，**不碰 `deleted_at`**：归档是"不再自动出现"，不是遗忘；
    /// 误归档可以从记忆页把状态改回 `active`，而删除是不可逆的。
    ///
    /// 条件四段缺一不可：`active`（候选与已归档的不重复处理）、`pinned = 0`
    /// （置顶是用户的显式意愿）、`importance <`（重要的事不该沉默消失）、
    /// `COALESCE(last_used_at, updated_at) <`（从没被用过就看创建/更新时间）。
    pub async fn decay_archive(
        &self,
        max_importance: f32,
        before: i64,
        limit: usize,
    ) -> Result<usize, MemoryError> {
        let now = crate::clock::now_ms();
        let affected = sqlx::query(
            "UPDATE memories SET status = 'archived', updated_at = ? \
             WHERE id IN ( \
               SELECT id FROM memories \
               WHERE status = 'active' AND pinned = 0 AND deleted_at IS NULL \
                 AND importance < ? \
                 AND COALESCE(last_used_at, updated_at) < ? \
               ORDER BY COALESCE(last_used_at, updated_at) ASC \
               LIMIT ?)",
        )
        .bind(now)
        .bind(f64::from(max_importance))
        .bind(before)
        .bind(limit as i64)
        .execute(self.pool)
        .await?
        .rows_affected();

        Ok(affected as usize)
    }
}

impl MemoryStore<'_> {
    /// 主观事实被新事实取代：旧记忆转 `archived`，但**行与证据都留着**。
    ///
    /// 为什么不是 `status='superseded'`：状态枚举是对外契约（客户端、OpenAPI 都按它
    /// 分支），为了一个内部语义新增枚举值会让所有读方都要处理未知状态。
    /// "被取代"用三列共同表达：`status=archived` + `valid_to` + `superseded_by`。
    ///
    /// 返回 `true` 表示确实转了一条（只有 `active` 才会被转，重复调用是幂等的）。
    pub async fn supersede(&self, old_id: &str, new_id: &str) -> Result<bool, MemoryError> {
        let now = crate::clock::now_ms();
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;

        let affected = sqlx::query(
            "UPDATE memories SET status = 'archived', superseded_by = ?, valid_to = ?, \
               updated_at = ? \
             WHERE id = ? AND deleted_at IS NULL AND status = 'active'",
        )
        .bind(new_id)
        .bind(now)
        .bind(now)
        .bind(old_id)
        .execute(&mut *tx)
        .await?
        .rows_affected();

        tx.commit().await?;
        Ok(affected > 0)
    }

    /// 抽取落库后调用：同主体 + 同谓词、内容不同的旧生效记忆全部转"被取代"。
    ///
    /// 一条 UPDATE 做完，避免"查出来再逐条更新"中间被别的写入插进来。
    /// `subject` 与 `predicate` 任一为空就直接返回 0——没有主体/谓词就没有
    /// "同一件事"的判据，宁可不取代，也不能按内容相似度乱杀。
    pub async fn supersede_conflicting(
        &self,
        subject: &str,
        predicate: &str,
        new_id: &str,
        new_content: &str,
    ) -> Result<usize, MemoryError> {
        if subject.trim().is_empty() || predicate.trim().is_empty() {
            return Ok(0);
        }

        let now = crate::clock::now_ms();
        let affected = sqlx::query(
            "UPDATE memories SET status = 'archived', superseded_by = ?, valid_to = ?, \
               updated_at = ? \
             WHERE status = 'active' AND deleted_at IS NULL AND id != ? \
               AND COALESCE(subject, '') = ? AND COALESCE(predicate, '') = ? \
               AND content != ?",
        )
        .bind(new_id)
        .bind(now)
        .bind(now)
        .bind(new_id)
        .bind(subject)
        .bind(predicate)
        .bind(new_content)
        .execute(self.pool)
        .await?
        .rows_affected();

        Ok(affected as usize)
    }
}

/// 归并分组的键：`(subject_norm, kind)` → `[(id, 归一化内容)]`。
type ConsolidateGroups =
    std::collections::BTreeMap<(Option<String>, String), Vec<(String, String)>>;

impl MemoryStore<'_> {
    /// 找一条"已经覆盖了这段内容"的生效记忆（同主体、同类型）。
    ///
    /// 抽取落库前用它做实时抑制：模型把同一个事实说得更简时，不该再写一行。
    pub async fn find_subsuming(
        &self,
        subject_norm: Option<&str>,
        kind: MemoryKind,
        content: &str,
    ) -> Result<Option<Memory>, MemoryError> {
        let target = tokenize::normalize_content(content);
        if target.chars().count() < tokenize::SUBSUME_MIN_CHARS {
            return Ok(None);
        }

        let rows: Vec<MemoryRow> = sqlx::query_as(
            "SELECT * FROM memories \
             WHERE subject_norm IS ? AND kind = ? AND deleted_at IS NULL \
               AND status = 'active' \
             ORDER BY length(content) DESC, updated_at DESC LIMIT 100",
        )
        .bind(subject_norm)
        .bind(kind.as_str())
        .fetch_all(self.pool)
        .await?;

        for row in rows {
            let existing = tokenize::normalize_content(&row.content);
            if tokenize::covers(&existing, &target) {
                return row.into_memory().map(Some);
            }
        }

        Ok(None)
    }

    /// 新断言覆盖了哪些旧记忆 → 归档它们（证据迁给新条）。
    ///
    /// 与"同谓词取代"互补：谓词写得不一样，但内容上新的更完整时，旧的应当退场。
    pub async fn supersede_subsumed(
        &self,
        subject_norm: Option<&str>,
        kind: MemoryKind,
        new_id: &str,
        new_content: &str,
    ) -> Result<usize, MemoryError> {
        let target = tokenize::normalize_content(new_content);
        if target.chars().count() < tokenize::SUBSUME_MIN_CHARS {
            return Ok(0);
        }

        let rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT id, content FROM memories \
             WHERE subject_norm IS ? AND kind = ? AND id != ? AND deleted_at IS NULL \
               AND status = 'active' \
             LIMIT 100",
        )
        .bind(subject_norm)
        .bind(kind.as_str())
        .bind(new_id)
        .fetch_all(self.pool)
        .await?;

        let mut merged = 0usize;
        for (old_id, content) in rows {
            let old = tokenize::normalize_content(&content);
            if tokenize::covers(&target, &old) {
                self.merge_into(&old_id, new_id).await?;
                merged += 1;
            }
        }

        Ok(merged)
    }

    /// 夜间归并：同主体 + 同类型，短内容被长内容覆盖的归档。
    ///
    /// 只处理 `profile` / `preference`：`event` 是流水，本来就该多条并存，
    /// 对它做包含归并会把时间线抹平。
    pub async fn consolidate_subsumed(&self, limit: usize) -> Result<usize, MemoryError> {
        let rows: Vec<(String, Option<String>, String, String, i64)> = sqlx::query_as(
            "SELECT id, subject_norm, kind, content, updated_at FROM memories \
             WHERE status = 'active' AND deleted_at IS NULL \
               AND kind IN ('profile', 'preference') \
             ORDER BY length(content) DESC, updated_at DESC LIMIT 500",
        )
        .fetch_all(self.pool)
        .await?;

        // 分块：只有同主体同类型才可能互为"详略"。
        let mut groups = ConsolidateGroups::new();
        for (id, subject_norm, kind, content, _) in rows {
            groups
                .entry((subject_norm, kind))
                .or_default()
                .push((id, tokenize::normalize_content(&content)));
        }

        let mut merged = 0usize;
        'groups: for (_, items) in groups {
            for (index, (keeper_id, keeper)) in items.iter().enumerate() {
                // 长的排前面，所以只可能是后面的被前面的覆盖。
                for (candidate_id, candidate) in items.iter().skip(index + 1) {
                    if !tokenize::covers(keeper, candidate) {
                        continue;
                    }
                    self.merge_into(candidate_id, keeper_id).await?;
                    merged += 1;
                    if merged >= limit {
                        break 'groups;
                    }
                }
            }
        }

        Ok(merged)
    }

    /// 把 `from` 并进 `into`：证据迁移、旧条转 `archived`、留 `superseded_by`。
    ///
    /// 证据是**迁移**不是复制：一条证据只该属于一条记忆，否则详情页会出现
    /// 同一段原话挂在两条记录上。
    async fn merge_into(&self, from: &str, into: &str) -> Result<(), MemoryError> {
        let now = crate::clock::now_ms();
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;

        sqlx::query("UPDATE memory_evidence SET memory_id = ? WHERE memory_id = ?")
            .bind(into)
            .bind(from)
            .execute(&mut *tx)
            .await?;

        sqlx::query(
            "UPDATE memories SET status = 'archived', superseded_by = ?, valid_to = ?, \
               updated_at = ? \
             WHERE id = ? AND deleted_at IS NULL AND status = 'active'",
        )
        .bind(into)
        .bind(now)
        .bind(now)
        .bind(from)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn importance_grows_with_evidence_pinned_and_use() {
        let base = importance_for(MemoryKind::Event, 1, false, 0);
        assert!((base - 0.3).abs() < f32::EPSILON);

        let more_evidence = importance_for(MemoryKind::Event, 3, false, 0);
        assert!(more_evidence > base);

        let pinned = importance_for(MemoryKind::Event, 1, true, 0);
        assert!((pinned - 0.55).abs() < 0.001);

        // 使用次数的加成封顶在 4 次，避免长期记忆把权重吃到 1.0。
        let capped = importance_for(MemoryKind::Event, 1, false, 100);
        assert!((capped - 0.5).abs() < 0.001);
    }

    #[test]
    fn importance_never_exceeds_one() {
        assert_eq!(
            importance_for(MemoryKind::Preference, 50, true, 10),
            1.0,
            "重要度必须 clamp 到 1.0"
        );
    }
}
