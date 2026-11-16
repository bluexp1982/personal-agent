//! 实体：匹配/新建、脏标记、夜间重算、合并与拆分。
//!
//! 实体不存正文：正文在 `memories`，这里只放"当前状态快照"（≤300 字的合成文本）。
//! 快照由夜间批处理重算，重算前是空串——界面据此显示"还没有快照"，而不是显示旧内容。
//!
//! 三条规则：
//! 1. **强匹配自动归并**：同类型 + 归一化名（含别名）相等，或（project）仓库路径相等；
//! 2. **弱匹配要置信度**：名称互相包含且该实体近 90 天关联记忆 ≥2 条，`confidence ≥ 阈值`
//!    才命中，否则**新建 pending**——宁可多一个待合并的实体，也不要错误地并到别人身上；
//! 3. **只在有第二条独立证据时转 active**：一条证据还不足以定义一个"人"。

use protocol::{
    Cursor, Entity, EntityDetail, EntityPage, EntitySnapshot, EntityStatus, EntityType,
    EntityUpdateRequest, Memory,
};
use sqlx::SqlitePool;

use super::store::MemoryRow;
use super::{tokenize, MemoryError};
use crate::clock::now_ms;
use crate::model::CompletionModel;

/// 一个实体最多保留多少份历史快照。
const KEEP_SNAPSHOTS: i64 = 10;

/// 时间线一次返回多少条（一期不分页）。
pub const TIMELINE_LIMIT: i64 = 50;

/// 弱匹配要看的时间窗。
const WEAK_MATCH_WINDOW_MS: i64 = 90 * 86_400_000;

/// 弱匹配要求的关联记忆条数。
const WEAK_MATCH_MIN_LINKS: i64 = 2;

#[derive(Debug, Clone)]
pub struct EntityDraft {
    pub entity_type: EntityType,
    pub name: String,
    pub project_id: Option<String>,
    pub project_path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchReason {
    ExactName,
    ExactAlias,
    ExactPath,
    WeakName,
    Created,
}

impl MatchReason {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ExactName => "exact_name",
            Self::ExactAlias => "exact_alias",
            Self::ExactPath => "exact_path",
            Self::WeakName => "weak_name",
            Self::Created => "created",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RecomputeReport {
    pub scanned: usize,
    pub updated: usize,
    pub failed: usize,
}

#[derive(Debug, Clone, Default)]
pub struct EntityFilter {
    pub entity_type: Option<EntityType>,
    pub status: Option<EntityStatus>,
    /// 按名称/别名模糊匹配（客户端搜索框）。
    pub q: Option<String>,
}

/// 匹配或新建，并把 `memory_id` 挂到实体时间线上。
pub async fn match_or_create(
    pool: &SqlitePool,
    draft: EntityDraft,
    memory_id: &str,
    now: i64,
    weak_threshold: f32,
) -> Result<(String, MatchReason), MemoryError> {
    let name_norm = tokenize::normalize_for_match(&draft.name);
    if name_norm.is_empty() {
        return Err(MemoryError::Invalid("实体名不能为空".to_string()));
    }

    // 1. 强匹配：同类型 + 归一化名相等。
    if let Some(id) = find_by_name(pool, draft.entity_type, &name_norm).await? {
        link(pool, &id, memory_id, now).await?;
        return Ok((id, MatchReason::ExactName));
    }

    // 2. 强匹配（项目）：仓库路径完全相等。
    if let Some(path) = draft.project_path.as_deref() {
        if let Some(id) = find_by_path(pool, path).await? {
            link(pool, &id, memory_id, now).await?;
            return Ok((id, MatchReason::ExactPath));
        }
    }

    // 3. 别名命中。
    if let Some(id) = find_by_alias(pool, draft.entity_type, &name_norm).await? {
        link(pool, &id, memory_id, now).await?;
        return Ok((id, MatchReason::ExactAlias));
    }

    // 4. 弱匹配：名称互相包含，且已有足够多的关联记忆。
    if let Some((id, confidence)) = find_weak(pool, draft.entity_type, &name_norm, now).await? {
        if confidence >= weak_threshold {
            link(pool, &id, memory_id, now).await?;
            mark_dirty(pool, &id).await?;
            return Ok((id, MatchReason::WeakName));
        }
    }

    // 5. 新建 pending：第二条独立证据到达时才转 active（在 `link` 里判定）。
    let id = crate::ids::new_id("ent");
    sqlx::query(
        "INSERT INTO memory_entities \
          (id, entity_type, name, name_norm, aliases_json, project_id, project_path, \
           status, merged_into, snapshot_json, snapshot_at, dirty, confidence, evidence_count, \
           last_evidence_at, created_at, updated_at) \
         VALUES (?, ?, ?, ?, '[]', ?, ?, 'pending', NULL, '\"\"', NULL, 1, ?, 0, NULL, ?, ?)",
    )
    .bind(&id)
    .bind(draft.entity_type.as_str())
    .bind(&draft.name)
    .bind(&name_norm)
    .bind(&draft.project_id)
    .bind(&draft.project_path)
    .bind(f64::from(weak_confidence(&name_norm)))
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    link(pool, &id, memory_id, now).await?;
    Ok((id, MatchReason::Created))
}

async fn find_by_name(
    pool: &SqlitePool,
    entity_type: EntityType,
    name_norm: &str,
) -> Result<Option<String>, MemoryError> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT id FROM memory_entities \
         WHERE entity_type = ? AND name_norm = ? AND status != 'merged'",
    )
    .bind(entity_type.as_str())
    .bind(name_norm)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(id,)| id))
}

