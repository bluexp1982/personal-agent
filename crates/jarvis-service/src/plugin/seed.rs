//! 随应用分发的示例技能（种子）。
//!
//! `trip-plan` / `bill-explain` 曾经是编译进 worker 的内置技能：装好就在，
//! 但永远删不掉，`@` 候选里一直占位。现在它们在应用第一次启动时被装成
//! **普通外部插件**——可以停用、可以卸载，行为与用户自己导入的包完全一致。
//!
//! 为什么不是"打包时预置目录"：安装要做归一化、写 sidecar、落库，这套逻辑
//! 只有 [`super::install`] 一份；预置目录等于在别处再实现一遍，迟早漂移。
//!
//! 为什么要有 `plugin_seeds` 表：卸载会删掉目录与 `plugins` 记录。若以
//! "目录是否存在"判断要不要播种，用户卸载后下次启动又会被装回来——那正是
//! "可卸载"要避免的。表里记住"这个版本处理过了"，用户主动卸载后记
//! `dismissed`，之后连升级也不再装回。
//!
//! 播种发生在 `worker::spawn` 之前：worker 只认 `plugin_dir`，装晚了还得
//! 额外触发一次重载。

use std::io::{Cursor, Write};
use std::path::Path;

use sqlx::SqlitePool;

use super::install;
use super::store;
use super::{now_ms, PluginError};

/// 一个种子包。内容编译期嵌入，运行期打成 zip 再走正常安装链路。
pub(crate) struct SeedPack {
    /// 插件 id，同时写进 `plugin.json` 的 `name`。带专属前缀，
    /// 避免与用户自行导入的包撞 id（撞了安装会被拒）。
    pub(crate) id: &'static str,
    /// 包版本。应用内置版本更高时，已装的旧版本会被补装。
    pub(crate) version: &'static str,
    /// 播种修订号：**素材内容或兼容层判据变化时 +1**。
    ///
    /// `version` 只回答"包是哪个版本"，回答不了"装进去的结论对不对"：
    /// 兼容层修好一个误判之后，包版本不必变，但已经落盘的 sidecar 仍然是错的。
    /// 只比版本就会永远跳过，用户看到的是"包在那儿，但用不了"。
    pub(crate) revision: &'static str,
    /// 插件管理页的说明。
    pub(crate) description: &'static str,
    /// zip 内的技能目录名（`skills/<dir>/SKILL.md`）。
    pub(crate) skill_dir: &'static str,
    /// `SKILL.md` 原文。
    pub(crate) skill_md: &'static str,
}

/// 随应用分发的示例技能清单。
///
/// 这里不放 `code-task`：它的可用性由 `code.enabled` 决定，而插件的启停
/// 由用户决定。两套开关放在同一个东西上，必然出现"插件启用、能力关闭"
/// 的错位状态，所以它继续留在 worker 的内置加载里。
pub(crate) const SEEDS: &[SeedPack] = &[
    SeedPack {
        id: "com.personal-agent.trip-plan",
        version: "0.3.0",
        // rev2：兼容层改为优先用 frontmatter 的 `steps`，修掉"取资料步骤
        // 不在 steps 中"的误判。rev1 装进去的是 unsupported，必须重算。
        revision: "2",
        description: "出行方案编排：把一句话行程变成交通对比、天气参考与推荐",
        skill_dir: "trip-plan",
        skill_md: include_str!("../../assets/seed-skills/trip-plan/SKILL.md"),
    },
    SeedPack {
        id: "com.personal-agent.bill-explain",
        version: "0.1.0",
        revision: "2",
        description: "账单解读：拆出费用构成、异常项与可执行建议",
        skill_dir: "bill-explain",
        skill_md: include_str!("../../assets/seed-skills/bill-explain/SKILL.md"),
    },
];

