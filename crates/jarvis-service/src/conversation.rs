//! 会话与消息。
//!
//! 职责：
//! - 会话的创建、列表、详情；
//! - 消息追加（含 `client_msg_id` 幂等去重）、cursor 分页；
//! - 组装上下文窗口（最近 N 条 + 省略提示）。
//!
//! 不含生成逻辑：回答由 `Responder` 产出，本模块只负责存取。

use protocol::{
    Attachment, Conversation, ConversationCreate, ConversationDetail, ConversationMode, Cursor,
    FileWrite, MediaAsset, Message, MessageRole, MessageSource, MessageStep, TaskSuggestion,
    TokenUsage,
};
use sqlx::SqlitePool;

use crate::clock::now_ms;
use crate::ids::new_id;
use crate::responder::PromptMessage;
use crate::title::MAX_TITLE_CHARS;

/// 单条消息进入上下文时的最大字符数，防止一条超长消息吃掉整个窗口。
const MAX_MESSAGE_CHARS: usize = 500;

/// 新建会话没给标题时的占位。标题生成只覆盖这一种，用户起过名的会话不动。
pub const DEFAULT_TITLE: &str = "新会话";

#[derive(Debug, thiserror::Error)]
pub enum ConversationError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
    #[error("会话不存在")]
    NotFound,
    #[error("项目不存在")]
    ProjectNotFound,
    #[error("状态冲突: {0}")]
    Conflict(&'static str),
    #[error("参数非法: {0}")]
    Invalid(&'static str),
}

/// 创建结果：`reused` 为真表示**没有真的新建**，命中了项目里已有的空白会话
/// （见 [`open_or_create`]）。调用方据此决定状态码与是否记 `conversation.created` 审计。
#[derive(Debug)]
pub struct CreateOutcome {
    pub conversation: Conversation,
    pub reused: bool,
}

/// 新建会话。标题缺省时取"新会话"，首条用户消息到达后由 [`crate::title`] 生成。
pub async fn create(
    pool: &SqlitePool,
    device_id: &str,
    request: &ConversationCreate,
) -> Result<Conversation, ConversationError> {
    // 空串与省略同义，都表示无归属直聊：库列本就可空，聊天链路对空归属
    // 已有兜底（基础系统提示、全局记忆、不给任务落点）。
    let project_id = normalize_project_id(request.project_id.as_deref());
    if let Some(id) = project_id {
        ensure_project(pool, id).await?;
    }

    let now = now_ms();
    let conversation = Conversation {
        id: new_id("conv"),
        project_id: project_id.unwrap_or_default().to_string(),
        title: request
            .title
            .as_deref()
            .map(str::trim)
            .filter(|title| !title.is_empty())
            .unwrap_or(DEFAULT_TITLE)
            .to_string(),
        mode: request.mode.unwrap_or(ConversationMode::Text),
        device_id: Some(device_id.to_string()),
        archived: false,
        created_at: now,
        updated_at: now,
    };

    sqlx::query(
        "INSERT INTO conversations (id, project_id, title, mode, device_id, archived, \
                created_at, updated_at) \
         VALUES (?, ?, ?, ?, ?, 0, ?, ?)",
    )
    .bind(&conversation.id)
    // 绑 `Option` 而不是 `conversation.project_id`：无归属要落成 NULL，
    // 空串会让 `project_id IS NULL` 这类过滤永远查不到它。
    .bind(project_id)
    .bind(&conversation.title)
    .bind(conversation.mode.as_str())
    .bind(device_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(conversation)
}

/// 打开项目里的空白会话：有就复用，没有才新建。
///
/// 侧栏的「新建会话」连点几下不该堆出一串同名的「新会话」——一个项目里留
/// 一条空白会话就够。只在**调用方没给标题**时复用：显式起名的创建请求
/// （脚本、导入、测试）期望的是一条全新会话，不该被并到旧的那条上。
///
/// 无归属直聊也走同一套复用：否则每点一次「新建会话」就多一条空会话，
/// 而它没有项目分组可在侧栏里收拢。
pub async fn open_or_create(
    pool: &SqlitePool,
    device_id: &str,
    request: &ConversationCreate,
) -> Result<CreateOutcome, ConversationError> {
    // 判"有没有给标题"的规则与 `create` 里取占位标题的那段保持一致：
    // 只有空白的标题不算显式命名，仍走复用。
    let titled = request
        .title
        .as_deref()
        .is_some_and(|title| !title.trim().is_empty());
    if titled {
        return Ok(CreateOutcome {
            conversation: create(pool, device_id, request).await?,
            reused: false,
        });
    }

    let project_id = normalize_project_id(request.project_id.as_deref());
    if let Some(id) = project_id {
        ensure_project(pool, id).await?;
    }

    // 模式也参与匹配：不同模式的会话界面不一样，把一条 staged 的空白会话
    // 交给 text 请求，用户进错了界面还得再退出来。
    // 归档与软删的不算：那两种都不在侧栏里，复用等于跳进一个看不见的会话。
    //
    // 归属分两支查：有项目按 id 匹配，无归属按 `IS NULL`。
    // 不能把空串直接绑进 `project_id = ?`——库里存的是 NULL，永远匹配不上。
    let mode = request.mode.unwrap_or(ConversationMode::Text);
    let existing: Option<ConversationRow> =
        match project_id {
            Some(id) => sqlx::query_as(
                "SELECT id, project_id, title, mode, device_id, archived, created_at, updated_at \
                 FROM conversations \
                 WHERE project_id = ? AND title = ? AND mode = ? AND archived = 0 \
                   AND deleted_at IS NULL \
                 ORDER BY updated_at DESC, id DESC LIMIT 1",
            )
            .bind(id)
            .bind(DEFAULT_TITLE)
            .bind(mode.as_str())
            .fetch_optional(pool)
            .await?,
            None => sqlx::query_as(
                "SELECT id, project_id, title, mode, device_id, archived, created_at, updated_at \
                 FROM conversations \
                 WHERE project_id IS NULL AND title = ? AND mode = ? AND archived = 0 \
                   AND deleted_at IS NULL \
                 ORDER BY updated_at DESC, id DESC LIMIT 1",
            )
            .bind(DEFAULT_TITLE)
            .bind(mode.as_str())
            .fetch_optional(pool)
            .await?,
        };

    let Some(row) = existing else {
        return Ok(CreateOutcome {
            conversation: create(pool, device_id, request).await?,
            reused: false,
        });
    };

    // 复用也刷新 `updated_at`：列表按它倒序排，不刷新的话一条几天没动的空白会话
    // 会沉到列表中部——点了「新建会话」却在侧栏看不见它，像是没生效。
    let now = now_ms();
    sqlx::query("UPDATE conversations SET updated_at = ? WHERE id = ? AND deleted_at IS NULL")
        .bind(now)
        .bind(&row.id)
        .execute(pool)
        .await?;

    Ok(CreateOutcome {
        conversation: Conversation {
            updated_at: now,
            ..conversation_from_row(row)
        },
        reused: true,
    })
}

/// 归属项目归一化：`None` 与空白串同义，都表示「无归属直聊」。
///
/// 只有拿到真实 id 时才需要校验——会话挂到一个不存在的项目上等于把
/// 能力边界（Git 项目才能派编码任务）交给调用方。
fn normalize_project_id(raw: Option<&str>) -> Option<&str> {
    raw.map(str::trim).filter(|id| !id.is_empty())
}

/// 给出的项目必须存在且未被软删：项目决定能力边界（Git 项目才能派编码任务），
/// 允许挂到不存在的 id 上等于把边界判断交给调用方。
async fn ensure_project(pool: &SqlitePool, project_id: &str) -> Result<(), ConversationError> {
    if project_id.is_empty() {
        return Err(ConversationError::Invalid("project_id 不能为空"));
    }

    let exists: Option<String> =
        sqlx::query_scalar("SELECT id FROM projects WHERE id = ? AND deleted_at IS NULL")
            .bind(project_id)
            .fetch_optional(pool)
            .await?;
    if exists.is_none() {
        return Err(ConversationError::ProjectNotFound);
    }

    Ok(())
}

/// 会话列表，按 `updated_at` 倒序。返回 `(items, next_cursor)`。
///
/// `project_id` 为 `Some` 时只看该项目；`unassigned_only` 为真时只看
/// **无归属直聊**（侧栏「对话」分组），此时忽略 `project_id`。
///
/// 两者不能合成一个参数：空串在 `project_id` 语义里表示"不筛选"，
/// 而无归属必须用独立的布尔量表达，否则会退化成"返回全部会话"。
///
/// 列表用 `LEFT JOIN projects`：项目被软删后其会话不再露出，
/// 而没有归属的会话仍然可见——组织方式出问题不该让人以为会话丢了。
pub async fn list(
    pool: &SqlitePool,
    project_id: Option<&str>,
    unassigned_only: bool,
    cursor: Option<&str>,
    limit: u32,
) -> Result<(Vec<Conversation>, Option<Cursor>), ConversationError> {
    let limit = clamp_limit(limit)?;
    let fetch = i64::from(limit) + 1;
    let project_id = if unassigned_only {
        None
    } else {
        normalize_project_id(project_id)
    };
    let unassigned_only = i64::from(u8::from(unassigned_only));

    let rows = match cursor {
        Some(raw) => {
            let cursor = Cursor::decode(raw).ok_or(ConversationError::Invalid("cursor"))?;
            sqlx::query_as::<_, ConversationRow>(
                "SELECT c.id, c.project_id, c.title, c.mode, c.device_id, c.archived, \
                        c.created_at, c.updated_at \
                 FROM conversations c LEFT JOIN projects w ON w.id = c.project_id \
                 WHERE c.archived = 0 AND c.deleted_at IS NULL \
                   AND (w.id IS NULL OR w.deleted_at IS NULL) \
                   AND (? IS NULL OR c.project_id = ?) \
                   AND (? = 0 OR c.project_id IS NULL) \
                   AND (c.updated_at < ? OR (c.updated_at = ? AND c.id < ?)) \
                 ORDER BY c.updated_at DESC, c.id DESC LIMIT ?",
            )
            .bind(project_id)
            .bind(project_id)
            .bind(unassigned_only)
            .bind(cursor.updated_at)
            .bind(cursor.updated_at)
            .bind(&cursor.id)
            .bind(fetch)
            .fetch_all(pool)
            .await?
        }
        None => {
            sqlx::query_as::<_, ConversationRow>(
                "SELECT c.id, c.project_id, c.title, c.mode, c.device_id, c.archived, \
                        c.created_at, c.updated_at \
                 FROM conversations c LEFT JOIN projects w ON w.id = c.project_id \
                 WHERE c.archived = 0 AND c.deleted_at IS NULL \
                   AND (w.id IS NULL OR w.deleted_at IS NULL) \
                   AND (? IS NULL OR c.project_id = ?) \
                   AND (? = 0 OR c.project_id IS NULL) \
                 ORDER BY c.updated_at DESC, c.id DESC LIMIT ?",
            )
            .bind(project_id)
            .bind(project_id)
            .bind(unassigned_only)
            .bind(fetch)
            .fetch_all(pool)
            .await?
        }
    };

    Ok(split_page(rows, limit))
}

/// 会话详情（含最近消息，按时间正序）。
pub async fn detail(
    pool: &SqlitePool,
    id: &str,
    recent: u32,
) -> Result<Option<ConversationDetail>, ConversationError> {
    let Some(conversation) = get(pool, id).await? else {
        return Ok(None);
    };

    let mut recent_messages = fetch_recent(pool, id, i64::from(clamp_limit(recent)?)).await?;
    recent_messages.reverse();

    // 压缩状态与消息流分开读：它的失败不该让详情页整体打不开，
    // 所以查不到就当作"没有压缩"。
    let compaction = crate::compaction::view(pool, id).await.unwrap_or_else(|err| {
        tracing::warn!(%err, conversation_id = %id, "读取上下文压缩状态失败");
        None
    });

    Ok(Some(ConversationDetail {
        conversation,
        recent_messages,
        compaction,
    }))
}

pub async fn get(pool: &SqlitePool, id: &str) -> Result<Option<Conversation>, ConversationError> {
    let row = sqlx::query_as::<_, ConversationRow>(
        "SELECT id, project_id, title, mode, device_id, archived, created_at, updated_at \
         FROM conversations WHERE id = ? AND deleted_at IS NULL",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(conversation_from_row))
}

/// 逻辑删除会话：只写 `deleted_at`，会话行与消息都留在库里。
///
/// 会话下**已结束**的任务跟着一起软删（返回级联条数，供审计记账）；
/// 只挡**未结束**的任务：worker 可能正在向它上报事件，删掉会让状态机悬空。
/// 已软删的任务不算——它们已经不在可用视图里。
///
/// 整个流程在一个事务里完成：检查与写入不能分开，否则并发下会出现
/// "检查时都结束了、写入前又冒出一个 running"的窗口。
pub async fn delete(pool: &SqlitePool, id: &str) -> Result<usize, ConversationError> {
    let now = now_ms();
    // 必须 `BEGIN IMMEDIATE`，不能用默认的延迟事务：本函数先读（存在性、未结束任务）
    // 再写，而延迟事务在读之后升级写锁时，如果别的连接这段时间提交过（worker 上报事件、
    // 执行器写步骤都会发生），SQLite 会立刻返回 SQLITE_BUSY_SNAPSHOT —— 它不受
    // busy_timeout 保护，表现为偶发的 500「服务内部错误」。开事务时先拿写锁，
    // 冲突就回到 busy_timeout 的排队重试路径上。
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;

    let exists: Option<String> =
        sqlx::query_scalar("SELECT id FROM conversations WHERE id = ? AND deleted_at IS NULL")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
    if exists.is_none() {
        return Err(ConversationError::NotFound);
    }

    // 与 `TaskState::is_terminal()` 互为反面：显式列出未结束的四个状态，
    // 而不是 `NOT IN ('succeeded','failed','canceled')`——将来新增终态时，
    // 显式清单会漏掉、NOT IN 会多挡，前者错在"多拦一次"，后者错在"删掉活任务"。
    let unfinished: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM tasks WHERE conversation_id = ? AND deleted_at IS NULL \
           AND state IN ('queued', 'running', 'needs_input', 'needs_approval')",
    )
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;
    if unfinished > 0 {
        return Err(ConversationError::Conflict(
            "会话下还有未结束的任务，请先取消或等它结束再删会话",
        ));
    }

    // 级联软删：与 `task::delete` 保持同一套语义。幂等键必须一起清掉——
    // 唯一索引不区分是否已删，键留着会让同一个键永远建不出新任务。
    let cascaded = sqlx::query(
        "UPDATE tasks SET deleted_at = ?, idempotency_key = NULL \
         WHERE conversation_id = ? AND deleted_at IS NULL",
    )
    .bind(now)
    .bind(id)
    .execute(&mut *tx)
    .await?
    .rows_affected() as usize;

    let updated =
        sqlx::query("UPDATE conversations SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL")
            .bind(now)
            .bind(id)
            .execute(&mut *tx)
            .await?;
    if updated.rows_affected() == 0 {
        // 并发下已被另一个请求删掉：对外仍按"不存在"处理。
        return Err(ConversationError::NotFound);
    }

    tx.commit().await?;
    Ok(cascaded)
}

/// 标题是否还是占位的那一个。
///
/// 只认 [`DEFAULT_TITLE`]：客户端显式传过标题（哪怕是"新会话"字样）也视为
/// 用户自己的命名，系统不再改动。
pub async fn has_default_title(pool: &SqlitePool, id: &str) -> Result<bool, ConversationError> {
    let title: Option<String> =
        sqlx::query_scalar("SELECT title FROM conversations WHERE id = ? AND deleted_at IS NULL")
            .bind(id)
            .fetch_optional(pool)
            .await?;
    Ok(title.as_deref() == Some(DEFAULT_TITLE))
}

/// 会话里最早的一条用户消息正文。
///
/// 标题取"用户第一次提问"而不是最新一条：会话的主题在第一句就定了，
/// 后面越聊越偏时按最新消息改名会让列表来回跳。
pub async fn first_user_content(
    pool: &SqlitePool,
    id: &str,
) -> Result<Option<String>, ConversationError> {
    let row: Option<String> = sqlx::query_scalar(
        "SELECT content_json FROM messages \
         WHERE conversation_id = ? AND role = 'user' \
         ORDER BY seq ASC LIMIT 1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row
        .map(|content_json| content_text(&content_json))
        .filter(|text| !text.trim().is_empty()))
}

/// 仍是占位标题的会话 id，供启动时回填。
pub async fn ids_with_default_title(pool: &SqlitePool) -> Result<Vec<String>, ConversationError> {
    let rows: Vec<String> = sqlx::query_scalar(
        "SELECT id FROM conversations WHERE title = ? AND deleted_at IS NULL \
             ORDER BY updated_at DESC",
    )
    .bind(DEFAULT_TITLE)
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// 只在标题仍是占位时写入。返回是否真的更新了。
///
/// `WHERE title = ?` 让"生成期间用户已经改过名"这种情况自动落空，
/// 不需要额外的读-判断-写窗口。
pub async fn set_title_if_default(
    pool: &SqlitePool,
    id: &str,
    title: &str,
) -> Result<bool, ConversationError> {
    let result = sqlx::query(
        "UPDATE conversations SET title = ? WHERE id = ? AND title = ? AND deleted_at IS NULL",
    )
    .bind(title)
    .bind(id)
    .bind(DEFAULT_TITLE)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() > 0)
}

/// 校验用户自己起的标题：trim 后非空、不超过 [`MAX_TITLE_CHARS`]。
///
/// 与自动生成的标题同一口径——列表一行放得下，也不会把栏头撑开。
/// `ConversationError::Invalid` 只带 `&'static str`，所以提示里不写具体字数：
/// 为一句变长文案把整条错误链换成 `String` 不值当。
fn validate_title(raw: &str) -> Result<String, ConversationError> {
    let title = raw.trim();
    if title.is_empty() {
        return Err(ConversationError::Invalid("会话标题不能为空"));
    }
    if title.chars().count() > MAX_TITLE_CHARS {
        return Err(ConversationError::Invalid("会话标题过长，请改短一些"));
    }
    Ok(title.to_string())
}

/// 重命名会话：只改标题，归属项目与模式不动。
///
/// **刻意不更新 `updated_at`**：它是会话列表的游标排序键（`idx_conversations_cursor`），
/// 改名不是"会话里有了新动静"，顺带刷新时间会让它莫名跳到列表最前。
/// 这一点与 [`crate::project::rename`] 不同，是有意为之，spec 里也写明了。
pub async fn rename(
    pool: &SqlitePool,
    id: &str,
    title: &str,
) -> Result<Conversation, ConversationError> {
    let title = validate_title(title)?;

    let affected =
        sqlx::query("UPDATE conversations SET title = ? WHERE id = ? AND deleted_at IS NULL")
            .bind(&title)
            .bind(id)
            .execute(pool)
            .await?
            .rows_affected();
    if affected == 0 {
        return Err(ConversationError::NotFound);
    }

    get(pool, id).await?.ok_or(ConversationError::NotFound)
}

/// 追加消息。
///
/// `client_msg_id` 非空时具备幂等性：重复提交返回已存在的那条，不再插入。
pub async fn append_message(
    pool: &SqlitePool,
    conversation_id: &str,
    role: MessageRole,
    content: &str,
    task_id: Option<&str>,
    client_msg_id: Option<&str>,
) -> Result<Message, ConversationError> {
    append_message_with_id(
        pool,
        &new_id("msg"),
        conversation_id,
        role,
        content,
        task_id,
        client_msg_id,
    )
    .await
}

/// 追加一条用户消息：可以只带附件、不带正文。
///
/// 与 [`append_message`] 相比只差两点：
/// - **允许空正文**——附件本身就是内容，"只发一张图"是完整意图；
/// - 附件元信息随 `content_json` 一起落库，历史回看才有芯片可画。
///
/// 幂等键语义与 [`append_message`] 完全一致（同一 `client_msg_id` 返回既有那条），
/// 所以调用方重发时不必再判一次。
pub async fn append_user_message(
    pool: &SqlitePool,
    conversation_id: &str,
    content: &str,
    client_msg_id: Option<&str>,
    attachments: &[Attachment],
) -> Result<Message, ConversationError> {
    if content.trim().is_empty() && attachments.is_empty() {
        return Err(ConversationError::Invalid("content 不能为空"));
    }

    if get(pool, conversation_id).await?.is_none() {
        return Err(ConversationError::NotFound);
    }

    if let Some(client_msg_id) = client_msg_id {
        if let Some(existing) = find_by_client_id(pool, conversation_id, client_msg_id).await? {
            return Ok(existing);
        }
    }

    let mut payload = serde_json::json!({ "text": content });
    if !attachments.is_empty() {
        payload["attachments"] = serde_json::json!(attachments);
    }

    insert_message(
        pool,
        &new_id("msg"),
        conversation_id,
        MessageRole::User,
        content,
        &payload.to_string(),
        None,
        client_msg_id,
        MessageMetrics::default(),
    )
    .await
}

/// 指定 id 追加消息。
///
/// 流式回答必须在第一个分片发出前就确定 `message_id`（否则客户端拿不到稳定的 id），
/// 但消息体要到流结束才完整，因此需要"先定 id、后插入"。
#[allow(clippy::too_many_arguments)]
pub async fn append_message_with_id(
    pool: &SqlitePool,
    id: &str,
    conversation_id: &str,
    role: MessageRole,
    content: &str,
    task_id: Option<&str>,
    client_msg_id: Option<&str>,
) -> Result<Message, ConversationError> {
    if content.trim().is_empty() {
        return Err(ConversationError::Invalid("content 不能为空"));
    }

    if get(pool, conversation_id).await?.is_none() {
        return Err(ConversationError::NotFound);
    }

    if let Some(client_msg_id) = client_msg_id {
        if let Some(existing) = find_by_client_id(pool, conversation_id, client_msg_id).await? {
            return Ok(existing);
        }
    }

    let content_json = serde_json::json!({ "text": content }).to_string();
    insert_message(
        pool,
        id,
        conversation_id,
        role,
        content,
        &content_json,
        task_id,
        client_msg_id,
        MessageMetrics::default(),
    )
    .await
}

/// 一条消息的统计元信息：耗时与 token 用量。
///
/// 单独成结构而不是塞进 `Message`：只有回答才需要这两个数，用户消息恒为默认值；
/// 落库入口拿到它即可，读路径也不必逐字段拆参数。
#[derive(Debug, Clone, Copy, Default)]
pub struct MessageMetrics {
    /// 从收到提问到答案落库的毫秒数。
    pub elapsed_ms: Option<i64>,
    pub prompt_tokens: Option<u32>,
    pub completion_tokens: Option<u32>,
    /// 本轮最后一次模型调用的输入 token 数（当前上下文长度）。
    ///
    /// 与 `prompt_tokens` 不同：后者是整轮累加值。历史行为 NULL，
    /// 读回为 0——没有真实采样时宁可不显示占比，也不拿累加值充数。
    pub context_tokens: Option<u32>,
    /// 用量是不是按字符估算出来的。
    pub tokens_estimated: bool,
    /// 回答终态（`stop` / `error` / `stopped`）；`None` 表示没记录，读回按已完成处理。
    ///
    /// 用 `&'static str` 而不是 `String`：取值只有几个常量，
    /// 这样加字段不会把这个结构从 `Copy` 变成只能 clone。
    pub finish_reason: Option<&'static str>,
}

impl MessageMetrics {
    /// 从模型侧的耗时与用量组装；两项都缺时退化成默认值。
    pub fn new(elapsed_ms: i64, usage: Option<TokenUsage>) -> Self {
        match usage {
            Some(usage) if !usage.is_empty() => Self {
                elapsed_ms: Some(elapsed_ms),
                prompt_tokens: Some(usage.prompt_tokens),
                completion_tokens: Some(usage.completion_tokens),
                context_tokens: Some(usage.context_tokens),
                tokens_estimated: usage.tokens_estimated,
                finish_reason: None,
            },
            // 没开模型或网关没给 usage：耗时仍然有意义，用量留空。
            _ => Self {
                elapsed_ms: Some(elapsed_ms),
                ..Self::default()
            },
        }
    }

    /// 标上回答终态。只有落库这一刻知道答案是怎么结束的，所以单独一步，
    /// 不影响 [`MessageMetrics::new`] 的既有调用点。
    pub fn with_finish_reason(mut self, reason: &'static str) -> Self {
        self.finish_reason = Some(reason);
        self
    }

    /// 读回时把各列还原成协议里的 `TokenUsage`；没有任何计数就是 `None`。
    fn usage(self) -> Option<TokenUsage> {
        match (self.prompt_tokens, self.completion_tokens) {
            (None, None) => None,
            (prompt_tokens, completion_tokens) => Some(TokenUsage {
                prompt_tokens: prompt_tokens.unwrap_or(0),
                completion_tokens: completion_tokens.unwrap_or(0),
                tokens_estimated: self.tokens_estimated,
                // 历史行没有这一列：读回 0，客户端显示空环。
                context_tokens: self.context_tokens.unwrap_or(0),
            }),
        }
    }
}

/// 落库一条带来源、建议与产物文件卡的回答。
///
/// `sources` 只存地址与采集时间，不存正文——正文已经在 `text` 里，重复存会让库膨胀。
/// `suggestions` 是"要不要我办"的提议，与实时事件同源：历史回看也能看到建议卡。
/// `file_writes` 同理：卡片状态（含待确认）必须与实时事件一致，否则刷新后
/// 用户会看到一张"又能点一次"的旧卡。
///
/// `steps` 是这一轮的执行过程：只推不存的话，刷新之后"刚才做了什么"就没处看，
/// 而这恰恰是用户最常回头确认的东西。
#[allow(clippy::too_many_arguments)]
pub async fn append_assistant_with_sources(
    pool: &SqlitePool,
    id: &str,
    conversation_id: &str,
    text: &str,
    sources: &[crate::tool_gateway::Source],
    suggestions: &[TaskSuggestion],
    file_writes: &[FileWrite],
    media: &[MediaAsset],
    steps: &[MessageStep],
    metrics: MessageMetrics,
) -> Result<Message, ConversationError> {
    if text.trim().is_empty() {
        return Err(ConversationError::Invalid("content 不能为空"));
    }
    if get(pool, conversation_id).await?.is_none() {
        return Err(ConversationError::NotFound);
    }

    let mut content = serde_json::json!({ "text": text });
    if !sources.is_empty() {
        content["sources"] = serde_json::Value::Array(
            sources
                .iter()
                .map(|source| {
                    // 透传 kind / memory_id：不加列、不迁移，老行没有这两个键，
                    // 读取侧靠 `#[serde(default)]` 兜底（见 protocol::SourceKind）。
                    let mut value = serde_json::json!({
                        "url": source.url,
                        "fetched_at": source.fetched_at,
                        "kind": source.kind,
                    });
                    if let Some(memory_id) = &source.memory_id {
                        value["memory_id"] = serde_json::json!(memory_id);
                    }
                    value
                })
                .collect(),
        );
    }
    if !suggestions.is_empty() {
        content["task_suggestions"] = serde_json::json!(suggestions);
    }
    if !file_writes.is_empty() {
        content["file_writes"] = serde_json::json!(file_writes);
    }
    if !media.is_empty() {
        content["media"] = serde_json::json!(media);
    }
    if !steps.is_empty() {
        content["steps"] = serde_json::json!(steps);
    }

    insert_message(
        pool,
        id,
        conversation_id,
        MessageRole::Assistant,
        text,
        &content.to_string(),
        None,
        None,
        metrics,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn insert_message(
    pool: &SqlitePool,
    id: &str,
    conversation_id: &str,
    role: MessageRole,
    content: &str,
    content_json: &str,
    task_id: Option<&str>,
    client_msg_id: Option<&str>,
    metrics: MessageMetrics,
) -> Result<Message, ConversationError> {
    let now = now_ms();
    let message = Message {
        id: id.to_string(),
        conversation_id: conversation_id.to_string(),
        role,
        content: content.to_string(),
        sources: sources_from_json(content_json),
        task_suggestions: suggestions_from_json(content_json),
        file_writes: file_writes_from_json(content_json),
        steps: steps_from_json(content_json),
        media: media_from_json(content_json),
        attachments: crate::attachment::from_content_json(content_json),
        task_id: task_id.map(str::to_string),
        created_at: now,
        elapsed_ms: metrics.elapsed_ms,
        usage: metrics.usage(),
        finish_reason: metrics.finish_reason.map(str::to_string),
    };

    // 单条语句里取 MAX(seq)+1：读与写在同一写语句内完成，避免并发下算出同一个序号。
    let insert = sqlx::query(
        "INSERT INTO messages (id, conversation_id, role, content_json, task_id, created_at, \
                client_msg_id, seq, elapsed_ms, prompt_tokens, completion_tokens, context_tokens, \
                tokens_estimated, finish_reason) \
         SELECT ?, ?, ?, ?, ?, ?, ?, COALESCE(MAX(seq), 0) + 1, ?, ?, ?, ?, ?, ? \
         FROM messages WHERE conversation_id = ?",
    )
    .bind(&message.id)
    .bind(&message.conversation_id)
    .bind(role.as_str())
    .bind(content_json)
    .bind(message.task_id.as_deref())
    .bind(now)
    .bind(client_msg_id)
    .bind(metrics.elapsed_ms)
    .bind(metrics.prompt_tokens)
    .bind(metrics.completion_tokens)
    .bind(metrics.context_tokens)
    .bind(i64::from(metrics.tokens_estimated))
    .bind(metrics.finish_reason)
    .bind(conversation_id)
    .execute(pool)
    .await;

    match insert {
        Ok(_) => {}
        Err(err) => {
            // 并发重复提交会撞唯一索引：此时返回已存在的那条，而不是报错。
            if let Some(client_msg_id) = client_msg_id {
                if let Some(existing) =
                    find_by_client_id(pool, conversation_id, client_msg_id).await?
                {
                    return Ok(existing);
                }
            }
            return Err(err.into());
        }
    }

    touch(pool, conversation_id, now).await?;

    Ok(message)
}

/// 消息分页（倒序，与客户端"往上翻历史"的交互一致）。
pub async fn list_messages(
    pool: &SqlitePool,
    conversation_id: &str,
    cursor: Option<&str>,
    limit: u32,
) -> Result<(Vec<Message>, Option<Cursor>), ConversationError> {
    if get(pool, conversation_id).await?.is_none() {
        return Err(ConversationError::NotFound);
    }

    let limit = clamp_limit(limit)?;
    let fetch = i64::from(limit) + 1;

    let rows = match cursor {
        Some(raw) => {
            let cursor = Cursor::decode(raw).ok_or(ConversationError::Invalid("cursor"))?;
            sqlx::query_as::<_, MessageRow>(
                "SELECT id, conversation_id, role, content_json, task_id, created_at, seq, \
                 elapsed_ms, prompt_tokens, completion_tokens, context_tokens, tokens_estimated, \
                 finish_reason \
                 FROM messages \
                 WHERE conversation_id = ? AND seq < ? \
                 ORDER BY seq DESC LIMIT ?",
            )
            .bind(conversation_id)
            .bind(cursor.updated_at)
            .bind(fetch)
            .fetch_all(pool)
            .await?
        }
        None => {
            sqlx::query_as::<_, MessageRow>(
                "SELECT id, conversation_id, role, content_json, task_id, created_at, seq, \
                 elapsed_ms, prompt_tokens, completion_tokens, context_tokens, tokens_estimated, \
                 finish_reason \
                 FROM messages WHERE conversation_id = ? \
                 ORDER BY seq DESC LIMIT ?",
            )
            .bind(conversation_id)
            .bind(fetch)
            .fetch_all(pool)
            .await?
        }
    };

    Ok(split_message_page(rows, limit))
}

/// 组装上下文：最近 N 条消息 + 一条"前面还有多少条"的省略提示。
///
/// M3 不做模型摘要（那需要 provider）；这里用确定性文本，保证同一份历史
/// 每次都得到同样的上下文，便于测试与排障。
pub async fn build_context(
    pool: &SqlitePool,
    conversation_id: &str,
    max_messages: usize,
) -> Result<String, ConversationError> {
    if get(pool, conversation_id).await?.is_none() {
        return Err(ConversationError::NotFound);
    }

    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM messages WHERE conversation_id = ?")
        .bind(conversation_id)
        .fetch_one(pool)
        .await?;

    let mut recent = fetch_recent(pool, conversation_id, max_messages as i64).await?;
    recent.reverse();

    let omitted = (total as usize).saturating_sub(recent.len());
    let mut lines = Vec::with_capacity(recent.len() + 1);
    if omitted > 0 {
        lines.push(format!("（更早的 {omitted} 条消息已省略）"));
    }
    for message in recent {
        let label = match message.role {
            MessageRole::User => "用户",
            MessageRole::Assistant => "助理",
            MessageRole::Tool => "工具",
            MessageRole::System => "系统",
        };
        lines.push(format!(
            "{label}: {}",
            truncate(&message.content, MAX_MESSAGE_CHARS)
        ));
    }

    Ok(lines.join("\n"))
}

/// 组装给模型的消息序列：系统提示 + 最近若干轮 + 一条省略提示。
///
/// 与 [`build_context`] 的区别：这里保留角色结构，模型才能理解多轮对话；
/// `build_context` 是给日志与调试看的纯文本视图。
pub async fn build_messages(
    pool: &SqlitePool,
    conversation_id: &str,
    max_messages: usize,
) -> Result<Vec<PromptMessage>, ConversationError> {
    build_messages_with(pool, conversation_id, max_messages, None).await
}

/// 带上下文压缩的版本：有可用摘要时把它前置，再拼 `seq > upto_seq` 的最近消息。
///
/// `None` 与 [`build_messages`] 逐字等价——压缩关掉或不可用时走的正是这条路径。
pub async fn build_messages_with(
    pool: &SqlitePool,
    conversation_id: &str,
    max_messages: usize,
    compaction: Option<&crate::compaction::Active>,
) -> Result<Vec<PromptMessage>, ConversationError> {
    if get(pool, conversation_id).await?.is_none() {
        return Err(ConversationError::NotFound);
    }

    let after = compaction.map(|active| active.upto_seq).unwrap_or(0);
    let total = count_replayable_after(pool, conversation_id, after).await?;
    let mut recent = fetch_recent_after(pool, conversation_id, after, max_messages as i64).await?;
    recent.reverse();

    let mut messages = Vec::with_capacity(recent.len() + 2);

    if let Some(active) = compaction {
        messages.push(PromptMessage::system(summary_notice(&active.summary)));
    }

    let omitted = total.saturating_sub(recent.len());
    if omitted > 0 {
        messages.push(PromptMessage::system(omitted_notice(omitted)));
    }

    for message in recent {
        let content = truncate(&message.content, MAX_MESSAGE_CHARS * 2);
        match message.role {
            MessageRole::User => messages.push(PromptMessage::user(with_attachment_note(
                content,
                &message.attachments,
            ))),
            MessageRole::Assistant => messages.push(PromptMessage::assistant(content)),
            // 工具与系统消息暂不送入模型：当前还没有工具调用协议。
            MessageRole::Tool | MessageRole::System => {}
        }
    }

    Ok(messages)
}

/// 把最近若干条消息转成带角色的对话消息，供模型使用。
pub async fn build_chat_messages(
    pool: &SqlitePool,
    conversation_id: &str,
    max_messages: usize,
) -> Result<Vec<crate::chat::ChatMessage>, ConversationError> {
    build_chat_messages_with(pool, conversation_id, max_messages, None).await
}

/// 带上下文压缩的版本，对应 [`build_chat_messages`]。
pub async fn build_chat_messages_with(
    pool: &SqlitePool,
    conversation_id: &str,
    max_messages: usize,
    compaction: Option<&crate::compaction::Active>,
) -> Result<Vec<crate::chat::ChatMessage>, ConversationError> {
    if get(pool, conversation_id).await?.is_none() {
        return Err(ConversationError::NotFound);
    }

    let after = compaction.map(|active| active.upto_seq).unwrap_or(0);
    let total = count_replayable_after(pool, conversation_id, after).await?;
    let mut recent = fetch_recent_after(pool, conversation_id, after, max_messages as i64).await?;
    recent.reverse();

    let mut messages = Vec::with_capacity(recent.len() + 2);
    if let Some(active) = compaction {
        messages.push(crate::chat::ChatMessage::system(summary_notice(
            &active.summary,
        )));
    }

    let omitted = total.saturating_sub(recent.len());
    if omitted > 0 {
        messages.push(crate::chat::ChatMessage::system(omitted_notice(omitted)));
    }

    for message in recent {
        let content = truncate(&message.content, MAX_MESSAGE_CHARS * 2);
        match message.role {
            MessageRole::User => messages.push(crate::chat::ChatMessage::user(
                with_attachment_note(content, &message.attachments),
            )),
            MessageRole::Assistant => {
                messages.push(crate::chat::ChatMessage::assistant(content, Vec::new()))
            }
            MessageRole::Tool | MessageRole::System => {}
        }
    }

    Ok(messages)
}

/// 摘要注入的措辞。
///
/// 明说"原文仍在历史里"很重要：否则模型会把摘要当成唯一事实，
/// 用户问"刚才原话是什么"时它就开始编。
fn summary_notice(summary: &str) -> String {
    format!(
        "以下是本会话更早内容的摘要（原文仍保存在历史消息里，用户提到细节时可以请他回看）：\n\n{summary}"
    )
}

fn omitted_notice(omitted: usize) -> String {
    format!("（更早的 {omitted} 条消息已省略）")
}

/// 取 `seq > after` 的最近 N 条**可重放**消息（新到旧）。
///
/// 与 [`fetch_recent`] 的差别只在过滤：这里在 SQL 里就排掉 `tool` / `system`，
/// 窗口条数才是"真正送进模型的条数"。
async fn fetch_recent_after(
    pool: &SqlitePool,
    conversation_id: &str,
    after: i64,
    limit: i64,
) -> Result<Vec<Message>, ConversationError> {
    let rows = sqlx::query_as::<_, MessageRow>(
        "SELECT id, conversation_id, role, content_json, task_id, created_at, seq, \
                elapsed_ms, prompt_tokens, completion_tokens, context_tokens, tokens_estimated, \
                finish_reason \
         FROM messages WHERE conversation_id = ? AND role IN ('user','assistant') AND seq > ? \
         ORDER BY seq DESC LIMIT ?",
    )
    .bind(conversation_id)
    .bind(after)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(message_from_row).collect())
}

/// 历史消息里的附件只留一行名字清单。
///
/// 正文不重发：一张图 base64 后几 MB，每轮都带上等于把上下文和请求体一起撑爆。
/// 但也不能什么都不说——模型至少要知道"那轮用户给了哪些文件"，
/// 否则它会以为自己凭空收到一句没头没尾的问题。
fn with_attachment_note(content: String, attachments: &[Attachment]) -> String {
    let Some(note) = crate::attachment::history_note(attachments) else {
        return content;
    };
    if content.trim().is_empty() {
        return note;
    }
    format!("{content}\n{note}")
}

/// 统计 `seq > after` 的可重放消息数（只有 user / assistant 会进上下文）。
///
/// 压缩的触发与边界都只认这一组消息：`Tool` / `System` 行不参与装配，
/// 把它们算进去会让"还剩多少条没压"与"实际送进去多少条"对不上。
pub async fn count_replayable_after(
    pool: &SqlitePool,
    conversation_id: &str,
    after: i64,
) -> Result<usize, ConversationError> {
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM messages \
         WHERE conversation_id = ? AND role IN ('user','assistant') AND seq > ?",
    )
    .bind(conversation_id)
    .bind(after)
    .fetch_one(pool)
    .await?;

    Ok(usize::try_from(count).unwrap_or(usize::MAX))
}

/// 压缩边界：从尾部数第 `keep + 1` 条可重放消息的 `seq`。
///
/// 这一条是**第一条被折叠**的消息（含），所以装配时取 `seq > 返回值`。
/// 可重放消息不足 `keep + 1` 条时返回 `None`——那时没有任何东西值得压。
pub async fn boundary_seq(
    pool: &SqlitePool,
    conversation_id: &str,
    after: i64,
    keep: usize,
) -> Result<Option<i64>, ConversationError> {
    let seq: Option<i64> = sqlx::query_scalar(
        "SELECT seq FROM messages \
         WHERE conversation_id = ? AND role IN ('user','assistant') AND seq > ? \
         ORDER BY seq DESC LIMIT 1 OFFSET ?",
    )
    .bind(conversation_id)
    .bind(after)
    .bind(i64::try_from(keep).unwrap_or(i64::MAX))
    .fetch_optional(pool)
    .await?;

    Ok(seq)
}

/// 取 `(after, upto]` 区间内的可重放消息，按 `seq` 正序。
pub async fn replayable_between(
    pool: &SqlitePool,
    conversation_id: &str,
    after: i64,
    upto: i64,
) -> Result<Vec<Message>, ConversationError> {
    let rows = sqlx::query_as::<_, MessageRow>(
        "SELECT id, conversation_id, role, content_json, task_id, created_at, seq, \
                elapsed_ms, prompt_tokens, completion_tokens, context_tokens, tokens_estimated, \
                finish_reason \
         FROM messages WHERE conversation_id = ? AND role IN ('user','assistant') \
           AND seq > ? AND seq <= ? \
         ORDER BY seq ASC",
    )
    .bind(conversation_id)
    .bind(after)
    .bind(upto)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(message_from_row).collect())
}

