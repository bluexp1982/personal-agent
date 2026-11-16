//! 审批：创建、决策与过期扫描。
//!
//! 关键约束（见「业务范围 › 审批与送达」）：
//! - 一次审批只接受**一个**决定，重复提交返回冲突；
//! - 决策用条件更新（`WHERE decision = 'pending'`），避免与超时扫描竞态；
//! - 过期由后台扫描处理，任务按失败结束，`error_code = approval_expired`；
//! - 同一任务同一时刻最多一条 pending（工具级审批靠这条不变量防重复建卡）。

use protocol::{
    Approval, ApprovalDecision, ApprovalScope, ApprovalTool, ApproveAction, ErrorCode, RiskLevel,
};
use sqlx::SqlitePool;

use crate::clock::now_ms;
use crate::ids::new_id;

#[derive(Debug, thiserror::Error)]
pub enum ApprovalError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
    #[error("审批不存在")]
    NotFound,
    #[error("审批已处理")]
    AlreadyDecided,
    #[error("审批已过期")]
    Expired,
}

/// 新建审批的入参。
///
/// 用结构体而不是继续加位置参数：`previews` / `scope` / `tool` 只在工具级审批用得上，
/// 位置参数堆到七八个之后，调用点会变成一串看不出含义的 `None`。
#[derive(Debug, Clone)]
pub struct NewApproval<'a> {
    pub task_id: &'a str,
    pub action: &'a str,
    pub target: Option<&'a str>,
    pub impact: Option<&'a str>,
    pub previews: Vec<String>,
    pub scope: ApprovalScope,
    pub tool: Option<ApprovalTool>,
    pub ttl_ms: i64,
}

impl<'a> NewApproval<'a> {
    /// 任务级审批（合并确认等）。
    pub fn task(task_id: &'a str, action: &'a str, ttl_ms: i64) -> Self {
        Self {
            task_id,
            action,
            target: None,
            impact: None,
            previews: Vec::new(),
            scope: ApprovalScope::Task,
            tool: None,
            ttl_ms,
        }
    }

    /// 工具级审批：只针对某一次工具调用。
    pub fn tool(
        task_id: &'a str,
        call_id: &'a str,
        name: &str,
        risk: RiskLevel,
        digest: &str,
        rememberable: bool,
        ttl_ms: i64,
    ) -> Self {
        Self {
            task_id,
            action: TOOL_ACTION,
            target: Some(call_id),
            // 影响说明由 `create` 按 tool 字段生成，避免这里持有临时 String。
            impact: None,
            previews: vec![digest.to_string()],
            scope: ApprovalScope::Tool,
            tool: Some(ApprovalTool {
                name: name.to_string(),
                risk,
                digest: digest.to_string(),
                rememberable,
            }),
            ttl_ms,
        }
    }

    pub fn with_target(mut self, target: &'a str) -> Self {
        self.target = Some(target);
        self
    }

    pub fn with_impact(mut self, impact: &'a str) -> Self {
        self.impact = Some(impact);
        self
    }
}

/// 工具级审批的动作标识。客户端按 `scope` 分支渲染，这里只用于审计与排障。
pub const TOOL_ACTION: &str = "code.tool_use";

impl NewApproval<'_> {
    /// 客户端展示用的影响说明（`tool` 模式已自带，这里给任务级用）。
    pub fn impact_text(&self) -> Option<&str> {
        self.impact
    }
}

