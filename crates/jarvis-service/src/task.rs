//! 任务：状态机、持久化与查询。
//!
//! 所有状态变更都走 [`transition`]，它做三件事：
//! 1. 用 `TaskState::can_transition` 校验合法性（状态机是显式表，不散落 if）；
//! 2. 用条件更新（`WHERE state = ?`）防并发覆盖，受影响行数为 0 即视为冲突；
//! 3. 终态写入 `finished_at`，错误写入 `error_code` / `error_hint`。

use protocol::{
    ApiError, Approval, Artifact, Cursor, ErrorCode, PlanStep, PlanStepState, Task,
    TaskCreateRequest, TaskState,
};
use sqlx::SqlitePool;

use crate::audit::{self, AuditEntry};
use crate::clock::now_ms;
use crate::conversation;
use crate::ids::new_id;

#[derive(Debug, thiserror::Error)]
pub enum TaskError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
    #[error("任务不存在")]
    NotFound,
    #[error("会话不存在")]
    ConversationNotFound,
    #[error("非法状态转移: {from} -> {to}")]
    InvalidTransition {
        from: &'static str,
        to: &'static str,
    },
    #[error("状态冲突: {0}")]
    Conflict(&'static str),
    #[error("参数非法: {0}")]
    Invalid(&'static str),
    #[error(transparent)]
    Artifact(#[from] crate::artifact_store::StoreError),
}

/// 创建任务。返回 `(task, created)`；`created=false` 表示幂等键命中已有任务。
pub async fn create(
    pool: &SqlitePool,
    request: &TaskCreateRequest,
    device_id: &str,
) -> Result<(Task, bool), TaskError> {
    if request.task_type.trim().is_empty() {
        return Err(TaskError::Invalid("type 不能为空"));
    }
    if conversation::get(pool, &request.conversation_id)
        .await
        .map_err(|err| {
            TaskError::Invalid(match err {
                conversation::ConversationError::Invalid(reason) => reason,
                _ => "会话不可用",
            })
        })?
        .is_none()
    {
        return Err(TaskError::ConversationNotFound);
    }

    if let Some(key) = request.idempotency_key.as_deref() {
        if let Some(existing) = find_by_idempotency(pool, key).await? {
            return Ok((existing, false));
        }
    }

    let now = now_ms();
    let task_id = new_id("task");

    // 审批模式只认两个值；其余一律按最保守的 `request` 处理，不拒绝请求
    // （老客户端、手写 curl 都不带这个字段）。
    let approval = normalize_approval(request.input.as_ref());
    let input_json = request.input.as_ref().map(|value| value.to_string());

    let insert = sqlx::query(
        "INSERT INTO tasks (id, conversation_id, type, skill, state, idempotency_key, retry_count, \
                input_json, created_at, updated_at) \
         VALUES (?, ?, ?, ?, 'queued', ?, 0, ?, ?, ?)",
    )
    .bind(&task_id)
    .bind(&request.conversation_id)
    .bind(&request.task_type)
    .bind(request.skill.as_deref())
    .bind(request.idempotency_key.as_deref())
    .bind(input_json)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await;

    if let Err(err) = insert {
        // 并发重复提交：幂等键唯一索引会报错，此时返回已存在的那条。
        if let Some(key) = request.idempotency_key.as_deref() {
            if let Some(existing) = find_by_idempotency(pool, key).await? {
                return Ok((existing, false));
            }
        }
        return Err(err.into());
    }

    audit::record(
        pool,
        &AuditEntry::new(&task_id, device_id, "task.created", "ok")
            .target(&task_id)
            .detail(serde_json::json!({
                "type": request.task_type,
                "conversation_id": request.conversation_id,
                // 事后复盘"这次为什么没弹卡"的第一现场。
                "approval": approval,
            })),
    )
    .await;

    let task = get(pool, &task_id).await?.ok_or(TaskError::NotFound)?;
    Ok((task, true))
}

/// 审批模式白名单：`request`（默认）/ `auto` / `trust`。
/// 非法值降级为 `request` 并记一条 warn。
pub(crate) fn normalize_approval(input: Option<&serde_json::Value>) -> String {
    let raw = input
        .and_then(|value| value.get("approval"))
        .and_then(serde_json::Value::as_str)
        .map(|value| value.trim().to_ascii_lowercase());

    match raw.as_deref() {
        None => "request".to_string(),
        Some("request") => "request".to_string(),
        Some("auto") => "auto".to_string(),
        Some("trust") => "trust".to_string(),
        Some(other) => {
            tracing::warn!(value = %other, "未知的 approval 取值，按 request 处理");
            "request".to_string()
        }
    }
}

/// 读取任务详情：含计划步骤、待批审批、产物与错误。
pub async fn get(pool: &SqlitePool, id: &str) -> Result<Option<Task>, TaskError> {
    let Some(row) = load_row(pool, id).await? else {
        return Ok(None);
    };

    let plan = load_plan(pool, id).await?;
    let pending_approval = pending_approval(pool, id).await?;
    let artifacts = load_artifacts(pool, id).await?;
    let error = row.error_code.as_deref().map(|code| ApiError {
        code: ErrorCode::parse(code).unwrap_or(ErrorCode::InternalError),
        message: "task failed".to_string(),
        retryable: ErrorCode::parse(code)
            .unwrap_or(ErrorCode::InternalError)
            .retryable(),
        hint: row.error_hint.clone().unwrap_or_default(),
    });

    Ok(Some(Task {
        id: row.id,
        conversation_id: row.conversation_id,
        task_type: row.task_type,
        skill: row.skill,
        state: TaskState::parse(&row.state).unwrap_or(TaskState::Failed),
        plan,
        pending_approval,
        artifacts,
        error,
        retry_count: row.retry_count,
        created_at: row.created_at,
        updated_at: row.updated_at,
        finished_at: row.finished_at,
        // 现场要读盘，只有详情端点会填（见 `attach_worktree`）：这里保持纯数据库语义。
        worktree: None,
        idempotency_key: row.idempotency_key,
    }))
}

/// 任务列表。列表视图不加载计划与产物，避免 N+1；详情走 [`get`]。
///
/// 项目归属经会话派生（任务本身不存 `project_id`），因此过滤走 `JOIN conversations`。
/// 项目被软删后，其任务也不再露出——与项目、会话三个视图保持一致。
pub async fn list(
    pool: &SqlitePool,
    state: Option<TaskState>,
    project_id: Option<&str>,
    conversation_id: Option<&str>,
    cursor: Option<&str>,
    limit: u32,
) -> Result<(Vec<Task>, Option<Cursor>), TaskError> {
    let limit = match limit {
        0 => return Err(TaskError::Invalid("limit 必须大于 0")),
        value if value > 100 => 100,
        value => value,
    };
    let fetch = i64::from(limit) + 1;
    let cursor = match cursor {
        Some(raw) => Some(Cursor::decode(raw).ok_or(TaskError::Invalid("cursor"))?),
        None => None,
    };
    let state_filter = state.map(TaskState::as_str);
    let project_id = project_id.map(str::trim).filter(|id| !id.is_empty());
    let conversation_id = conversation_id.map(str::trim).filter(|id| !id.is_empty());

    let rows = sqlx::query_as::<_, TaskRow>(
        "SELECT t.id, t.conversation_id, t.type, t.skill, t.state, t.retry_count, \
                t.error_code, t.error_hint, t.created_at, t.updated_at, t.finished_at, \
                t.idempotency_key \
         FROM tasks t \
         LEFT JOIN conversations c ON c.id = t.conversation_id \
         LEFT JOIN projects w ON w.id = c.project_id \
         WHERE t.deleted_at IS NULL AND (? IS NULL OR t.state = ?) \
           AND (w.id IS NULL OR w.deleted_at IS NULL) \
           AND (? IS NULL OR c.project_id = ?) \
           AND (? IS NULL OR t.conversation_id = ?) \
           AND (? IS NULL OR t.updated_at < ? OR (t.updated_at = ? AND t.id < ?)) \
         ORDER BY t.updated_at DESC, t.id DESC LIMIT ?",
    )
    .bind(state_filter)
    .bind(state_filter)
    .bind(project_id)
    .bind(project_id)
    .bind(conversation_id)
    .bind(conversation_id)
    .bind(cursor.as_ref().map(|value| value.updated_at))
    .bind(cursor.as_ref().map(|value| value.updated_at))
    .bind(cursor.as_ref().map(|value| value.updated_at))
    .bind(cursor.as_ref().map(|value| value.id.clone()))
    .bind(fetch)
    .fetch_all(pool)
    .await?;

    let mut rows = rows;
    let has_more = rows.len() > limit as usize;
    if has_more {
        rows.truncate(limit as usize);
    }
    let next = has_more
        .then(|| {
            rows.last()
                .map(|row| Cursor::new(row.updated_at, row.id.clone()))
        })
        .flatten();

    let items = rows
        .into_iter()
        .map(|row| Task {
            id: row.id,
            conversation_id: row.conversation_id,
            task_type: row.task_type,
            skill: row.skill,
            state: TaskState::parse(&row.state).unwrap_or(TaskState::Failed),
            plan: Vec::new(),
            pending_approval: None,
            artifacts: Vec::new(),
            error: None,
            retry_count: row.retry_count,
            created_at: row.created_at,
            updated_at: row.updated_at,
            finished_at: row.finished_at,
            // 列表不为每个任务读一次 meta.json：N+1 且绝大多数行没有现场。
            worktree: None,
            idempotency_key: row.idempotency_key,
        })
        .collect();

    Ok((items, next))
}

/// 读取任务创建时的原始输入。worker 执行时需要它（例如 `submit` 开关）。
pub async fn load_input(
    pool: &SqlitePool,
    id: &str,
) -> Result<Option<serde_json::Value>, TaskError> {
    let raw: Option<Option<String>> =
        sqlx::query_scalar("SELECT input_json FROM tasks WHERE id = ? AND deleted_at IS NULL")
            .bind(id)
            .fetch_optional(pool)
            .await?;

    match raw {
        None => Err(TaskError::NotFound),
        Some(None) => Ok(None),
        Some(Some(text)) => Ok(serde_json::from_str(&text).ok()),
    }
}

/// 按 worker 上报的步骤名覆盖计划（顺序即 `seq`）。
pub async fn replace_plan_named(
    pool: &SqlitePool,
    task_id: &str,
    steps: &[String],
) -> Result<(), TaskError> {
    let names: Vec<&str> = steps.iter().map(String::as_str).collect();
    replace_plan(pool, task_id, &names).await
}

/// 状态转移。非法转移返回 [`TaskError::InvalidTransition`]，并发冲突返回 `Conflict`。
pub async fn transition(
    pool: &SqlitePool,
    id: &str,
    next: TaskState,
    error: Option<&ApiError>,
) -> Result<(), TaskError> {
    let row = load_row(pool, id).await?.ok_or(TaskError::NotFound)?;
    let from = TaskState::parse(&row.state).unwrap_or(TaskState::Failed);

    if !from.can_transition(next) {
        return Err(TaskError::InvalidTransition {
            from: from.as_str(),
            to: next.as_str(),
        });
    }

    let now = now_ms();
    let finished_at = next.is_terminal().then_some(now);

    let result = sqlx::query(
        "UPDATE tasks SET state = ?, updated_at = ?, finished_at = COALESCE(?, finished_at), \
                error_code = ?, error_hint = ? \
         WHERE id = ? AND state = ? AND deleted_at IS NULL",
    )
    .bind(next.as_str())
    .bind(now)
    .bind(finished_at)
    .bind(error.map(|value| value.code.as_str()))
    .bind(error.map(|value| value.hint.clone()))
    .bind(id)
    .bind(from.as_str())
    .execute(pool)
    .await?;

    if result.rows_affected() == 0 {
        return Err(TaskError::Conflict("任务状态已被其他操作改变"));
    }

    // 任务进入终态：任务级授权随之失效（取消路径也走这里）。
    if next.is_terminal() {
        if let Err(err) = crate::grants::revoke_by_task(pool, id).await {
            tracing::warn!(%err, %id, "撤销任务级执行授权失败");
        }
    }

    audit::record(
        pool,
        &AuditEntry::new(id, "system", "task.state_changed", "ok")
            .target(id)
            .detail(serde_json::json!({
                "from": from.as_str(),
                "to": next.as_str(),
                "error": error.map(|value| value.code.as_str()),
            })),
    )
    .await;

    Ok(())
}

/// 取消任务，并把它名下处于 pending 的审批标记为 rejected，避免悬挂。
pub async fn cancel(pool: &SqlitePool, id: &str, actor: &str) -> Result<(), TaskError> {
    let row = load_row(pool, id).await?.ok_or(TaskError::NotFound)?;
    let state = TaskState::parse(&row.state).unwrap_or(TaskState::Failed);
    if !state.is_cancelable() {
        return Err(TaskError::Conflict("任务已结束，无法取消"));
    }

    let now = now_ms();
    let mut tx = pool.begin().await?;
    sqlx::query(
        "UPDATE tasks SET state = 'canceled', updated_at = ?, finished_at = ? \
         WHERE id = ? AND deleted_at IS NULL",
    )
    .bind(now)
    .bind(now)
    .bind(id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE approvals SET decision = 'rejected', decided_at = ? \
         WHERE task_id = ? AND decision = 'pending'",
    )
    .bind(now)
    .bind(id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    audit::record(
        pool,
        &AuditEntry::new(id, actor, "task.canceled", "ok").target(id),
    )
    .await;

    Ok(())
}

/// 重试：把已结束的任务重新排队。这是"新一次执行"，不是状态转移，因此绕开转移表。
pub async fn retry(pool: &SqlitePool, id: &str, actor: &str) -> Result<Task, TaskError> {
    let now = now_ms();
    let result = sqlx::query(
        "UPDATE tasks SET state = 'queued', retry_count = retry_count + 1, updated_at = ?, \
                finished_at = NULL, error_code = NULL, error_hint = NULL \
         WHERE id = ? AND state IN ('failed', 'canceled') AND deleted_at IS NULL",
    )
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    if result.rows_affected() == 0 {
        // 区分"不存在"与"状态不允许"，否则客户端无法给出正确提示。
        if load_row(pool, id).await?.is_none() {
            return Err(TaskError::NotFound);
        }
        return Err(TaskError::Conflict("只有失败或已取消的任务可以重试"));
    }

    audit::record(
        pool,
        &AuditEntry::new(id, actor, "task.retried", "ok").target(id),
    )
    .await;

    get(pool, id).await?.ok_or(TaskError::NotFound)
}

/// 逻辑删除任务：写 `deleted_at`，步骤、审批、产物元信息都留在库里。
///
/// 同时把 `idempotency_key` 置空：唯一索引不区分是否已删，键留着会让同一个
/// 幂等键永远无法再创建任务。丢掉的只是去重键，任务其余数据完整保留。
///
/// 未结束的任务不允许删：worker 可能正在向它上报事件，删掉会让状态机悬空。
/// 磁盘上的产物正文与编码任务工作树按约定保留。
pub async fn delete(pool: &SqlitePool, id: &str) -> Result<(), TaskError> {
    let row = load_row(pool, id).await?.ok_or(TaskError::NotFound)?;
    let state = TaskState::parse(&row.state).unwrap_or(TaskState::Failed);
    if !state.is_terminal() {
        return Err(TaskError::Conflict("任务还没结束，先取消再删"));
    }

    let result = sqlx::query(
        "UPDATE tasks SET deleted_at = ?, idempotency_key = NULL \
         WHERE id = ? AND deleted_at IS NULL \
           AND state IN ('succeeded', 'failed', 'canceled')",
    )
    .bind(now_ms())
    .bind(id)
    .execute(pool)
    .await?;

    if result.rows_affected() == 0 {
        // 并发下已被另一个请求删掉，或状态在检查之后变了。
        if load_row(pool, id).await?.is_none() {
            return Err(TaskError::NotFound);
        }
        return Err(TaskError::Conflict("任务状态已变化，请刷新后重试"));
    }

    Ok(())
}

/// 清掉某次尝试留下的产物（行与文件）。
///
/// 重试是一次**全新的尝试**：不清的话，上一次失败的 `run_log` 会挂在新结果旁边，
/// 任务详情看起来像"这次也失败了"。
pub async fn clear_artifacts(
    pool: &SqlitePool,
    task_id: &str,
    artifacts_root: &std::path::Path,
) -> Result<(), TaskError> {
    let paths: Vec<String> = sqlx::query_scalar("SELECT path FROM artifacts WHERE task_id = ?")
        .bind(task_id)
        .fetch_all(pool)
        .await?;

    let store = crate::artifact_store::ArtifactStore::new(artifacts_root);
    for relative in &paths {
        if let Err(err) = store.remove(relative).await {
            tracing::warn!(%err, task_id, path = %relative, "删除旧产物文件失败");
        }
    }

    sqlx::query("DELETE FROM artifacts WHERE task_id = ?")
        .bind(task_id)
        .execute(pool)
        .await?;

    Ok(())
}

/// 写入计划步骤（覆盖式：执行器每次重建计划）。
pub async fn replace_plan(
    pool: &SqlitePool,
    task_id: &str,
    steps: &[&str],
) -> Result<(), TaskError> {
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM task_steps WHERE task_id = ?")
        .bind(task_id)
        .execute(&mut *tx)
        .await?;

    for (index, name) in steps.iter().enumerate() {
        sqlx::query(
            "INSERT INTO task_steps (id, task_id, seq, name, state) VALUES (?, ?, ?, ?, 'pending')",
        )
        .bind(new_id("step"))
        .bind(task_id)
        .bind(index as i64)
        .bind(*name)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

/// 单步过程摘要的字符上限。
///
/// worker 每批最多 6 行、每行 ≤ 180 字，正常只有几百字；这里的上限是防御
/// "别的执行器把整段模型输出塞进 summary"——memory 抽取会读这一列。
const STEP_OUTPUT_LIMIT: usize = 4_000;

/// 覆盖式写入步骤的最新过程摘要。
///
/// 返回 `false` 表示没有命中任何行：`PlanCreated` 会 `DELETE` + 重建步骤，
/// 先到的 `StepOutput` 找不到目标，或者任务已经进入终态。这是正常时序，
/// 调用方记 debug 即可，不要当成故障刷 warn。
///
/// 只改 `task_steps`，**不动 `tasks.updated_at`**：那个字段由状态转移维护，
/// 悬空任务回收（[`recover_stale_running`]）靠它判断"多久没动"；
/// 进度每 5 秒刷一次会把这个判据废掉。
pub async fn set_step_output(
    pool: &SqlitePool,
    task_id: &str,
    seq: i64,
    summary: &str,
) -> Result<bool, TaskError> {
    let summary = truncate_chars(summary.trim(), STEP_OUTPUT_LIMIT);
    if summary.is_empty() {
        return Ok(false);
    }

    let payload = serde_json::json!({ "summary": summary, "at": now_ms() }).to_string();
    let result = sqlx::query(
        "UPDATE task_steps SET output_json = ? \
         WHERE task_id = ? AND seq = ? \
           AND EXISTS (SELECT 1 FROM tasks t WHERE t.id = task_steps.task_id \
                       AND t.deleted_at IS NULL \
                       AND t.state IN ('queued','running','needs_approval','needs_input'))",
    )
    .bind(payload)
    .bind(task_id)
    .bind(seq)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() > 0)
}

/// 解析 `task_steps.output_json`，得到 `(摘要, 生成时间)`。
///
/// 兼容两种形态：本轮写入的 `{"summary": "...", "at": 123}` 信封，以及纯文本
/// （升级前的历史数据、或将来的其它写入方）。解析不出摘要时返回 `None`，
/// 而不是把一段 JSON 当解释给用户看。
pub fn parse_step_output(raw: &str) -> Option<(String, Option<i64>)> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if let Some(summary) = value.get("summary").and_then(serde_json::Value::as_str) {
            let summary = summary.trim();
            if summary.is_empty() {
                return None;
            }
            return Some((
                summary.to_string(),
                value.get("at").and_then(serde_json::Value::as_i64),
            ));
        }
    }

    Some((trimmed.to_string(), None))
}

/// 按字符截断，超出以 `…` 结尾（按字节切会切断中文）。
fn truncate_chars(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    text.chars().take(max).collect::<String>() + "…"
}

/// 更新单个步骤的状态。
pub async fn set_step_state(
    pool: &SqlitePool,
    task_id: &str,
    seq: i64,
    state: PlanStepState,
) -> Result<(), TaskError> {
    let now = now_ms();
    let started_at = matches!(state, PlanStepState::Running).then_some(now);
    let ended_at = matches!(state, PlanStepState::Done | PlanStepState::Failed).then_some(now);

    sqlx::query(
        "UPDATE task_steps SET state = ?, started_at = COALESCE(?, started_at), \
                ended_at = COALESCE(?, ended_at) \
         WHERE task_id = ? AND seq = ?",
    )
    .bind(state.as_str())
    .bind(started_at)
    .bind(ended_at)
    .bind(task_id)
    .bind(seq)
    .execute(pool)
    .await?;
    Ok(())
}

/// 追加产物：先原子落盘，再把相对路径与元信息写入数据库。
///
/// 顺序不能反：先入库后写盘会留下"有记录没文件"的悬空产物，
/// 而先写盘后入库最多留一个无人引用的文件（可清理，不影响一致性）。
pub async fn add_artifact(
    pool: &SqlitePool,
    store: &crate::artifact_store::ArtifactStore,
    task_id: &str,
    kind: &str,
    mime: Option<&str>,
    content: &str,
) -> Result<Artifact, TaskError> {
    let id = new_id("art");
    let (path, size) = store.save(task_id, &id, mime, content).await?;

    let artifact = Artifact {
        id,
        task_id: task_id.to_string(),
        kind: kind.to_string(),
        size,
        mime: mime.map(str::to_string),
        created_at: now_ms(),
    };

    sqlx::query(
        "INSERT INTO artifacts (id, task_id, kind, path, size, mime, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&artifact.id)
    .bind(&artifact.task_id)
    .bind(&artifact.kind)
    .bind(&path)
    .bind(artifact.size)
    .bind(artifact.mime.as_deref())
    .bind(artifact.created_at)
    .execute(pool)
    .await?;

    Ok(artifact)
}

/// 回收悬空任务：`running` 且超过时限的，转 `queued` 并累加重试次数。
///
/// 只做"重新排队"，不自动执行——由调用方（ticker 或启动恢复）决定是否再派给执行器。
pub async fn recover_stale_running(
    pool: &SqlitePool,
    cutoff_ms: i64,
) -> Result<Vec<String>, TaskError> {
    let ids: Vec<String> = sqlx::query_scalar(
        "SELECT id FROM tasks WHERE state = 'running' AND updated_at < ? \
         AND deleted_at IS NULL",
    )
    .bind(cutoff_ms)
    .fetch_all(pool)
    .await?;

    let mut recovered = Vec::with_capacity(ids.len());
    for id in ids {
        let result = sqlx::query(
            "UPDATE tasks SET state = 'queued', retry_count = retry_count + 1, updated_at = ? \
             WHERE id = ? AND state = 'running' AND deleted_at IS NULL",
        )
        .bind(now_ms())
        .bind(&id)
        .execute(pool)
        .await?;

        if result.rows_affected() > 0 {
            audit::record(
                pool,
                &AuditEntry::new(&id, "system", "task.recovered", "ok")
                    .target(&id)
                    .detail(serde_json::json!({ "reason": "stale running" })),
            )
            .await;
            recovered.push(id);
        }
    }

    Ok(recovered)
}

async fn pending_approval(pool: &SqlitePool, task_id: &str) -> Result<Option<Approval>, TaskError> {
    let row = sqlx::query_as::<_, crate::approval::ApprovalRow>(
        "SELECT id, task_id, action, target, impact_json, previews_json, scope, tool_json, \
                expires_at, decision \
         FROM approvals WHERE task_id = ? AND decision = 'pending' \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(task_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(crate::approval::IntoApproval::into_approval))
}

async fn load_plan(pool: &SqlitePool, task_id: &str) -> Result<Vec<PlanStep>, TaskError> {
    let rows = sqlx::query_as::<_, (i64, String, String, Option<String>)>(
        "SELECT seq, name, state, output_json FROM task_steps WHERE task_id = ? ORDER BY seq ASC",
    )
    .bind(task_id)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| {
            let (output, updated_at) = row
                .3
                .as_deref()
                .and_then(parse_step_output)
                .map(|(summary, at)| (Some(summary), at))
                .unwrap_or((None, None));

            PlanStep {
                seq: row.0,
                name: row.1,
                state: PlanStepState::parse(&row.2).unwrap_or(PlanStepState::Pending),
                output,
                updated_at,
            }
        })
        .collect())
}

async fn load_artifacts(pool: &SqlitePool, task_id: &str) -> Result<Vec<Artifact>, TaskError> {
    let rows = sqlx::query_as::<_, (String, String, String, i64, Option<String>, i64)>(
        "SELECT id, task_id, kind, size, mime, created_at FROM artifacts \
         WHERE task_id = ? ORDER BY created_at ASC",
    )
    .bind(task_id)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| Artifact {
            id: row.0,
            task_id: row.1,
            kind: row.2,
            size: row.3,
            mime: row.4,
            created_at: row.5,
        })
        .collect())
}