/// 播种随应用分发的示例技能，返回本次实际安装的包数。
///
/// 单个包失败只记日志、不中断：示例能力装不上不该让服务起不来
/// （与 `project::ensure_default` 的处理一致）。
pub async fn ensure(pool: &SqlitePool, plugins_root: &Path) -> Result<usize, String> {
    install::ensure_plugins_root(plugins_root).map_err(|err| err.to_string())?;

    let mut installed = 0;
    for seed in SEEDS {
        match ensure_one(pool, plugins_root, seed).await {
            Ok(true) => installed += 1,
            Ok(false) => {}
            Err(err) => tracing::error!(seed = seed.id, %err, "示例技能安装失败，本次跳过"),
        }
    }
    Ok(installed)
}

/// 恢复预置技能：把用户主动卸载过的种子重新装回来。
///
/// 与 [`ensure`] 的差别是**对"用户意愿"的处理方向相反**：`ensure` 看到
/// `dismissed` 就跳过（卸载过就不该自己长回来），而 `restore` 是用户显式
/// 要求"我要它回来"，所以先清记录再装。
///
/// 已经装着的也会先卸再装：恢复的语义是回到出厂状态，而不是留着一份可能
/// 已经过时的 sidecar。
pub async fn restore(
    pool: &SqlitePool,
    plugins_root: &Path,
    only: Option<&str>,
) -> Result<Vec<String>, String> {
    let targets: Vec<&SeedPack> = SEEDS
        .iter()
        .filter(|seed| match only {
            None => true,
            Some(wanted) => wanted == seed.id || wanted == seed.skill_dir,
        })
        .collect();

    if targets.is_empty() {
        let names: Vec<&str> = SEEDS.iter().map(|seed| seed.id).collect();
        return Err(format!(
            "没有叫 {} 的预置技能；可用：{}",
            only.unwrap_or_default(),
            names.join("、")
        ));
    }

    for seed in &targets {
        // 装着也先卸：恢复要的是出厂状态，而不是"还留着上次的 sidecar"。
        if let Ok((version, _dir)) = store::load_location(pool, seed.id).await {
            install::remove_plugin_dir(plugins_root, seed.id, &version)
                .map_err(|err| err.to_string())?;
            store::delete(pool, seed.id)
                .await
                .map_err(|err| err.to_string())?;
        }
        // 必须在 `store::delete` 之后删：它会顺手把种子记成 dismissed，
        // 记录留在那里的话 `ensure` 会认为"用户卸载过"，照样跳过。
        sqlx::query("DELETE FROM plugin_seeds WHERE name = ?")
            .bind(seed.id)
            .execute(pool)
            .await
            .map_err(|err| format!("清理播种记录失败：{err}"))?;
    }

    ensure(pool, plugins_root).await?;

    let mut lines = Vec::new();
    for seed in &targets {
        let skill: Option<(String, String)> =
            sqlx::query_as("SELECT name, status FROM plugin_skills WHERE plugin_id = ?")
                .bind(seed.id)
                .fetch_optional(pool)
                .await
                .map_err(|err| format!("查询技能状态失败：{err}"))?;

        match skill {
            Some((name, status)) => lines.push(format!("已恢复 {name}  [{status}]")),
            // `ensure` 把单个包的失败记进日志、不向上抛；这里如实说明，
            // 别让命令行看起来"都成功了"。
            None => lines.push(format!("{} 未能恢复（原因见服务端日志）", seed.id)),
        }

        // 一并给出落盘位置，排查"装到哪去了"时不用再猜。
        if let Ok((version, dir)) = store::load_location(pool, seed.id).await {
            lines.push(format!("  · {version}  {dir}"));
        }
    }
    Ok(lines)
}

