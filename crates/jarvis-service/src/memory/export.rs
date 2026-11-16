//! 项目记忆导出：把当前仓库的项目层记忆渲染成 `AGENTS.md` 片段。
//!
//! 三条硬规则：
//! 1. **只替换标记块**：`<!-- personal-agent:memory:begin hash=… -->` 与
//!    `<!-- personal-agent:memory:end -->` 之间的内容会被替换，标记外一字不动；
//! 2. **预览必须先看**：`preview` 返回 unified diff，客户端展示后用户才点写入；
//! 3. **哈希不一致就不写**：`expected_hash` 是预览时算的文件哈希，apply 时重算，
//!    不一致说明文件被改过，返回 `conflict` 让用户重新预览。

use std::path::{Path, PathBuf};

use protocol::{ExportApplyResult, ExportPreview};
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;

use super::MemoryError;

const BEGIN_PREFIX: &str = "<!-- personal-agent:memory:begin";
const END_MARKER: &str = "<!-- personal-agent:memory:end -->";
const FILE_NAME: &str = "AGENTS.md";

/// 生成预览：不写文件。
pub async fn preview(pool: &SqlitePool, project_id: &str) -> Result<ExportPreview, MemoryError> {
    let (root, entries) = load(pool, project_id).await?;
    let path = root.join(FILE_NAME);
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    let block = render_block(&entries);
    let next = splice(&current, &block);

    Ok(ExportPreview {
        project_id: project_id.to_string(),
        path: path.to_string_lossy().to_string(),
        diff: unified_diff(&current, &next, FILE_NAME),
        entries: entries.len(),
        content_hash: hash(current.as_bytes()),
    })
}

/// 写入。哈希不一致 → `conflict`；路径越界 → `invalid`。
pub async fn apply(
    pool: &SqlitePool,
    project_id: &str,
    expected_hash: &str,
) -> Result<ExportApplyResult, MemoryError> {
    let (root, entries) = load(pool, project_id).await?;
    let path = root.join(FILE_NAME);

    let current = std::fs::read_to_string(&path).unwrap_or_default();
    if hash(current.as_bytes()) != expected_hash {
        return Err(MemoryError::Conflict(
            "文件已被改动，请重新预览后再写入".to_string(),
        ));
    }

    let next = splice(&current, &render_block(&entries));
    ensure_inside(&root, &path)?;
    std::fs::write(&path, &next)
        .map_err(|err| MemoryError::Invalid(format!("写入 {} 失败: {err}", path.display())))?;

    super::audit_reject(
        pool,
        "memory.exported",
        serde_json::json!({
            "project_id": project_id,
            "entries": entries.len(),
            "bytes": next.len(),
        }),
    )
    .await;

    Ok(ExportApplyResult {
        path: path.to_string_lossy().to_string(),
        bytes: next.len(),
    })
}

/// 取数：项目层 + normal + 生效中，按重要度倒序。
async fn load(
    pool: &SqlitePool,
    project_id: &str,
) -> Result<(PathBuf, Vec<(String, String)>), MemoryError> {
    let row: Option<(String, String)> =
        sqlx::query_as("SELECT path, mode FROM projects WHERE id = ? AND deleted_at IS NULL")
            .bind(project_id)
            .fetch_optional(pool)
            .await?;

    let Some((path, mode)) = row else {
        return Err(MemoryError::NotFound);
    };
    if mode != "code" {
        return Err(MemoryError::Invalid(
            "只有 Git 项目能导出 AGENTS.md".to_string(),
        ));
    }

    let rows: Vec<(String, Option<String>)> = sqlx::query_as(
        "SELECT content, subject FROM memories \
         WHERE kind = 'project' AND scope = 'project' AND project_id = ? \
           AND status = 'active' AND sensitivity = 'normal' AND deleted_at IS NULL \
         ORDER BY importance DESC, updated_at DESC LIMIT 200",
    )
    .bind(project_id)
    .fetch_all(pool)
    .await?;

    Ok((
        PathBuf::from(path),
        rows.into_iter()
            .map(|(content, subject)| (content, subject.unwrap_or_default()))
            .collect(),
    ))
}

