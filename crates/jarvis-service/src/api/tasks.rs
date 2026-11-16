//! 任务端点：创建（显式触发）、查询、取消、审批、重试。

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use protocol::{
    ApprovalScope, ApproveAction, ApproveRequest, ErrorCode, PrepareTaskRequest, PreparedTaskInput,
    Project, Task, TaskCreateRequest, TaskPage, TaskState, ToolDecisionKind,
};
use serde::Deserialize;

/// 编码任务技能名。判定"是不是编码任务"以能力声明为准，这个常量只是兜底。
const CODE_SKILL: &str = "code-task";

/// 编码任务的能力名。带它的技能不走通用参数解析。
const CODE_TOOL: &str = "code.exec";

/// 需求长度上限，与 worker 侧保持一致。
const MAX_CODE_INSTRUCTION_CHARS: usize = 8_000;

use super::error::ApiRejection;
use super::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::runner::TaskContext;
use crate::state::AppState;
use crate::{approval, task};

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub state: Option<String>,
    pub project_id: Option<String>,
    /// 会话维度过滤：回答里的建议卡要按 `conversation_id` 拉"这次建议有没有被派出去"。
    pub conversation_id: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<TaskPage>, ApiRejection> {
    let filter = match query.state.as_deref() {
        Some(raw) => Some(TaskState::parse(raw).ok_or_else(|| {
            ApiRejection::new(
                protocol::ErrorCode::InvalidRequest,
                "unknown task state",
                "任务状态取值不合法",
            )
        })?),
        None => None,
    };

    let (items, next) = task::list(
        &state.pool,
        filter,
        query.project_id.as_deref(),
        query.conversation_id.as_deref(),
        query.cursor.as_deref(),
        query.limit.unwrap_or(20),
    )
    .await?;

    Ok(Json(TaskPage::from_items(items, next)))
}

/// 创建任务。返回 201 表示新建，200 表示幂等键命中已有任务。
pub async fn create(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(request): ApiJson<TaskCreateRequest>,
) -> Result<(StatusCode, Json<Task>), ApiRejection> {
    // 任务的能力边界由所属会话的项目决定：模式只认库里的记录，不接受客户端传参。
    // 无归属直聊（`None`）放行普通任务，但编码任务仍然必须落在项目里。
    let project = project_of_conversation(&state, &request.conversation_id).await?;

    // 编码任务的额外检查必须发生在建任务之前：用户点"派这件事"的一瞬间
    // 就该知道能不能跑，而不是等 CLI 启动失败才看到错误。
    let mut request = request;
    if is_code_task(&state, &request) {
        let Some(project) = project.as_ref() else {
            return Err(ApiRejection::new(
                ErrorCode::InvalidRequest,
                "coding task needs a project",
                "编码任务需要一个项目：它要选仓库、执行方式与审批档，无归属直聊里没有这些边界。请在项目里新建会话后再派",
            ));
        };
        validate_code_task(&state, project, &request)?;
        // 仓库路径由项目提供，不信客户端传的 `input.repo`：项目就是这次任务的边界。
        inject_repo(&mut request, project);
    }

    let (task, created) = task::create(&state.pool, &request, &device.device_id).await?;

    if created {
        state.executor.spawn(TaskContext {
            pool: state.pool.clone(),
            task_id: task.id.clone(),
        });
    }

    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };

    Ok((status, Json(task)))
}

