//! 把 worker 上报的事件应用为任务状态、审批、产物与审计。
//!
//! 原则：
//! - **只接受合法状态转移**：重复或乱序事件被忽略并记 warn，不覆盖已有终态；
//! - **完成由契约判定**：`task_finished` 必须通过 skill 声明的 `outputs` 校验；
//! - worker 的自我描述（"我完成了"）不作为结论，只作为待验证的断言。

use std::collections::HashSet;

use sqlx::SqlitePool;

use crate::audit::{self, AuditEntry};
use crate::clock::now_ms;
use crate::state::AppState;
use crate::{approval, task};
use protocol::{
    ApiError, ErrorCode, IpcMessage, PlanStepState, RiskLevel, StepSpec, TaskState,
    ToolDecisionKind,
};

/// 处理一条来自 worker 的事件。未知方向的消息只记日志。
pub async fn apply(state: &AppState, message: IpcMessage) {
    match message {
        IpcMessage::PlanCreated { task_id, steps } => {
            apply_plan(state, &task_id, &steps).await;
        }
        IpcMessage::StepStarted { task_id, seq, name } => {
            let _ =
                task::set_step_state(&state.pool, &task_id, seq, protocol::PlanStepState::Running)
                    .await;
            audit::record(
                &state.pool,
                &AuditEntry::new(&task_id, "worker", "step.started", "ok")
                    .target(&task_id)
                    .detail(serde_json::json!({ "seq": seq, "name": name })),
            )
            .await;
        }
        IpcMessage::StepOutput {
            task_id,
            seq,
            summary,
        } => {
            // 过程摘要写进 `task_steps`，随任务详情下发；**不再逐条写审计**：
            // 编码任务每 5 秒一条，13 分钟就是 150 多行，会把审计表刷成进度条。
            // 完整过程仍在 `run_log` 产物里，审计只保留步骤开始/任务结束这类事件。
            match task::set_step_output(&state.pool, &task_id, seq, &summary).await {
                // 步骤已被 `PlanCreated` 重建或任务已结束：正常时序，不刷 warn。
                Ok(false) => tracing::debug!(%task_id, seq, "过程摘要没有命中步骤"),
                Ok(true) => {}
                Err(err) => tracing::warn!(%err, %task_id, "写入步骤过程摘要失败"),
            }
        }
        IpcMessage::LocalToolCall {
            call_id,
            task_id,
            tool,
            args,
        } => {
            // 读文件可能慢（大目录、网络盘），不能阻塞事件循环：
            // spawn 出去，结果自己经 `LocalToolResult` 回传。
            let state = state.clone();
            tokio::spawn(async move {
                crate::api::local_tool::handle(&state, call_id, task_id, tool, args).await;
            });
        }
        IpcMessage::ApprovalRequired {
            task_id,
            action,
            target,
            impact,
        } => {
            apply_approval_required(state, &task_id, &action, target, impact).await;
        }
        IpcMessage::ToolApprovalRequired {
            task_id,
            call_id,
            provider,
            tool,
            risk,
            digest,
            rules,
        } => {
            apply_tool_approval_required(
                state, &task_id, &call_id, &provider, &tool, &risk, &digest, &rules,
            )
            .await;
        }
        IpcMessage::ArtifactCreated {
            task_id,
            kind,
            size,
            mime,
            content,
        } => {
            apply_artifact(state, &task_id, &kind, size, mime.as_deref(), &content).await;
        }
        IpcMessage::TaskFinished { task_id, summary } => {
            apply_finished(state, &task_id, &summary).await;
        }
        IpcMessage::TaskFailed {
            task_id,
            code,
            hint,
            retryable,
        } => {
            apply_failed(state, &task_id, code, hint, retryable).await;
        }
        other => {
            tracing::warn!(?other, "收到不应由服务端处理的 IPC 消息");
        }
    }
}