/// 压缩边界之后第一条消息的 id。
///
/// 客户端拿它在消息流里插一条"更早 N 条已整理"的横条。这是**位置锚点**，
/// 不是区间端点：别把它当某段消息的开始去算长度（未来支持多段压缩时，
/// 位置会变得不连续，那时需要的是区间而不是单点）。
pub async fn anchor_message_id(
    pool: &SqlitePool,
    conversation_id: &str,
    upto_seq: i64,
) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT id FROM messages WHERE conversation_id = ? AND seq > ? \
         ORDER BY seq ASC LIMIT 1",
    )
    .bind(conversation_id)
    .bind(upto_seq)
    .fetch_optional(pool)
    .await
}

async fn fetch_recent(
    pool: &SqlitePool,
    conversation_id: &str,
    limit: i64,
) -> Result<Vec<Message>, ConversationError> {
    let rows = sqlx::query_as::<_, MessageRow>(
        "SELECT id, conversation_id, role, content_json, task_id, created_at, seq, \
                 elapsed_ms, prompt_tokens, completion_tokens, context_tokens, tokens_estimated, \
                 finish_reason \
         FROM messages WHERE conversation_id = ? \
         ORDER BY seq DESC LIMIT ?",
    )
    .bind(conversation_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(message_from_row).collect())
}

