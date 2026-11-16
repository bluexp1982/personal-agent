//! 插件的落库与查询。
//!
//! 表只存**归一化之后**的结论：装包时算好的 manifest、状态与原因。
//! 这样 worker 没连上时管理页也能给出完整列表，不必再扫一遍磁盘。
//!
//! 一次性读全表再在内存分组，而不是每个插件查一次：个人场景插件数是几十，
//! N+1 查询只会让管理页慢半拍，省下的内存可以忽略。

use std::collections::HashMap;

use protocol::{Plugin, PluginPage, Skill, SkillManifest, SkillStatus};
use sqlx::SqlitePool;

use super::compat::NormalizedSkill;
use super::install::{Installed, Reserved};
use super::PluginError;

/// 真正的内置技能名。它们不随插件安装/卸载，但冲突检测必须把它们算进去——
/// 外部包叫 `code-task` 会直接盖掉内置技能的解释。
///
/// `trip-plan` / `bill-explain` 已改为随应用分发的外部插件（见
/// [`super::seed`]）：它们要能停用、能卸载，就不能占着保留名——
/// 否则播种安装自己的包会被这条规则挡掉。
pub(crate) const BUILTIN_SKILL_NAMES: &[&str] = &["code-task"];

/// 收集已被占用的 id 与技能名，供安装前查重。
pub(crate) async fn reserved(pool: &SqlitePool) -> Result<Reserved, PluginError> {
    let ids = sqlx::query_as::<_, (String,)>("SELECT id FROM plugins")
        .fetch_all(pool)
        .await
        .map_err(|err| PluginError::Io(format!("查询插件失败：{err}")))?;

    let names = sqlx::query_as::<_, (String,)>("SELECT name FROM plugin_skills")
        .fetch_all(pool)
        .await
        .map_err(|err| PluginError::Io(format!("查询技能失败：{err}")))?;

    let mut skill_names: Vec<String> = BUILTIN_SKILL_NAMES
        .iter()
        .map(|name| (*name).to_string())
        .collect();
    skill_names.extend(names.into_iter().map(|(name,)| name));

    Ok(Reserved {
        plugin_ids: ids.into_iter().map(|(id,)| id).collect(),
        skill_names,
    })
}

/// 写入一次成功安装。调用方保证文件已经落到最终目录。
pub(crate) async fn save(pool: &SqlitePool, installed: &Installed) -> Result<(), PluginError> {
    let now = super::now_ms();
    let manifest = &installed.manifest;

    let mut tx = pool
        .begin()
        .await
        .map_err(|err| PluginError::Io(format!("开启事务失败：{err}")))?;

    sqlx::query(
        "INSERT INTO plugins (id, name, version, author, description, dir, checksum, enabled, \
                installed_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)",
    )
    .bind(&manifest.id)
    .bind(&manifest.name)
    .bind(&manifest.version)
    .bind(manifest.author.as_deref())
    .bind(manifest.description.as_deref())
    .bind(installed.dir.to_string_lossy().to_string())
    .bind(&installed.checksum)
    .bind(now)
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(|err| PluginError::Io(format!("写入插件失败：{err}")))?;

    for skill in &installed.skills {
        insert_skill(&mut tx, &manifest.id, skill).await?;
    }

    tx.commit()
        .await
        .map_err(|err| PluginError::Io(format!("提交失败：{err}")))?;

    Ok(())
}

