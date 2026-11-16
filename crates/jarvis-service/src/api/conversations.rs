//! 会话与消息端点。
//!
//! `POST /api/conversations/{id}/messages` 是关键路径：
//! 落库用户消息 → 组装上下文 → 生成分片 → 先落库回答 → 逐条 `message.delta`
//! → 发 `message_completed`。客户端收到 completed 时，消息一定已可查询。

use std::convert::Infallible;
use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::{Extension, Json};
use futures_util::stream::{self, Stream, StreamExt};
use protocol::{
    Conversation, ConversationCreate, ConversationDetail, ConversationPage, ConversationUpdate,
    ErrorCode, MemoryCreateRequest, MemoryScope, MessagePage, MessageRole, ProjectMode,
    SendMessageRequest, StreamEvent, FINISH_ERROR, FINISH_STOP, FINISH_STOPPED,
};
use serde::Deserialize;

use super::error::ApiRejection;
use super::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::chat::{self, ChatLimits, ChatMessage, StopSignal, ToolSpec};
use crate::local_tools::media_gen::{GenerateMediaTool, MediaKind};
use crate::memory::digest::{Digest, DigestContext, DigestMode};
use crate::memory::explicit::ExplicitCommand;
use crate::memory::retrieve::RecallScope;
use crate::responder::PromptMessage;
use crate::state::{chat_stop_key, AppState};
use crate::tool_gateway::Source;
use crate::{conversation, ids, sse};

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub project_id: Option<String>,
    /// 只看无归属直聊（侧栏「对话」分组）：为真时忽略 `project_id`。
    ///
    /// 单独一个布尔量而不是"传空串"：`project_id` 的空值语义是"不筛选"，
    /// 两者混用会让按空串查询退化成返回全部会话。
    pub unassigned: Option<bool>,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct DetailQuery {
    pub recent: Option<u32>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<ConversationPage>, ApiRejection> {
    let (items, next) = conversation::list(
        &state.pool,
        query.project_id.as_deref(),
        query.unassigned.unwrap_or(false),
        query.cursor.as_deref(),
        query.limit.unwrap_or(20),
    )
    .await?;
    Ok(Json(ConversationPage::from_items(items, next)))
}

/// 新建会话。没给标题时是幂等的：该项目已有空白会话就复用它，返回 200。
pub async fn create(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(request): ApiJson<ConversationCreate>,
) -> Result<(StatusCode, Json<Conversation>), ApiRejection> {
    let outcome = conversation::open_or_create(&state.pool, &device.device_id, &request).await?;

    // 复用时没有发生创建，不该记 `conversation.created` 审计；
    // 200 与 201 的差别只在这里有意义——客户端两边拿到的都是会话本体。
    if outcome.reused {
        return Ok((StatusCode::OK, Json(outcome.conversation)));
    }

    let conversation = outcome.conversation;
    audit::record(
        &state.pool,
        &AuditEntry::new(
            &conversation.id,
            &device.device_id,
            "conversation.created",
            "ok",
        )
        .target(&conversation.id)
        .detail(serde_json::json!({ "mode": conversation.mode.as_str() })),
    )
    .await;

    Ok((StatusCode::CREATED, Json(conversation)))
}

pub async fn detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<DetailQuery>,
) -> Result<Json<ConversationDetail>, ApiRejection> {
    let detail = conversation::detail(&state.pool, &id, query.recent.unwrap_or(20))
        .await?
        .ok_or_else(|| ApiRejection::from(crate::conversation::ConversationError::NotFound))?;
    Ok(Json(detail))
}

/// 重命名会话。只改标题：归属项目与模式一经创建不可变。
///
/// 与项目改名不同，这里**不动 `updated_at`**（见 `conversation::rename`）：
/// 会话列表按它排序，改名不该把会话顶到最前。
pub async fn rename(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<ConversationUpdate>,
) -> Result<Json<Conversation>, ApiRejection> {
    let renamed = conversation::rename(&state.pool, &id, &request.title).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "conversation.renamed", "ok")
            .target(&id)
            .detail(serde_json::json!({ "title": renamed.title })),
    )
    .await;

    Ok(Json(renamed))
}