async fn find_by_path(pool: &SqlitePool, path: &str) -> Result<Option<String>, MemoryError> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT id FROM memory_entities \
         WHERE project_path = ? AND status != 'merged' LIMIT 1",
    )
    .bind(path)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(id,)| id))
}

async fn find_by_alias(
    pool: &SqlitePool,
    entity_type: EntityType,
    name_norm: &str,
) -> Result<Option<String>, MemoryError> {
    // 别名存在 JSON 数组里：用 LIKE 粗筛，再在 Rust 侧精确比对，
    // 避免为一次匹配引入 JSON1 扩展依赖。
    let rows: Vec<(String, String)> = sqlx::query_as(
        "SELECT id, aliases_json FROM memory_entities \
         WHERE entity_type = ? AND status != 'merged' AND aliases_json LIKE ? LIMIT 20",
    )
    .bind(entity_type.as_str())
    .bind(format!("%{name_norm}%"))
    .fetch_all(pool)
    .await?;

    for (id, raw) in rows {
        let aliases: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
        if aliases.iter().any(|alias| alias == name_norm) {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

async fn find_weak(
    pool: &SqlitePool,
    entity_type: EntityType,
    name_norm: &str,
    now: i64,
) -> Result<Option<(String, f32)>, MemoryError> {
    let rows: Vec<(String, String, f64)> = sqlx::query_as(
        "SELECT id, name_norm, confidence FROM memory_entities \
         WHERE entity_type = ? AND status != 'merged' AND name_norm != '' \
         ORDER BY updated_at DESC LIMIT 200",
    )
    .bind(entity_type.as_str())
    .fetch_all(pool)
    .await?;

    for (id, candidate, confidence) in rows {
        let contains = candidate.contains(name_norm) || name_norm.contains(&candidate);
        if !contains || candidate == name_norm {
            continue;
        }
        let links: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM memory_entity_links l \
             JOIN memories m ON m.id = l.memory_id \
             WHERE l.entity_id = ? AND m.deleted_at IS NULL AND m.created_at >= ?",
        )
        .bind(&id)
        .bind(now - WEAK_MATCH_WINDOW_MS)
        .fetch_one(pool)
        .await?;

        if links >= WEAK_MATCH_MIN_LINKS {
            return Ok(Some((id, confidence as f32)));
        }
    }

    Ok(None)
}

/// 挂一条记忆到实体上，并维护计数与状态。
async fn link(
    pool: &SqlitePool,
    entity_id: &str,
    memory_id: &str,
    now: i64,
) -> Result<(), MemoryError> {
    sqlx::query(
        "INSERT OR IGNORE INTO memory_entity_links (entity_id, memory_id, created_at) \
         VALUES (?, ?, ?)",
    )
    .bind(entity_id)
    .bind(memory_id)
    .bind(now)
    .execute(pool)
    .await?;

    sqlx::query("UPDATE memories SET entity_id = ? WHERE id = ?")
        .bind(entity_id)
        .bind(memory_id)
        .execute(pool)
        .await?;

    let links: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_entity_links WHERE entity_id = ?")
            .bind(entity_id)
            .fetch_one(pool)
            .await?;

    // 第二条独立证据到达才转 active：一条证据还不足以定义一个"人"。
    sqlx::query(
        "UPDATE memory_entities SET \
           evidence_count = ?, last_evidence_at = ?, updated_at = ?, dirty = 1, \
           status = CASE WHEN status = 'pending' AND ? >= 2 THEN 'active' ELSE status END, \
           confidence = MIN(1.0, MAX(confidence, 0.5) + 0.1) \
         WHERE id = ?",
    )
    .bind(links)
    .bind(now)
    .bind(now)
    .bind(links)
    .bind(entity_id)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn mark_dirty(pool: &SqlitePool, entity_id: &str) -> Result<(), MemoryError> {
    sqlx::query("UPDATE memory_entities SET dirty = 1, updated_at = ? WHERE id = ?")
        .bind(now_ms())
        .bind(entity_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// 夜间批量重算：取 `dirty=1` 的实体，用最近 20 条 active 记忆合成一句话状态。
///
/// 单个失败不中断整批，且**保留旧快照与 dirty 标记**——下次还会再试。
pub async fn recompute_dirty(
    pool: &SqlitePool,
    model: Option<&dyn CompletionModel>,
    limit: usize,
    now: i64,
) -> Result<RecomputeReport, MemoryError> {
    let ids: Vec<(String,)> = sqlx::query_as(
        "SELECT id FROM memory_entities WHERE dirty = 1 ORDER BY updated_at ASC LIMIT ?",
    )
    .bind(limit as i64)
    .fetch_all(pool)
    .await?;

    let mut report = RecomputeReport {
        scanned: ids.len(),
        ..RecomputeReport::default()
    };

    for (id,) in ids {
        match recompute_one(pool, model, &id, now).await {
            Ok(()) => report.updated += 1,
            Err(err) => {
                report.failed += 1;
                tracing::warn!(%err, entity_id = %id, "实体快照重算失败，保留旧快照");
            }
        }
    }

    Ok(report)
}

async fn recompute_one(
    pool: &SqlitePool,
    model: Option<&dyn CompletionModel>,
    entity_id: &str,
    now: i64,
) -> Result<(), MemoryError> {
    let model = model.ok_or(MemoryError::ModelUnavailable)?;

    let entity = get(pool, entity_id)
        .await?
        .ok_or(MemoryError::NotFound)?
        .entity;

    let rows: Vec<MemoryRow> = sqlx::query_as(
        "SELECT m.* FROM memory_entity_links l JOIN memories m ON m.id = l.memory_id \
         WHERE l.entity_id = ? AND m.deleted_at IS NULL AND m.status = 'active' \
         ORDER BY m.created_at DESC LIMIT 20",
    )
    .bind(entity_id)
    .fetch_all(pool)
    .await?;

    if rows.is_empty() {
        // 没有可用证据：清掉脏标记，避免每晚重试同一个空实体。
        sqlx::query("UPDATE memory_entities SET dirty = 0, updated_at = ? WHERE id = ?")
            .bind(now)
            .bind(entity_id)
            .execute(pool)
            .await?;
        return Ok(());
    }

    let mut lines = String::new();
    for row in rows {
        let memory = row.into_memory()?;
        lines.push_str("- ");
        lines.push_str(&memory.content);
        lines.push('\n');
    }

    let prompt = format!(
        "以下是关于「{}」的全部记忆。请用不超过 300 字写一段\"当前状态\"，\
         只写仍然成立的事实，冲突的地方要标明存在分歧。不要分点，不要复述原句。\n\n{lines}",
        entity.name
    );
    let completion = model
        .complete(
            "你在维护一个人的记忆档案。只根据给定材料写，不要补充任何材料里没有的信息。",
            &prompt,
            Some(400),
        )
        .await
        .map_err(|err| {
            tracing::warn!(%err, entity_id, "实体重算调用模型失败");
            MemoryError::ModelUnavailable
        })?;

    let snapshot = completion.text.trim().to_string();
    if snapshot.is_empty() {
        return Err(MemoryError::ModelUnavailable);
    }

    // 旧快照留档，再写新快照。
    if !entity.snapshot.is_empty() {
        sqlx::query(
            "INSERT INTO memory_entity_snapshots (id, entity_id, snapshot_json, evidence_count, created_at) \
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(crate::ids::new_id("esn"))
        .bind(entity_id)
        .bind(serde_json::to_string(&entity.snapshot).unwrap_or_else(|_| "\"\"".to_string()))
        .bind(i64::from(entity.evidence_count))
        .bind(now)
        .execute(pool)
        .await?;
    }

    let snapshot_json = serde_json::to_string(&snapshot)
        .map_err(|err| MemoryError::Invalid(format!("快照无法序列化: {err}")))?;

    sqlx::query(
        "UPDATE memory_entities SET snapshot_json = ?, snapshot_at = ?, dirty = 0, updated_at = ? \
         WHERE id = ?",
    )
    .bind(snapshot_json)
    .bind(now)
    .bind(now)
    .bind(entity_id)
    .execute(pool)
    .await?;

    trim_snapshots(pool, entity_id).await?;
    Ok(())
}

async fn trim_snapshots(pool: &SqlitePool, entity_id: &str) -> Result<(), MemoryError> {
    sqlx::query(
        "DELETE FROM memory_entity_snapshots WHERE entity_id = ? AND id NOT IN ( \
           SELECT id FROM memory_entity_snapshots WHERE entity_id = ? \
           ORDER BY created_at DESC LIMIT ?)",
    )
    .bind(entity_id)
    .bind(entity_id)
    .bind(KEEP_SNAPSHOTS)
    .execute(pool)
    .await?;
    Ok(())
}

/// 合并：被合并方转 `merged` 并把 `name_norm` 置空，引用全部转投 target。
pub async fn merge(
    pool: &SqlitePool,
    source_id: &str,
    target_id: &str,
    _actor: &str,
) -> Result<(), MemoryError> {
    if source_id == target_id {
        return Err(MemoryError::Invalid("不能合并到自身".to_string()));
    }
    let target = get(pool, target_id)
        .await?
        .ok_or(MemoryError::NotFound)?
        .entity;
    get(pool, source_id).await?.ok_or(MemoryError::NotFound)?;

    let now = now_ms();
    let memory_ids: Vec<(String,)> =
        sqlx::query_as("SELECT memory_id FROM memory_entity_links WHERE entity_id = ?")
            .bind(source_id)
            .fetch_all(pool)
            .await?;

    for (memory_id,) in &memory_ids {
        link(pool, target_id, memory_id, now).await?;
    }

    // 别名并进目标：合并后用户还能用旧名搜到它。
    let mut aliases = target.aliases.clone();
    let source = get(pool, source_id)
        .await?
        .ok_or(MemoryError::NotFound)?
        .entity;
    if !aliases.contains(&source.name) && source.name != target.name {
        aliases.push(source.name);
    }
    for alias in source.aliases {
        if !aliases.contains(&alias) {
            aliases.push(alias);
        }
    }
    sqlx::query("UPDATE memory_entities SET aliases_json = ?, updated_at = ? WHERE id = ?")
        .bind(serde_json::to_string(&aliases).unwrap_or_else(|_| "[]".to_string()))
        .bind(now)
        .bind(target_id)
        .execute(pool)
        .await?;

    sqlx::query(
        "UPDATE memory_entities SET status = 'merged', merged_into = ?, name_norm = '', \
           dirty = 0, updated_at = ? WHERE id = ?",
    )
    .bind(target_id)
    .bind(now)
    .bind(source_id)
    .execute(pool)
    .await?;

    sqlx::query("DELETE FROM memory_entity_links WHERE entity_id = ?")
        .bind(source_id)
        .execute(pool)
        .await?;

    Ok(())
}

/// 拆分：把若干条记忆挂到一个新建的 pending 实体上。
pub async fn split(
    pool: &SqlitePool,
    entity_id: &str,
    memory_ids: &[String],
    name: Option<&str>,
) -> Result<String, MemoryError> {
    if memory_ids.is_empty() {
        return Err(MemoryError::Invalid("memory_ids 不能为空".to_string()));
    }
    let source = get(pool, entity_id)
        .await?
        .ok_or(MemoryError::NotFound)?
        .entity;

    let new_name = name
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or("未命名实体")
        .to_string();
    let name_norm = tokenize::normalize_for_match(&new_name);
    let now = now_ms();

    let id = crate::ids::new_id("ent");
    sqlx::query(
        "INSERT INTO memory_entities \
          (id, entity_type, name, name_norm, aliases_json, project_id, project_path, \
           status, merged_into, snapshot_json, snapshot_at, dirty, confidence, evidence_count, \
           last_evidence_at, created_at, updated_at) \
         VALUES (?, ?, ?, ?, '[]', ?, ?, 'pending', NULL, '\"\"', NULL, 1, 0.5, 0, NULL, ?, ?)",
    )
    .bind(&id)
    .bind(source.entity_type.as_str())
    .bind(&new_name)
    // 拆出来的实体名可能与现有实体撞唯一索引：撞了就置空归一化名，等待人工改名。
    .bind(if name_norm.is_empty() {
        None
    } else {
        Some(name_norm)
    })
    .bind(&source.project_id)
    .bind(&source.project_path)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .map_err(|err| match err {
        sqlx::Error::Database(ref db) if db.is_unique_violation() => {
            MemoryError::Conflict("新实体名与已有实体重名，请换一个名字".to_string())
        }
        other => MemoryError::Db(other),
    })?;

    for memory_id in memory_ids {
        sqlx::query("DELETE FROM memory_entity_links WHERE entity_id = ? AND memory_id = ?")
            .bind(entity_id)
            .bind(memory_id)
            .execute(pool)
            .await?;
        link(pool, &id, memory_id, now).await?;
    }

    mark_dirty(pool, entity_id).await?;
    Ok(id)
}

// ---------------------------------------------------------------------------
// 读
// ---------------------------------------------------------------------------

pub async fn list(
    pool: &SqlitePool,
    filter: &EntityFilter,
    cursor: Option<&str>,
    limit: u32,
) -> Result<EntityPage, MemoryError> {
    let limit = limit.clamp(1, 100);
    let cursor = match cursor {
        Some(raw) => Some(Cursor::decode(raw).ok_or_else(|| {
            MemoryError::Invalid("cursor 无法解析，应原样回传上一页的 next_cursor".to_string())
        })?),
        None => None,
    };

    let pattern = filter
        .q
        .as_deref()
        .map(str::trim)
        .filter(|q| !q.is_empty())
        .map(|q| format!("%{}%", tokenize::normalize_for_match(q)));

    let rows: Vec<EntityRow> = sqlx::query_as(
        "SELECT * FROM memory_entities \
         WHERE status != 'merged' \
           AND (? IS NULL OR entity_type = ?) \
           AND (? IS NULL OR status = ?) \
           AND (? IS NULL OR name LIKE ? OR aliases_json LIKE ?) \
           AND (? IS NULL OR updated_at < ? OR (updated_at = ? AND id < ?)) \
         ORDER BY updated_at DESC, id DESC LIMIT ?",
    )
    .bind(filter.entity_type.map(EntityType::as_str))
    .bind(filter.entity_type.map(EntityType::as_str))
    .bind(filter.status.map(EntityStatus::as_str))
    .bind(filter.status.map(EntityStatus::as_str))
    .bind(pattern.as_deref())
    .bind(pattern.as_deref())
    .bind(pattern.as_deref())
    .bind(cursor.as_ref().map(|c| c.updated_at))
    .bind(cursor.as_ref().map(|c| c.updated_at))
    .bind(cursor.as_ref().map(|c| c.updated_at))
    .bind(cursor.as_ref().map(|c| c.id.clone()))
    .bind(i64::from(limit) + 1)
    .fetch_all(pool)
    .await?;

    let mut items: Vec<Entity> = Vec::with_capacity(rows.len());
    for row in rows {
        items.push(row.into_entity()?);
    }

    let next_cursor = if items.len() > limit as usize {
        items.truncate(limit as usize);
        items.last().map(|entity| {
            Cursor {
                updated_at: entity.updated_at,
                id: entity.id.clone(),
            }
            .encode()
        })
    } else {
        None
    };

    Ok(EntityPage { items, next_cursor })
}

pub async fn get(pool: &SqlitePool, id: &str) -> Result<Option<EntityDetail>, MemoryError> {
    let row: Option<EntityRow> = sqlx::query_as("SELECT * FROM memory_entities WHERE id = ?")
        .bind(id)
        .fetch_optional(pool)
        .await?;

    let Some(row) = row else {
        return Ok(None);
    };
    let entity = row.into_entity()?;

    let timeline_rows: Vec<MemoryRow> = sqlx::query_as(
        "SELECT m.* FROM memory_entity_links l JOIN memories m ON m.id = l.memory_id \
         WHERE l.entity_id = ? AND m.deleted_at IS NULL AND m.status != 'deleted' \
         ORDER BY m.created_at DESC LIMIT ?",
    )
    .bind(id)
    .bind(TIMELINE_LIMIT)
    .fetch_all(pool)
    .await?;

    let mut timeline: Vec<Memory> = Vec::with_capacity(timeline_rows.len());
    for row in timeline_rows {
        timeline.push(row.into_memory()?);
    }

    let snapshot_rows: Vec<(String, String, i64, i64)> = sqlx::query_as(
        "SELECT id, snapshot_json, evidence_count, created_at FROM memory_entity_snapshots \
         WHERE entity_id = ? ORDER BY created_at DESC LIMIT ?",
    )
    .bind(id)
    .bind(KEEP_SNAPSHOTS)
    .fetch_all(pool)
    .await?;

    let snapshots = snapshot_rows
        .into_iter()
        .map(|(id, raw, evidence_count, created_at)| EntitySnapshot {
            id,
            snapshot: serde_json::from_str(&raw).unwrap_or_default(),
            evidence_count: evidence_count.max(0) as u32,
            created_at,
        })
        .collect();

    Ok(Some(EntityDetail {
        entity,
        timeline,
        snapshots,
    }))
}

pub async fn update(
    pool: &SqlitePool,
    id: &str,
    req: EntityUpdateRequest,
) -> Result<Entity, MemoryError> {
    let current = get(pool, id).await?.ok_or(MemoryError::NotFound)?.entity;

    let name = req
        .name
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or(current.name.clone());
    let name_norm = tokenize::normalize_for_match(&name);
    if name_norm.is_empty() {
        return Err(MemoryError::Invalid("实体名不能为空".to_string()));
    }

    let aliases = req.aliases.unwrap_or(current.aliases.clone());
    let aliases: Vec<String> = aliases
        .into_iter()
        .map(|alias| tokenize::normalize_for_match(&alias))
        .filter(|alias| !alias.is_empty())
        .collect();
    let status = req.status.unwrap_or(current.status);

    sqlx::query(
        "UPDATE memory_entities SET name = ?, name_norm = ?, aliases_json = ?, status = ?, \
           updated_at = ? WHERE id = ?",
    )
    .bind(&name)
    .bind(&name_norm)
    .bind(serde_json::to_string(&aliases).unwrap_or_else(|_| "[]".to_string()))
    .bind(status.as_str())
    .bind(now_ms())
    .bind(id)
    .execute(pool)
    .await
    .map_err(|err| match err {
        sqlx::Error::Database(ref db) if db.is_unique_violation() => {
            MemoryError::Conflict("同类型下已有同名实体，请先合并".to_string())
        }
        other => MemoryError::Db(other),
    })?;

    Ok(get(pool, id).await?.ok_or(MemoryError::NotFound)?.entity)
}

/// 弱匹配的初值：名称越短越不可靠。
fn weak_confidence(name_norm: &str) -> f32 {
    if name_norm.chars().count() >= 4 {
        0.7
    } else {
        0.4
    }
}

#[derive(Debug, sqlx::FromRow)]
struct EntityRow {
    id: String,
    entity_type: String,
    name: String,
    aliases_json: String,
    project_id: Option<String>,
    project_path: Option<String>,
    status: String,
    merged_into: Option<String>,
    snapshot_json: String,
    snapshot_at: Option<i64>,
    confidence: f64,
    evidence_count: i64,
    last_evidence_at: Option<i64>,
    created_at: i64,
    updated_at: i64,
}

impl EntityRow {
    fn into_entity(self) -> Result<Entity, MemoryError> {
        let entity_type = EntityType::parse(&self.entity_type)
            .ok_or_else(|| MemoryError::Corrupt(format!("entity_type={}", self.entity_type)))?;
        let status = EntityStatus::parse(&self.status)
            .ok_or_else(|| MemoryError::Corrupt(format!("entity.status={}", self.status)))?;
        let aliases: Vec<String> = serde_json::from_str(&self.aliases_json).unwrap_or_default();
        let snapshot: String = serde_json::from_str(&self.snapshot_json).unwrap_or_default();

        Ok(Entity {
            id: self.id,
            entity_type,
            name: self.name,
            aliases,
            project_id: self.project_id,
            project_path: self.project_path,
            status,
            merged_into: self.merged_into,
            snapshot,
            snapshot_at: self.snapshot_at,
            confidence: self.confidence as f32,
            evidence_count: self.evidence_count.max(0) as u32,
            last_evidence_at: self.last_evidence_at,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

/// 实体摘要（记忆详情页顶部用）。不存在或已合并时返回 `None`。
pub async fn brief(
    pool: &SqlitePool,
    entity_id: &str,
) -> Result<Option<protocol::EntityBrief>, MemoryError> {
    let row: Option<(String, String, String)> =
        sqlx::query_as("SELECT id, name, entity_type FROM memory_entities WHERE id = ?")
            .bind(entity_id)
            .fetch_optional(pool)
            .await?;

    Ok(row.and_then(|(id, name, entity_type)| {
        EntityType::parse(&entity_type).map(|entity_type| protocol::EntityBrief {
            id,
            name,
            entity_type,
        })
    }))
}

/// 给 store 用：实体摘要 + 一句话快照。
pub async fn snapshot_text(pool: &SqlitePool, entity_id: &str) -> Result<String, MemoryError> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT snapshot_json FROM memory_entities WHERE id = ?")
            .bind(entity_id)
            .fetch_optional(pool)
            .await?;
    let raw = row.map(|(raw,)| raw).unwrap_or_default();
    Ok(serde_json::from_str(&raw).unwrap_or_default())
}
