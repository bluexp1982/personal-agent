//! 会话侧文件生成：落盘、备份与"覆盖前确认"的存储层。
//!
//! 三件事集中在这里，且只在这里实现一次：
//!
//! 1. **写哪个根**：会话绑了项目就写项目根，没绑就写 `{data_dir}/drafts/{conversation_id}/`；
//! 2. **怎么落盘**：临时文件 + `rename`，中途失败不留下半截文件，原文件也不受影响；
//! 3. **覆盖怎么确认**：待写内容先落 `file_write_requests`，用户点确认后才真正覆盖。
//!
//! 为什么确认不挂起对话流：挂起要把事件通道、断线恢复、超时全都串进 `chat::run`；
//! 而"用户确认后写这一份内容"本身是确定性的，不需要模型再参与一次。
//! 落库后由独立端点完成写入，断流、重启、超时都能自然收敛。
//!
//! 备份刻意不放进项目目录：那会在用户仓库里凭空多出一批文件，
//! `git status` 与文件搜索都会把它们当成用户自己的东西。

use std::path::{Path, PathBuf};

use sqlx::SqlitePool;

use crate::clock;
use crate::config::Config;
use crate::ids;
use crate::local_tools::path_guard::ProjectRoot;

/// 草稿目录名（相对数据目录）。
pub(crate) const DRAFTS_DIR: &str = "drafts";
/// 覆盖前备份目录名（相对数据目录）。
pub(crate) const BACKUPS_DIR: &str = "file-backups";

/// 单次写入的字节上限。
///
/// 与 `protocol::MAX_ARTIFACT_BYTES` 同量级：模型一次回答本来也到不了更大，
/// 定得再高只会让一次失控的调用把磁盘和上下文一起拖垮。
pub(crate) const MAX_WRITE_BYTES: usize = 256 * 1024;

pub(crate) const STATUS_PENDING: &str = "pending";
pub(crate) const STATUS_WRITTEN: &str = "written";
pub(crate) const STATUS_REJECTED: &str = "rejected";
pub(crate) const STATUS_EXPIRED: &str = "expired";
pub(crate) const STATUS_FAILED: &str = "failed";
pub(crate) const STATUS_SUPERSEDED: &str = "superseded";

/// 写入落在哪个根。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WriteScope {
    /// 会话绑定的项目根。
    Project,
    /// 无项目会话的草稿目录。
    Draft,
}