/// 派任务前的参数解析。
///
/// 只服务会话里的 `@技能`：用户说的是人话，任务要的是结构化 `input`。
/// 任务页有自己的表单，不需要这一层。
///
/// **永远返回可用结果**：没有模型或解析失败时只带原文（见 [`crate::task_prepare`]），
/// 用 `missing` 说明还差哪些字段，由界面提示。这里不因为解析不出参数就拒绝派任务。
pub async fn prepare(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(request): ApiJson<PrepareTaskRequest>,
) -> Result<Json<PreparedTaskInput>, ApiRejection> {
    let text = request.text.trim();
    if text.is_empty() {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "empty text",
            "先说一句要办什么，再派任务",
        ));
    }

    // 先查库、再查执行进程上报的清单：插件刚装好时 worker 可能还没重载，
    // 这期间技能只存在于库里。只读 registry 会让用户点了刚装的技能却被
    // 告知"技能不可用"——而它明明就在设置页里躺着。
    let from_store = crate::plugin::store::enabled_manifest(&state.pool, &request.skill)
        .await
        .unwrap_or_else(|err| {
            tracing::warn!(%err, "读取插件技能清单失败，回退到执行进程上报");
            None
        });

    let manifest = from_store.or_else(|| {
        let registry = state
            .skills
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry
            .iter()
            .find(|item| item.name == request.skill)
            .cloned()
    });

    let Some(manifest) = manifest else {
        return Err(ApiRejection::new(
            ErrorCode::SkillUnknown,
            "skill not found",
            format!("技能 {} 不可用；确认它已安装并启用", request.skill),
        ));
    };

    // 编码任务要的是「任务描述 + 执行方式 + 审批档」，通用解析给不出，
    // 派出来只会缺参数。让它走任务页的专用对话框。
    if manifest.required_tools.iter().any(|tool| tool == CODE_TOOL) {
        return Err(ApiRejection::new(
            ErrorCode::SkillUnknown,
            "coding task needs its own form",
            "编码任务请在任务页派：它要选仓库、执行方式与审批档",
        ));
    }

    // 插件技能还要过「已启用且可运行」这一关，与对话建议卡同源：
    // 停用的插件不该还能从会话里派出任务。
    let source = if manifest.source.trim().is_empty() {
        protocol::BUILTIN_SOURCE
    } else {
        manifest.source.as_str()
    };
    if source != protocol::BUILTIN_SOURCE {
        let runnable = crate::plugin::store::enabled_runnable_skill_names(&state.pool)
            .await
            .unwrap_or_default();
        if !runnable.iter().any(|name| name == &manifest.name) {
            return Err(ApiRejection::new(
                ErrorCode::SkillUnknown,
                "plugin disabled or unsupported",
                format!("技能 {} 所属插件已停用或不可运行", manifest.name),
            ));
        }
    }

    let completion = state.completion_model();
    let prepared = crate::task_prepare::prepare(completion.as_deref(), &manifest, text).await;

    audit::record(
        &state.pool,
        &AuditEntry::new(
            &request.conversation_id,
            &device.device_id,
            "task.prepare",
            "ok",
        )
        .target(&manifest.name)
        // 只记形态，**不记用户原话**：那句话可能含个人信息。
        .detail(serde_json::json!({
            "skill": manifest.name,
            "source": prepared.source.as_str(),
            "missing": prepared.missing,
            "chars": text.chars().count(),
        })),
    )
    .await;

    Ok(Json(prepared))
}

pub async fn detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Task>, ApiRejection> {
    let mut task = task::get(&state.pool, &id)
        .await?
        .ok_or_else(|| ApiRejection::from(crate::task::TaskError::NotFound))?;

    // 现场只在详情里读盘填充：列表页不显示它，也就不该为此付 N 次 IO。
    task.worktree = crate::worktree::info_of(&state.config, &id);

    Ok(Json(task))
}

/// 清理编码任务的现场（隔离工作树目录）。
///
/// 只删数据目录里的这棵克隆；**原仓库里已合并的 `agent/{task_id}` 分支不碰**——
/// 那是用户仓库的历史，删它属于改用户的仓库。
///
/// 三种情况拒绝：任务不存在（404）、任务还没结束（409）、worker 仍在收尾（409）。
/// 目录本来就不存在时返回 204：清理是幂等的，客户端重试不该报错。
pub async fn clean_worktree(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    let task = task::get(&state.pool, &id)
        .await?
        .ok_or_else(|| ApiRejection::from(crate::task::TaskError::NotFound))?;

    if !task.state.is_terminal() {
        return Err(ApiRejection::new(
            ErrorCode::Conflict,
            "task is still running",
            "任务还没结束：先取消并等它停下来，再清理现场",
        ));
    }

    // worker 心跳里的活跃列表：取消之后它要几百毫秒到几秒才会把任务摘掉，
    // 这个窗口里删目录会与还在退出的 CLI 抢同一个工作树。
    if state.worker.is_task_active(&id) {
        return Err(ApiRejection::new(
            ErrorCode::Conflict,
            "worktree is still in use",
            "worker 还在收尾（通常几秒），稍后重试清理",
        ));
    }

    let removed = crate::worktree::clean(&state.config, &id).await?;

    if removed {
        audit::record(
            &state.pool,
            &AuditEntry::new(&id, &device.device_id, "task.worktree_cleaned", "ok")
                .target(&id)
                .detail(serde_json::json!({
                    "path": state.config.code_worktree_dir().join(&id).display().to_string(),
                })),
        )
        .await;
    }

    Ok(StatusCode::NO_CONTENT)
}