async fn find_by_idempotency(pool: &SqlitePool, key: &str) -> Result<Option<Task>, TaskError> {
    let id: Option<String> = sqlx::query_scalar("SELECT id FROM tasks WHERE idempotency_key = ?")
        .bind(key)
        .fetch_optional(pool)
        .await?;

    match id {
        Some(id) => get(pool, &id).await,
        None => Ok(None),
    }
}

async fn load_row(pool: &SqlitePool, id: &str) -> Result<Option<TaskRow>, TaskError> {
    let row = sqlx::query_as::<_, TaskRow>(
        "SELECT id, conversation_id, type, skill, state, retry_count, error_code, error_hint, \
                created_at, updated_at, finished_at, idempotency_key \
         FROM tasks WHERE id = ? AND deleted_at IS NULL",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

/// 任务行。`type` 是 SQL 关键字，列名映射到 `task_type` 字段。
#[derive(Debug, sqlx::FromRow)]
struct TaskRow {
    id: String,
    conversation_id: String,
    #[sqlx(rename = "type")]
    task_type: String,
    skill: Option<String>,
    state: String,
    retry_count: i64,
    error_code: Option<String>,
    error_hint: Option<String>,
    created_at: i64,
    updated_at: i64,
    finished_at: Option<i64>,
    idempotency_key: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn approval_mode_falls_back_to_request() {
        // 老客户端、手写 curl、拼错的值：一律按最保守的那档处理。
        assert_eq!(normalize_approval(None), "request");
        assert_eq!(
            normalize_approval(Some(&serde_json::json!({"instruction": "改个 bug"}))),
            "request"
        );
        assert_eq!(
            normalize_approval(Some(&serde_json::json!({"approval": "whatever"}))),
            "request"
        );
    }

    #[test]
    fn approval_mode_accepts_the_three_known_values() {
        assert_eq!(
            normalize_approval(Some(&serde_json::json!({"approval": "request"}))),
            "request"
        );
        assert_eq!(
            normalize_approval(Some(&serde_json::json!({"approval": "auto"}))),
            "auto"
        );
        assert_eq!(
            normalize_approval(Some(&serde_json::json!({"approval": "trust"}))),
            "trust"
        );
        // 大小写与空白不该让人猜。
        assert_eq!(
            normalize_approval(Some(&serde_json::json!({"approval": " AUTO "}))),
            "auto"
        );
        assert_eq!(
            normalize_approval(Some(&serde_json::json!({"approval": " TRUST "}))),
            "trust"
        );
    }

    #[test]
    fn step_output_envelope_roundtrips_and_plain_text_still_parses() {
        let raw = r#"{"summary":"工具：Bash（只读）git status","at":1700000000000}"#;
        assert_eq!(
            parse_step_output(raw),
            Some((
                "工具：Bash（只读）git status".to_string(),
                Some(1_700_000_000_000)
            ))
        );

        // 纯文本：升级前的历史数据或其它写入方，不能被当成"没有过程"。
        assert_eq!(
            parse_step_output("已生成行程草案"),
            Some(("已生成行程草案".to_string(), None))
        );
        assert_eq!(parse_step_output("   "), None);
        assert_eq!(parse_step_output(r#"{"summary":"  "}"#), None);
    }

    #[test]
    fn step_output_truncation_is_char_based() {
        // 按字节切会切断中文：40 个汉字必须完整留下前 10 个。
        let text = "汉".repeat(40);
        let cut = truncate_chars(&text, 10);
        assert_eq!(cut.chars().count(), 11, "10 个字 + 省略号");
        assert!(cut.ends_with('…'));
        assert_eq!(truncate_chars("短", 10), "短", "没超限不该加省略号");
    }

    #[test]
    fn terminal_states_have_finished_at_semantics() {
        assert!(TaskState::Succeeded.is_terminal());
        assert!(TaskState::Canceled.is_terminal());
        assert!(!TaskState::NeedsApproval.is_terminal());
    }

    #[test]
    fn retry_only_from_terminal_states() {
        // 这是 `retry` 的 SQL 条件，与状态机保持同一条规则。
        assert!(TaskState::Failed.is_terminal());
        assert!(TaskState::Canceled.is_terminal());
        assert!(!TaskState::Running.is_terminal());
    }
}
