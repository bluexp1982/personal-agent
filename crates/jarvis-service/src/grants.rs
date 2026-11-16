//! 执行授权（grants）：审批的**缓存层**。
//!
//! 只跳过"询问"，不改变"判定"：
//! - 现在问过、用户勾了"记住"→ 下次同类调用不再建卡，直接放行；
//! - 风险档是 `irreversible_write`、或不是工具级审批时，**永不建 grant**。
//!
//! 三条边界（缺一条就会变成"用户没同意也放行"）：
//! 1. 作用域 id 一律从库里查，不接受客户端直传；
//! 2. `expires_at` 只由作用域决定，客户端改不了；
//! 3. 命中 grant 也要写审计——用户要能回答"它为什么没问我"。

use protocol::{Cursor, Grant, GrantPage, GrantScope, RiskLevel};
use sqlx::SqlitePool;

use crate::clock::now_ms;

#[derive(Debug, thiserror::Error)]
pub enum GrantError {
    #[error("授权不存在")]
    NotFound,
    #[error("状态冲突: {0}")]
    Conflict(String),
    #[error("参数不合法: {0}")]
    Invalid(String),
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
}

/// 建授权的输入。`approval_id` 必须有：凭空出现的 grant 无法追责。
#[derive(Debug, Clone)]
pub struct NewGrant<'a> {
    pub tool: &'a str,
    pub risk: RiskLevel,
    pub scope: GrantScope,
    pub approval_id: &'a str,
    pub device_id: Option<&'a str>,
}

/// 作用域解析结果。
#[derive(Debug, Clone)]
pub struct ResolvedScope {
    pub scope_id: String,
    pub expires_at: i64,
}

/// 把 `task/session/project` 解析成具体的 `scope_id` 与过期时刻。
///
/// 全部从库里查：客户端直传的 id 一律不认，否则一个请求就能把授权挂到别人身上。
pub async fn resolve_scope(
    pool: &SqlitePool,
    task_id: &str,
    scope: GrantScope,
    task_ttl_ms: i64,
    now: i64,
) -> Result<ResolvedScope, GrantError> {
    match scope {
        GrantScope::Task => Ok(ResolvedScope {
            scope_id: task_id.to_string(),
            expires_at: now + task_ttl_ms.max(60_000),
        }),
        GrantScope::Session => {
            let row: Option<(String,)> =
                sqlx::query_as("SELECT conversation_id FROM tasks WHERE id = ?")
                    .bind(task_id)
                    .fetch_optional(pool)
                    .await?;
            let scope_id = row.ok_or(GrantError::NotFound)?.0;
            Ok(ResolvedScope {
                scope_id,
                expires_at: now + GrantScope::Session.default_ttl_ms(),
            })
        }
        GrantScope::Project => {
            let row: Option<(Option<String>,)> = sqlx::query_as(
                "SELECT c.project_id FROM tasks t JOIN conversations c ON c.id = t.conversation_id \
                 WHERE t.id = ?",
            )
            .bind(task_id)
            .fetch_optional(pool)
            .await?;
            let scope_id = row.and_then(|(project_id,)| project_id).ok_or_else(|| {
                // 项目级授权的 scope_id 就是项目 id，无归属会话没有这个粒度。
                // 拒绝时给出可用的替代档，别让人卡在"记住"按钮上反复重试。
                GrantError::Invalid(
                    "无归属会话的任务不能建项目级授权：请改选「本次任务」或「本会话」".to_string(),
                )
            })?;
            Ok(ResolvedScope {
                scope_id,
                expires_at: now + GrantScope::Project.default_ttl_ms(),
            })
        }
    }
}