fn render_block(entries: &[(String, String)]) -> String {
    let body = entries
        .iter()
        .map(|(content, subject)| {
            if subject.is_empty() {
                format!("- {content}")
            } else {
                format!("- {content}（{subject}）")
            }
        })
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "<!-- personal-agent:memory:begin hash={} -->\n\
         <!-- 以下内容由 personal-agent 生成，下次导出会整体替换；请勿手改本块内部。 -->\n\
         {body}\n\
         {END_MARKER}",
        hash(body.as_bytes())
    )
}

/// 只替换标记块。没有标记就追加到文件末尾（保留用户手写内容）。
fn splice(current: &str, block: &str) -> String {
    let Some(begin) = current.find(BEGIN_PREFIX) else {
        if current.trim().is_empty() {
            return format!("{block}\n");
        }
        return format!("{}\n\n{block}\n", current.trim_end());
    };
    let Some(relative_end) = current[begin..].find(END_MARKER) else {
        return format!("{}\n\n{block}\n", current.trim_end());
    };
    let end = begin + relative_end + END_MARKER.len();

    format!("{}{}{}", &current[..begin], block, &current[end..])
}

fn ensure_inside(root: &Path, path: &Path) -> Result<(), MemoryError> {
    // 目标文件可能还不存在：校验它的父目录落在项目内即可。
    let parent = path.parent().unwrap_or(root);
    let root = root
        .canonicalize()
        .map_err(|err| MemoryError::Invalid(format!("项目路径不可用: {err}")))?;
    let parent = parent
        .canonicalize()
        .map_err(|err| MemoryError::Invalid(format!("目标目录不可用: {err}")))?;

    if !parent.starts_with(&root) {
        return Err(MemoryError::Invalid(
            "导出目标不在项目内，已拒绝写入".to_string(),
        ));
    }
    Ok(())
}

fn hash(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())[..16].to_string()
}

/// 极简 unified diff：逐行比，够用户看清"改了哪几行"。
fn unified_diff(before: &str, after: &str, name: &str) -> String {
    if before == after {
        return String::new();
    }

    let old: Vec<&str> = before.lines().collect();
    let new: Vec<&str> = after.lines().collect();
    let mut out = format!("--- a/{name}\n+++ b/{name}\n");

    let max = old.len().max(new.len());
    for index in 0..max {
        match (old.get(index), new.get(index)) {
            (Some(left), Some(right)) if left == right => out.push_str(&format!(" {left}\n")),
            (left, right) => {
                if let Some(left) = left {
                    out.push_str(&format!("-{left}\n"));
                }
                if let Some(right) = right {
                    out.push_str(&format!("+{right}\n"));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splice_keeps_handwritten_content() {
        let current = "# 我的仓库\n\n手写段落\n";
        let block = render_block(&[("时间统一用毫秒".to_string(), String::new())]);
        let next = splice(current, &block);
        assert!(next.contains("手写段落"));
        assert!(next.contains("时间统一用毫秒"));
    }

    #[test]
    fn splice_replaces_only_marked_block() {
        let block = render_block(&[("新内容".to_string(), String::new())]);
        let current = format!("头部\n\n{block}\n\n尾部手写\n");
        let next = splice(
            &current,
            &render_block(&[("替换后".to_string(), String::new())]),
        );

        assert!(next.starts_with("头部"));
        assert!(next.ends_with("尾部手写\n"));
        assert!(next.contains("替换后"));
        assert!(!next.contains("新内容"));
    }

    #[test]
    fn diff_marks_added_and_removed_lines() {
        let diff = unified_diff("a\nb\n", "a\nc\n", "AGENTS.md");
        assert!(diff.contains("-b"));
        assert!(diff.contains("+c"));
    }
}