/// 删除会话。会话下还有**未结束**的任务时由领域层返回 409；
/// 已结束的任务随会话一起软删，级联条数记进审计明细。
pub async fn delete(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    // 证据的 `source_id` 是消息 id（不是会话 id），所以必须先采集再删：
    // 将来 `conversation::delete` 若改成硬删，这里也不会静默失效。
    let message_ids: Vec<(String,)> =
        sqlx::query_as("SELECT id FROM messages WHERE conversation_id = ?")
            .bind(&id)
            .fetch_all(&state.pool)
            .await?;

    let cascaded = conversation::delete(&state.pool, &id).await?;

    // 会话没了，挂在它上面的会话级授权也不该继续生效。
    if let Err(err) =
        crate::grants::revoke_by_scope(&state.pool, protocol::GrantScope::Session, &id).await
    {
        tracing::warn!(%err, conversation_id = %id, "撤销会话级执行授权失败");
    }

    // 依赖这些消息的记忆转 stale：不再进摘要与召回，但详情仍能看原话。
    let mut memory_stale = 0usize;
    for (message_id,) in &message_ids {
        match state
            .memory
            .mark_sources_stale(protocol::EvidenceSource::Message, message_id)
            .await
        {
            Ok(count) => memory_stale += count,
            Err(err) => tracing::warn!(%err, message_id, "记忆失效传播失败"),
        }
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "conversation.deleted", "ok")
            .target(&id)
            .detail(serde_json::json!({
                "cascaded_tasks": cascaded,
                "memory_stale": memory_stale,
            })),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn list_messages(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ListQuery>,
) -> Result<Json<MessagePage>, ApiRejection> {
    let (items, next) = conversation::list_messages(
        &state.pool,
        &id,
        query.cursor.as_deref(),
        query.limit.unwrap_or(20),
    )
    .await?;
    Ok(Json(MessagePage::from_items(items, next)))
}

/// 系统提示：与「信息与质量标准」对齐——先结论、讲依据、无来源要标未核实。
///
/// 来源不再要求写进正文：客户端用结构化 `sources` 渲染卡片，
/// 正文里再贴一遍地址与时间只会让回答变脏，两边还可能对不上。
const SYSTEM_PROMPT: &str = "你是跑在用户自有机器上的个人助理。回答先给结论，再给依据。\
需要外部事实（新闻、政策、人物、赛事、价格、机构信息等）而手里没有确切地址时，\
先用 web_search 搜关键词拿候选，再对选中的候选调用 web_fetch 核对正文；\
手里已有明确地址时直接 web_fetch。\
引用查证结果时只说明依据是什么，不要把地址与采集时间写进正文——\
系统会在回答下方单独展示来源卡片。\
搜索摘要只是线索，不能当成已核实的事实；没有查证结果、工具失败或不确定时，\
必须明确写“未核实”，不要编造来源、时间或数据。\
当用户明确要你办一件事（例如安排行程、解读账单），且与某个可用技能匹配时，\
调用 suggest_task 提议一次任务：用户会看到一张卡片，点击确认后才会创建。\
只做提议，绝不声称任务已创建、已开始或已完成；同一技能只提议一次。\
需要产出文件（网页、脚本、文档）时调用 write_file，它会真的写到磁盘并在回答下方给出卡片；\
没有调用工具时不要声称已经改过文件。\
读文件被提示「已截断」时，必须用 offset 续读到末尾再动手；\
「文件被截断」不是「工具额度用尽」——只有工具结果里明确写了额度用尽，才可以这么告诉用户，\
否则那是在把自己的放弃说成系统限制。\
生成网页时页面要同时经得起 Chrome 与 App 内置 WKWebView（WebKit 内核）：\
圆角容器别把背景与阴影画在同一个盒子上——渐变与 box-shadow 放到 ::before，\
容器自身 `background: none`，否则 WebKit 会让方形背景从圆角外露出一个角；\
带 `filter: blur()` 的装饰层即使在 `overflow: hidden` + `border-radius` 的父级里，\
WebKit 也可能跳出圆角、在机身外露出一块方角——这类溢出的装饰层要么别超出父盒，\
要么给父级加 `clip-path: inset(0 round Xpx)`（X 与 border-radius 一致）；\
居中用 `min-height: 100dvh` 配 `place-items: safe center`，内容比窗口高时可滚动、\
不会被裁掉顶部；`backdrop-filter` / `background-clip: text` 等新特性必须同时写 -webkit- 前缀。\
当用户以「记住…」开头时，系统会自动保存到长期记忆并在会话里给出提示：\
你不需要也无法代为写入，不要声称自己已写入，也不要说自己没有写入能力，不要重复确认。";

/// Git 项目追加的上下文。
///
/// 不写"你正在看某个仓库"这种话：模型看不到代码，暗示它能读会让它编造文件名。
/// 明确写出边界——回答给方法与命令，真正的改动走编码任务。
const GIT_PROJECT_PROMPT: &str = "当前会话属于 Git 项目（编程语境）：回答围绕工程问题展开，\
优先给出可执行步骤、涉及的文件与命令。你没有读过仓库内容，需要时先说明要查看什么，\
不要臆测具体代码或文件是否存在。涉及改代码时，建议派发编码任务——\
不要声称你已经改过任何文件。";

/// 按项目模式组装系统提示。历史会话没有归属时按普通模式处理。
fn system_prompt_for(mode: Option<ProjectMode>) -> String {
    match mode {
        Some(ProjectMode::Code) => format!("{SYSTEM_PROMPT}\n{GIT_PROJECT_PROMPT}"),
        _ => SYSTEM_PROMPT.to_string(),
    }
}

/// 会话所属项目的模式与 id。缺失（历史空归属或项目已删）时各自返回 `None`。
///
/// 一次查询取两件事：`mode` 决定系统提示，`project_id` 决定记忆摘要里
/// 项目层能看见哪个仓库——分成两次查会让这两件事可能来自不同的瞬间。
async fn conversation_context_of(
    state: &AppState,
    conversation_id: &str,
) -> Result<(Option<ProjectMode>, Option<String>), ApiRejection> {
    let row: Option<(Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT w.mode, c.project_id FROM conversations c \
         LEFT JOIN projects w ON w.id = c.project_id \
         WHERE c.id = ? AND c.deleted_at IS NULL",
    )
    .bind(conversation_id)
    .fetch_optional(&state.pool)
    .await?;

    let Some((mode, project_id)) = row else {
        return Ok((None, None));
    };

    Ok((mode.as_deref().and_then(ProjectMode::parse), project_id))
}

/// 摘要只在会话存在时才有意义；会话被删/不存在时返回空摘要。
fn digest_mode_of(mode: Option<ProjectMode>) -> Option<DigestMode> {
    match mode {
        Some(ProjectMode::Code) => Some(DigestMode::Code),
        Some(ProjectMode::Work) => Some(DigestMode::Work),
        None => None,
    }
}

/// 把工具产出的 UI 动作推给客户端。
///
/// 抽出来是因为它有两处调用：正常完成时，以及"模型没说话"的兜底分支。
/// 后者尤其不能漏——工具已经成功执行（预览站把页面准备好了），
/// 模型说不说话是另一回事，用户要的是那个页面。
async fn push_ui_events(
    tx: &tokio::sync::mpsc::Sender<Result<Event, Infallible>>,
    actions: &[chat::ChatUiAction],
) {
    for action in actions {
        match action {
            chat::ChatUiAction::OpenUrl {
                url,
                title,
                display,
            } => {
                let event = StreamEvent::OpenUrl {
                    url: url.clone(),
                    display: display.clone(),
                    title: title.clone(),
                };
                let _ = tx.send(Ok(sse::to_sse(&event))).await;
            }
            // 文件卡片不走这里：已写入的随 `message_completed` 一次给全，
            // 待确认的由调用方单独推（它需要用户决策，顺序与打开页面不同）。
            chat::ChatUiAction::FileWrite { .. } => {}
            // 媒体卡片同理：它在回答里渲染，不需要客户端立刻开什么东西。
            chat::ChatUiAction::Media { .. } => {}
        }
    }
}

/// 模型没给正文、但文件已经写好时的回执正文。
///
/// 不报"生成失败"：文件在盘上、卡片也在，用户要的结果已经产生了。
/// 文案自己生成，不再问模型一次——它刚才就是因为没话可说才空着的。
fn file_write_summary(writes: &[protocol::FileWrite]) -> String {
    let mut text = String::from("文件已生成：");
    for write in writes {
        let scope = if write.scope == "project" {
            "项目内"
        } else {
            "会话草稿"
        };
        let pending = if write.status == crate::write_store::STATUS_PENDING {
            "，等待确认覆盖"
        } else {
            ""
        };
        text.push_str(&format!(
            "\n- {}（{scope}，{}）{pending}",
            write.path,
            crate::local_tools::format_size(write.bytes.max(0) as u64),
        ));
    }
    text
}

/// 把 digest 参与注入的记忆转成来源卡片。
///
/// 与工具来源按 `memory_id` 去重，并封顶 20 条：摘要可能每轮都命中同一批偏好，
/// 来源区不应该变成一面墙。
fn merge_memory_sources(sources: &[Source], digest: &Digest) -> Vec<Source> {
    const MAX_MEMORY_SOURCES: usize = 20;

    let mut merged = sources.to_vec();
    let mut added = 0usize;
    for id in &digest.memory_ids {
        if added >= MAX_MEMORY_SOURCES {
            break;
        }
        if merged
            .iter()
            .any(|source| source.memory_id.as_deref() == Some(id.as_str()))
        {
            continue;
        }
        merged.push(Source::memory(id, crate::clock::now_ms()));
        added += 1;
    }
    merged
}

/// 显式记忆指令：识别「记住…」并确定性写入，返回一句给用户看的提示。
///
/// 返回 `None` 表示这条消息不是记忆指令（普通对话零开销、不落提示）。
/// 提示会作为 `system` 消息落库——上下文构建（`build_messages`）与抽取
/// （只取 user/assistant）都排除 system，不会污染后续对话；
/// 同时随 `message_completed.notice` 带给客户端，本次会话立刻可见。
async fn handle_explicit_remember(
    state: &AppState,
    conversation_id: &str,
    user_message_id: &str,
    raw_text: &str,
) -> Option<String> {
    let command = crate::memory::explicit::parse(raw_text);
    // 幂等键绑在用户消息上：同一条消息被重发时提示也只留一条。
    let client_msg_id = format!("notice:{user_message_id}");
    let (notice, ok, kind) = match command {
        ExplicitCommand::NotACommand => return None,
        ExplicitCommand::MissingContent => (
            "要记住什么？例如：记住：我儿子叫小姚，2007 年出生".to_string(),
            false,
            None,
        ),
        ExplicitCommand::Remember { content, kind } => {
            // 网络重试导致同一条消息被再次提交：记忆与提示都已经写过，
            // 直接回既有提示，不重复追加证据。
            if let Ok(Some(existing)) =
                conversation::find_by_client_id(&state.pool, conversation_id, &client_msg_id).await
            {
                return Some(existing.content);
            }

            let request = MemoryCreateRequest {
                kind,
                content,
                subject: None,
                predicate: None,
                time_scope: None,
                // 个人事实跨会话可见；一期不做"按项目自动判定项目记忆"，
                // 否则同一句话在不同会话里表现不一致。
                scope: Some(MemoryScope::Global),
                project_id: None,
                pipeline: None,
                sensitivity: None,
                pinned: None,
                // 证据必须是用户原话：显式写入也要能回答"凭什么记这条"。
                evidence_quote: Some(raw_text.trim().to_string()),
            };

            match state.memory.remember_explicit(request).await {
                // 用落库后的正文而不是用户原文：私密内容在写入时已脱敏，
                // 提示消息不该再把原文抄一遍。
                Ok(detail) => (
                    format!("已记住：{}", detail.memory.content),
                    true,
                    Some(kind),
                ),
                Err(err) => {
                    tracing::warn!(%err, conversation_id, "显式记忆写入失败");
                    (
                        format!("没有保存：{}", explicit_failure_hint(&err)),
                        false,
                        Some(kind),
                    )
                }
            }
        }
    };

    crate::memory::audit_reject(
        &state.pool,
        "memory.explicit",
        serde_json::json!({
            "ok": ok,
            "kind": kind.map(|kind| kind.as_str()),
            "chars": raw_text.chars().count(),
            "source": "chat_command",
        }),
    )
    .await;

    if let Err(err) = conversation::append_message(
        &state.pool,
        conversation_id,
        MessageRole::System,
        &notice,
        None,
        Some(&client_msg_id),
    )
    .await
    {
        // 提示写不进去不该影响这一轮回答：用户至少还能在记忆页看到结果。
        tracing::warn!(%err, conversation_id, "记忆提示写库失败");
    }

    Some(notice)
}

/// 显式写入失败时给用户的一句话。`MemoryError` 的文案已是中文，直接透出；
/// 内部错误换成可执行的口径，不把库细节暴露给用户。
fn explicit_failure_hint(err: &crate::memory::MemoryError) -> String {
    use crate::memory::MemoryError;
    match err {
        MemoryError::Disabled | MemoryError::ModelUnavailable => "记忆功能未开启".to_string(),
        MemoryError::Invalid(reason) => reason.clone(),
        _ => "记忆暂时不可用，请稍后再试".to_string(),
    }
}

/// 发送用户消息并以 SSE 流式返回回答。
///
/// 顺序很重要：用户消息先落库 → 逐片转发 → 完整回答落库 → 再发完成事件。
/// 这样"收到 `message_completed` 就一定能查到消息"这个约定才成立。
///
/// 两条路径共用同一套落库与审计：
/// - 配了模型：走 [`chat::run`]，模型可请求只读工具，来源随回答一起落库；
/// - 没配模型：确定性回答，不调用任何工具。
pub async fn send_message(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<SendMessageRequest>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, ApiRejection> {
    // 回答的"用时"从收到提问算起：客户端不该自己去掐表，历史回看也要看到同一个数。
    let started = std::time::Instant::now();

    // 0. 登记本轮停止信号。放在所有 await 之前：用户完全可能在首个分片回来之前
    //    就点停止，晚一步登记就会"点了没反应"。
    //
    //    没有 client_msg_id 的老客户端无法寻址这一轮，也就不提供停止入口：
    //    给一个不登记的信号，语义等同于"没有停止能力"。
    let (stop, stop_guard): (Arc<StopSignal>, Option<crate::state::ChatStopGuard>) =
        match request.client_msg_id.as_deref() {
            Some(client_msg_id) => {
                let (signal, guard) = state.register_chat_stop(chat_stop_key(&id, client_msg_id));
                (signal, Some(guard))
            }
            None => (Arc::new(StopSignal::default()), None),
        };

    // 1. 落库用户消息（client_msg_id 相同则幂等返回，不重复插入）
    //
    // 附件与消息必须一起处理：先 claim（校验存在、属于本设备、还没被用过），
    // 再把元信息写进 `content_json`，最后按消息 id 绑定。三步的顺序不能换——
    // 反过来会出现"界面上已经发出去、库里却没有附件"的窗口。
    //
    // 重复提交（同一个 client_msg_id）跳过整段：附件早已绑在原来那条消息上，
    // 再 claim 一次只会撞上 `already bound`。
    let existing = match request.client_msg_id.as_deref() {
        Some(client_msg_id) => {
            conversation::find_by_client_id(&state.pool, &id, client_msg_id).await?
        }
        None => None,
    };
    let (user_message, turn_attachments) = match existing {
        Some(message) => (message, Vec::new()),
        None => {
            let attachments =
                crate::attachment::claim(&state, &device.device_id, &request.attachments).await?;
            let message = conversation::append_user_message(
                &state.pool,
                &id,
                &request.content,
                request.client_msg_id.as_deref(),
                &attachments,
            )
            .await?;
            if !attachments.is_empty() {
                let ids = attachments
                    .iter()
                    .map(|attachment| attachment.id.clone())
                    .collect::<Vec<_>>();
                crate::attachment::bind(&state.pool, &ids, &id, &message.id).await?;
            }
            (message, attachments)
        }
    };

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "message.created", "ok")
            .target(&user_message.id)
            .detail(serde_json::json!({ "role": "user" })),
    )
    .await;

    // 1.5 显式「记住」：用户明确要求时不该靠后台抽取碰运气。
    //     必须同步做且在 spawn 之前落库，顺序才是「用户 → 提示 → 回答」；
    //     整条链路只有一两次 SQLite 写，对首字延迟影响可忽略。
    let notice_for_client =
        handle_explicit_remember(&state, &id, &user_message.id, &request.content).await;

    // 首条提问决定会话标题。放后台跑：标题不该占首字延迟，模型慢或失败
    // 也只退回截断，不影响这一轮回答。
    let title_pool = state.pool.clone();
    let title_model = state.completion_model();
    let title_conversation = id.clone();
    tokio::spawn(async move {
        if let Err(err) =
            crate::title::refresh(&title_pool, title_model.as_deref(), &title_conversation).await
        {
            tracing::warn!(%err, conversation_id = %title_conversation, "生成会话标题失败");
        }
    });

    // 1.6 本轮的推理等级。客户端只在本次会话里选，随消息带上，不落库。
    //     白名单之外的值一律当没传：上游对这个参数严格校验（非法值直接 400），
    //     不该让一条脏参数把整轮对话打死。能力位在 `llm` 里统一守门。
    let effort = match request.reasoning_effort.as_deref() {
        Some(raw) => match crate::llm::normalize_reasoning(raw) {
            Some(effort) => Some(effort),
            None => {
                tracing::warn!(requested = raw, "忽略无法识别的推理等级");
                None
            }
        },
        None => None,
    };

    // 2. 上下文：有模型时保留角色结构，没有时用纯文本视图。
    //
    // 压缩摘要只在这条路径上有意义：没有模型时回答是确定性的，根本不读历史。
    let model = state.chat_model_with(effort);
    let compaction_summary = if model.is_some() {
        crate::compaction::load_active(&state.pool, &id)
            .await
            .unwrap_or_else(|err| {
                tracing::warn!(%err, conversation_id = %id, "读取上下文摘要失败，按无摘要装配");
                None
            })
    } else {
        None
    };
    let mut history = if model.is_some() {
        Some(
            conversation::build_chat_messages_with(
                &state.pool,
                &id,
                state.config.context_messages,
                compaction_summary.as_ref(),
            )
            .await?,
        )
    } else {
        None
    };
    // 2.5 本轮附件进上下文：图片走多模态、文本类内联摘录、其余只给说明。
    //     只注入这一轮——历史消息里只留一行名字清单（见 `build_chat_messages`），
    //     否则第三轮起每轮都在重发第一轮那份文件的全文。
    if !turn_attachments.is_empty() {
        if let Some(messages) = history.as_mut() {
            crate::attachment::decorate_turn(&state, messages, &turn_attachments).await;
        }
    }
    let plain_history = if model.is_none() {
        Some(conversation::build_messages(&state.pool, &id, state.config.context_messages).await?)
    } else {
        None
    };

    // 3. 先定 message_id，再开始流式：分片与完成事件必须用同一个 id
    let assistant_id = ids::new_id("msg");
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Event, Infallible>>(8);

    let pool = state.pool.clone();
    let conversation_id = id.clone();
    let device_id = device.device_id.clone();
    // 写文件要落草稿目录 / 备份目录，两处都在数据目录下；配置本身是只读的。
    let config = state.config.clone();
    // 这一轮用的模型名先取快照：生成过程中切换配置不会让审计记错模型。
    let model_label = state.active_model().model;
    let responder = state.responder.clone();
    let gateway = state.tool_gateway.clone();
    // 预览站句柄：`preview_url` 用它拼文件/运行目标的地址。
    let web_preview = state.web_preview.clone();
    let limits = ChatLimits {
        max_calls_per_turn: state.config.tool.max_calls_per_turn,
        max_local_calls_per_turn: state.config.tool.max_local_calls_per_turn,
        max_media_calls_per_turn: state.config.tool.max_media_calls_per_turn,
        media_call_timeout: std::time::Duration::from_millis(
            state.config.tool.media_call_timeout_ms,
        ),
        media_turn_budget: std::time::Duration::from_millis(state.config.tool.media_turn_budget_ms),
        max_rounds: state.config.tool.max_rounds,
        turn_budget: std::time::Duration::from_millis(state.config.tool.turn_budget_ms),
    };
    // 可用技能在建任务前就确定：模型只能建议这些，服务端也只接受这些。
    // 模式取自会话所属项目：普通项目不给编码技能，模型也就不会建议它。
    //
    // 无归属直聊也能派任务（见 `tasks::create`），所以不再一票否决建议卡；
    // 但它没有编码边界，按 WORK 取可用技能——编码技能不会进建议，
    // 否则模型会推一张点了就被拒的卡片。
    let (mode, project_id) = conversation_context_of(&state, &id).await?;
    let suggest_skills =
        super::skills::available_names_for(&state, mode.or(Some(ProjectMode::Work))).await;
    let system_prompt = system_prompt_for(mode);

    // 文件工具只对"有项目"的会话注册：路径边界就是那个目录。
    // 目录不可用（被删、权限变化）时同样不注册——注册了也只会每次都拒绝。
    let project_root = match project_id.as_deref() {
        Some(id) => match crate::project::get(&state.pool, id).await {
            Ok(Some(project)) => {
                match crate::local_tools::path_guard::ProjectRoot::new(&project.path) {
                    Ok(root) => Some(root),
                    Err(err) => {
                        tracing::warn!(%err, %id, "项目目录不可用，本轮不注册文件工具");
                        None
                    }
                }
            }
            Ok(None) => None,
            Err(err) => {
                tracing::warn!(%err, %id, "查询项目失败，本轮不注册文件工具");
                None
            }
        },
        None => None,
    };

    // 记忆摘要在 spawn 之前同步取一次：放进 spawn 里会让首字多等一次查询。
    // 失败只 warn 并按"没有记忆"回答——记忆坏了不该让对话坏掉。
    let digest_ctx = DigestContext::at(
        digest_mode_of(mode),
        project_id.clone(),
        crate::clock::now_ms(),
    );
    // 召回工具的句柄：spawn 里只借用它自己的连接池与配置，不把整个 `state` 搬进去。
    let memory_handle = state.memory.clone();
    // 抽取要引用用户那条原话，所以把 id 提前克隆进闭包。
    let user_message_id_for_extract = user_message.id.clone();
    // "该查没查"的观测只需要问句本身，同样提前克隆。
    let user_query_for_recall_audit = request.content.clone();
    // 出图尺寸只认用户这一句里的显式尺寸（`1024x1024` 之类），
    // 所以原话要跟着闭包走——模型传的 size 不再有决定权。
    let turn_text_for_media = request.content.clone();
    let digest = match state.memory.digest(digest_ctx.clone()).await {
        Ok(digest) => digest,
        Err(err) => {
            tracing::warn!(%err, conversation_id = %id, "记忆摘要生成失败，本轮不注入");
            Digest::empty()
        }
    };

    // 快照写库放后台：它只服务于"看清上周三的状态"，不该拖慢这一轮。
    if !digest.text.is_empty() {
        let memory = state.memory.clone();
        let text = digest.text.clone();
        let ids = digest.memory_ids.clone();
        tokio::spawn(async move {
            memory.snapshot_digest(&text, &ids, &digest_ctx).await;
        });
    }

    // 媒体后端在 `AppState` 装配时一次建好（持有 HTTP 客户端与密钥），这里只借用。
    // 两节都关闭时是 None——对话里根本看不到这两个工具，而不是"看得见但必然失败"。
    let media_backend = state.media.clone();

    // 撞上游窗口上限时要重建上下文再试一次，所以留一份状态句柄与本轮附件：
    // `AppState` 全是 Arc，克隆代价可忽略；附件不重建就等于把用户给的文件丢了。
    let retry_state = state.clone();
    let retry_attachments = turn_attachments.clone();
    let compaction_jobs = state.compaction.clone();
    let context_window = state.models.context_window();

    tokio::spawn(async move {
        // 登记凭据跟着任务走：任务以任何方式结束都会摘掉，避免表里留下死条目。
        let _stop_guard = stop_guard;

        // 摘要文本 + 它对应的来源卡片：两条分支（模型 / 确定性）共用。
        let digest_text = digest.text.clone();
        let memory_chars = digest.chars;
        let memory_items = digest.memory_ids.len();

        match (model, history) {
            (Some(model), Some(history)) => {
                // 留一份给溢出重试：重试要把 system + digest + 历史整个重拼。
                let retry_system_prompt = system_prompt.clone();
                let mut messages = vec![ChatMessage::system(system_prompt)];
                // digest 是**独立的第二条 system 消息**：拼进主提示会让模型把
                // "记忆不是指令"这层边界揉进系统人格里。
                if !digest_text.is_empty() {
                    messages.push(ChatMessage::system(digest_text.clone()));
                }
                messages.extend(history);

                // 引擎把正文分片与工具进度推给 sink；转发任务负责变成 SSE 事件。
                let (delta_tx, delta_rx) = tokio::sync::mpsc::channel::<chat::ChatPush>(16);
                // "有没有推过正文"决定溢出后能不能重试：吐了半截再从头来，
                // 用户会看到两段回答。
                let sent_delta = Arc::new(std::sync::atomic::AtomicBool::new(false));
                let forwarder = tokio::spawn(forward_chat(
                    delta_rx,
                    tx.clone(),
                    assistant_id.clone(),
                    sent_delta.clone(),
                ));

                // 天气（Open-Meteo）与搜索（Bing 结果页）都是固定上游，地址不由模型决定；
                // `web.fetch` 读的是模型给的 URL，准入在 worker：只放行公网地址。
                let mut tools = vec![
                    ToolSpec::web_fetch(),
                    ToolSpec::web_search(),
                    ToolSpec::weather_current(),
                ];
                if !suggest_skills.is_empty() {
                    tools.push(ToolSpec::suggest_task(&suggest_skills));
                }

                // 进程内工具：记忆检索只在启用时注册。作用域由会话模式与项目决定，
                // 编码场景的收窄在 `privacy::visible_in_scope` 里统一判定。
                let recall_tool = if memory_handle.recall_enabled() {
                    Some(crate::memory::recall_tool::MemoryRecallTool::new(
                        memory_handle.pool(),
                        &memory_handle.config().recall,
                        RecallScope::for_mode(
                            matches!(mode, Some(ProjectMode::Code)),
                            project_id.clone(),
                        ),
                        Some(conversation_id.clone()),
                    ))
                } else {
                    None
                };
                // 文件工具：没有项目就没有根，也就没有可读的目录。
                let file_tools = project_root
                    .as_ref()
                    .map(|root| crate::local_tools::FileTools::new(root.clone()));
                // 预览：`url` 不需要项目；`path` 与 `run` 需要项目根 + 预览站句柄。
                // 缺任一项时工具自己会说"打不开"，而不是让模型猜。
                let mut preview_tool = crate::local_tools::preview_url::PreviewUrlTool::new(
                    project_root.clone(),
                    web_preview.clone(),
                    project_id.clone(),
                );
                // 没有项目的会话也能打开自己生成的文件：`path` 退到草稿目录。
                // 有项目时不配，避免"看哪个 index.html"出现两种解释。
                if project_root.is_none() {
                    preview_tool =
                        preview_tool.with_draft(crate::local_tools::preview_url::DraftScope {
                            conversation_id: conversation_id.clone(),
                            config: config.clone(),
                        });
                }

                // 写入：有项目写项目根，没项目写会话草稿目录。
                // 两种落点共用同一套准入（`resolve_new`），只是根不同。
                let write_tool = crate::local_tools::write_file::WriteFileTool::new(
                    pool.clone(),
                    config.clone(),
                    conversation_id.clone(),
                    assistant_id.clone(),
                    if project_root.is_some() {
                        crate::write_store::WriteScope::Project
                    } else {
                        crate::write_store::WriteScope::Draft
                    },
                );

                // 媒体生成：只在对应能力启用时注册。配置关闭时工具不存在，
                // 模型看不见就不会调，也不会把"没开这个功能"变成一次失败尝试。
                let image_tool = media_backend
                    .as_ref()
                    .filter(|backend| backend.image_enabled())
                    .map(|backend| {
                        GenerateMediaTool::new(
                            MediaKind::Image,
                            backend.clone(),
                            pool.clone(),
                            conversation_id.clone(),
                            &config,
                            &turn_text_for_media,
                        )
                    });
                let video_tool = media_backend
                    .as_ref()
                    .filter(|backend| backend.video_enabled())
                    .map(|backend| {
                        GenerateMediaTool::new(
                            MediaKind::Video,
                            backend.clone(),
                            pool.clone(),
                            conversation_id.clone(),
                            &config,
                            // 视频的档位仍由模型按参数表填，原话传进去只是保持签名一致。
                            &turn_text_for_media,
                        )
                    });

                let mut local_tools = chat::LocalToolRegistry::new();
                if let Some(tools) = &file_tools {
                    local_tools = tools.register(local_tools);
                }
                if let Some(tool) = &recall_tool {
                    local_tools = local_tools.with(tool);
                }
                local_tools = local_tools.with(&preview_tool);
                local_tools = local_tools.with(&write_tool);
                if let Some(tool) = &image_tool {
                    local_tools = local_tools.with(tool);
                }
                if let Some(tool) = &video_tool {
                    local_tools = local_tools.with(tool);
                }
                // 工具清单与注册表同源：漏注册等于模型看不见，多注册等于调了必失败。
                tools.extend(local_tools.specs());

                // 重试要用同一份工具清单，先留一份：第一次调用会把 `tools` 吃掉。
                let retry_tools = tools.clone();
                let mut outcome = chat::run(
                    model.as_ref(),
                    gateway.as_ref(),
                    &local_tools,
                    messages,
                    tools,
                    &suggest_skills,
                    limits,
                    &delta_tx,
                    stop.as_ref(),
                )
                .await;

                drop(delta_tx);
                let _ = forwarder.await;

                // 上游报「上下文超长」：同步压一次再重试一次。
                //
                // 这条路径与常规压缩的目的不同：常规压缩是"别在下一轮才发现丢了前情"，
                // 这里是"这一轮已经注定失败，压完还有机会答出来"。所以它同步等待，
                // 而且只试一次——再溢出就说明单条内容太长，压缩救不了。
                if let Err(err) = &outcome {
                    if compaction_jobs.retry_on_overflow()
                        && crate::compaction::is_context_overflow(err)
                        && !sent_delta.load(std::sync::atomic::Ordering::Relaxed)
                    {
                        tracing::warn!(
                            %err,
                            conversation_id = %conversation_id,
                            "上游报上下文超长：同步压缩后重试一次"
                        );
                        let compacted = compaction_jobs
                            .compact_now(&conversation_id, "overflow")
                            .await;
                        audit::record(
                            &pool,
                            &AuditEntry::new(
                                &conversation_id,
                                &device_id,
                                "conversation.compaction_retry",
                                if compacted.ready { "ok" } else { "error" },
                            )
                            .target(&conversation_id)
                            .detail(serde_json::json!({ "compacted": compacted.ready })),
                        )
                        .await;
                        if compacted.ready {
                            if let Some(retry_messages) = build_retry_messages(
                                &retry_state,
                                &conversation_id,
                                &retry_system_prompt,
                                &digest_text,
                                &retry_attachments,
                            )
                            .await
                            {
                                let (retry_tx, retry_rx) =
                                    tokio::sync::mpsc::channel::<chat::ChatPush>(16);
                                let retry_forwarder = tokio::spawn(forward_chat(
                                    retry_rx,
                                    tx.clone(),
                                    assistant_id.clone(),
                                    sent_delta.clone(),
                                ));
                                outcome = chat::run(
                                    model.as_ref(),
                                    gateway.as_ref(),
                                    &local_tools,
                                    retry_messages,
                                    retry_tools,
                                    &suggest_skills,
                                    limits,
                                    &retry_tx,
                                    stop.as_ref(),
                                )
                                .await;
                                drop(retry_tx);
                                let _ = retry_forwarder.await;
                            }
                        }
                    }
                }

                let mut outcome = match outcome {
                    Ok(outcome) => outcome,
                    Err(err) => {
                        tracing::warn!(%err, conversation_id = %conversation_id, "模型生成失败");

                        // 失败要留痕：以前这条错误只推到客户端，库里什么都没有，
                        // 事后只能靠用户截图猜"是我们掐的还是上游断的"。
                        // `kind` 从文案反推（`llm.rs` 的 describe_* 是唯一产出方），
                        // 比让错误类型穿透 `ChatModel` 的 `Result<_, String>` 更省事。
                        let kind = if err.contains("没有输出") {
                            "stream_idle"
                        } else if err.contains("流被中断") {
                            "stream_closed"
                        } else if err.contains("连不上") {
                            "connect"
                        } else if err.contains("超过时限") {
                            "request_timeout"
                        } else if err.contains("模型返回") {
                            "upstream_status"
                        } else {
                            "unknown"
                        };
                        audit::record(
                            &pool,
                            &AuditEntry::new(&conversation_id, &device_id, "llm.failed", "error")
                                .target(&conversation_id)
                                .detail(serde_json::json!({
                                    "kind": kind,
                                    "elapsed_ms": started.elapsed().as_millis() as i64,
                                    "model": model_label,
                                    "error": err.chars().take(300).collect::<String>(),
                                })),
                        )
                        .await;

                        let event = StreamEvent::Error {
                            code: "dependency_unavailable".to_string(),
                            hint: format!("生成中断：{err}"),
                        };
                        let _ = tx.send(Ok(sse::to_sse(&event))).await;
                        return;
                    }
                };

                // 文件已经写好、只是模型没说话：用户要的就是那个文件。
                // 这时判"生成失败"是把成功当失败——用确定性回执当正文落库。
                if outcome.text.trim().is_empty() && !outcome.file_writes.is_empty() {
                    outcome.text = file_write_summary(&outcome.file_writes);

                    // 必须把这段回执也推给客户端：`message_completed` 不带正文，
                    // 界面只认 delta 累积出来的内容。少这一推，库里明明有字，
                    // 用户看到的却是一个占位符"…"。
                    let event = StreamEvent::MessageDelta {
                        message_id: assistant_id.clone(),
                        text: outcome.text.clone(),
                    };
                    let _ = tx.send(Ok(sse::to_sse(&event))).await;
                }

                // 工具调用逐条审计：地址、耗时、结果码。不记录网页正文。
                for record in &outcome.calls {
                    audit::record(
                        &pool,
                        &AuditEntry::new(
                            &conversation_id,
                            &device_id,
                            "tool.called",
                            if record.ok { "ok" } else { "error" },
                        )
                        .target(&conversation_id)
                        .detail(serde_json::json!({
                            "tool": record.tool,
                            "target": record.target,
                            "elapsed_ms": record.elapsed_ms,
                            "error": record.error,
                        })),
                    )
                    .await;
                }

                if outcome.aborted {
                    tracing::debug!(conversation_id = %conversation_id, "客户端断开，丢弃半截回答");
                    return;
                }

                if outcome.text.trim().is_empty() {
                    // 被用户叫停、而且一个 token 都没写出来：没有正文可落库，
                    // 也就不写历史。事件也不发——任务返回时 SSE 流自然结束，
                    // 客户端据此收尾，不会一直卡在"生成中"。
                    if outcome.stopped {
                        tracing::debug!(conversation_id = %conversation_id, "用户停止，未产生正文");
                        return;
                    }
                    // 工具已经产出的 UI 动作不能因为"模型没说话"就丢掉：
                    // 预览站已经把页面准备好了，打开它才是用户要的结果。
                    // 这一步必须在报错之前——先开页面，再说明模型没给回答。
                    push_ui_events(&tx, &outcome.ui).await;

                    // 空回答最难查：没有异常、没有错误码，客户端只显示"生成失败"。
                    // 这一行把"为什么空"留进日志——调了几次、几次失败、花了多久。
                    // 撞时间预算与"模型就是不想说"处置完全不同，事后只能靠它分辨。
                    tracing::warn!(
                        conversation_id = %conversation_id,
                        elapsed_ms = outcome.elapsed_ms,
                        tool_calls = outcome.calls.len(),
                        failed_calls = outcome
                            .calls
                            .iter()
                            .filter(|record| !record.ok)
                            .count(),
                        "模型没有给出正文，本轮按失败收尾"
                    );

                    // 日志只在 dev 终端里，重启就没了；这条进库，
                    // 事后能直接看"这一轮按什么顺序调了什么、花了多久"。
                    // `tool.called` 是逐条流水，缺的正是"整轮画像"。
                    audit::record(
                        &pool,
                        &AuditEntry::new(
                            &conversation_id,
                            &device_id,
                            "chat.empty_answer",
                            "error",
                        )
                        .target(&conversation_id)
                        .detail(serde_json::json!({
                            "elapsed_ms": outcome.elapsed_ms,
                            "text_chars": outcome.text.chars().count(),
                            "tools": outcome
                                .calls
                                .iter()
                                .map(|record| record.tool.as_str())
                                .collect::<Vec<_>>(),
                            "failed_calls": outcome
                                .calls
                                .iter()
                                .filter(|record| !record.ok)
                                .count(),
                        })),
                    )
                    .await;

                    // 提示按原因分档：工具全失败时说清"资料没取到"，
                    // 否则用户会把一个注定失败的请求反复重试。
                    let event = StreamEvent::Error {
                        code: "dependency_unavailable".to_string(),
                        hint: chat::empty_answer_hint(&outcome.calls),
                    };
                    let _ = tx.send(Ok(sse::to_sse(&event))).await;
                    return;
                }

                // 终态：被用户停止就记 stopped，半截回答照样落库。
                let finish_reason = if outcome.stopped {
                    FINISH_STOPPED
                } else {
                    FINISH_STOP
                };

                // 工具来源 + digest 来源按 memory_id 去重后一起下发。
                let sources = merge_memory_sources(&outcome.sources, &digest);

                // 执行过程：实时展示与历史回看必须读同一份，否则刷新一次
                // "刚才做了什么"就从界面上消失了。
                let steps = chat::steps_from_calls(&outcome.calls);

                match conversation::append_assistant_with_sources(
                    &pool,
                    &assistant_id,
                    &conversation_id,
                    &outcome.text,
                    &sources,
                    &outcome.suggestions,
                    &outcome.file_writes,
                    &outcome.media,
                    &steps,
                    conversation::MessageMetrics::new(outcome.elapsed_ms, outcome.usage)
                        .with_finish_reason(finish_reason),
                )
                .await
                {
                    Ok(saved) => {
                        audit::record(
                            &pool,
                            &AuditEntry::new(&conversation_id, &device_id, "message.created", "ok")
                                .target(&saved.id)
                                .detail(serde_json::json!({
                                    "role": "assistant",
                                    "chars": outcome.text.chars().count(),
                                    "sources": sources.len(),
                                    "memory_chars": memory_chars,
                                    "memory_items": memory_items,
                                    "elapsed_ms": saved.elapsed_ms,
                                    "tokens": saved.usage.map(|usage| usage.total()),
                                    "finish_reason": finish_reason,
                                })),
                        )
                        .await;

                        // 观测"该查没查"：本轮没有任何记忆来源、而问句明显在指代
                        // 过去说过的事时记一条审计。只观测、不改变回答，也不影响预算。
                        if sources.iter().all(|source| source.memory_id.is_none()) {
                            let cue =
                                crate::memory::retrieve::recall_cue(&user_query_for_recall_audit);
                            if cue.should_recall() {
                                crate::memory::audit_reject(
                                    &pool,
                                    "memory.unrecalled",
                                    serde_json::json!({
                                        "conversation_id": conversation_id,
                                        "has_person_name": cue.has_person_name,
                                        "has_date": cue.has_date,
                                        "has_reference": cue.has_reference,
                                    }),
                                )
                                .await;
                            }
                        }

                        // 回填"用过"：回答正文里真的出现了记忆的连续片段才算。
                        // 与抽取一样，失败只 warn，不影响这一轮的收尾。
                        let used_ids: Vec<String> = sources
                            .iter()
                            .filter_map(|source| source.memory_id.clone())
                            .collect();
                        if !used_ids.is_empty() {
                            memory_handle.touch_used(&used_ids, &outcome.text).await;
                        }

                        // 抽取只在落库成功后投递：回答没落库就没有可引用的原文。
                        // 被停止/出错的轮次、太短的轮次不抽——省额度也避噪音。
                        if finish_reason == FINISH_STOP && outcome.text.chars().count() >= 40 {
                            memory_handle.submit_extract(crate::memory::extract::ExtractJob {
                                batch_id: ids::new_id("bat"),
                                trace_id: conversation_id.clone(),
                                source: crate::memory::extract::ExtractSource::Session {
                                    conversation_id: conversation_id.clone(),
                                    user_message_id: user_message_id_for_extract.clone(),
                                    assistant_message_id: saved.id.clone(),
                                },
                            });
                        }

                        // UI 动作在 completed 之前推：客户端先开标签再收尾，
                        // 顺序与"模型提出想看这页"一致；落库失败则一个都不推。
                        push_ui_events(&tx, &outcome.ui).await;

                        // 覆盖确认卡单独推：它需要用户决策，而 `OpenUrl` 只是打开页面。
                        // 已写入的卡片不推——它们在 `message_completed` 里一次给全。
                        for write in outcome
                            .file_writes
                            .iter()
                            .filter(|write| write.status == crate::write_store::STATUS_PENDING)
                        {
                            let _ = tx
                                .send(Ok(sse::to_sse(&sse::file_write_request(write))))
                                .await;
                        }

                        // 回答已经落库：顺手看看要不要在后台把更早的对话整理成摘要。
                        // 不 await——摘要生成与这一轮的 SSE 收尾没有关系。
                        maybe_compact(
                            &compaction_jobs,
                            &conversation_id,
                            saved.usage,
                            context_window,
                        );

                        let done = sse::completed(sse::CompletedPayload {
                            message_id: &saved.id,
                            finish_reason,
                            sources: &saved.sources,
                            suggestions: &saved.task_suggestions,
                            file_writes: &saved.file_writes,
                            media: &saved.media,
                            steps: &saved.steps,
                            elapsed_ms: saved.elapsed_ms,
                            usage: saved.usage,
                            notice: notice_for_client.clone(),
                        });
                        let _ = tx.send(Ok(sse::to_sse(&done))).await;
                    }
                    Err(err) => {
                        tracing::error!(%err, conversation_id = %conversation_id, "保存回答失败");
                        let event = StreamEvent::Error {
                            code: "internal_error".to_string(),
                            hint: "回答已生成但保存失败，请重试".to_string(),
                        };
                        let _ = tx.send(Ok(sse::to_sse(&event))).await;
                    }
                }
            }
            _ => {
                // 确定性路径：不调用工具，行为与 M3 一致。
                // 摘要照样注入：没有模型时它至少能出现在提示里，来源卡片也一致。
                let mut messages = vec![PromptMessage::system(system_prompt)];
                if !digest_text.is_empty() {
                    messages.push(PromptMessage::system(digest_text.clone()));
                }
                messages.extend(plain_history.unwrap_or_default());

                let mut stream = responder.stream(messages);
                let mut full = String::new();
                let mut failure: Option<String> = None;
                // 确定性回答同样是逐片推进的：停止检查与模型路径保持同一处。
                let mut stopped = false;

                loop {
                    // 与 `chat::run` 同构：停止信号和下一个分片赛跑，谁先到算谁。
                    let next = tokio::select! {
                        biased;
                        () = stop.wait() => { stopped = true; break; }
                        next = stream.next() => next,
                    };
                    let Some(item) = next else { break };

                    match item {
                        Ok(text) if !text.is_empty() => {
                            full.push_str(&text);
                            let event = StreamEvent::MessageDelta {
                                message_id: assistant_id.clone(),
                                text,
                            };
                            if tx.send(Ok(sse::to_sse(&event))).await.is_err() {
                                tracing::debug!(conversation_id = %conversation_id, "客户端已断开，停止生成");
                                return;
                            }
                        }
                        Ok(_) => {}
                        Err(err) => {
                            failure = Some(err);
                            break;
                        }
                    }
                }

                if !full.trim().is_empty() {
                    // 三种终态互斥：被喊停 > 出错 > 正常写完。
                    let finish_reason = if stopped {
                        FINISH_STOPPED
                    } else if failure.is_some() {
                        FINISH_ERROR
                    } else {
                        FINISH_STOP
                    };

                    // 确定性回答不经过模型：没有 token 用量，耗时照样记。
                    // 来源里仍然可能有记忆卡片：摘要是服务端注入的，与模型无关。
                    let sources = merge_memory_sources(&[], &digest);

                    match conversation::append_assistant_with_sources(
                        &pool,
                        &assistant_id,
                        &conversation_id,
                        &full,
                        &sources,
                        &[],
                        &[],
                        // 确定性回答没有工具调用，也就没有生成产物与执行过程。
                        &[],
                        &[],
                        conversation::MessageMetrics::new(
                            started.elapsed().as_millis() as i64,
                            None,
                        )
                        .with_finish_reason(finish_reason),
                    )
                    .await
                    {
                        Ok(saved) => {
                            audit::record(
                                &pool,
                                &AuditEntry::new(
                                    &conversation_id,
                                    &device_id,
                                    "message.created",
                                    "ok",
                                )
                                .target(&saved.id)
                                .detail(serde_json::json!({
                                    "role": "assistant",
                                    "chars": full.chars().count(),
                                    "sources": sources.len(),
                                    "memory_chars": memory_chars,
                                    "memory_items": memory_items,
                                    "finish_reason": finish_reason,
                                })),
                            )
                            .await;

                            // 确定性回答没有用量，但条数仍可能已经超上限——
                            // 那时把更早的对话交给模型整理，下一次提问就能接上前情。
                            maybe_compact(
                                &compaction_jobs,
                                &conversation_id,
                                saved.usage,
                                context_window,
                            );

                            let done = sse::completed(sse::CompletedPayload {
                                message_id: &saved.id,
                                finish_reason,
                                sources: &saved.sources,
                                suggestions: &[],
                                file_writes: &saved.file_writes,
                                media: &saved.media,
                                steps: &saved.steps,
                                elapsed_ms: saved.elapsed_ms,
                                usage: saved.usage,
                                notice: notice_for_client.clone(),
                            });
                            let _ = tx.send(Ok(sse::to_sse(&done))).await;
                        }
                        Err(err) => {
                            tracing::error!(%err, conversation_id = %conversation_id, "保存回答失败");
                            let event = StreamEvent::Error {
                                code: "internal_error".to_string(),
                                hint: "回答已生成但保存失败，请重试".to_string(),
                            };
                            let _ = tx.send(Ok(sse::to_sse(&event))).await;
                            return;
                        }
                    }
                }

                if let Some(err) = failure {
                    tracing::warn!(%err, conversation_id = %conversation_id, "生成回答失败");
                    let event = StreamEvent::Error {
                        code: "dependency_unavailable".to_string(),
                        hint: format!("生成中断：{err}"),
                    };
                    let _ = tx.send(Ok(sse::to_sse(&event))).await;
                }
            }
        }
    });

    let stream = stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|item| (item, rx))
    });

    Ok(Sse::new(stream).keep_alive(KeepAlive::default()))
}