/// worker 断开时把 `running` 任务排回队列，避免"进程没了但任务还在跑"。
///
/// 返回被回收的任务数。已经结束的任务不受影响。
pub async fn requeue_on_disconnect(state: &AppState, reason: &str) -> usize {
    let ids: Vec<String> =
        sqlx::query_scalar("SELECT id FROM tasks WHERE state = 'running' AND deleted_at IS NULL")
            .fetch_all(&state.pool)
            .await
            .unwrap_or_default();

    let mut count = 0;
    for id in ids {
        let result = sqlx::query(
            "UPDATE tasks SET state = 'queued', retry_count = retry_count + 1, updated_at = ? \
             WHERE id = ? AND state = 'running' AND deleted_at IS NULL",
        )
        .bind(now_ms())
        .bind(&id)
        .execute(&state.pool)
        .await;

        if matches!(result, Ok(ref outcome) if outcome.rows_affected() > 0) {
            count += 1;
            // 任务排回队列等于重新开始，旧任务的用量不该继续占着预算。
            state.model_bridge.forget(&id);
            audit::record(
                &state.pool,
                &AuditEntry::new(&id, "system", "task.requeued", "ok")
                    .target(&id)
                    .detail(serde_json::json!({ "reason": reason })),
            )
            .await;
        }
    }

    count
}

async fn apply_plan(state: &AppState, task_id: &str, steps: &[StepSpec]) {
    let names: Vec<String> = steps.iter().map(|step| step.name.clone()).collect();

    if let Err(err) = task::replace_plan_named(&state.pool, task_id, &names).await {
        tracing::warn!(%err, %task_id, "写入计划失败");
        return;
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(task_id, "worker", "plan.created", "ok")
            .target(task_id)
            .detail(serde_json::json!({ "steps": names })),
    )
    .await;
}

async fn apply_approval_required(
    state: &AppState,
    task_id: &str,
    action: &str,
    target: Option<String>,
    impact: Option<String>,
) {
    if let Err(err) = task::transition(&state.pool, task_id, TaskState::NeedsApproval, None).await {
        tracing::warn!(%err, %task_id, "审批请求到达时任务不在可挂起状态，忽略");
        return;
    }

    let mut request = approval::NewApproval::task(task_id, action, state.config.approval_ttl_ms);
    if let Some(target) = target.as_deref() {
        request = request.with_target(target);
    }
    if let Some(impact) = impact.as_deref() {
        request = request.with_impact(impact);
    }

    match approval::create(&state.pool, request).await {
        Ok(approval) => {
            tracing::info!(task_id, approval_id = %approval.id, "任务等待审批");
            audit::record(
                &state.pool,
                &AuditEntry::new(task_id, "worker", "approval.requested", "ok")
                    .target(&approval.id)
                    .detail(serde_json::json!({ "action": action })),
            )
            .await;
        }
        Err(err) => {
            tracing::error!(%err, %task_id, "创建审批失败，任务转失败");
            let error = ApiError::new(
                ErrorCode::InternalError,
                "approval creation failed",
                "任务执行中断，请重试",
            );
            let _ = task::transition(&state.pool, task_id, TaskState::Failed, Some(&error)).await;
        }
    }
}

