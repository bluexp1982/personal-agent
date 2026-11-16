//! 把任务下发给 `jarvis-worker` 的执行器。
//!
//! 与 M3 的 `SimulatedExecutor` 实现同一个 trait，因此路由、状态机、审批都不需要改。
//! 差异只有一处：执行发生在另一个进程里，服务端只负责下发命令与应用事件。

use std::sync::{Arc, RwLock};

use protocol::{ApiError, ErrorCode, IpcMessage, SkillManifest, TaskState, ToolDecisionKind};

use super::supervisor::WorkerHandle;
use crate::code::{available_providers, count_repo_files, router};
use crate::code_proxy::CodeProxy;
use crate::config::Config;
use crate::runner::{TaskContext, TaskExecutor};
use crate::task;

#[derive(Debug, Clone)]
pub struct WorkerExecutor {
    handle: WorkerHandle,
    /// 编码能力未启用时为 `None`，此时编码任务直接判不可用。
    code_proxy: Option<Arc<CodeProxy>>,
    /// worker 上报的技能清单：用来判断"这个任务要不要代理令牌"。
    skills: Arc<RwLock<Vec<SkillManifest>>>,
    /// 路由需要读 `code.providers` / `code.routing`，它们是启动期常量。
    config: Arc<Config>,
}

impl WorkerExecutor {
    pub fn new(
        handle: WorkerHandle,
        code_proxy: Option<Arc<CodeProxy>>,
        skills: Arc<RwLock<Vec<SkillManifest>>>,
        config: Arc<Config>,
    ) -> Self {
        Self {
            handle,
            code_proxy,
            skills,
            config,
        }
    }

    /// 该任务是否需要编码代理令牌。
    fn needs_code_token(&self, skill: Option<&str>) -> bool {
        let Some(skill) = skill else {
            return false;
        };
        let registry = self
            .skills
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.iter().any(|manifest| {
            manifest.name == skill
                && manifest
                    .required_tools
                    .iter()
                    .any(|tool| tool == "code.exec")
        })
    }

    /// 按任务形态选 provider 与模型档位，并落一条 `code.route` 审计。
    ///
    /// 失败返回 `(错误码, 中文提示)`：档位写错是用户输入问题，没有可用 CLI 是环境问题，
    /// 两者要给不同的错误码，客户端才能显示"改一下"还是"装一个"。
    async fn route(
        &self,
        pool: &sqlx::SqlitePool,
        task_id: &str,
        input: &serde_json::Value,
    ) -> Result<router::RouteDecision, (&'static str, String)> {
        let instruction = input
            .get("instruction")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        let file_count = match input
            .get("repo")
            .and_then(serde_json::Value::as_str)
            .map(std::path::Path::new)
        {
            Some(repo) => count_repo_files(repo).await,
            None => None,
        };

        let request = router::RouteRequest {
            requested_provider: input.get("provider").and_then(serde_json::Value::as_str),
            requested_tier: input.get("model_tier").and_then(serde_json::Value::as_str),
            instruction_chars: instruction.chars().count(),
            file_count,
            instruction,
        };

        let decision = router::route(
            &request,
            &self.config.code.routing,
            &self.config.code.provider,
            &available_providers(&self.config),
            &self.config.code_tier_model("fast"),
            &self.config.code_tier_model("strong"),
        )
        .map_err(|err| (err.code(), err.to_string()))?;

        crate::audit::record(
            pool,
            &crate::audit::AuditEntry::new(task_id, "service", "code.route", "ok")
                .target(&decision.provider)
                .detail(serde_json::json!({
                    "provider": decision.provider,
                    "model": decision.model,
                    "tier": decision.tier,
                    "reason": decision.reason,
                    "file_count": file_count,
                    "instruction_chars": request.instruction_chars,
                })),
        )
        .await;
        Ok(decision)
    }

    async fn start(&self, context: TaskContext) {
        let pool = &context.pool;
        let task_id = context.task_id.as_str();

        let task = match task::get(pool, task_id).await {
            Ok(Some(task)) => task,
            Ok(None) => {
                tracing::warn!(task_id, "任务不存在，跳过下发");
                return;
            }
            Err(err) => {
                tracing::error!(%err, task_id, "读取任务失败，无法下发");
                return;
            }
        };

        if !self.handle.is_connected() {
            fail_with_worker_error(pool, task_id, "worker 未连接").await;
            return;
        }

        let input = task::load_input(pool, task_id)
            .await
            .ok()
            .flatten()
            .unwrap_or_else(|| serde_json::json!({}));

        let is_code = self.needs_code_token(task.skill.as_deref());

        // 编码任务必须带上一次性令牌：没有令牌，worker 会立刻判 `code_unavailable`。
        let token = if is_code {
            match self
                .code_proxy
                .as_ref()
                .and_then(|proxy| proxy.mint(task_id))
            {
                Some(token) => Some(token),
                None => {
                    fail_with_code_error(
                        pool,
                        task_id,
                        "code_unavailable",
                        "编码能力不可用：代理未启用或缺少模型密钥",
                        "编码任务暂不可用，请检查 code 配置与模型密钥",
                    )
                    .await;
                    return;
                }
            }
        } else {
            None
        };

        // 路由在 service 侧算完随 `Start` 下发：worker 不读配置，也不自己挑 CLI。
        let route = if is_code {
            match self.route(pool, task_id, &input).await {
                Ok(decision) => Some(decision),
                Err((code, hint)) => {
                    fail_with_code_error(pool, task_id, code, &hint, &hint).await;
                    return;
                }
            }
        } else {
            None
        };

        // 先转 running 再下发：worker 的事件以"任务已在运行"为前提。
        if let Err(err) = task::transition(pool, task_id, TaskState::Running, None).await {
            tracing::warn!(%err, task_id, "任务无法进入 running，跳过下发");
            return;
        }

        // `bin` 只在该 provider 配了覆盖路径时下发；否则 worker 走 PATH。
        let bin = route
            .as_ref()
            .and_then(|decision| self.config.code_provider_bin(&decision.provider))
            .map(|path| path.to_string_lossy().into_owned());

        let sent = self
            .handle
            .send(IpcMessage::Start {
                task_id: task.id.clone(),
                task_type: task.task_type.clone(),
                skill: task.skill.clone(),
                input,
                token,
                provider: route.as_ref().map(|decision| decision.provider.clone()),
                model: route.as_ref().map(|decision| decision.model.clone()),
                bin,
                route_reason: route.as_ref().map(|decision| decision.reason.clone()),
            })
            .await;

        if !sent {
            fail_with_worker_error(pool, task_id, "下发命令失败").await;
        }
    }