impl WriteScope {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Project => "project",
            Self::Draft => "draft",
        }
    }

    pub(crate) fn parse(raw: &str) -> Option<Self> {
        match raw {
            "project" => Some(Self::Project),
            "draft" => Some(Self::Draft),
            _ => None,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum WriteError {
    #[error("{0}")]
    Denied(String),
    #[error("{0}")]
    Invalid(String),
    #[error("写入失败：{0}")]
    Io(#[from] std::io::Error),
    #[error("数据库不可用：{0}")]
    Db(#[from] sqlx::Error),
}

impl From<crate::local_tools::path_guard::GuardError> for WriteError {
    fn from(error: crate::local_tools::path_guard::GuardError) -> Self {
        use crate::local_tools::path_guard::GuardError;

        match error {
            GuardError::Denied(reason) => Self::Denied(reason),
            GuardError::Invalid(reason) => Self::Invalid(reason),
        }
    }
}

/// 一条待确认 / 已决策的写请求。
#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct WriteRequest {
    pub(crate) id: String,
    pub(crate) conversation_id: String,
    pub(crate) message_id: Option<String>,
    pub(crate) scope: String,
    pub(crate) path: String,
    pub(crate) content: String,
    pub(crate) bytes: i64,
    pub(crate) existing_bytes: i64,
    pub(crate) status: String,
    pub(crate) backup_path: Option<String>,
    /// 失败原因。排障用，不进回执也不进审计。
    #[allow(dead_code)]
    pub(crate) error: Option<String>,
    pub(crate) created_at: i64,
    /// 决策时刻。当前只落库不读：客户端看的是状态，不是时间戳。
    #[allow(dead_code)]
    pub(crate) decided_at: Option<i64>,
    pub(crate) expires_at: i64,
}

/// 新建一条写请求的入参。
pub(crate) struct PendingWrite<'a> {
    pub(crate) conversation_id: &'a str,
    pub(crate) message_id: Option<&'a str>,
    pub(crate) scope: WriteScope,
    pub(crate) path: &'a str,
    pub(crate) content: &'a str,
    pub(crate) existing_bytes: i64,
    /// 初始状态：新建文件直接是 `written`，覆盖请求是 `pending`。
    ///
    /// 让 INSERT 一次写到终态，而不是"先 pending 再 UPDATE"：那两步之间
    /// 若进程退出，会留下一条 `expires_at=0` 的 pending，被过期清理扫成
    /// `expired`——文件明明已经写好了，记录却说它作废了。
    pub(crate) status: &'static str,
    /// 过期时刻。用 `approval_ttl_ms` 推导，不额外加配置项；终态传 0。
    pub(crate) expires_at: i64,
}

/// 会话可写的根。
///
/// - 项目：查会话归属的项目目录；项目已删除或会话无归属时拒绝；
/// - 草稿：`{data_dir}/drafts/{conversation_id}/`，按需创建。
///
/// 草稿根也构造 [`ProjectRoot`]：路径准入（越界、软链接、敏感名）只该有一份实现，
/// 草稿目录同样是"一个根"，没有理由走另一套规则。
pub(crate) async fn resolve_root(
    pool: &SqlitePool,
    config: &Config,
    conversation_id: &str,
    scope: WriteScope,
) -> Result<ProjectRoot, WriteError> {
    check_segment(conversation_id)?;

    let root = match scope {
        WriteScope::Project => {
            let row = sqlx::query_as::<_, (String,)>(
                "SELECT p.path FROM conversations c \
                 JOIN projects p ON p.id = c.project_id \
                 WHERE c.id = ? AND p.deleted_at IS NULL",
            )
            .bind(conversation_id)
            .fetch_optional(pool)
            .await?;

            match row {
                Some((path,)) => PathBuf::from(path),
                None => {
                    return Err(WriteError::Denied(
                        "这个会话没有绑定项目（或项目已被删除），只能写入草稿目录".to_string(),
                    ))
                }
            }
        }
        WriteScope::Draft => {
            let dir = config.drafts_dir().join(conversation_id);
            tokio::fs::create_dir_all(&dir).await?;
            dir
        }
    };

    ProjectRoot::new(&root.to_string_lossy()).map_err(WriteError::from)
}

/// 写入新文件，必要时创建中间目录。
///
/// 先写同目录下的隐藏临时文件再 `rename`：同一文件系统内的 rename 是原子的，
/// 读者要么看到旧内容、要么看到完整的新内容，不会撞见半截文件。
pub(crate) async fn atomic_write(target: &Path, content: &str) -> Result<(), WriteError> {
    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    let name = target
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .ok_or_else(|| WriteError::Invalid("目标路径没有文件名".to_string()))?;

    let temporary = target.with_file_name(format!(".{name}.{}.part", rand_suffix()));
    if let Err(err) = tokio::fs::write(&temporary, content.as_bytes()).await {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(WriteError::Io(err));
    }

    if let Err(err) = tokio::fs::rename(&temporary, target).await {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(WriteError::Io(err));
    }

    Ok(())
}

/// 覆盖前把原文件复制到备份目录，返回备份的**绝对路径**。
///
/// 这里返回绝对路径而不是项目相对路径：备份不在项目里，"相对哪里"没有意义，
/// 而用户要还原时需要一个能直接复制去用的路径。
pub(crate) async fn backup_existing(
    config: &Config,
    conversation_id: &str,
    request_id: &str,
    relative: &str,
    source: &Path,
) -> Result<String, WriteError> {
    check_segment(conversation_id)?;
    check_segment(request_id)?;

    let target = config
        .file_backups_dir()
        .join(conversation_id)
        .join(request_id)
        .join(relative);

    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    tokio::fs::copy(source, &target).await?;
    Ok(target.to_string_lossy().to_string())
}

/// 新建一条写请求。
///
/// 同一路径上还挂着旧的待确认请求时先标 `superseded`：
/// 否则用户会对同一个文件看到两张卡，点哪张都不确定。
///
/// 顺带收一遍过期请求，让"过期"这个状态不必等后台任务才出现。
pub(crate) async fn create_pending(
    pool: &SqlitePool,
    pending: PendingWrite<'_>,
) -> Result<WriteRequest, WriteError> {
    let now = clock::now_ms();
    let id = ids::new_id("fw");
    let bytes = pending.content.len() as i64;
    // 终态记录不存正文：文件已经在盘上，卡片只需要路径与大小。
    // 数据库里长期留一份用户文件的全文是没有必要的负担。
    let stored_content = if pending.status == STATUS_PENDING {
        pending.content
    } else {
        ""
    };

    expire_overdue(pool).await?;
    supersede_pending(pool, pending.conversation_id, pending.path, now).await?;

    sqlx::query(
        "INSERT INTO file_write_requests \
         (id, conversation_id, message_id, scope, path, content, bytes, existing_bytes, \
          status, created_at, decided_at, expires_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&id)
    .bind(pending.conversation_id)
    .bind(pending.message_id)
    .bind(pending.scope.as_str())
    .bind(pending.path)
    .bind(stored_content)
    .bind(bytes)
    .bind(pending.existing_bytes)
    .bind(pending.status)
    .bind(now)
    // 终态记录没有"决策时刻"可言，直接落成创建时刻；状态才是权威。
    .bind((pending.status != STATUS_PENDING).then_some(now))
    .bind(pending.expires_at)
    .execute(pool)
    .await?;

    Ok(WriteRequest {
        id,
        conversation_id: pending.conversation_id.to_string(),
        message_id: pending.message_id.map(str::to_string),
        scope: pending.scope.as_str().to_string(),
        path: pending.path.to_string(),
        content: pending.content.to_string(),
        bytes,
        existing_bytes: pending.existing_bytes,
        status: pending.status.to_string(),
        backup_path: None,
        error: None,
        created_at: now,
        decided_at: None,
        expires_at: pending.expires_at,
    })
}

/// 把同一会话同一路径下仍处于 pending 的请求标为 `superseded`（正文一并清空）。
pub(crate) async fn supersede_pending(
    pool: &SqlitePool,
    conversation_id: &str,
    path: &str,
    now: i64,
) -> Result<(), WriteError> {
    sqlx::query(
        "UPDATE file_write_requests SET status = ?, content = '', decided_at = ? \
         WHERE conversation_id = ? AND path = ? AND status = ?",
    )
    .bind(STATUS_SUPERSEDED)
    .bind(now)
    .bind(conversation_id)
    .bind(path)
    .bind(STATUS_PENDING)
    .execute(pool)
    .await?;

    Ok(())
}

/// 读一条请求。不存在返回 `None`。
pub(crate) async fn get(pool: &SqlitePool, id: &str) -> Result<Option<WriteRequest>, WriteError> {
    let row = sqlx::query_as::<_, WriteRequest>(
        "SELECT id, conversation_id, message_id, scope, path, content, bytes, existing_bytes, \
                status, backup_path, error, created_at, decided_at, expires_at \
         FROM file_write_requests WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;

    Ok(row)
}

/// 记录决策结果。
///
/// 无论哪个终态都清空正文：内容只在"还没决定"的窗口里有价值，
/// 留着只会让数据库里长期存一份用户根本没要的文件全文。
pub(crate) async fn mark_decided(
    pool: &SqlitePool,
    id: &str,
    status: &str,
    backup_path: Option<&str>,
    error: Option<&str>,
) -> Result<(), WriteError> {
    let now = clock::now_ms();

    sqlx::query(
        "UPDATE file_write_requests \
         SET status = ?, content = '', backup_path = ?, error = ?, decided_at = ? \
         WHERE id = ?",
    )
    .bind(status)
    .bind(backup_path)
    .bind(error)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(())
}

/// 把已过期的 pending 标成 `expired` 并清空正文。
///
/// 不设后台任务：确认端点与新建待确认时会顺带调用，
/// 一次 UPDATE 走 `(status, expires_at)` 索引，成本可以忽略。
pub(crate) async fn expire_overdue(pool: &SqlitePool) -> Result<(), WriteError> {
    let now = clock::now_ms();

    sqlx::query(
        "UPDATE file_write_requests SET status = ?, content = '', decided_at = ? \
         WHERE status = ? AND expires_at <= ?",
    )
    .bind(STATUS_EXPIRED)
    .bind(now)
    .bind(STATUS_PENDING)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(())
}

/// 单段路径标识的合法性：会话 id、请求 id 都要当目录名用。
///
/// 这两个值都来自数据库，理论上可信；但它们会被拼进文件路径，
/// 一旦上游出错就是"写到数据目录之外"，宁可在这一层直接拒绝。
pub(crate) fn check_segment(value: &str) -> Result<(), WriteError> {
    let ok = !value.is_empty()
        && value.len() <= 64
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_');

    if ok {
        Ok(())
    } else {
        Err(WriteError::Invalid(format!("标识非法：{value}")))
    }
}

/// 临时文件名后缀。只用十六进制：不引入时间格式，也没有跨平台路径字符问题。
fn rand_suffix() -> String {
    let bytes: [u8; 6] = rand::random();
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pa-write-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        dir
    }

    #[test]
    fn scope_round_trips() {
        for scope in [WriteScope::Project, WriteScope::Draft] {
            assert_eq!(WriteScope::parse(scope.as_str()), Some(scope));
        }
        assert_eq!(WriteScope::parse("elsewhere"), None);
    }

    #[test]
    fn rejects_bad_segments() {
        assert!(check_segment("conv_abc123").is_ok());
        assert!(check_segment("").is_err());
        assert!(check_segment("../etc").is_err());
        assert!(check_segment("a/b").is_err());
        assert!(check_segment(&"a".repeat(65)).is_err());
    }

    #[tokio::test]
    async fn atomic_write_creates_missing_dirs_and_replaces() {
        let root = temp_root("atomic");
        let target = root.join("prototypes").join("index.html");

        atomic_write(&target, "<h1>v1</h1>")
            .await
            .expect("首次写入");
        assert_eq!(
            tokio::fs::read_to_string(&target).await.expect("读回"),
            "<h1>v1</h1>"
        );

        atomic_write(&target, "<h1>v2</h1>").await.expect("覆盖");
        assert_eq!(
            tokio::fs::read_to_string(&target).await.expect("读回"),
            "<h1>v2</h1>"
        );

        // 不留临时文件：目录里只该有目标文件。
        let mut entries = tokio::fs::read_dir(target.parent().expect("有父目录"))
            .await
            .expect("列目录");
        let mut names = Vec::new();
        while let Some(entry) = entries.next_entry().await.expect("下一项") {
            names.push(entry.file_name().to_string_lossy().to_string());
        }
        assert_eq!(names, vec!["index.html".to_string()]);
    }
}