/// 创建待批记录。同一任务同时只应有一个 pending 审批。
pub async fn create(pool: &SqlitePool, new: NewApproval<'_>) -> Result<Approval, ApprovalError> {
    let now = now_ms();
    // 工具级的影响说明由工具名 + 风险档拼出来，调用方不需要再传一遍。
    let impact = new.impact.map(str::to_string).or_else(|| {
        new.tool
            .as_ref()
            .map(|tool| format!("{}：{}", tool.risk.label(), tool.name))
    });
    let approval = Approval {
        id: new_id("apr"),
        task_id: new.task_id.to_string(),
        action: new.action.to_string(),
        target: new.target.map(str::to_string),
        impact,
        previews: new.previews.clone(),
        scope: new.scope,
        tool: new.tool.clone(),
        expires_at: now + new.ttl_ms.max(1),
        decision: ApprovalDecision::Pending,
    };

    let previews_json = serde_json::to_string(&approval.previews).unwrap_or_else(|_| "[]".into());
    let tool_json = approval
        .tool
        .as_ref()
        .and_then(|tool| serde_json::to_string(tool).ok());

    sqlx::query(
        "INSERT INTO approvals (id, task_id, action, target, impact_json, previews_json, \
                scope, tool_json, expires_at, decision, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
    )
    .bind(&approval.id)
    .bind(&approval.task_id)
    .bind(&approval.action)
    .bind(approval.target.as_deref())
    .bind(approval.impact.as_deref())
    .bind(previews_json)
    .bind(approval.scope.as_str())
    .bind(tool_json)
    .bind(approval.expires_at)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(approval)
}

/// 提交决定。返回 `(task_id, 最终决定)`。
///
/// 过期或已处理的审批不会被执行；调用方据错误类型给客户端明确提示。
pub async fn decide(
    pool: &SqlitePool,
    approval_id: &str,
    action: ApproveAction,
) -> Result<(String, ApprovalDecision), ApprovalError> {
    let row = sqlx::query_as::<_, (String, String, i64)>(
        "SELECT task_id, decision, expires_at FROM approvals WHERE id = ?",
    )
    .bind(approval_id)
    .fetch_optional(pool)
    .await?
    .ok_or(ApprovalError::NotFound)?;

    let (task_id, decision, expires_at) = row;
    if decision != ApprovalDecision::Pending.as_str() {
        return Err(ApprovalError::AlreadyDecided);
    }
    if expires_at <= now_ms() {
        mark_expired(pool, approval_id).await?;
        return Err(ApprovalError::Expired);
    }

    let decided = match action {
        ApproveAction::Approve => ApprovalDecision::Approved,
        ApproveAction::Reject => ApprovalDecision::Rejected,
    };

    let result = sqlx::query(
        "UPDATE approvals SET decision = ?, decided_at = ? WHERE id = ? AND decision = 'pending'",
    )
    .bind(decided.as_str())
    .bind(now_ms())
    .bind(approval_id)
    .execute(pool)
    .await?;

    if result.rows_affected() == 0 {
        // 说明另一个请求（或超时扫描）刚刚处理了它。
        return Err(ApprovalError::AlreadyDecided);
    }

    Ok((task_id, decided))
}

/// 最近一条审批，**优先返回 pending 的那条**。
///
/// 以前是 `ORDER BY created_at DESC`：工具级审批会让同一个任务出现多条记录，
/// 取"最近一条"可能拿到刚被驳回的那张，模拟执行器路径就会读错。
pub async fn latest_for_task(
    pool: &SqlitePool,
    task_id: &str,
) -> Result<Option<Approval>, ApprovalError> {
    let row = sqlx::query_as::<_, ApprovalRow>(
        "SELECT id, task_id, action, target, impact_json, previews_json, scope, tool_json, \
                expires_at, decision \
         FROM approvals WHERE task_id = ? \
         ORDER BY (decision = 'pending') DESC, created_at DESC LIMIT 1",
    )
    .bind(task_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(ApprovalRow::into_approval))
}

/// 按 id 取一条审批（含已决）。
pub async fn get(pool: &SqlitePool, approval_id: &str) -> Result<Approval, ApprovalError> {
    let row = sqlx::query_as::<_, ApprovalRow>(
        "SELECT id, task_id, action, target, impact_json, previews_json, scope, tool_json, \
                expires_at, decision FROM approvals WHERE id = ?",
    )
    .bind(approval_id)
    .fetch_optional(pool)
    .await?
    .ok_or(ApprovalError::NotFound)?;

    Ok(row.into_approval())
}