/// 删除任务记录。未结束的任务由领域层返回 409，提示先取消。
///
/// 只删数据库行：产物文件与编码任务工作树按约定保留在数据目录。
pub async fn delete(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    task::delete(&state.pool, &id).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "task.deleted", "ok").target(&id),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn cancel(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<Json<Task>, ApiRejection> {
    task::cancel(&state.pool, &id, &device.device_id).await?;

    // 先落库再通知：状态立刻对客户端生效，执行侧随后停手。
    // 只改库不通知的话，worker 里的 CLI 会继续跑到超时（还会一直占着并发位）。
    state.executor.cancel(TaskContext {
        pool: state.pool.clone(),
        task_id: id.clone(),
    });
    // 令牌随之吊销：CLI 即使还在退出，也调不动模型了（取消 = 立刻停止计价）。
    revoke_code_token(&state, &id);

    let task = task::get(&state.pool, &id)
        .await?
        .ok_or_else(|| ApiRejection::from(crate::task::TaskError::NotFound))?;
    Ok(Json(task))
}

/// 用户在工具审批卡上勾了「记住」→ 建一条执行授权。
///
/// 失败只 warn：授权是"下次少问一次"的优化，不该让这一次已经批准的调用失败。
async fn create_grant_for_approval(
    state: &AppState,
    device: &AuthDevice,
    task_id: &str,
    record: &protocol::Approval,
    tool: &protocol::ApprovalTool,
    scope: Option<protocol::GrantScope>,
) {
    let scope = scope.unwrap_or(protocol::GrantScope::Task);
    let now = crate::clock::now_ms();
    let ttl = state.config.code.tool_approval.ttl_ms;

    let resolved = match crate::grants::resolve_scope(&state.pool, task_id, scope, ttl, now).await {
        Ok(resolved) => resolved,
        Err(err) => {
            tracing::warn!(%err, %task_id, "解析授权作用域失败，本次不建授权");
            return;
        }
    };

    let new = crate::grants::NewGrant {
        tool: &tool.name,
        risk: tool.risk,
        scope,
        approval_id: &record.id,
        device_id: Some(&device.device_id),
    };

    match crate::grants::create_resolved(&state.pool, new, resolved, now).await {
        Ok(grant) => {
            audit::record(
                &state.pool,
                &AuditEntry::new(
                    &device.device_id,
                    "approval",
                    "approval.grant_created",
                    "ok",
                )
                .target(&grant.id)
                .detail(serde_json::json!({
                    "tool": grant.tool,
                    "risk": grant.risk.as_str(),
                    "scope": grant.scope.as_str(),
                    "scope_id": grant.scope_id,
                    "approval_id": record.id,
                })),
            )
            .await;
        }
        Err(err) => {
            // 不可逆动作会走到这里（硬边界），按 warn 记录即可。
            tracing::warn!(%err, %task_id, "建执行授权失败");
        }
    }
}

/// 批准或拒绝待办审批。
///
/// 两种 scope 的语义不同（见 `api-spec/openapi.yaml` 的同名端点说明）：
/// - `task`（如 `merge_changes`）：批准继续合并；拒绝则取消任务并保留现场。
/// - `tool`（`code.tool_use`）：批准放行这一次调用；拒绝只是驳回这一步，
///   **任务继续跑**——CLI 会看到工具失败并自行调整，整任务作废是另一回事。
pub async fn approve(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<ApproveRequest>,
) -> Result<(StatusCode, Json<Task>), ApiRejection> {
    // 先读一次记录：`decide` 只回 (task_id, 决定)，这里还需要 scope 与 call_id。
    let record = approval::get(&state.pool, &request.approval_id).await?;
    let (task_id, decision) =
        approval::decide(&state.pool, &request.approval_id, request.decision).await?;

    if task_id != id {
        return Err(ApiRejection::new(
            protocol::ErrorCode::Conflict,
            "approval does not belong to this task",
            "该确认不属于当前任务，请刷新后重试",
        ));
    }

    let call_id = record.target.clone();
    match (record.scope, decision) {
        (ApprovalScope::Tool, protocol::ApprovalDecision::Approved) => {
            // 只放行这一次调用，任务回到 running 让 CLI 继续跑。
            task::transition(&state.pool, &id, TaskState::Running, None).await?;

            // 勾了「记住」才建授权；不可逆动作与不可记住的规则在 create_resolved 里被拒。
            if request.remember {
                if let Some(tool) = record.tool.as_ref().filter(|tool| tool.rememberable) {
                    create_grant_for_approval(
                        &state,
                        &device,
                        &id,
                        &record,
                        tool,
                        request.remember_scope,
                    )
                    .await;
                }
            }
            if let Some(call_id) = call_id.as_deref() {
                state.executor.tool_decision(
                    TaskContext {
                        pool: state.pool.clone(),
                        task_id: id.clone(),
                    },
                    call_id,
                    ToolDecisionKind::Approve,
                    request.remember,
                );
            } else {
                tracing::warn!(task_id = %id, "工具审批缺少 call_id，无法下发裁决");
            }
        }
        (ApprovalScope::Tool, protocol::ApprovalDecision::Rejected) => {
            // 驳回 != 取消任务：钩子回 deny，CLI 接着往下跑。
            task::transition(&state.pool, &id, TaskState::Running, None).await?;
            if let Some(call_id) = call_id.as_deref() {
                state.executor.tool_decision(
                    TaskContext {
                        pool: state.pool.clone(),
                        task_id: id.clone(),
                    },
                    call_id,
                    ToolDecisionKind::Reject,
                    false,
                );
            } else {
                tracing::warn!(task_id = %id, "工具审批缺少 call_id，按取消任务处理");
                cancel_task_after_reject(&state, &id).await?;
            }
        }
        (_, protocol::ApprovalDecision::Approved) => {
            // needs_approval → running，然后交给执行器继续跑完。
            task::transition(&state.pool, &id, TaskState::Running, None).await?;
            state.executor.resume(TaskContext {
                pool: state.pool.clone(),
                task_id: id.clone(),
            });
        }
        (_, protocol::ApprovalDecision::Rejected) => {
            cancel_task_after_reject(&state, &id).await?;
        }
        (_, other) => {
            tracing::warn!(?other, task_id = %id, "审批决定异常");
        }
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "approval.decided", "ok")
            .target(&request.approval_id)
            .detail(serde_json::json!({
                "decision": match request.decision { ApproveAction::Approve => "approve", ApproveAction::Reject => "reject" },
                "scope": record.scope.as_str(),
                "call_id": record.target,
                "tool": record.tool.as_ref().map(|tool| tool.name.clone()),
                "remember": request.remember,
            })),
    )
    .await;

    let task = task::get(&state.pool, &id)
        .await?
        .ok_or_else(|| ApiRejection::from(crate::task::TaskError::NotFound))?;
    Ok((StatusCode::ACCEPTED, Json(task)))
}