async fn insert_skill(
    tx: &mut sqlx::SqliteConnection,
    plugin_id: &str,
    skill: &NormalizedSkill,
) -> Result<(), PluginError> {
    let manifest_json = serde_json::to_string(&skill.manifest)
        .map_err(|err| PluginError::Io(format!("序列化清单失败：{err}")))?;
    let reasons_json = serde_json::to_string(&skill.reasons)
        .map_err(|err| PluginError::Io(format!("序列化原因失败：{err}")))?;

    sqlx::query(
        "INSERT INTO plugin_skills (plugin_id, name, status, reasons_json, manifest_json, \
                description) VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(plugin_id)
    .bind(&skill.manifest.name)
    .bind(skill.status.as_str())
    .bind(reasons_json)
    .bind(manifest_json)
    .bind(skill.description.as_deref())
    .execute(&mut *tx)
    .await
    .map_err(|err| PluginError::Io(format!("写入技能失败：{err}")))?;

    Ok(())
}

/// 列出全部插件（含已停用的，管理页要能重新打开）。
pub(crate) async fn list(
    pool: &SqlitePool,
    pending_reload: bool,
) -> Result<PluginPage, PluginError> {
    let rows = sqlx::query_as::<_, PluginRow>(
        "SELECT id, name, version, author, description, dir, enabled, installed_at, updated_at \
         FROM plugins ORDER BY installed_at DESC, id",
    )
    .fetch_all(pool)
    .await
    .map_err(|err| PluginError::Io(format!("查询插件失败：{err}")))?;

    let skill_rows = sqlx::query_as::<_, SkillRow>(
        "SELECT plugin_id, name, status, reasons_json, manifest_json, description \
         FROM plugin_skills ORDER BY name",
    )
    .fetch_all(pool)
    .await
    .map_err(|err| PluginError::Io(format!("查询技能失败：{err}")))?;

    let mut by_plugin: HashMap<String, Vec<Skill>> = HashMap::new();
    for row in skill_rows {
        let manifest: SkillManifest = match serde_json::from_str(&row.manifest_json) {
            Ok(manifest) => manifest,
            // 清单坏了就跳过这一条：一条坏数据不该让整个管理页打不开。
            Err(err) => {
                tracing::error!(skill = %row.name, %err, "插件技能清单无法解析，已跳过");
                continue;
            }
        };

        let status = SkillStatus::parse(&row.status).unwrap_or(SkillStatus::Unsupported);
        let reasons: Vec<String> = serde_json::from_str(&row.reasons_json).unwrap_or_default();
        let plugin_name = rows
            .iter()
            .find(|plugin| plugin.id == row.plugin_id)
            .map(|plugin| plugin.name.clone())
            .unwrap_or_else(|| row.plugin_id.clone());

        by_plugin
            .entry(row.plugin_id.clone())
            .or_default()
            .push(Skill {
                name: manifest.name.clone(),
                version: manifest.version.clone(),
                source: manifest.source.clone(),
                risk_level: manifest.risk_level.clone(),
                required_tools: manifest.required_tools.clone(),
                plugin_id: Some(row.plugin_id.clone()),
                plugin_name: Some(plugin_name),
                description: row.description,
                status,
                reasons,
            });
    }

    let items = rows
        .into_iter()
        .map(|row| Plugin {
            skills: by_plugin.remove(&row.id).unwrap_or_default(),
            id: row.id,
            name: row.name,
            version: row.version,
            author: row.author,
            description: row.description,
            enabled: row.enabled != 0,
            installed_at: row.installed_at,
            updated_at: row.updated_at,
        })
        .collect();

    Ok(PluginPage {
        items,
        pending_reload,
    })
}

/// 启停插件。
pub(crate) async fn set_enabled(
    pool: &SqlitePool,
    id: &str,
    enabled: bool,
) -> Result<(), PluginError> {
    let result = sqlx::query("UPDATE plugins SET enabled = ?, updated_at = ? WHERE id = ?")
        .bind(i64::from(enabled))
        .bind(super::now_ms())
        .bind(id)
        .execute(pool)
        .await
        .map_err(|err| PluginError::Io(format!("更新插件失败：{err}")))?;

    if result.rows_affected() == 0 {
        return Err(PluginError::NotFound(format!("插件 {id} 不存在")));
    }
    Ok(())
}

/// 取一个插件的版本与目录，卸载时先查再删。
pub(crate) async fn load_location(
    pool: &SqlitePool,
    id: &str,
) -> Result<(String, String), PluginError> {
    let row =
        sqlx::query_as::<_, (String, String)>("SELECT version, dir FROM plugins WHERE id = ?")
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(|err| PluginError::Io(format!("查询插件失败：{err}")))?;

    row.ok_or_else(|| PluginError::NotFound(format!("插件 {id} 不存在")))
}

/// 删库记录。文件由调用方在此之前删掉。
///
/// 顺手给种子记录盖上 `dismissed`：用户卸载示例技能后，之后每次启动
/// （包括应用升级带来新版本时）都不该把它装回来。升级路径里会紧接着
/// `record` 把它改回 0——那条路径的意思是"我确实要装"。
pub(crate) async fn delete(pool: &SqlitePool, id: &str) -> Result<(), PluginError> {
    let result = sqlx::query("DELETE FROM plugins WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await
        .map_err(|err| PluginError::Io(format!("删除插件失败：{err}")))?;

    if result.rows_affected() == 0 {
        return Err(PluginError::NotFound(format!("插件 {id} 不存在")));
    }

    // 普通插件在种子表里没有对应行，这条 UPDATE 影响 0 行；不算错误。
    sqlx::query("UPDATE plugin_seeds SET dismissed = 1, applied_at = ? WHERE name = ?")
        .bind(super::now_ms())
        .bind(id)
        .execute(pool)
        .await
        .map_err(|err| PluginError::Io(format!("更新种子记录失败：{err}")))?;

    Ok(())
}

/// 按技能名取"已启用插件里、可运行"的归一化清单。
///
/// `prepare` 用它而不是只读 worker 上报的清单：装完插件到 worker 重载完成
/// 之间有一小段窗口，这期间技能已经在库里、界面上也能选到，但 registry
/// 里还没有——只读 registry 会让用户点了刚装的技能却被告知"技能不可用"。
pub(crate) async fn enabled_manifest(
    pool: &SqlitePool,
    name: &str,
) -> Result<Option<SkillManifest>, PluginError> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT s.manifest_json FROM plugin_skills s \
         JOIN plugins p ON p.id = s.plugin_id \
         WHERE s.name = ? AND p.enabled = 1 AND s.status != 'unsupported'",
    )
    .bind(name)
    .fetch_optional(pool)
    .await
    .map_err(|err| PluginError::Io(format!("查询技能清单失败：{err}")))?;

    let Some((raw,)) = row else {
        return Ok(None);
    };

    // 清单是装包时序列化的，损坏只可能是手工改库：按"查不到"处理，
    // 让调用方回退到注册表，而不是把一次解析失败升级成 500。
    Ok(serde_json::from_str(&raw).ok())
}

