//! `jarvis-service plugin ...` 的实现。
//!
//! 直接操作数据库与插件目录，**不经过运行中的服务**：用户完全可能在想装包时
//! 服务并没起来（或刚装好还没 `install`）。代价是装完不会立刻生效——
//! 返回的提示里会说明"重启服务或等 worker 空闲后生效"。
//!
//! 放在 lib 里而不是 `main.rs`：`install` / `store` 的类型是本 crate 内部的，
//! 让 bin 直接引用会把它们全部提升成 `pub`，等于为了一个命令行口子
//! 把内部结构暴露出去。

use std::path::PathBuf;

use crate::config::Config;

use super::{install, store};

/// 命令行动作。
#[derive(Debug, Clone)]
pub enum CliAction {
    Install(PathBuf),
    List,
    Remove(String),
    Enable(String),
    Disable(String),
    /// 恢复随应用分发的预置技能（卸载过也能装回）。
    Restore(Option<String>),
}

/// 执行动作，返回要打印给用户的行。
///
/// 返回字符串而不是直接 `println!`：project 的 lint 禁止 `print_stdout`，
/// 输出统一由调用方（`main.rs` 的 tracing）负责。
pub async fn run(config: &Config, action: CliAction) -> Result<Vec<String>, String> {
    let pool = crate::db::connect(&config.db_path())
        .await
        .map_err(|err| format!("打开数据库失败：{err}"))?;
    crate::db::migrate(&pool)
        .await
        .map_err(|err| format!("执行迁移失败：{err}"))?;

    let plugins_root = config.plugins_dir();

    match action {
        CliAction::Install(path) => {
            let bytes = tokio::fs::read(&path)
                .await
                .map_err(|err| format!("读不到 {}：{err}", path.display()))?;

            install::ensure_plugins_root(&plugins_root).map_err(|err| err.to_string())?;
            let reserved = store::reserved(&pool)
                .await
                .map_err(|err| err.to_string())?;
            let installed = install::install(&bytes, &plugins_root, &reserved)
                .map_err(|err| err.to_string())?;

            store::save(&pool, &installed)
                .await
                .map_err(|err| err.to_string())?;

            let mut lines = vec![format!(
                "已安装 {} ({})  ／  {} 个技能",
                installed.manifest.name,
                installed.manifest.version,
                installed.skills.len()
            )];

            for skill in &installed.skills {
                let suffix = if skill.reasons.is_empty() {
                    String::new()
                } else {
                    format!("  —  {}", skill.reasons.join("；"))
                };
                lines.push(format!(
                    "  · {}  [{}]{}",
                    skill.manifest.name,
                    skill.status.as_str(),
                    suffix
                ));
            }

            lines.push("重启服务后生效；服务在运行时会在执行进程空闲后自动重载".to_string());
            Ok(lines)
        }

        CliAction::List => {
            let page = store::list(&pool, false)
                .await
                .map_err(|err| err.to_string())?;

            if page.items.is_empty() {
                return Ok(vec!["还没有安装任何技能包".to_string()]);
            }

            let mut lines = Vec::new();
            for plugin in page.items {
                lines.push(format!(
                    "{}  {}  [{}]",
                    plugin.id,
                    plugin.version,
                    if plugin.enabled { "启用" } else { "停用" }
                ));
                for skill in plugin.skills {
                    lines.push(format!("  · {}  [{}]", skill.name, skill.status.as_str()));
                }
            }
            Ok(lines)
        }

        CliAction::Remove(id) => {
            let (version, _dir) = store::load_location(&pool, &id)
                .await
                .map_err(|err| err.to_string())?;
            install::remove_plugin_dir(&plugins_root, &id, &version)
                .map_err(|err| err.to_string())?;
            store::delete(&pool, &id)
                .await
                .map_err(|err| err.to_string())?;
            Ok(vec![format!("已卸载 {id} ({version})")])
        }

        CliAction::Enable(id) => {
            store::set_enabled(&pool, &id, true)
                .await
                .map_err(|err| err.to_string())?;
            Ok(vec![format!("已启用 {id}")])
        }

        CliAction::Disable(id) => {
            store::set_enabled(&pool, &id, false)
                .await
                .map_err(|err| err.to_string())?;
            Ok(vec![format!("已停用 {id}")])
        }

        CliAction::Restore(id) => {
            let mut lines = super::seed::restore(&pool, &plugins_root, id.as_deref()).await?;
            lines.push("重启服务后生效；服务在运行时会在执行进程空闲后自动重载".to_string());
            Ok(lines)
        }
    }
}
