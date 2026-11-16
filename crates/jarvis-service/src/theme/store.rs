//! 主题包的落库与查询。
//!
//! 表里存**稀疏覆盖**（`colors_json`），不存展开后的完整色表：
//! 展开后的值只是"内置派生值 + 覆盖"的中间产物，存下来就等于在服务端
//! 复制了一份 Flutter 的色表，客户端一加 token 两边就会漂。
//!
//! 列表一次读全表：主题包数量是"几十"，分页与 N+1 查询都不值得。

use protocol::{ThemePage, ThemeSpec};
use sqlx::SqlitePool;

use super::install::Installed;
use super::manifest::ThemeManifest;
use super::ThemeError;

/// 写入一次成功安装。同 id 覆盖，`installed_at` 保留首次安装时间。
pub(crate) async fn save(pool: &SqlitePool, installed: &Installed) -> Result<(), ThemeError> {
    let now = super::now_ms();
    let manifest = &installed.manifest;
    let colors_json = serde_json::to_string(&manifest.colors)
        .map_err(|err| ThemeError::Io(format!("序列化颜色失败：{err}")))?;

    sqlx::query(
        "INSERT INTO themes (id, name, version, author, description, brightness, colors_json, \
                dir, checksum, installed_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
         ON CONFLICT (id) DO UPDATE SET \
                name = excluded.name, \
                version = excluded.version, \
                author = excluded.author, \
                description = excluded.description, \
                brightness = excluded.brightness, \
                colors_json = excluded.colors_json, \
                dir = excluded.dir, \
                checksum = excluded.checksum, \
                updated_at = excluded.updated_at",
    )
    .bind(&manifest.id)
    .bind(&manifest.name)
    .bind(&manifest.version)
    .bind(manifest.author.as_deref())
    .bind(manifest.description.as_deref())
    .bind(manifest.brightness.as_str())
    .bind(colors_json)
    .bind(installed.dir.to_string_lossy().to_string())
    .bind(&installed.checksum)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .map_err(|err| ThemeError::Io(format!("写入主题失败：{err}")))?;

    Ok(())
}

/// 列出全部主题包。最近更新的排前面（覆盖安装会把它顶上来）。
pub(crate) async fn list(pool: &SqlitePool) -> Result<ThemePage, ThemeError> {
    let rows = sqlx::query_as::<_, ThemeRow>(
        "SELECT id, name, version, author, description, brightness, colors_json, installed_at, \
                updated_at FROM themes ORDER BY updated_at DESC, id",
    )
    .fetch_all(pool)
    .await
    .map_err(|err| ThemeError::Io(format!("查询主题失败：{err}")))?;

    let items = rows
        .into_iter()
        .map(|row| {
            let colors = serde_json::from_str(&row.colors_json).unwrap_or_else(|err| {
                // 颜色坏了就按"完全稀疏"处理：一个坏包不该让整个主题列表打不开。
                tracing::error!(id = %row.id, %err, "主题颜色无法解析，已按未覆盖处理");
                protocol::ThemeColors::default()
            });
            ThemeSpec {
                id: row.id,
                name: row.name,
                version: row.version,
                author: row.author,
                description: row.description,
                brightness: protocol::ThemeBrightness::parse(&row.brightness)
                    .unwrap_or(protocol::ThemeBrightness::Light),
                colors,
                installed_at: row.installed_at,
                updated_at: row.updated_at,
            }
        })
        .collect();

    Ok(ThemePage { items })
}

/// 取一个主题的元数据，删除前用它判断"是否存在"。
pub(crate) async fn load_manifest(
    pool: &SqlitePool,
    id: &str,
) -> Result<ThemeManifest, ThemeError> {
    let row = sqlx::query_as::<
        _,
        (
            String,
            String,
            String,
            Option<String>,
            Option<String>,
            String,
            String,
        ),
    >(
        "SELECT id, name, version, author, description, brightness, colors_json \
         FROM themes WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(|err| ThemeError::Io(format!("查询主题失败：{err}")))?;

    let Some((id, name, version, author, description, brightness, colors_json)) = row else {
        return Err(ThemeError::NotFound(format!("主题 {id} 不存在")));
    };

    Ok(ThemeManifest {
        theme_api: super::THEME_API,
        id,
        name,
        version,
        author,
        description,
        brightness: protocol::ThemeBrightness::parse(&brightness)
            .unwrap_or(protocol::ThemeBrightness::Light),
        colors: serde_json::from_str(&colors_json).unwrap_or_default(),
    })
}

/// 删库记录。文件由调用方在此之前删掉。
pub(crate) async fn delete(pool: &SqlitePool, id: &str) -> Result<(), ThemeError> {
    let result = sqlx::query("DELETE FROM themes WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await
        .map_err(|err| ThemeError::Io(format!("删除主题失败：{err}")))?;

    if result.rows_affected() == 0 {
        return Err(ThemeError::NotFound(format!("主题 {id} 不存在")));
    }
    Ok(())
}

#[derive(Debug, sqlx::FromRow)]
struct ThemeRow {
    id: String,
    name: String,
    version: String,
    author: Option<String>,
    description: Option<String>,
    brightness: String,
    colors_json: String,
    installed_at: i64,
    updated_at: i64,
}