/// 工具级审批：把一次"工具调用前"的请求变成一张 `scope=tool` 的审批卡。
///
/// 与任务级审批共用 `needs_approval` 状态——对用户来说都是"它在等你"，
/// 没必要为了粒度差异再造一个状态。
#[allow(clippy::too_many_arguments)]
async fn apply_tool_approval_required(
    state: &AppState,
    task_id: &str,
    call_id: &str,
    provider: &str,
    tool: &str,
    risk: &str,
    digest: &str,
    rules: &[String],
) {
    let risk = RiskLevel::parse(risk).unwrap_or(RiskLevel::IrreversibleWrite);
    let ttl_ms = state.config.code.tool_approval.ttl_ms;

    // 执行授权是审批的缓存层：命中就直接放行，**不建卡、不挂起任务**。
    // 顺序很重要——必须在"查 pending"之前，否则一个更早的待决卡会让本次命中
    // 被当成"重复建卡"驳回，等于授权在最需要它的时候失效。
    match crate::grants::find_hit(&state.pool, task_id, tool, risk, now_ms()).await {
        Ok(Some(grant)) => {
            audit::record(
                &state.pool,
                &AuditEntry::new(task_id, "worker", "approval.granted_by_grant", "ok")
                    .target(call_id)
                    .detail(serde_json::json!({
                        "grant_id": grant.id,
                        "tool": tool,
                        "risk": risk.as_str(),
                        "task_id": task_id,
                        "call_id": call_id,
                        "hit_count": grant.hit_count,
                    })),
            )
            .await;
            tracing::info!(%task_id, grant_id = %grant.id, %tool, "命中执行授权，跳过询问");
            state.executor.tool_decision(
                crate::runner::TaskContext {
                    pool: state.pool.clone(),
                    task_id: task_id.to_string(),
                },
                call_id,
                ToolDecisionKind::Approve,
                // 同时让 worker 在本任务内也记住：少一次往返。
                true,
            );
            return;
        }
        Ok(None) => {}
        Err(err) => tracing::warn!(%err, %task_id, "查询执行授权失败，按未命中处理"),
    }

    // 串行不变量：同一任务同一时刻最多一条 pending。
    // 已有待决审批时立刻驳回这次调用（不让钩子白等 115 秒），并记 warn。
    match approval::pending_for_task(&state.pool, task_id).await {
        Ok(Some(existing)) => {
            tracing::warn!(
                %task_id, existing = %existing.id, %call_id,
                "已有待决审批，拒绝为同任务的另一次工具调用建卡"
            );
            audit::record(
                &state.pool,
                &AuditEntry::new(task_id, "worker", "approval.rejected", "error")
                    .target(call_id)
                    .detail(serde_json::json!({
                        "reason": "pending_approval_exists",
                        "existing": existing.id,
                        "tool": tool,
                        "call_id": call_id,
                    })),
            )
            .await;
            state.executor.tool_decision(
                crate::runner::TaskContext {
                    pool: state.pool.clone(),
                    task_id: task_id.to_string(),
                },
                call_id,
                ToolDecisionKind::Reject,
                false,
            );
            return;
        }
        Ok(None) => {}
        Err(err) => {
            tracing::error!(%err, %task_id, "读取待决审批失败，按驳回处理");
            state.executor.tool_decision(
                crate::runner::TaskContext {
                    pool: state.pool.clone(),
                    task_id: task_id.to_string(),
                },
                call_id,
                ToolDecisionKind::Reject,
                false,
            );
            return;
        }
    }

    if let Err(err) = task::transition(&state.pool, task_id, TaskState::NeedsApproval, None).await {
        tracing::warn!(%err, %task_id, "工具审批请求到达时任务不在可挂起状态，驳回本次调用");
        state.executor.tool_decision(
            crate::runner::TaskContext {
                pool: state.pool.clone(),
                task_id: task_id.to_string(),
            },
            call_id,
            ToolDecisionKind::Reject,
            false,
        );
        return;
    }

    // 只有「帮我审批」才提供"本任务内不再询问"：请求审批档必须逐条问。
    let rememberable = match task::load_input(&state.pool, task_id).await {
        Ok(input) => {
            task::normalize_approval(input.as_ref()) == "auto" && protocol::rememberable_for(rules)
        }
        Err(err) => {
            tracing::warn!(%err, %task_id, "读取任务输入失败，本次不提供「记住」选项");
            false
        }
    };

    let request =
        approval::NewApproval::tool(task_id, call_id, tool, risk, digest, rememberable, ttl_ms);

    match approval::create(&state.pool, request).await {
        Ok(created) => {
            tracing::info!(
                %task_id, approval_id = %created.id, %call_id, %tool, ?risk,
                "工具调用等待人工放行"
            );
            audit::record(
                &state.pool,
                &AuditEntry::new(task_id, "worker", "approval.requested", "ok")
                    .target(&created.id)
                    .detail(serde_json::json!({
                        "scope": "tool",
                        "call_id": call_id,
                        "provider": provider,
                        "tool": tool,
                        "risk": risk.as_str(),
                        "rules": rules,
                    })),
            )
            .await;
        }
        Err(err) => {
            // 建卡失败不能放行：立刻驳回这次调用，任务继续（CLI 会看到工具失败）。
            tracing::error!(%err, %task_id, "创建工具审批失败，驳回本次调用");
            state.executor.tool_decision(
                crate::runner::TaskContext {
                    pool: state.pool.clone(),
                    task_id: task_id.to_string(),
                },
                call_id,
                ToolDecisionKind::Reject,
                false,
            );
        }
    }
}