/// 建授权。已存在同一 (tool, risk, scope, scope_id) 的活授权时刷新过期时间而不是报错：
/// 重复勾选"记住"是正常操作，不该失败。
pub async fn create_resolved(
    pool: &SqlitePool,
    new: NewGrant<'_>,
    resolved: ResolvedScope,
    now: i64,
) -> Result<Grant, GrantError> {
    if new.risk == RiskLevel::IrreversibleWrite {
        return Err(GrantError::Conflict(
            "不可逆动作不提供「记住」：每次都必须单独确认".to_string(),
        ));
    }

    sqlx::query(
        "INSERT INTO memory_grants \
          (id, tool, risk, scope, scope_id, approved_by, device_id, created_at, expires_at, \
           revoked_at, last_hit_at, hit_count) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 0) \
         ON CONFLICT (tool, risk, scope, scope_id) WHERE revoked_at IS NULL \
         DO UPDATE SET expires_at = excluded.expires_at, approved_by = excluded.approved_by, \
           created_at = excluded.created_at, device_id = excluded.device_id",
    )
    .bind(crate::ids::new_id("grt"))
    .bind(new.tool)
    .bind(new.risk.as_str())
    .bind(new.scope.as_str())
    .bind(&resolved.scope_id)
    .bind(new.approval_id)
    .bind(new.device_id)
    .bind(now)
    .bind(resolved.expires_at)
    .execute(pool)
    .await?;

    let row: GrantRow = sqlx::query_as(
        "SELECT * FROM memory_grants \
         WHERE tool = ? AND risk = ? AND scope = ? AND scope_id = ? AND revoked_at IS NULL",
    )
    .bind(new.tool)
    .bind(new.risk.as_str())
    .bind(new.scope.as_str())
    .bind(&resolved.scope_id)
    .fetch_one(pool)
    .await?;

    row.into_grant()
}

