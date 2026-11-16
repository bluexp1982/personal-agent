//! 编码任务的现场：隔离工作树与任务分支。
//!
//! 现场由 `jarvis-worker` 创建在 `{worktree_dir}/{task_id}/`：
//!
//! ```text
//! base/wt/            独立克隆（CLI 的 cwd），分支 agent/{task_id}
//! base/conf/          CLI 配置
//! base/meta.json      基础分支、任务分支、CLI 会话 id
//! ```
//!
//! 服务端在这里只做两件事：**读出来**给客户端看（详情端点），**按用户要求删掉**
//! （清理端点）。它从不主动改动里面的内容——现场保留是刻意的设计，
//! 失败或拒绝之后用户还要能进去看、能手动合并。
//!
//! 删除只针对数据目录里的这棵克隆；**原仓库里已合并的 `agent/*` 分支一律不碰**：
//! 那已经是用户仓库的历史，删它属于改用户的仓库。

use std::path::PathBuf;

use protocol::WorktreeInfo;

use crate::config::Config;

/// `meta.json` 里我们关心的字段。与 worker 侧 `code::worktree::Meta` 对齐。
#[derive(Debug, serde::Deserialize)]
struct Meta {
    branch: String,
}

#[derive(Debug, thiserror::Error)]
pub enum WorktreeError {
    /// 任务标识不像服务端生成的 id：拒绝拼路径。
    #[error("任务标识非法")]
    InvalidId,
    /// 目标目录不在预期位置（`..` 或软链接逃逸）。
    #[error("工作树目录不在预期位置: {0}")]
    Escape(String),
    #[error("清理工作树失败: {0}")]
    Io(String),
}

/// 读取某个任务的现场信息。没有现场（普通任务、从未准备成功、已清理）时返回 `None`。
///
/// 只读一个一百来字节的 `meta.json`，可以放心在详情端点里调用。
pub fn info_of(config: &Config, task_id: &str) -> Option<WorktreeInfo> {
    let base = base_dir(config, task_id)?;
    let path = base.join("wt");

    let raw = std::fs::read_to_string(base.join("meta.json")).ok()?;
    let meta: Meta = serde_json::from_str(&raw).ok()?;
    if meta.branch.trim().is_empty() {
        return None;
    }

    Some(WorktreeInfo {
        path: path.to_string_lossy().to_string(),
        branch: meta.branch,
        exists: path.is_dir(),
    })
}

/// 删除某个任务的整个现场目录。
///
/// 返回是否真的删了东西：目录本来就不存在时返回 `Ok(false)`，让接口可以幂等。
pub async fn clean(config: &Config, task_id: &str) -> Result<bool, WorktreeError> {
    let base = base_dir(config, task_id).ok_or(WorktreeError::InvalidId)?;
    if !base.exists() {
        return Ok(false);
    }

    // 规范化后必须是 `worktree_dir` 的直接子目录：防 `..`、防软链接把删除引到别处。
    let root = config.code_worktree_dir();
    let root = root.canonicalize().map_err(|err| {
        WorktreeError::Io(format!("工作树根目录不可访问（{}）：{err}", root.display()))
    })?;
    let canonical = base.canonicalize().map_err(|err| {
        WorktreeError::Io(format!("工作树目录不可访问（{}）：{err}", base.display()))
    })?;
    if canonical.parent() != Some(root.as_path()) || canonical.file_name() != Some(task_id.as_ref())
    {
        return Err(WorktreeError::Escape(
            canonical.to_string_lossy().to_string(),
        ));
    }

    tokio::fs::remove_dir_all(&canonical)
        .await
        .map_err(|err| WorktreeError::Io(format!("删除 {} 失败：{err}", canonical.display())))?;

    tracing::info!(task_id, path = %canonical.display(), "已清理编码任务现场");
    Ok(true)
}

/// 任务在现场目录里的那一层：`{worktree_dir}/{task_id}`。
///
/// 任务标识只允许 worker 也会接受的字符集；不合规就当作"没有现场"，
/// 绝不用它去拼一个可能带 `..` 的路径。
fn base_dir(config: &Config, task_id: &str) -> Option<PathBuf> {
    if task_id.is_empty()
        || !task_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return None;
    }
    Some(config.code_worktree_dir().join(task_id))
}

/// 判断一个路径是否就是某个任务的现场目录（供测试与排障使用）。
#[cfg(test)]
fn is_task_dir(config: &Config, task_id: &str) -> bool {
    base_dir(config, task_id)
        .map(|path| path.parent() == Some(config.code_worktree_dir().as_path()))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_with_dir(dir: &std::path::Path) -> Config {
        let mut config = Config::default();
        config.code.worktree_dir = Some(dir.to_path_buf());
        config
    }

    #[test]
    fn rejects_ids_that_could_escape_the_root() {
        let config = Config::default();
        for bad in ["", "..", "a/b", "task_1/../..", "task 1"] {
            assert!(base_dir(&config, bad).is_none(), "{bad} 不该被接受");
        }
        assert!(base_dir(&config, "task_abc-123_x").is_some());
    }

    #[test]
    fn info_is_absent_without_meta() {
        let dir = std::env::temp_dir().join(format!("pa-wt-info-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("task_1")).expect("创建目录失败");
        let config = config_with_dir(&dir);

        assert!(
            info_of(&config, "task_1").is_none(),
            "没有 meta.json 时应当没有现场"
        );
        assert!(info_of(&config, "../etc").is_none(), "非法标识不该读盘");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn info_reports_branch_and_existence() {
        let dir = std::env::temp_dir().join(format!("pa-wt-info2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let base = dir.join("task_1");
        std::fs::create_dir_all(base.join("wt")).expect("创建目录失败");
        std::fs::write(
            base.join("meta.json"),
            r#"{"base_branch":"main","branch":"agent/task_1"}"#,
        )
        .expect("写文件失败");
        let config = config_with_dir(&dir);

        let info = info_of(&config, "task_1").expect("应能读到现场");
        assert_eq!(info.branch, "agent/task_1");
        assert!(info.exists);
        assert!(info.path.ends_with("task_1/wt"), "{}", info.path);
        assert!(is_task_dir(&config, "task_1"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn clean_removes_only_the_task_directory() {
        let dir = std::env::temp_dir().join(format!("pa-wt-clean-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let base = dir.join("task_1");
        std::fs::create_dir_all(base.join("wt")).expect("创建目录失败");
        std::fs::write(dir.join("keep.txt"), "x").expect("写文件失败");
        let config = config_with_dir(&dir);

        assert!(clean(&config, "task_1").await.expect("清理失败"));
        assert!(!base.exists(), "任务目录应被删除");
        assert!(dir.join("keep.txt").is_file(), "同级文件不该被牵连");
        assert!(
            !clean(&config, "task_1").await.expect("重复清理应成功"),
            "目录已不存在时返回 false，便于接口幂等"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn clean_rejects_invalid_ids() {
        let config = Config::default();
        let err = clean(&config, "../../etc")
            .await
            .expect_err("非法标识必须拒绝");
        assert!(matches!(err, WorktreeError::InvalidId));
    }
}