/// 停止本轮生成的请求体。
#[derive(Debug, Deserialize)]
pub struct StopRequest {
    /// 与发送时带的 `client_msg_id` 同一个值：一轮回答的身份。
    pub client_msg_id: String,
}

/// 停止本轮生成。
///
/// **不是**靠客户端断开连接实现的：断在服务端看来就是"没人要了"，
/// 半截回答会被丢弃。这里显式置位，生成侧在下一个事件边界收尾、
/// 把已有内容落库，并把终态记成 `stopped`。
///
/// 幂等：这一轮已经结束（或这个键根本没登记过）时返回 204 而不是报错。
/// 客户端可能连点两次，也可能在网络重试里补一发，这两种都不该看到失败。
pub async fn stop(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<StopRequest>,
) -> Result<StatusCode, ApiRejection> {
    let key = chat_stop_key(&id, &request.client_msg_id);
    if !state.request_chat_stop(&key) {
        tracing::debug!(conversation_id = %id, "停止请求未命中：本轮已经结束");
        return Ok(StatusCode::NO_CONTENT);
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "chat.stopped", "ok").target(&id),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

/// 手动重新整理上下文。异步受理：返回当前状态，摘要就绪后由详情接口回读。
pub async fn compact(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<(StatusCode, Json<protocol::Compaction>), ApiRejection> {
    state
        .compaction
        .spawn_manual(&id)
        .await
        .map_err(|err| match err {
            // 正在整理：不排队、不重复跑，直接告诉客户端"已经在做了"。
            crate::compaction::CompactError::Busy => ApiRejection::new(
                ErrorCode::Conflict,
                "compaction already running",
                "这个会话正在整理上下文，稍后再看结果",
            ),
            crate::compaction::CompactError::Unavailable => ApiRejection::new(
                ErrorCode::DependencyUnavailable,
                "model unavailable",
                "没有可用的模型，无法整理上下文",
            ),
            crate::compaction::CompactError::NotFound => ApiRejection::new(
                ErrorCode::NotFound,
                "conversation not found",
                "会话不存在",
            ),
        })?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "conversation.compaction_requested", "ok")
            .target(&id),
    )
    .await;

    // 受理即返回：这一轮还没写完，状态给 `pending`，界面据此显示"整理中"。
    let view = crate::compaction::view(&state.pool, &id)
        .await
        .ok()
        .flatten()
        .unwrap_or(protocol::Compaction {
            status: "pending".to_string(),
            summary: None,
            anchor_message_id: None,
            source_messages: 0,
            model: None,
            updated_at: None,
            tokens: None,
            elapsed_ms: None,
            last_failure: None,
        });
    Ok((StatusCode::ACCEPTED, Json(view)))
}