/// 查一次命中：任务级、会话级、项目级三种作用域一起看。
///
/// **必须在"查 pending 审批"之前调用**：先查 pending 会让一个更早的待决卡
/// 把本次命中当成"重复建卡"驳回，等于授权在最需要它的时候失效。
pub async fn find_hit(
    pool: &SqlitePool,
    task_id: &str,
    tool: &str,
    risk: RiskLevel,
    now: i64,
) -> Result<Option<Grant>, GrantError> {
    let row: Option<(String, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT t.id, c.id, c.project_id FROM tasks t \
         LEFT JOIN conversations c ON c.id = t.conversation_id \
         WHERE t.id = ?",
    )
    .bind(task_id)
    .fetch_optional(pool)
    .await?;

    let Some((_, conversation_id, project_id)) = row else {
        return Ok(None);
    };

    let hit: Option<GrantRow> = sqlx::query_as(
        "SELECT * FROM memory_grants \
         WHERE tool = ? AND risk = ? AND revoked_at IS NULL AND expires_at > ? \
           AND ((scope = 'task' AND scope_id = ?) \
             OR (scope = 'session' AND scope_id = ?) \
             OR (scope = 'project' AND scope_id = ?)) \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(tool)
    .bind(risk.as_str())
    .bind(now)
    .bind(task_id)
    .bind(conversation_id.as_deref().unwrap_or(""))
    .bind(project_id.as_deref().unwrap_or(""))
    .fetch_optional(pool)
    .await?;

    let Some(row) = hit else {
        return Ok(None);
    };

    sqlx::query("UPDATE memory_grants SET hit_count = hit_count + 1, last_hit_at = ? WHERE id = ?")
        .bind(now)
        .bind(&row.id)
        .execute(pool)
        .await?;

    let mut grant = row.into_grant()?;
    grant.hit_count += 1;
    grant.last_hit_at = Some(now);
    Ok(Some(grant))
}

pub async fn revoke(pool: &SqlitePool, id: &str, now: i64) -> Result<(), GrantError> {
    let affected =
        sqlx::query("UPDATE memory_grants SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
            .bind(now)
            .bind(id)
            .execute(pool)
            .await?
            .rows_affected();

    if affected == 0 {
        // 撤销已撤销的授权按幂等处理：客户端重复点击不该报错。
        let exists: Option<(String,)> = sqlx::query_as("SELECT id FROM memory_grants WHERE id = ?")
            .bind(id)
            .fetch_optional(pool)
            .await?;
        return match exists {
            Some(_) => Ok(()),
            None => Err(GrantError::NotFound),
        };
    }

    Ok(())
}

/// 任务进入终态：撤销它的任务级授权。
pub async fn revoke_by_task(pool: &SqlitePool, task_id: &str) -> Result<usize, GrantError> {
    revoke_by_scope(pool, GrantScope::Task, task_id).await
}

/// 会话/项目被删除：撤销对应作用域的授权。
pub async fn revoke_by_scope(
    pool: &SqlitePool,
    scope: GrantScope,
    scope_id: &str,
) -> Result<usize, GrantError> {
    let now = now_ms();
    let affected = sqlx::query(
        "UPDATE memory_grants SET revoked_at = ? \
         WHERE scope = ? AND scope_id = ? AND revoked_at IS NULL",
    )
    .bind(now)
    .bind(scope.as_str())
    .bind(scope_id)
    .execute(pool)
    .await?
    .rows_affected();

    Ok(affected as usize)
}

/// 过期清标。挂心跳每轮跑一次；进程重启也靠它收敛。
pub async fn expire_due(pool: &SqlitePool, now: i64) -> Result<usize, GrantError> {
    let affected = sqlx::query(
        "UPDATE memory_grants SET revoked_at = expires_at \
         WHERE revoked_at IS NULL AND expires_at <= ?",
    )
    .bind(now)
    .execute(pool)
    .await?
    .rows_affected();

    Ok(affected as usize)
}

#[derive(Debug, Clone, Default)]
pub struct GrantFilter {
    pub scope: Option<GrantScope>,
    pub scope_id: Option<String>,
    pub tool: Option<String>,
}

pub async fn list(
    pool: &SqlitePool,
    filter: &GrantFilter,
    cursor: Option<&str>,
    limit: u32,
    now: i64,
) -> Result<GrantPage, GrantError> {
    let limit = limit.clamp(1, 100);
    let cursor = match cursor {
        Some(raw) => Some(
            Cursor::decode(raw)
                .ok_or_else(|| GrantError::Invalid("cursor 无法解析".to_string()))?,
        ),
        None => None,
    };

    let rows: Vec<GrantRow> = sqlx::query_as(
        "SELECT * FROM memory_grants \
         WHERE revoked_at IS NULL AND expires_at > ? \
           AND (? IS NULL OR scope = ?) \
           AND (? IS NULL OR scope_id = ?) \
           AND (? IS NULL OR tool = ?) \
           AND (? IS NULL OR created_at < ? OR (created_at = ? AND id < ?)) \
         ORDER BY created_at DESC, id DESC LIMIT ?",
    )
    .bind(now)
    .bind(filter.scope.map(GrantScope::as_str))
    .bind(filter.scope.map(GrantScope::as_str))
    .bind(filter.scope_id.as_deref())
    .bind(filter.scope_id.as_deref())
    .bind(filter.tool.as_deref())
    .bind(filter.tool.as_deref())
    .bind(cursor.as_ref().map(|c| c.updated_at))
    .bind(cursor.as_ref().map(|c| c.updated_at))
    .bind(cursor.as_ref().map(|c| c.updated_at))
    .bind(cursor.as_ref().map(|c| c.id.clone()))
    .bind(i64::from(limit) + 1)
    .fetch_all(pool)
    .await?;

    let mut items: Vec<Grant> = Vec::with_capacity(rows.len());
    for row in rows {
        items.push(row.into_grant()?);
    }

    let next_cursor = if items.len() > limit as usize {
        items.truncate(limit as usize);
        items.last().map(|grant| {
            Cursor {
                updated_at: grant.created_at,
                id: grant.id.clone(),
            }
            .encode()
        })
    } else {
        None
    };

    Ok(GrantPage { items, next_cursor })
}

#[derive(Debug, sqlx::FromRow)]
struct GrantRow {
    id: String,
    tool: String,
    risk: String,
    scope: String,
    scope_id: String,
    approved_by: String,
    created_at: i64,
    expires_at: i64,
    revoked_at: Option<i64>,
    last_hit_at: Option<i64>,
    hit_count: i64,
}

impl GrantRow {
    fn into_grant(self) -> Result<Grant, GrantError> {
        let risk = RiskLevel::parse(&self.risk)
            .ok_or_else(|| GrantError::Invalid(format!("grant.risk={}", self.risk)))?;
        let scope = GrantScope::parse(&self.scope)
            .ok_or_else(|| GrantError::Invalid(format!("grant.scope={}", self.scope)))?;

        Ok(Grant {
            id: self.id,
            tool: self.tool,
            risk,
            scope,
            scope_id: self.scope_id,
            approved_by: self.approved_by,
            created_at: self.created_at,
            expires_at: self.expires_at,
            revoked_at: self.revoked_at,
            last_hit_at: self.last_hit_at,
            hit_count: self.hit_count.max(0) as u32,
        })
    }
}
