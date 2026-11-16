//! 服务端目录浏览：给客户端选项目目录用。
//!
//! 客户端（尤其手机）看不到服务端这台电脑的文件系统，只能靠这个接口一层层往下走。
//! 边界必须由服务端把住：
//!
//! - 请求路径规范化后必须落在该模式允许的根目录内；
//! - 每个条目再规范化一次并复核包含关系，**借软链接跳出白名单的条目直接不展示**；
//! - 只返回目录，不返回文件——项目只能绑定目录；
//! - 单次最多 [`MAX_ENTRIES`] 条，不递归、不缓存，保证"看到的就是现在"。

use std::path::{Path, PathBuf};

use protocol::{DirEntry, DirKind, DirListing, ProjectMode};

use crate::config::Config;
use crate::project::{self, ProjectError};

/// 单次返回的条目上限。个人目录通常远小于这个数量，超出说明该用搜索而不是浏览。
const MAX_ENTRIES: usize = 200;

/// 列出一层目录。
///
/// `raw` 为空时从第一个允许的根目录开始；客户端首次进入项目选择器就走这条路径。
pub fn list(
    config: &Config,
    mode: ProjectMode,
    raw: Option<&str>,
) -> Result<DirListing, ProjectError> {
    let roots = project::roots_for(config, mode)?;

    let path = match raw.map(str::trim).filter(|raw| !raw.is_empty()) {
        Some(raw) => canonical_dir(raw)?,
        None => roots[0].clone(),
    };

    if !roots.iter().any(|root| path.starts_with(root)) {
        return Err(ProjectError::Denied(format!(
            "{} 不在允许浏览的目录范围内：请从根目录重新进入",
            path.display()
        )));
    }

    let entries = collect(&path, &roots);
    let parent = parent_of(&path, &roots);

    Ok(DirListing {
        path: path.to_string_lossy().to_string(),
        parent,
        roots: roots
            .iter()
            .map(|root| root.to_string_lossy().to_string())
            .collect(),
        entries,
    })
}

/// 上一级目录。已经站在某个根上时返回 `None`。
///
/// 用「所属的根」（最长匹配）而不是「任意一个根」来判断边界：否则站在 A 根上时，
/// 只要 A 的父目录碰巧是另一个根 B，「上一级」就会把人带进另一个白名单区域。
fn parent_of(path: &Path, roots: &[PathBuf]) -> Option<String> {
    let root = roots
        .iter()
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.as_os_str().len())?;

    if path == root {
        return None;
    }

    path.parent()
        .filter(|parent| parent.starts_with(root))
        .map(|parent| parent.to_string_lossy().to_string())
}

fn canonical_dir(raw: &str) -> Result<PathBuf, ProjectError> {
    let candidate = PathBuf::from(raw);
    if !candidate.is_absolute() {
        return Err(ProjectError::Invalid(format!(
            "目录路径必须是绝对路径（当前是 \"{raw}\"）"
        )));
    }

    let path = candidate.canonicalize().map_err(|err| {
        ProjectError::Invalid(format!(
            "目录不可访问（{}）：{err}；请返回上一级重试",
            candidate.display()
        ))
    })?;

    if !path.is_dir() {
        return Err(ProjectError::Invalid(format!(
            "{} 不是目录",
            path.display()
        )));
    }
    Ok(path)
}

fn collect(path: &Path, roots: &[PathBuf]) -> Vec<DirEntry> {
    let Ok(reader) = std::fs::read_dir(path) else {
        tracing::warn!(path = %path.display(), "目录不可读，返回空列表");
        return Vec::new();
    };

    let mut entries: Vec<DirEntry> = Vec::new();
    for item in reader {
        if entries.len() >= MAX_ENTRIES {
            break;
        }
        let Ok(item) = item else { continue };

        let name = item.file_name().to_string_lossy().to_string();
        // 隐藏目录（含 .git、.cache）不展示：选择器里它们是噪音，命中概率远低于误触。
        if name.starts_with('.') {
            continue;
        }

        // 跟随软链接后复核边界：`~/link -> /` 这种条目不能出现，否则浏览等于没有白名单。
        let Ok(real) = item.path().canonicalize() else {
            continue;
        };
        if !real.is_dir() || !roots.iter().any(|root| real.starts_with(root)) {
            continue;
        }

        let kind = if real.join(".git").exists() {
            DirKind::Repo
        } else {
            DirKind::Dir
        };

        entries.push(DirEntry {
            name,
            path: real.to_string_lossy().to_string(),
            kind,
        });
    }

    // 只有目录，所以"目录优先"退化为名称升序；大小写不敏感更符合直觉（code 与 Code 挨着）。
    entries.sort_by_key(|entry| entry.name.to_lowercase());
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pa-fs-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        dir.canonicalize().expect("规范化失败")
    }

    fn config_for(root: &Path) -> Config {
        let mut config = Config::default();
        config.project.browse_roots = vec![root.to_path_buf()];
        config
    }

    #[test]
    fn lists_only_directories_and_marks_repos() {
        let root = temp_root("list");
        std::fs::create_dir_all(root.join("docs")).expect("建目录失败");
        std::fs::create_dir_all(root.join("code")).expect("建目录失败");
        std::fs::write(root.join("note.txt"), "x").expect("写文件失败");
        std::fs::create_dir_all(root.join("code").join(".git")).expect("建 .git 失败");
        std::fs::create_dir_all(root.join(".hidden")).expect("建隐藏目录失败");

        let listing = list(&config_for(&root), ProjectMode::Work, None).expect("应成功");
        let names: Vec<&str> = listing.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["code", "docs"], "只列目录、按名称升序");
        assert_eq!(listing.entries[0].kind, DirKind::Repo);
        assert_eq!(listing.entries[1].kind, DirKind::Dir);
        assert!(listing.parent.is_none(), "根目录不该给出上一级");
    }

    #[test]
    fn rejects_path_outside_roots() {
        let root = temp_root("outside");
        let config = config_for(&root);
        let err = list(&config, ProjectMode::Work, Some("/")).expect_err("越界必须拒绝");
        assert!(matches!(err, ProjectError::Denied(_)), "{err}");
    }

    #[test]
    fn subdirectory_reports_parent() {
        let root = temp_root("sub");
        std::fs::create_dir_all(root.join("inner")).expect("建目录失败");

        let child = root.join("inner").to_string_lossy().to_string();
        let listing = list(&config_for(&root), ProjectMode::Work, Some(&child)).expect("应成功");
        assert_eq!(
            listing.parent.as_deref(),
            Some(root.to_string_lossy().as_ref()),
            "子目录应能返回上一级"
        );
    }

    #[test]
    fn relative_path_is_rejected() {
        let root = temp_root("relative");
        let err = list(&config_for(&root), ProjectMode::Work, Some("docs/../../"))
            .expect_err("相对路径必须拒绝");
        assert!(matches!(err, ProjectError::Invalid(_)), "{err}");
    }
}