/// 关掉这个会话的上下文压缩：装配回到「最近 N 条 + 省略提示」。
pub async fn uncompact(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    state
        .compaction
        .disable(&id)
        .await
        .map_err(|_| {
            ApiRejection::new(ErrorCode::NotFound, "conversation not found", "会话不存在")
        })?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "conversation.compaction_disabled", "ok")
            .target(&id),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

/// 把引擎推来的分片转成 SSE。
///
/// `sent` 记录"有没有推过正文"：溢出重试只在没推过正文时允许——
/// 吐了半截再从头来，用户会看到两段回答。
async fn forward_chat(
    mut delta_rx: tokio::sync::mpsc::Receiver<chat::ChatPush>,
    tx: tokio::sync::mpsc::Sender<Result<Event, Infallible>>,
    message_id: String,
    sent: Arc<std::sync::atomic::AtomicBool>,
) {
    use std::sync::atomic::Ordering;
    while let Some(item) = delta_rx.recv().await {
        let event = match item {
            chat::ChatPush::Text(piece) => {
                sent.store(true, Ordering::Relaxed);
                StreamEvent::MessageDelta {
                    message_id: message_id.clone(),
                    text: piece,
                }
            }
            // 工具进度不是正文，客户端按 id 覆盖同一行状态。
            chat::ChatPush::Activity(activity) => sse::activity(&activity),
        };
        if tx.send(Ok(sse::to_sse(&event))).await.is_err() {
            return;
        }
    }
}