/// 按幂等键查消息。`append_message` 内部用它做去重，会话链路也用它判断
/// "这条用户消息是不是重发"（重发时不该重复执行显式记忆写入）。
pub(crate) async fn find_by_client_id(
    pool: &SqlitePool,
    conversation_id: &str,
    client_msg_id: &str,
) -> Result<Option<Message>, ConversationError> {
    let row = sqlx::query_as::<_, MessageRow>(
        "SELECT id, conversation_id, role, content_json, task_id, created_at, seq, \
                 elapsed_ms, prompt_tokens, completion_tokens, context_tokens, tokens_estimated, \
                 finish_reason \
         FROM messages WHERE conversation_id = ? AND client_msg_id = ?",
    )
    .bind(conversation_id)
    .bind(client_msg_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(message_from_row))
}

async fn touch(
    pool: &SqlitePool,
    conversation_id: &str,
    now: i64,
) -> Result<(), ConversationError> {
    sqlx::query("UPDATE conversations SET updated_at = ? WHERE id = ? AND deleted_at IS NULL")
        .bind(now)
        .bind(conversation_id)
        .execute(pool)
        .await?;
    Ok(())
}

fn clamp_limit(limit: u32) -> Result<u32, ConversationError> {
    match limit {
        0 => Err(ConversationError::Invalid("limit 必须大于 0")),
        value if value > 100 => Ok(100),
        value => Ok(value),
    }
}

fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut truncated: String = text.chars().take(max_chars).collect();
    truncated.push('…');
    truncated
}

fn split_page(mut rows: Vec<ConversationRow>, limit: u32) -> (Vec<Conversation>, Option<Cursor>) {
    let has_more = rows.len() > limit as usize;
    if has_more {
        rows.truncate(limit as usize);
    }
    let next = if has_more {
        rows.last()
            .map(|row| Cursor::new(row.updated_at, row.id.clone()))
    } else {
        None
    };
    (rows.into_iter().map(conversation_from_row).collect(), next)
}

fn split_message_page(mut rows: Vec<MessageRow>, limit: u32) -> (Vec<Message>, Option<Cursor>) {
    let has_more = rows.len() > limit as usize;
    if has_more {
        rows.truncate(limit as usize);
    }
    let next = if has_more {
        // 游标携带会话内序号，而不是时间戳：同一毫秒内的两条消息也能稳定翻页。
        rows.last().map(|row| Cursor::new(row.seq, row.id.clone()))
    } else {
        None
    };
    (rows.into_iter().map(message_from_row).collect(), next)
}

#[derive(Debug, sqlx::FromRow)]
struct ConversationRow {
    id: String,
    /// 升级前创建、且回填失败的历史会话才会为空；正常路径下一定有值。
    project_id: Option<String>,
    title: String,
    mode: String,
    device_id: Option<String>,
    archived: i64,
    created_at: i64,
    updated_at: i64,
}

