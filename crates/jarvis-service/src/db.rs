//! SQLite 连接与迁移。
//!
//! 设计取舍：
//! - 迁移用 `sqlx::migrate!` 在编译期内嵌，运行时不依赖 `migrations/` 目录存在；
//! - 连接统一开启 `foreign_keys` 与 WAL：前者保证级联删除生效，后者让读写不互相阻塞；
//! - M1 只用运行时查询（`sqlx::query`），暂不引入 `query!` 宏，
//!   避免构建期必须连到数据库；M3 引入业务查询时再补 `.sqlx` 离线缓存。

use std::path::Path;
use std::time::Duration;

use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::SqlitePool;

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error("准备数据目录失败: {0}")]
    PrepareDir(#[from] std::io::Error),
    #[error("打开数据库失败: {0}")]
    Connect(#[from] sqlx::Error),
    #[error("执行迁移失败: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),
}

/// 打开（必要时创建）数据库并返回连接池。
pub async fn connect(path: &Path) -> Result<SqlitePool, DbError> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .foreign_keys(true)
        .journal_mode(SqliteJournalMode::Wal)
        // 服务端并发不高，但在审批与任务状态同时更新时会有短暂写冲突。
        .synchronous(SqliteSynchronous::Normal)
        .busy_timeout(Duration::from_secs(5));

    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?;

    Ok(pool)
}

/// 执行内嵌迁移。重复调用安全（sqlx 会记录已应用的版本）。
pub async fn migrate(pool: &SqlitePool) -> Result<(), DbError> {
    sqlx::migrate!("./migrations").run(pool).await?;
    Ok(())
}

/// 健康探针：能执行一条最简查询即视为可用。
pub async fn healthy(pool: &SqlitePool) -> bool {
    sqlx::query("SELECT 1").execute(pool).await.is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_db_path(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("系统时间异常")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "personal-agent-{tag}-{}-{nanos}.db",
            std::process::id()
        ))
    }

    async fn migrated_pool(tag: &str) -> (SqlitePool, PathBuf) {
        let path = temp_db_path(tag);
        let pool = connect(&path).await.expect("打开数据库失败");
        migrate(&pool).await.expect("迁移失败");
        (pool, path)
    }

    #[tokio::test]
    async fn migrations_create_expected_tables() {
        let (pool, path) = migrated_pool("tables").await;

        // FTS5 虚表会带出一批影子表（memories_fts_data / _idx / _docsize ...），
        // 它们不是业务表，必须一起过滤掉，否则断言永远对不上。
        let tables: Vec<(String,)> = sqlx::query_as(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' \
             AND name NOT LIKE 'memories_fts%' \
             AND name != '_sqlx_migrations' ORDER BY name",
        )
        .fetch_all(&pool)
        .await
        .expect("查询表名失败");

        let names: Vec<String> = tables.into_iter().map(|(name,)| name).collect();
        assert_eq!(
            names,
            vec![
                "approvals",
                "artifacts",
                "attachments",
                "audit_log",
                "conversation_compactions",
                "conversations",
                "credentials",
                "devices",
                "file_write_requests",
                "media_assets",
                "memories",
                "memory_digest_snapshots",
                "memory_entities",
                "memory_entity_links",
                "memory_entity_snapshots",
                "memory_evidence",
                "memory_extract_daily",
                "memory_grants",
                "memory_heartbeat_state",
                "memory_notifications",
                "memory_recall_log",
                "messages",
                "pairing_requests",
                "plugin_seeds",
                "plugin_skills",
                "plugins",
                "projects",
                "recording_segments",
                "recordings",
                "sessions",
                "task_steps",
                "tasks",
                "themes",
            ]
        );

        pool.close().await;
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn migrate_is_idempotent() {
        let (pool, path) = migrated_pool("idempotent").await;
        migrate(&pool).await.expect("重复迁移应当成功");
        assert!(healthy(&pool).await);

        pool.close().await;
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn foreign_keys_are_enforced() {
        let (pool, path) = migrated_pool("fk").await;

        let result = sqlx::query(
            "INSERT INTO messages (id, conversation_id, role, content_json, created_at) \
             VALUES ('m1', 'missing-conversation', 'user', '{}', 0)",
        )
        .execute(&pool)
        .await;

        assert!(result.is_err(), "外键约束应当拒绝孤立消息");

        pool.close().await;
        let _ = std::fs::remove_file(path);
    }
}