/// 该任务当前待决的审批（没有则 `None`）。
pub async fn pending_for_task(
    pool: &SqlitePool,
    task_id: &str,
) -> Result<Option<Approval>, ApprovalError> {
    let row = sqlx::query_as::<_, ApprovalRow>(
        "SELECT id, task_id, action, target, impact_json, previews_json, scope, tool_json, \
                expires_at, decision \
         FROM approvals WHERE task_id = ? AND decision = 'pending' \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(task_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(ApprovalRow::into_approval))
}

/// 把所有到期未决的审批置为 expired，返回 `(approval_id, task_id)` 列表。
pub async fn expire_due(
    pool: &SqlitePool,
    now: i64,
) -> Result<Vec<(String, String)>, ApprovalError> {
    let due = sqlx::query_as::<_, (String, String)>(
        "SELECT id, task_id FROM approvals WHERE decision = 'pending' AND expires_at <= ?",
    )
    .bind(now)
    .fetch_all(pool)
    .await?;

    let mut expired = Vec::with_capacity(due.len());
    for (approval_id, task_id) in due {
        if mark_expired(pool, &approval_id).await? {
            expired.push((approval_id, task_id));
        }
    }
    Ok(expired)
}

/// 过期任务应使用的错误体。
pub fn expired_error() -> protocol::ApiError {
    protocol::ApiError::new(
        ErrorCode::ApprovalExpired,
        "approval expired",
        "确认已超时，任务已停止；可重试任务重新发起",
    )
}

async fn mark_expired(pool: &SqlitePool, approval_id: &str) -> Result<bool, ApprovalError> {
    let result = sqlx::query(
        "UPDATE approvals SET decision = 'expired', decided_at = ? \
         WHERE id = ? AND decision = 'pending'",
    )
    .bind(now_ms())
    .bind(approval_id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() > 0)
}

/// `approvals` 表的一行（含新增的 scope / tool 列）。
pub(crate) type ApprovalRow = (
    String,
    String,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    String,
    Option<String>,
    i64,
    String,
);

pub(crate) trait IntoApproval {
    fn into_approval(self) -> Approval;
}

impl IntoApproval for ApprovalRow {
    fn into_approval(self) -> Approval {
        let tool = self
            .7
            .as_deref()
            .and_then(|raw| serde_json::from_str::<ApprovalTool>(raw).ok());
        Approval {
            id: self.0,
            task_id: self.1,
            action: self.2,
            target: self.3,
            impact: self.4,
            previews: self
                .5
                .and_then(|raw| serde_json::from_str::<Vec<String>>(&raw).ok())
                .unwrap_or_default(),
            scope: ApprovalScope::parse(&self.6).unwrap_or_default(),
            tool,
            expires_at: self.8,
            decision: ApprovalDecision::parse(&self.9).unwrap_or(ApprovalDecision::Pending),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expired_error_code_matches_contract() {
        let error = expired_error();
        assert_eq!(error.code.as_str(), "approval_expired");
        assert!(!error.retryable);
        assert!(!error.hint.is_empty());
    }

    #[test]
    fn tool_approval_carries_digest_and_scope() {
        let new = NewApproval::tool(
            "task_1",
            "call_2",
            "Bash",
            RiskLevel::IrreversibleWrite,
            "rm -rf build",
            true,
            120_000,
        );
        assert_eq!(new.scope, ApprovalScope::Tool);
        assert_eq!(new.action, TOOL_ACTION);
        assert_eq!(new.target, Some("call_2"));
        assert_eq!(new.previews, vec!["rm -rf build".to_string()]);
        assert_eq!(new.tool.as_ref().map(|tool| tool.rememberable), Some(true));
        assert_eq!(
            new.tool.as_ref().map(|tool| tool.risk),
            Some(RiskLevel::IrreversibleWrite)
        );
    }
}