fn conversation_from_row(row: ConversationRow) -> Conversation {
    Conversation {
        id: row.id,
        project_id: row.project_id.unwrap_or_default(),
        title: row.title,
        mode: ConversationMode::parse(&row.mode).unwrap_or(ConversationMode::Text),
        device_id: row.device_id,
        archived: row.archived != 0,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

#[derive(Debug, sqlx::FromRow)]
struct MessageRow {
    id: String,
    conversation_id: String,
    role: String,
    content_json: String,
    task_id: Option<String>,
    created_at: i64,
    seq: i64,
    elapsed_ms: Option<i64>,
    prompt_tokens: Option<i64>,
    completion_tokens: Option<i64>,
    /// 历史行（本列出现之前写入的）为 NULL：读回 0，环形按 0% 显示。
    context_tokens: Option<i64>,
    tokens_estimated: i64,
    /// 历史行（本列出现之前写入的）为 NULL，读回后按"已完成"处理。
    finish_reason: Option<String>,
}

fn message_from_row(row: MessageRow) -> Message {
    let content = content_text(&row.content_json);
    let metrics = MessageMetrics {
        elapsed_ms: row.elapsed_ms,
        prompt_tokens: row
            .prompt_tokens
            .and_then(|value| u32::try_from(value).ok()),
        completion_tokens: row
            .completion_tokens
            .and_then(|value| u32::try_from(value).ok()),
        context_tokens: row
            .context_tokens
            .and_then(|value| u32::try_from(value).ok()),
        tokens_estimated: row.tokens_estimated != 0,
        finish_reason: None,
    };

    Message {
        id: row.id,
        conversation_id: row.conversation_id,
        role: MessageRole::parse(&row.role).unwrap_or(MessageRole::System),
        content,
        sources: sources_from_json(&row.content_json),
        task_suggestions: suggestions_from_json(&row.content_json),
        file_writes: file_writes_from_json(&row.content_json),
        steps: steps_from_json(&row.content_json),
        media: media_from_json(&row.content_json),
        attachments: crate::attachment::from_content_json(&row.content_json),
        task_id: row.task_id,
        created_at: row.created_at,
        elapsed_ms: metrics.elapsed_ms,
        usage: metrics.usage(),
        finish_reason: row.finish_reason,
    }
}

/// 从 `content_json` 里取出正文。
///
/// 消息表不单独存正文列：`content_json` 是唯一真相，正文只是它的一个键。
pub(crate) fn content_text(content_json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(content_json)
        .ok()
        .and_then(|value| {
            value
                .get("text")
                .and_then(|text| text.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default()
}

/// 从 `content_json` 里取出 `sources`。
///
/// 解析失败一律当"没有来源"：历史里可能留着早期格式的消息，
/// 缺来源只影响卡片显示，不该让整条历史查询失败。
fn sources_from_json(content_json: &str) -> Vec<MessageSource> {
    serde_json::from_str::<serde_json::Value>(content_json)
        .ok()
        .and_then(|value| value.get("sources").cloned())
        .and_then(|sources| serde_json::from_value::<Vec<MessageSource>>(sources).ok())
        .unwrap_or_default()
}

/// 从 `content_json` 里取出 `task_suggestions`。解析失败同样是"没有建议"，
/// 老数据的 `content_json` 里没有这个键，不能因此让历史查询失败。
fn suggestions_from_json(content_json: &str) -> Vec<TaskSuggestion> {
    serde_json::from_str::<serde_json::Value>(content_json)
        .ok()
        .and_then(|value| value.get("task_suggestions").cloned())
        .and_then(|items| serde_json::from_value::<Vec<TaskSuggestion>>(items).ok())
        .unwrap_or_default()
}

/// 从 `content_json` 里取出生成的文件卡片。形状不对就当没有：
/// 一张卡片读失败不该让整段历史消失。
fn file_writes_from_json(content_json: &str) -> Vec<FileWrite> {
    serde_json::from_str::<serde_json::Value>(content_json)
        .ok()
        .and_then(|value| value.get("file_writes").cloned())
        .and_then(|items| serde_json::from_value::<Vec<FileWrite>>(items).ok())
        .unwrap_or_default()
}

/// 从 `content_json` 里取出生成的图片 / 视频。老数据没有这个键，解析为空列表。
fn media_from_json(content_json: &str) -> Vec<MediaAsset> {
    serde_json::from_str::<serde_json::Value>(content_json)
        .ok()
        .and_then(|value| value.get("media").cloned())
        .and_then(|items| serde_json::from_value::<Vec<MediaAsset>>(items).ok())
        .unwrap_or_default()
}

/// 从 `content_json` 里取出执行过程。老数据没有这个键，解析为空列表——
/// "没记录过过程"与"这一轮没调工具"对界面是同一件事。
fn steps_from_json(content_json: &str) -> Vec<MessageStep> {
    serde_json::from_str::<serde_json::Value>(content_json)
        .ok()
        .and_then(|value| value.get("steps").cloned())
        .and_then(|items| serde_json::from_value::<Vec<MessageStep>>(items).ok())
        .unwrap_or_default()
}

/// 更新一条消息里某张文件卡片的状态（覆盖决策之后调用）。
///
/// 状态必须同步回 `content_json`：否则用户刷新一次，已经处理过的请求
/// 又会显示成"待确认"，点下去只会拿到 `conflict`。
///
/// 消息或卡片找不到时静默返回：决策本身已经生效，
/// 因为一条历史消息的展示问题让整个请求失败，只会让用户重复点。
pub async fn update_file_write_status(
    pool: &SqlitePool,
    message_id: &str,
    request_id: &str,
    status: &str,
    backup_path: Option<&str>,
) -> Result<(), ConversationError> {
    let row = sqlx::query_as::<_, (String,)>("SELECT content_json FROM messages WHERE id = ?")
        .bind(message_id)
        .fetch_optional(pool)
        .await?;

    let Some((raw,)) = row else {
        return Ok(());
    };

    let mut value: serde_json::Value =
        serde_json::from_str(&raw).unwrap_or_else(|_| serde_json::json!({}));
    if !value.is_object() {
        value = serde_json::json!({});
    }

    let mut writes = file_writes_from_json(&raw);
    let Some(item) = writes.iter_mut().find(|item| item.request_id == request_id) else {
        return Ok(());
    };

    item.status = status.to_string();
    item.backup_path = backup_path.map(str::to_string);
    // 决策之后就没有"过期"这回事了，把时间戳去掉，客户端不会再显示倒计时。
    item.expires_at = None;

    value["file_writes"] = serde_json::json!(writes);

    sqlx::query("UPDATE messages SET content_json = ? WHERE id = ?")
        .bind(value.to_string())
        .bind(message_id)
        .execute(pool)
        .await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suggestions_parse_tolerates_old_and_broken_payloads() {
        assert!(suggestions_from_json(r#"{"text":"旧消息"}"#).is_empty());
        assert!(suggestions_from_json("not-json").is_empty());
        assert!(suggestions_from_json(r#"{"task_suggestions":"oops"}"#).is_empty());
    }

    #[test]
    fn steps_parse_tolerates_old_and_broken_payloads() {
        // 老消息没有这个键 → 空列表 → 界面不显示折叠面板。
        assert!(steps_from_json(r#"{"text":"旧消息"}"#).is_empty());
        assert!(steps_from_json("not-json").is_empty());
        assert!(steps_from_json(r#"{"steps":"oops"}"#).is_empty());

        let parsed = steps_from_json(
            r#"{"steps":[{"tool":"read_file","label":"已读取 a.html",
                "target":"file:a.html:1-20","ok":true,"elapsed_ms":3}]}"#,
        );
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].label, "已读取 a.html");
        assert!(parsed[0].ok);
        assert_eq!(parsed[0].elapsed_ms, 3);
    }

    #[test]
    fn file_writes_parse_tolerates_old_and_broken_payloads() {
        // 老消息没有这个键，形状不对时也只当没有卡片，不能让整段历史读失败。
        assert!(file_writes_from_json(r#"{"text":"旧消息"}"#).is_empty());
        assert!(file_writes_from_json("not-json").is_empty());
        assert!(file_writes_from_json(r#"{"file_writes":"oops"}"#).is_empty());

        let parsed = file_writes_from_json(
            r#"{"file_writes":[{"request_id":"fw_1","path":"a.html","scope":"draft",
                "status":"written","bytes":12,"created_at":1}]}"#,
        );
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].path, "a.html");
        assert_eq!(parsed[0].existing_bytes, 0, "缺省按新建处理");
        assert!(parsed[0].backup_path.is_none());
    }

    #[test]
    fn truncate_keeps_short_text() {
        assert_eq!(truncate("你好", 10), "你好");
    }

    #[test]
    fn truncate_marks_cut_text() {
        let truncated = truncate("一二三四五", 3);
        assert_eq!(truncated, "一二三…");
    }

    #[test]
    fn limit_is_clamped_and_zero_rejected() {
        assert!(clamp_limit(0).is_err());
        assert_eq!(clamp_limit(20).expect("合法"), 20);
        assert_eq!(clamp_limit(1000).expect("合法"), 100);
    }

    #[test]
    fn title_is_trimmed_before_saving() {
        assert_eq!(validate_title("  周报  ").expect("合法"), "周报");
    }

    #[test]
    fn empty_title_is_rejected() {
        assert!(matches!(
            validate_title("   "),
            Err(ConversationError::Invalid(_))
        ));
    }

    #[test]
    fn title_longer_than_the_limit_is_rejected() {
        // 上限是"字数"而不是字节：中文标题按字符数算才算得准。
        let just_fits = "字".repeat(MAX_TITLE_CHARS);
        assert!(validate_title(&just_fits).is_ok());

        let too_long = "字".repeat(MAX_TITLE_CHARS + 1);
        assert!(matches!(
            validate_title(&too_long),
            Err(ConversationError::Invalid(_))
        ));
    }

    #[test]
    fn message_metrics_round_trips_context_tokens() {
        let metrics = MessageMetrics::new(
            1_200,
            Some(TokenUsage {
                prompt_tokens: 3_600,
                completion_tokens: 200,
                tokens_estimated: false,
                context_tokens: 2_400,
            }),
        );
        let usage = metrics.usage().expect("有用量");
        assert_eq!(usage.prompt_tokens, 3_600, "整轮总量照旧累加");
        assert_eq!(usage.context_tokens, 2_400, "上下文长度只留最后一次调用");
    }

    #[test]
    fn old_message_rows_read_back_context_as_zero() {
        // 这一列出现之前落库的行：prompt/completion 有值、context 为 NULL。
        let metrics = MessageMetrics {
            elapsed_ms: Some(10),
            prompt_tokens: Some(800),
            completion_tokens: Some(120),
            context_tokens: None,
            tokens_estimated: false,
            finish_reason: None,
        };
        let usage = metrics.usage().expect("有用量");
        assert_eq!(usage.context_tokens, 0, "没有真实采样就按 0 显示空环");
    }
}