async fn apply_artifact(
    state: &AppState,
    task_id: &str,
    kind: &str,
    size: i64,
    mime: Option<&str>,
    content: &str,
) {
    // 按 kind 去重：worker 重连重放事件时不应产生重复产物。
    let existing: Option<String> =
        sqlx::query_scalar("SELECT id FROM artifacts WHERE task_id = ? AND kind = ?")
            .bind(task_id)
            .bind(kind)
            .fetch_optional(&state.pool)
            .await
            .unwrap_or(None);

    if existing.is_some() {
        return;
    }

    // 事件里声明的 size 只用于日志对照：落盘后以实际字节数为准，
    // 否则"记录说 100 字节、文件只有 80 字节"这种不一致会一直藏着。
    let store = crate::artifact_store::ArtifactStore::new(state.config.artifacts_dir());
    match task::add_artifact(&state.pool, &store, task_id, kind, mime, content).await {
        Ok(artifact) => {
            if artifact.size != size {
                tracing::debug!(
                    %task_id,
                    declared = size,
                    actual = artifact.size,
                    "产物字节数与事件声明不一致，以实际写入为准"
                );
            }
            audit::record(
                &state.pool,
                &AuditEntry::new(task_id, "worker", "artifact.created", "ok")
                    .target(&artifact.id)
                    .detail(serde_json::json!({ "kind": kind, "size": artifact.size })),
            )
            .await;
        }
        // 写盘失败不阻断任务：让后续 `outputs` 校验判 `output_missing`，
        // 语义与"worker 没产出"一致，不需要新增错误码。
        Err(err) => tracing::warn!(%err, %task_id, "写入产物失败"),
    }
}

/// worker 报告失败。
///
/// 任务已经被取消/拒绝/判过期时，worker 收尾阶段的失败上报属于正常竞态：
/// 记 debug 就够了，否则每次取消都会在日志里留下一条看起来像故障的 warn。
async fn apply_failed(
    state: &AppState,
    task_id: &str,
    code: String,
    hint: String,
    retryable: bool,
) {
    let error = ApiError {
        code: ErrorCode::parse(&code).unwrap_or(ErrorCode::InternalError),
        message: code,
        retryable,
        hint,
    };

    if let Some(task) = load_task(state, task_id).await {
        if task.state.is_terminal() {
            tracing::debug!(
                %task_id,
                state = ?task.state,
                "任务已结束，忽略 worker 的失败上报"
            );
            // 预算与令牌仍然随终态释放：人工重试应当是一次新的额度。
            state.model_bridge.forget(task_id);
            if let Some(proxy) = &state.code_proxy {
                proxy.forget(task_id);
            }
            return;
        }
    }

    if let Err(err) = task::transition(&state.pool, task_id, TaskState::Failed, Some(&error)).await
    {
        tracing::warn!(%err, %task_id, "worker 报告失败，但任务状态不允许转 failed");
    }
    audit::record(
        &state.pool,
        &AuditEntry::new(task_id, "worker", "task.failed", "error")
            .target(task_id)
            .detail(serde_json::json!({ "code": error.code.as_str() })),
    )
    .await;
    state.model_bridge.forget(task_id);
    settle_steps(&state.pool, task_id, false).await;
}

