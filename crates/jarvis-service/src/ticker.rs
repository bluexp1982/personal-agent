//! 后台定时任务：审批过期与悬空任务回收。
//!
//! 单进程服务里用 `tokio::time::interval` 足够；它随运行时退出而结束，
//! 不需要额外的取消令牌。扫描周期与任务超时都来自配置，测试可注入短周期。

use std::time::Duration;

use protocol::TaskState;

use crate::audit::{self, AuditEntry};
use crate::clock::now_ms;
use crate::runner::TaskContext;
use crate::state::AppState;
use crate::{approval, task};

/// 启动 ticker。返回的句柄可用于测试中显式 abort。
pub fn spawn(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let period = state.config.tick_interval_ms.max(100);
        let mut interval = tokio::time::interval(Duration::from_millis(period));

        loop {
            interval.tick().await;
            if let Err(err) = run_once(&state).await {
                // ticker 出错不退出：下一轮继续尝试，避免一次抖动导致过期审批永久悬挂。
                tracing::warn!(%err, "后台扫描失败");
            }
        }
    })
}

/// 执行一轮扫描。测试可直接调用，无需等待定时器。
pub async fn run_once(state: &AppState) -> Result<(), String> {
    run_once_at(state, now_ms()).await
}

/// 以指定"当前时间"执行一轮扫描。
///
/// 把时间作为参数而不是内部取 `now_ms()`：审批过期是纯时间比较，
/// 测试直接传一个"已经过期"的时刻就能断言结果，不必 sleep 等它真的过期。
/// 那些 sleep 在并行跑测试时正是偶发失败的来源。
pub async fn run_once_at(state: &AppState, now: i64) -> Result<(), String> {
    let expired = approval::expire_due(&state.pool, now)
        .await
        .map_err(|err| err.to_string())?;

    for (approval_id, task_id) in expired {
        // 先留一份记录：过期后要靠 scope/工具名区分"合并确认超时"与"某一步工具没等到人看"。
        let record = approval::get(&state.pool, &approval_id).await.ok();
        let error = approval::expired_error();
        if let Err(err) =
            task::transition(&state.pool, &task_id, TaskState::Failed, Some(&error)).await
        {
            // 任务可能已被取消或已结束：这不是错误，记录即可。
            tracing::warn!(%err, %task_id, %approval_id, "过期审批对应的任务未能转为失败");
            continue;
        }

        // 审批过期时 worker 还停在 `control.recv()` 上等 Resume：不通知的话
        // 它会永远占着编码任务的并发位（max_concurrent 默认 1，等于后续全排队）。
        state.executor.cancel(TaskContext {
            pool: state.pool.clone(),
            task_id: task_id.clone(),
        });
        // 过期之后不该继续消耗额度。
        if let Some(proxy) = &state.code_proxy {
            proxy.forget(&task_id);
        }

        audit::record(
            &state.pool,
            &AuditEntry::new(&task_id, "system", "approval.expired", "ok")
                .target(&task_id)
                .detail(serde_json::json!({
                    "approval_id": approval_id,
                    "scope": record.as_ref().map(|approval| approval.scope.as_str()),
                    "tool": record
                        .as_ref()
                        .and_then(|approval| approval.tool.as_ref())
                        .map(|tool| tool.name.clone()),
                })),
        )
        .await;
    }

    let cutoff = now - state.config.task_timeout_ms;
    let recovered = task::recover_stale_running(&state.pool, cutoff)
        .await
        .map_err(|err| err.to_string())?;

    if !recovered.is_empty() {
        // 回收只是把库里的状态改回 queued：worker 里那个执行实例可能还活着。
        // 先让它停手，否则用户重试时会出现"同一个 task 两份执行"同时改工作树。
        for task_id in &recovered {
            state.executor.cancel(TaskContext {
                pool: state.pool.clone(),
                task_id: task_id.clone(),
            });
            if let Some(proxy) = &state.code_proxy {
                proxy.forget(task_id);
            }
        }

        tracing::warn!(
            count = recovered.len(),
            "发现悬空 running 任务，已停手并转回 queued 等待重试"
        );
    }

    Ok(())
}