/// 回答落库后的常规触发。丢进后台：摘要生成不该拖住这一轮的 SSE 收尾。
fn maybe_compact(
    jobs: &Arc<crate::compaction::Jobs>,
    conversation_id: &str,
    usage: Option<protocol::TokenUsage>,
    context_window: u32,
) {
    let jobs = jobs.clone();
    let conversation_id = conversation_id.to_string();
    let context_tokens = usage.map(|usage| usage.context_tokens).unwrap_or(0);
    tokio::spawn(async move {
        jobs.maybe_spawn(&conversation_id, context_tokens, context_window)
            .await;
    });
}

/// 溢出重试用的上下文：按刚写好的摘要重新装配一遍，并把本轮附件补回去。
///
/// 返回 `None` 表示重建失败——那时保留原来的错误，不要让重试把真实原因盖掉。
async fn build_retry_messages(
    state: &AppState,
    conversation_id: &str,
    system_prompt: &str,
    digest_text: &str,
    attachments: &[protocol::Attachment],
) -> Option<Vec<ChatMessage>> {
    let active = crate::compaction::load_active(&state.pool, conversation_id)
        .await
        .ok()
        .flatten();
    let mut history = match conversation::build_chat_messages_with(
        &state.pool,
        conversation_id,
        state.config.context_messages,
        active.as_ref(),
    )
    .await
    {
        Ok(history) => history,
        Err(err) => {
            tracing::warn!(%err, conversation_id, "重建上下文失败，放弃溢出重试");
            return None;
        }
    };
    if !attachments.is_empty() {
        crate::attachment::decorate_turn(state, &mut history, attachments).await;
    }

    let mut messages = vec![ChatMessage::system(system_prompt.to_string())];
    if !digest_text.is_empty() {
        messages.push(ChatMessage::system(digest_text.to_string()));
    }
    messages.extend(history);
    Some(messages)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &str, scope: &str, status: &str, bytes: i64) -> protocol::FileWrite {
        protocol::FileWrite {
            request_id: format!("fw_{path}"),
            path: path.to_string(),
            scope: scope.to_string(),
            status: status.to_string(),
            bytes,
            existing_bytes: 0,
            backup_path: None,
            expires_at: None,
            created_at: 0,
        }
    }

    #[test]
    fn fallback_summary_covers_written_and_pending_files() {
        let text = file_write_summary(&[
            write("calc.html", "draft", "written", 2048),
            write("index.html", "project", "pending", 100),
        ]);

        assert!(text.contains("calc.html（会话草稿，2.0 KB）"), "{text}");
        assert!(
            text.contains("index.html（项目内，100 B），等待确认覆盖"),
            "{text}"
        );
    }
}