    /// 通知 worker 停手。调用方必须已经把任务落成终态。
    ///
    /// worker 侧：正在跑 CLI 的会 SIGTERM 进程组；停在审批等待的会立刻返回并释放并发位；
    /// 还没开始的会记进"已取消"集合，Start 到达时直接忽略。
    async fn send_cancel(&self, context: TaskContext) {
        let task_id = context.task_id;

        if !self.handle.is_connected() {
            // 不补发也不报错：重启后的 worker 不会捡起旧任务，服务端有悬空回收兜底。
            tracing::debug!(%task_id, "worker 未连接，取消通知跳过");
            return;
        }

        if !self
            .handle
            .send(IpcMessage::Cancel {
                task_id: task_id.clone(),
            })
            .await
        {
            tracing::warn!(%task_id, "取消通知发送失败，worker 里的任务可能仍在运行");
        }
    }

    async fn resume(&self, context: TaskContext) {
        let pool = &context.pool;
        let task_id = context.task_id.as_str();

        let state = match task::get(pool, task_id).await {
            Ok(Some(task)) => task.state,
            Ok(None) => return,
            Err(err) => {
                tracing::warn!(%err, task_id, "读取任务失败，无法恢复");
                return;
            }
        };

        // 只有仍在等待或运行中的任务才需要恢复；已取消/已结束的直接忽略。
        if !matches!(state, TaskState::NeedsApproval | TaskState::Running) {
            tracing::debug!(?state, task_id, "任务状态不需要恢复，跳过");
            return;
        }

        if !self.handle.is_connected() {
            fail_with_worker_error(pool, task_id, "恢复时 worker 未连接").await;
            return;
        }

        if !self
            .handle
            .send(IpcMessage::Resume {
                task_id: task_id.to_string(),
                call_id: None,
                decision: None,
                remember: None,
            })
            .await
        {
            fail_with_worker_error(pool, task_id, "恢复命令发送失败").await;
        }
    }
}

impl TaskExecutor for WorkerExecutor {
    fn spawn(&self, context: TaskContext) {
        let executor = self.clone();
        tokio::spawn(async move {
            executor.start(context).await;
        });
    }

    fn resume(&self, context: TaskContext) {
        let executor = self.clone();
        tokio::spawn(async move {
            executor.resume(context).await;
        });
    }

    /// 把工具级裁决转成 `Resume{call_id, decision}`：worker 按 `call_id` 唤醒钩子。
    ///
    /// 这里**不看任务状态**：工具级审批期间任务可能刚被别的事件改成 running/failed，
    /// 裁决本身是"对某一次调用的回答"，与任务状态机无关；唤醒失败只记日志。
    fn tool_decision(
        &self,
        context: TaskContext,
        call_id: &str,
        decision: ToolDecisionKind,
        remember: bool,
    ) {
        let handle = self.handle.clone();
        let task_id = context.task_id.clone();
        let call_id = call_id.to_string();
        tokio::spawn(async move {
            if !handle
                .send(IpcMessage::Resume {
                    task_id: task_id.clone(),
                    call_id: Some(call_id),
                    decision: Some(decision),
                    // 不勾选时不发这个字段：线缆形状与升级前一致，便于排查。
                    remember: remember.then_some(true),
                })
                .await
            {
                tracing::warn!(task_id, "工具级裁决下发失败：worker 未连接");
            }
        });
    }

    fn cancel(&self, context: TaskContext) {
        let executor = self.clone();
        tokio::spawn(async move {
            executor.send_cancel(context).await;
        });
    }
}

/// 编码能力不可用：直接落 failed，不把任务交给 worker 去撞。
async fn fail_with_code_error(
    pool: &sqlx::SqlitePool,
    task_id: &str,
    code: &str,
    message: &str,
    hint: &str,
) {
    let error = ApiError::new(
        ErrorCode::parse(code).unwrap_or(ErrorCode::InternalError),
        message,
        hint,
    );

    let _ = task::transition(pool, task_id, TaskState::Running, None).await;
    if let Err(err) = task::transition(pool, task_id, TaskState::Failed, Some(&error)).await {
        tracing::warn!(%err, task_id, "标记编码任务失败时状态不允许");
    }
}

/// 执行进程侧的失败统一落到 failed，并标记为可重试。
async fn fail_with_worker_error(pool: &sqlx::SqlitePool, task_id: &str, reason: &str) {
    let error = ApiError::new(
        ErrorCode::WorkerUnavailable,
        reason,
        "执行进程未就绪，任务已停止；可稍后重试",
    );

    // queued → failed 不是合法转移，先转 running 表示"尝试过"。
    let _ = task::transition(pool, task_id, TaskState::Running, None).await;
    if let Err(err) = task::transition(pool, task_id, TaskState::Failed, Some(&error)).await {
        tracing::warn!(%err, task_id, "标记任务失败时状态不允许");
    }
}