/// 处理单个种子包。返回是否真的装了新东西。
async fn ensure_one(
    pool: &SqlitePool,
    plugins_root: &Path,
    seed: &SeedPack,
) -> Result<bool, PluginError> {
    let recorded: Option<(String, String, i64)> =
        sqlx::query_as("SELECT version, revision, dismissed FROM plugin_seeds WHERE name = ?")
            .bind(seed.id)
            .fetch_optional(pool)
            .await
            .map_err(db_error)?;

    if let Some((version, revision, dismissed)) = &recorded {
        // 用户主动卸载过：永久不再播种，应用升级也不装回。
        if *dismissed != 0 {
            return Ok(false);
        }
        // 版本与修订号都一致才算"处理过"。只比版本会错过
        // "包没变、但装进去的结论已经错了"的情况（判据修复、sidecar 重算）。
        if version == seed.version && revision == seed.revision {
            return Ok(false);
        }
    }

    let current: Option<String> = sqlx::query_scalar("SELECT version FROM plugins WHERE id = ?")
        .bind(seed.id)
        .fetch_optional(pool)
        .await
        .map_err(db_error)?;

    if let Some(version) = &current {
        if recorded.is_none() {
            // 没播种过、却有同 id 的包：那是用户自己导入的，不能覆盖。
            // 记一笔"已处理"，避免每次启动都来这里判断一次。
            tracing::warn!(
                seed = seed.id,
                installed = %version,
                builtin = seed.version,
                "已存在同 id 的插件，跳过播种（不覆盖用户内容）"
            );
            record(pool, seed).await?;
            return Ok(false);
        }
        // 是我们种过的包，且走到这里说明版本或修订号已经不一致：
        // 版本不同是升级，版本相同则意味着"包的结论要重算"（判据/素材变了）。
        // 两种都拆掉重装——只比版本就补记录的话，误判会永远留在库里。
        let (old_version, _dir) = store::load_location(pool, seed.id).await?;
        install::remove_plugin_dir(plugins_root, seed.id, &old_version)?;
        store::delete(pool, seed.id).await?;
    }

    let bytes = pack(seed)?;
    // 卸载旧版之后重新取一遍保留名：刚删掉的那条不该再挡住自己。
    let reserved = store::reserved(pool).await?;
    let installed = install::install(&bytes, plugins_root, &reserved)?;
    store::save(pool, &installed).await?;
    record(pool, seed).await?;

    tracing::info!(seed = seed.id, version = seed.version, "示例技能已安装");
    Ok(true)
}

/// 记一笔"这个版本处理过了"。`dismissed` 显式归零：走上来的路径要么是
/// 首次安装、要么是升级补装，都意味着这个包现在是存在的。
async fn record(pool: &SqlitePool, seed: &SeedPack) -> Result<(), PluginError> {
    sqlx::query(
        "INSERT INTO plugin_seeds (name, version, revision, dismissed, applied_at) \
         VALUES (?, ?, ?, 0, ?) \
         ON CONFLICT (name) DO UPDATE SET version = excluded.version, \
                revision = excluded.revision, dismissed = 0, applied_at = excluded.applied_at",
    )
    .bind(seed.id)
    .bind(seed.version)
    .bind(seed.revision)
    .bind(now_ms())
    .execute(pool)
    .await
    .map_err(db_error)?;
    Ok(())
}

/// 把种子内容打成安装包。字段与用户导入的 zip 完全一致，
/// 后面走同一条 [`install::install`]，不另开旁路。
fn pack(seed: &SeedPack) -> Result<Vec<u8>, PluginError> {
    let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    let manifest = serde_json::json!({
        "plugin_api": super::PLUGIN_API,
        "name": seed.id,
        "version": seed.version,
        "description": seed.description,
    });

    writer
        .start_file("plugin.json", options)
        .map_err(zip_error)?;
    writer
        .write_all(manifest.to_string().as_bytes())
        .map_err(write_error)?;

    let path = format!("skills/{}/SKILL.md", seed.skill_dir);
    writer.start_file(path, options).map_err(zip_error)?;
    writer
        .write_all(seed.skill_md.as_bytes())
        .map_err(write_error)?;

    let cursor = writer.finish().map_err(zip_error)?;
    Ok(cursor.into_inner())
}

fn db_error(err: sqlx::Error) -> PluginError {
    PluginError::Io(format!("读写种子技能记录失败：{err}"))
}

fn write_error(err: std::io::Error) -> PluginError {
    PluginError::Io(format!("打包示例技能失败：{err}"))
}

fn zip_error(err: zip::result::ZipError) -> PluginError {
    PluginError::Io(format!("打包示例技能失败：{err}"))
}
