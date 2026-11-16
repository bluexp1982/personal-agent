//! 审计落库。
//!
//! 约束（见「任务执行与工具」与开发方案关键实现要点）：
//! - 写失败**不阻断**业务，但必须留下 `tracing::error!`，否则缺口不可见；
//! - 一条链共用同一个 `trace_id`，一次任务的全部动作可串起来查；
//! - `detail` 存结构化补充信息（不存原文，避免把对话内容写进审计）。

use sqlx::SqlitePool;

use crate::clock::now_ms;

/// 一条审计记录。使用 owned 字段，便于在跨 await 的任务里传递。
#[derive(Debug, Clone)]
pub struct AuditEntry {
    pub trace_id: String,
    pub actor: String,
    pub action: String,
    pub target: Option<String>,
    pub result: String,
    pub detail: Option<serde_json::Value>,
}

impl AuditEntry {
    pub fn new(
        trace_id: impl Into<String>,
        actor: impl Into<String>,
        action: impl Into<String>,
        result: impl Into<String>,
    ) -> Self {
        Self {
            trace_id: trace_id.into(),
            actor: actor.into(),
            action: action.into(),
            target: None,
            result: result.into(),
            detail: None,
        }
    }

    pub fn target(mut self, target: impl Into<String>) -> Self {
        self.target = Some(target.into());
        self
    }

    pub fn detail(mut self, detail: serde_json::Value) -> Self {
        self.detail = Some(detail);
        self
    }
}

/// 写入审计。失败只记日志，不向调用方返回错误。
pub async fn record(pool: &SqlitePool, entry: &AuditEntry) {
    let detail = entry
        .detail
        .as_ref()
        .map(|value| value.to_string())
        .unwrap_or_default();

    let result = sqlx::query(
        "INSERT INTO audit_log (ts, trace_id, actor, action, target, result, detail_json) \
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(now_ms())
    .bind(&entry.trace_id)
    .bind(&entry.actor)
    .bind(&entry.action)
    .bind(entry.target.as_deref())
    .bind(&entry.result)
    .bind(detail)
    .execute(pool)
    .await;

    if let Err(err) = result {
        // 审计写失败不阻断业务，但必须可见：这条日志是排查"审计缺记录"的唯一线索。
        tracing::error!(
            %err,
            trace_id = %entry.trace_id,
            action = %entry.action,
            "审计写入失败"
        );
    }
}

/// 按 trace_id 读取审计轨迹（管理面与测试使用）。
pub async fn list_by_trace(
    pool: &SqlitePool,
    trace_id: &str,
) -> Result<Vec<AuditRecord>, sqlx::Error> {
    let rows = sqlx::query_as::<_, (i64, String, String, String, Option<String>, String, String)>(
        "SELECT ts, trace_id, actor, action, target, result, detail_json \
         FROM audit_log WHERE trace_id = ? ORDER BY ts ASC, id ASC",
    )
    .bind(trace_id)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| AuditRecord {
            ts: row.0,
            trace_id: row.1,
            actor: row.2,
            action: row.3,
            target: row.4,
            result: row.5,
            detail_json: row.6,
        })
        .collect())
}

#[derive(Debug, Clone)]
pub struct AuditRecord {
    pub ts: i64,
    pub trace_id: String,
    pub actor: String,
    pub action: String,
    pub target: Option<String>,
    pub result: String,
    pub detail_json: String,
}