async fn apply_finished(state: &AppState, task_id: &str, summary: &str) {
    let Some(task) = load_task(state, task_id).await else {
        return;
    };

    // 已经结束的任务收到重复 finished：忽略，不覆盖终态。
    if task.state.is_terminal() {
        tracing::debug!(%task_id, "任务已结束，忽略重复的完成事件");
        return;
    }

    match validate_outputs(state, &task).await {
        Ok(()) => {
            if let Err(err) =
                task::transition(&state.pool, task_id, TaskState::Succeeded, None).await
            {
                tracing::warn!(%err, %task_id, "任务无法转为成功");
                return;
            }
            settle_steps(&state.pool, task_id, true).await;
            // 任务成功后投递抽取：产物在 task_steps 里，是可靠的原文来源。
            state
                .memory
                .submit_extract(crate::memory::extract::ExtractJob {
                    batch_id: crate::ids::new_id("bat"),
                    trace_id: task_id.to_string(),
                    source: crate::memory::extract::ExtractSource::Task {
                        task_id: task_id.to_string(),
                    },
                });
            audit::record(
                &state.pool,
                &AuditEntry::new(task_id, "worker", "task.finished", "ok")
                    .target(task_id)
                    .detail(serde_json::json!({ "summary": truncate(summary, 200) })),
            )
            .await;
            state.model_bridge.forget(task_id);
            // 令牌与内存用量随任务结束一起回收：明细已在审计表里。
            if let Some(proxy) = &state.code_proxy {
                proxy.forget(task_id);
            }
        }
        Err(missing) => {
            tracing::warn!(%task_id, missing = ?missing, "产物不满足 skill 声明的 outputs");
            let error = ApiError::new(
                ErrorCode::OutputMissing,
                format!("missing outputs: {}", missing.join(",")),
                "任务产出不完整，已结束；可重试或修改参数后重发",
            );
            let _ = task::transition(&state.pool, task_id, TaskState::Failed, Some(&error)).await;
            settle_steps(&state.pool, task_id, false).await;
            state.model_bridge.forget(task_id);
            if let Some(proxy) = &state.code_proxy {
                proxy.forget(task_id);
            }
        }
    }
}

/// 步骤收尾。
///
/// IPC 里没有"步骤完成"这类消息，任务终态时按结果统一落定；否则详情页的步骤会
/// 永远停在"进行中"——这个显示 bug 在编码任务之前就存在，只是没人盯着看。
///
/// 只要 `pool` 就够：代理判预算失败时也要收尾（它拿不到 `AppState`），
/// 这里就别再依赖整个状态对象。
pub(crate) async fn settle_steps(pool: &SqlitePool, task_id: &str, ok: bool) {
    let Ok(Some(task)) = task::get(pool, task_id).await else {
        return;
    };

    for step in task.plan {
        let next = match step.state {
            // 已有结论的步骤不覆盖。
            PlanStepState::Done | PlanStepState::Failed | PlanStepState::Skipped => continue,
            // 失败的：只把"跑到一半"的那一步标失败，没开始的保持未开始。
            PlanStepState::Running => {
                if ok {
                    PlanStepState::Done
                } else {
                    PlanStepState::Failed
                }
            }
            PlanStepState::Pending => {
                if ok {
                    PlanStepState::Done
                } else {
                    continue;
                }
            }
        };

        let _ = task::set_step_state(pool, task_id, step.seq, next).await;
    }
}

/// 产物是否覆盖 skill 声明的 `outputs`。未声明时视为通过。
async fn validate_outputs(state: &AppState, task: &protocol::Task) -> Result<(), Vec<String>> {
    let manifest = {
        let registry = state
            .skills
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry
            .iter()
            .find(|skill| Some(&skill.name) == task.skill.as_ref())
            .cloned()
    };

    let Some(manifest) = manifest else {
        // 技能未知（worker 未上报或已被禁用）：不能判定完成。
        return Err(vec!["skill_unknown".to_string()]);
    };

    if manifest.outputs.is_empty() {
        return Ok(());
    }

    let have: HashSet<&str> = task
        .artifacts
        .iter()
        .map(|artifact| artifact.kind.as_str())
        .collect();

    let missing: Vec<String> = manifest
        .outputs
        .iter()
        .filter(|output| !have.contains(output.as_str()))
        .cloned()
        .collect();

    if missing.is_empty() {
        Ok(())
    } else {
        Err(missing)
    }
}

async fn load_task(state: &AppState, task_id: &str) -> Option<protocol::Task> {
    match task::get(&state.pool, task_id).await {
        Ok(task) => task,
        Err(err) => {
            tracing::warn!(%err, %task_id, "读取任务失败");
            None
        }
    }
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    text.chars().take(max).collect::<String>() + "…"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_marks_cut() {
        assert_eq!(truncate("abcdef", 3), "abc…");
        assert_eq!(truncate("abc", 3), "abc");
    }
}