/// 重试失败或已取消的任务：重新排队并派给执行器。
pub async fn retry(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<(StatusCode, Json<Task>), ApiRejection> {
    let task = task::retry(&state.pool, &id, &device.device_id).await?;

    // 状态已经回到 queued，旧产物就不再代表这个任务的现状。
    if let Err(err) = task::clear_artifacts(&state.pool, &id, &state.config.artifacts_dir()).await {
        tracing::warn!(%err, task_id = %id, "清理旧产物失败，重试结果可能夹带上一次的产物");
    }

    state.executor.spawn(TaskContext {
        pool: state.pool.clone(),
        task_id: id,
    });

    Ok((StatusCode::ACCEPTED, Json(task)))
}

/// 任务级驳回：取消任务、通知执行器停手、吊销代理令牌。
async fn cancel_task_after_reject(state: &AppState, id: &str) -> Result<(), ApiRejection> {
    task::transition(&state.pool, id, TaskState::Canceled, None).await?;
    // 拒绝之后 worker 仍停在"等 Resume"上，不通知就会永久占住并发位。
    state.executor.cancel(TaskContext {
        pool: state.pool.clone(),
        task_id: id.to_string(),
    });
    revoke_code_token(state, id);
    Ok(())
}

/// 这个任务是不是编码任务。以技能声明的能力为准，技能名只作兜底。
/// 吊销某个任务的编码代理令牌（幂等；非编码任务没有令牌）。
fn revoke_code_token(state: &AppState, task_id: &str) {
    if let Some(proxy) = &state.code_proxy {
        proxy.forget(task_id);
    }
}

fn is_code_task(state: &AppState, request: &TaskCreateRequest) -> bool {
    let Some(skill) = request.skill.as_deref() else {
        return false;
    };
    if skill == CODE_SKILL {
        return true;
    }

    let registry = state
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

/// 会话所属的项目。任务的能力边界（尤其"能不能跑编码任务"）由它决定。
///
/// 返回 `None` 表示**无归属直聊**：会话没有项目（`project_id IS NULL`）。
/// 这是空态页"随时开聊"的正常形态，不是错误——这类会话可以派非编码任务，
/// 但没有文件读取与代码执行的边界（见 [`super::local_tool`] 的降级分支）。
///
/// 会话挂着一个**已被删除**的项目仍按 404 处理：那是用户需要知道的状态，
/// 不能悄悄降级成"无归属"，否则任务会在用户以为还在原项目时跑起来。
async fn project_of_conversation(
    state: &AppState,
    conversation_id: &str,
) -> Result<Option<Project>, ApiRejection> {
    let found: Option<Option<String>> = sqlx::query_scalar(
        "SELECT project_id FROM conversations WHERE id = ? AND deleted_at IS NULL",
    )
    .bind(conversation_id)
    .fetch_optional(&state.pool)
    .await?;

    let Some(project_id) = found else {
        return Err(ApiRejection::from(
            crate::task::TaskError::ConversationNotFound,
        ));
    };

    // 历史回填可能留下空串，与 NULL 同义，都当无归属。
    let Some(project_id) = project_id.filter(|id| !id.trim().is_empty()) else {
        return Ok(None);
    };

    match crate::project::get(&state.pool, &project_id).await? {
        Some(project) => Ok(Some(project)),
        None => Err(ApiRejection::new(
            ErrorCode::NotFound,
            "project not found",
            "会话所属项目不存在或已被删除：请换一个项目新建会话后再派任务",
        )),
    }
}

/// 编码任务的创建前检查：模式、能力、上游、需求长度。
///
/// 都在建任务之前拒绝，理由一致——**编码任务会改真实文件**，
/// 让它在参数不成立时先跑起来再失败，用户面对的是一棵已经建好的工作树和一句含糊的错误。
///
/// 仓库路径不在这里校验：它由项目提供（[`inject_repo`]），项目创建时已经验过
/// 「git 仓库根、有提交、非游离 HEAD、在 `code.allow_roots` 内」。
fn validate_code_task(
    state: &AppState,
    project: &Project,
    request: &TaskCreateRequest,
) -> Result<(), ApiRejection> {
    if !project.mode.allows_code_tasks() {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "code task requires a git project",
            "当前项目没有启用 Git 仓库，编码任务只能在 Git 项目里发起",
        ));
    }

    if !state.config.code.enabled {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "code capability is disabled",
            "编码能力未启用：请先在配置里打开 code.enabled",
        ));
    }

    let available = state
        .code_proxy
        .as_ref()
        .map(|proxy| proxy.has_upstream())
        .unwrap_or(false);
    if !available {
        return Err(ApiRejection::new(
            ErrorCode::CodeUnavailable,
            "code upstream is not configured",
            "编码任务缺少模型密钥：请设置 code.upstream.api_key_env 指向的环境变量",
        ));
    }

    let instruction = request
        .input
        .as_ref()
        .and_then(|value| value.get("instruction"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .unwrap_or_default();
    if instruction.is_empty() {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "input.instruction is required",
            "请写一句要改什么，再发起编码任务",
        ));
    }
    if instruction.chars().count() > MAX_CODE_INSTRUCTION_CHARS {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "instruction is too long",
            "需求过长（上限 8000 字）：请拆成多次任务",
        ));
    }

    Ok(())
}

/// 把仓库路径注入任务入参。
///
/// 客户端不传 repo（项目就是仓库），传了也会被覆盖：否则"项目边界"形同虚设。
/// 落库后重试沿用同一份 `input_json`，路径自然一致。
fn inject_repo(request: &mut TaskCreateRequest, project: &Project) {
    let mut map = match request.input.take() {
        Some(serde_json::Value::Object(map)) => map,
        _ => serde_json::Map::new(),
    };
    map.insert(
        "repo".to_string(),
        serde_json::Value::String(project.path.clone()),
    );
    request.input = Some(serde_json::Value::Object(map));
}