/// 已启用且可运行的技能名。
///
/// 对话引擎用它约束「建议哪件事」：把装不了或已停用的技能喂给模型，
/// 只会让它建议一些点了就失败的事。
pub(crate) async fn enabled_runnable_skill_names(
    pool: &SqlitePool,
) -> Result<Vec<String>, PluginError> {
    let rows = sqlx::query_as::<_, (String,)>(
        "SELECT s.name FROM plugin_skills s JOIN plugins p ON p.id = s.plugin_id \
         WHERE p.enabled = 1 AND s.status != 'unsupported' ORDER BY s.name",
    )
    .fetch_all(pool)
    .await
    .map_err(|err| PluginError::Io(format!("查询可用技能失败：{err}")))?;

    Ok(rows.into_iter().map(|(name,)| name).collect())
}

/// 插件技能的展示补充信息：技能名 → (插件名, 状态, 原因, 描述, 是否启用)。
///
/// `/api/skills` 收到的清单来自 worker（只有契约字段），
/// 插件名与状态只在库里，所以要在这一层拼回去。
///
/// **停用的插件也要查出来**（不能只查 `enabled = 1`）：worker 的 registry
/// 要到重载后才更新，那段时间它里面仍有停用插件的技能。调用方靠
/// [`SkillAnnotation::enabled`] 把这类残留挡掉——否则用户停用后还会看到
/// 一条没有描述、状态却写着"可用"的技能。
pub(crate) async fn skill_annotations(
    pool: &SqlitePool,
) -> Result<HashMap<String, SkillAnnotation>, PluginError> {
    let rows = sqlx::query_as::<_, (String, String, String, String, Option<String>, i64)>(
        "SELECT s.name, p.name, s.status, s.reasons_json, s.description, p.enabled \
         FROM plugin_skills s JOIN plugins p ON p.id = s.plugin_id",
    )
    .fetch_all(pool)
    .await
    .map_err(|err| PluginError::Io(format!("查询技能标注失败：{err}")))?;

    let mut map = HashMap::new();
    for (skill, plugin_name, status, reasons_json, description, enabled) in rows {
        map.insert(
            skill,
            SkillAnnotation {
                plugin_name,
                status: SkillStatus::parse(&status).unwrap_or(SkillStatus::Unsupported),
                reasons: serde_json::from_str(&reasons_json).unwrap_or_default(),
                description,
                enabled: enabled != 0,
            },
        );
    }
    Ok(map)
}

/// 一条插件技能的展示补充信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SkillAnnotation {
    pub(crate) plugin_name: String,
    pub(crate) status: SkillStatus,
    pub(crate) reasons: Vec<String>,
    pub(crate) description: Option<String>,
    /// 所属插件是否启用。停用的技能一律不进 `/api/skills`。
    pub(crate) enabled: bool,
}

#[derive(Debug, sqlx::FromRow)]
struct PluginRow {
    id: String,
    name: String,
    version: String,
    author: Option<String>,
    description: Option<String>,
    #[allow(dead_code)]
    dir: String,
    enabled: i64,
    installed_at: i64,
    updated_at: i64,
}

#[derive(Debug, sqlx::FromRow)]
struct SkillRow {
    plugin_id: String,
    name: String,
    status: String,
    reasons_json: String,
    manifest_json: String,
    description: Option<String>,
}
