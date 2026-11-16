//! 会话媒体的元信息表读写（`media_assets`）。
//!
//! 只做存取，不含业务判断：参数校验、超时、额度都在工具层（`local_tools::media_gen`）。
//! 正文仍在 `ArtifactStore` 下，这里只记相对路径——数据目录整体搬迁后记录依然有效。

use protocol::MediaAsset;
use sqlx::SqlitePool;

/// 写入一条媒体元信息。
///
/// `path` 由 [`crate::artifact_store::ArtifactStore`] 生成，客户端永远拿不到也传不进路径；
/// 下载端点只按 `id` 查回路径，这是唯一的准入边界。
pub async fn insert_asset(
    pool: &SqlitePool,
    conversation_id: &str,
    asset: &MediaAsset,
    path: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO media_assets (id, conversation_id, kind, path, mime, bytes, model, prompt, \
                width, height, duration_ms, resolution, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&asset.id)
    .bind(conversation_id)
    .bind(&asset.kind)
    .bind(path)
    .bind(&asset.mime)
    .bind(asset.bytes)
    .bind(&asset.model)
    .bind(&asset.prompt)
    .bind(asset.width.map(i64::from))
    .bind(asset.height.map(i64::from))
    .bind(asset.duration_ms.map(i64::from))
    .bind(asset.resolution.as_deref())
    .bind(asset.created_at)
    .execute(pool)
    .await?;
    Ok(())
}

/// 按 id 查回产物相对路径与 mime。
///
/// 返回 `None` 表示记录不存在（例如被清理过的旧数据），调用方应回 404 而不是 500。
pub async fn lookup(pool: &SqlitePool, id: &str) -> Result<Option<(String, String)>, sqlx::Error> {
    let row =
        sqlx::query_as::<_, (String, String)>("SELECT path, mime FROM media_assets WHERE id = ?")
            .bind(id)
            .fetch_optional(pool)
            .await?;
    Ok(row)
}

/// 记下视频封面的相对路径。
///
/// 单独一次 UPDATE 而不是塞进 [`insert_asset`]：抽帧发生在正文落盘之后，
/// 而且允许失败。把两者绑在一个 INSERT 里，抽帧失败就得回滚整条媒体记录——
/// 那等于"封面没抽出来，视频也白生成了"。
pub async fn set_poster(pool: &SqlitePool, id: &str, poster: &str) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE media_assets SET poster_path = ? WHERE id = ?")
        .bind(poster)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

/// 封面端点用的查询：正文相对路径、mime、所属会话、已有封面。
///
/// 抽帧能力上线前生成的视频 `poster_path` 是空的，端点会拿这份信息现场补一张；
/// 会话 id 与正文路径都是补封面必需的（落盘目录与源文件）。
pub async fn lookup_poster_source(
    pool: &SqlitePool,
    id: &str,
) -> Result<Option<(String, String, String, Option<String>)>, sqlx::Error> {
    let row = sqlx::query_as::<_, (String, String, String, Option<String>)>(
        "SELECT path, mime, conversation_id, poster_path FROM media_assets WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

/// 按 id 查回相对路径、mime，以及这条产物所属会话挂的项目。
///
/// 「保存到项目」必须知道产物归谁：客户端手上只有会话标题与目录，没有 project_id，
/// 由服务端从 `media_assets → conversations` 反查，顺带把"客户端指定任意项目"
/// 这条路彻底堵死。
///
/// 用 LEFT JOIN：会话被删（或老数据没有归属）时仍然能取到正文信息，
/// 由调用方决定回"没有归属项目"，而不是连 404/400 都分不清。
pub async fn lookup_with_project(
    pool: &SqlitePool,
    id: &str,
) -> Result<Option<(String, String, String, Option<String>)>, sqlx::Error> {
    let row = sqlx::query_as::<_, (String, String, String, Option<String>)>(
        "SELECT m.path, m.mime, m.conversation_id, c.project_id \
         FROM media_assets m \
         LEFT JOIN conversations c ON c.id = m.conversation_id \
         WHERE m.id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset(id: &str) -> MediaAsset {
        MediaAsset {
            id: id.to_string(),
            kind: "image".to_string(),
            mime: "image/png".to_string(),
            bytes: 1024,
            model: "qwen-image-3.0".to_string(),
            prompt: "一只猫".to_string(),
            width: Some(1328),
            height: Some(1328),
            duration_ms: None,
            resolution: None,
            created_at: 1_700_000_000_000,
        }
    }

    async fn memory_pool() -> SqlitePool {
        let pool = SqlitePool::connect("sqlite::memory:")
            .await
            .expect("建内存库失败");
        sqlx::query(include_str!("../../migrations/0023_media_assets.sql"))
            .execute(&pool)
            .await
            .expect("建表失败");
        pool
    }

    #[tokio::test]
    async fn inserts_and_looks_up_by_id() {
        let pool = memory_pool().await;
        insert_asset(&pool, "conv_1", &asset("img_1"), "conv_1/img_1.png")
            .await
            .expect("写入失败");

        assert_eq!(
            lookup(&pool, "img_1").await.expect("查询失败"),
            Some(("conv_1/img_1.png".to_string(), "image/png".to_string()))
        );
    }

    #[tokio::test]
    async fn unknown_id_is_none() {
        let pool = memory_pool().await;
        assert!(lookup(&pool, "img_missing")
            .await
            .expect("查询失败")
            .is_none());
    }
}
