//! git worktree 封装。
//!
//! 每个编码任务在 `{worktree_root}/{task_id}/wt` 下拿一棵独立工作树与 `agent/{task_id}`
//! 分支：失败或取消时原仓库保持干净，任务之间互不影响。
//!
//! 目录布局（`base = {worktree_root}/{task_id}`）：
//!
//! ```text
//! base/wt/                     工作树（CLI 的 cwd）
//! base/conf/opencode.json      CLI 配置（不落在仓库里，不污染 diff）
//! base/meta.json               基础分支、分支名、CLI 会话 id（恢复现场用）
//! ```
//!
//! 不用数据库记这些：路径由 `task_id` 决定，worker 重启后按同一路径找回来即可。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::process::Command;

/// 提交时使用的身份。固定值而不是读用户 git 配置：任务提交不该依赖环境差异。
const GIT_NAME: &str = "personal-agent";
const GIT_EMAIL: &str = "agent@local";

#[derive(Debug, thiserror::Error)]
pub(crate) enum WorktreeError {
    #[error("仓库不可用：{0}")]
    Repo(String),
    #[error("仓库 HEAD 处于游离状态：请先切到一个分支，再发起编码任务")]
    Detached,
    #[error("git 命令失败：{0}")]
    Git(String),
    #[error("合并冲突：{0}")]
    Conflict(String),
    #[error("文件操作失败：{0}")]
    Io(#[from] std::io::Error),
}

impl WorktreeError {
    /// 给用户的建议，随 `TaskFailed.hint` 一起下发。
    ///
    /// 返回 `String` 而不是 `&'static str`：客户端只展示 hint，固定文案等于把
    /// 唯一的线索留在终端日志里——git 的失败原因必须能被用户直接看到。
    pub(crate) fn hint(&self) -> String {
        match self {
            Self::Detached => "请先在目标仓库切到一个分支，再重试".to_string(),
            Self::Conflict(_) => "改动与该分支冲突：分支与工作树已保留，请手动合并".to_string(),
            // `Repo` 的 message 在 `prepare` 里就写成"出了什么问题 + 该怎么改"。
            Self::Repo(reason) => reason.clone(),
            Self::Git(reason) => format!("git 报错：{}", first_line(reason)),
            Self::Io(err) => format!("本地文件操作失败：{err}"),
        }
    }

    /// 该错误对应的稳定错误码。
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::Conflict(_) => "code_merge_conflict",
            Self::Detached | Self::Repo(_) => "code_project_denied",
            Self::Git(_) | Self::Io(_) => "code_failed",
        }
    }
}

/// hint 只放一行摘要：完整 git 输出留在 `message` 与 worker 日志里。
const HINT_MAX_CHARS: usize = 160;

fn first_line(raw: &str) -> String {
    let line = raw
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("");
    if line.is_empty() {
        return "未知错误（详见运行日志）".to_string();
    }

    let mut summary: String = line.chars().take(HINT_MAX_CHARS).collect();
    if line.chars().count() > HINT_MAX_CHARS {
        summary.push('…');
    }
    summary
}

/// 任务现场。
#[derive(Debug, Clone)]
pub(crate) struct Workspace {
    /// 原仓库根目录（合并回这里）。
    pub(crate) repo: PathBuf,
    /// 隔离工作树（CLI 的 cwd）。
    pub(crate) path: PathBuf,
    /// 任务分支。
    pub(crate) branch: String,
    /// 创建分支时所在的基分支。
    pub(crate) base_branch: String,
    /// 配置目录（与工作树同级，不在仓库内）。
    pub(crate) config_dir: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Meta {
    base_branch: String,
    branch: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
}

/// 准备（或复用）一个任务的工作树。
pub(crate) async fn prepare(
    repo: &Path,
    root: &Path,
    task_id: &str,
) -> Result<Workspace, WorktreeError> {
    if !task_id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Err(WorktreeError::Repo(format!("任务标识非法: {task_id}")));
    }

    let repo = std::fs::canonicalize(repo).map_err(|err| {
        WorktreeError::Repo(format!(
            "仓库路径无法访问（{}）：{err}；请确认目录存在且服务进程能读它",
            repo.display()
        ))
    })?;

    // 必须是**仓库根**，不能是仓库里的子目录。
    // `--is-inside-work-tree` 对任意子目录都返回 true，填错路径会一路过检查、
    // 直到 clone 才炸（`fatal: repository '...' does not exist`），
    // 用户只看到 code_failed，还得去翻终端才知道原因。
    let toplevel = git(&repo, &["rev-parse", "--show-toplevel"])
        .await
        .map_err(|_| {
            WorktreeError::Repo(format!(
                "{} 不是 git 仓库；请填仓库根目录（含 .git 的那一层）",
                repo.display()
            ))
        })?;
    let toplevel =
        std::fs::canonicalize(toplevel.trim()).unwrap_or_else(|_| PathBuf::from(toplevel.trim()));
    if toplevel != repo {
        return Err(WorktreeError::Repo(format!(
            "{} 不是仓库根目录（它属于 {}）；请直接填后者",
            repo.display(),
            toplevel.display()
        )));
    }

    // 空仓库也要在这里挡住：没有任何提交时 `rev-parse --abbrev-ref HEAD` 直接失败，
    // 会被当成普通 git 错误报成 code_failed，用户看不出"只是还没 commit"。
    git(&repo, &["rev-parse", "--verify", "HEAD"])
        .await
        .map_err(|_| {
            WorktreeError::Repo(format!(
                "{} 还没有任何提交；请先在仓库里 commit 一次再派活",
                repo.display()
            ))
        })?;

    let base = git(&repo, &["rev-parse", "--abbrev-ref", "HEAD"]).await?;
    let base_branch = base.trim().to_string();
    if base_branch.is_empty() || base_branch == "HEAD" {
        return Err(WorktreeError::Detached);
    }

    let base_dir = root.join(task_id);
    let path = base_dir.join("wt");
    let config_dir = base_dir.join("conf");
    let meta_path = base_dir.join("meta.json");
    let branch = format!("agent/{task_id}");

    // 复用：worker 崩溃重启后任务重跑，不该丢掉已经改好的工作树。
    //
    // 判据是 `.git` 是**目录**：那是独立克隆；旧版的 `git worktree` 这里是文件，
    // 会被当成残留重建（原因见下方 clone 的注释）。
    if path.join(".git").is_dir() && meta_path.is_file() {
        if let Ok(raw) = std::fs::read_to_string(&meta_path) {
            if let Ok(meta) = serde_json::from_str::<Meta>(&raw) {
                return Ok(Workspace {
                    repo,
                    path,
                    branch: meta.branch,
                    base_branch: meta.base_branch,
                    config_dir,
                });
            }
        }
        tracing::warn!(task_id, "meta.json 无法解析，重建工作树");
    }

    // 残留目录（上次失败留下）：旧版可能是 git worktree，先摘登记再删目录。
    if path.exists() {
        let _ = git(
            &repo,
            &["worktree", "remove", "--force", &path.to_string_lossy()],
        )
        .await;
        let _ = std::fs::remove_dir_all(&path);
    }
    std::fs::create_dir_all(&base_dir)?;

    // 用**独立克隆**而不是 `git worktree`。
    //
    // 实测（opencode 2.1.4）：它的"项目根"会顺着 worktree 的 `.git` 文件回到主仓库，
    // 于是 CLI 把文件改在主仓库里，我们这边看到"无改动 → 成功"，隔离承诺是假的。
    // 克隆有自己完整的 `.git` 目录，CLI 没有任何指针能跳回主仓库。
    // `--local` 走硬链接，跨文件系统（例如数据目录在 /Volumes、仓库在 /tmp）会直接
    // 报 "Cross-device link"。先试硬链接（快），失败再退回真实复制。
    if let Err(err) = git(
        &repo,
        &[
            "clone",
            "--quiet",
            "--local",
            &repo.to_string_lossy(),
            &path.to_string_lossy(),
        ],
    )
    .await
    {
        tracing::warn!(%err, "硬链接克隆失败，改用复制（跨文件系统时必然发生）");
        let _ = std::fs::remove_dir_all(&path);
        git(
            &repo,
            &[
                "clone",
                "--quiet",
                "--no-hardlinks",
                &repo.to_string_lossy(),
                &path.to_string_lossy(),
            ],
        )
        .await?;
    }

    // 克隆里建任务分支：基点就是克隆时的 HEAD。
    git(&path, &["checkout", "--quiet", "-b", &branch]).await?;

    write_meta(
        &meta_path,
        &Meta {
            base_branch: base_branch.clone(),
            branch: branch.clone(),
            session_id: None,
        },
    )?;

    Ok(Workspace {
        repo,
        path,
        branch,
        base_branch,
        config_dir,
    })
}

/// 记录 CLI 会话 id，便于后续续跑与排障。
pub(crate) fn remember_session(workspace: &Workspace, session_id: &str) {
    let meta_path = workspace.path.parent().map(|base| base.join("meta.json"));
    let Some(meta_path) = meta_path else {
        return;
    };
    let meta = Meta {
        base_branch: workspace.base_branch.clone(),
        branch: workspace.branch.clone(),
        session_id: Some(session_id.to_string()),
    };
    if let Err(err) = write_meta(&meta_path, &meta) {
        tracing::warn!(%err, "写入会话 id 失败");
    }
}

fn write_meta(path: &Path, meta: &Meta) -> Result<(), WorktreeError> {
    let text =
        serde_json::to_vec_pretty(meta).map_err(|err| WorktreeError::Git(err.to_string()))?;
    std::fs::write(path, text)?;
    Ok(())
}

/// 仓库状态快照（`git status --porcelain`）。
///
/// 用途是"运行前后比对"：CLI 若绕过工作树改了主仓库，这里能看出来。
/// 内容为空表示干净。
pub(crate) async fn status_of(repo: &Path) -> Result<String, WorktreeError> {
    git(repo, &["status", "--porcelain"]).await
}

/// 工作树里有没有未提交改动。
pub(crate) async fn has_changes(worktree: &Path) -> Result<bool, WorktreeError> {
    let status = git(worktree, &["status", "--porcelain"]).await?;
    Ok(!status.trim().is_empty())
}

/// 把工作树里的改动提交到任务分支。返回是否真的产生了提交。
pub(crate) async fn commit(worktree: &Path, message: &str) -> Result<bool, WorktreeError> {
    if !has_changes(worktree).await? {
        return Ok(false);
    }

    git(worktree, &["add", "-A"]).await?;
    git(
        worktree,
        &[
            "-c",
            &format!("user.name={GIT_NAME}"),
            "-c",
            &format!("user.email={GIT_EMAIL}"),
            "commit",
            "-q",
            "-m",
            message,
        ],
    )
    .await?;
    Ok(true)
}

/// 相对基分支的 `(stat, patch)`。基分支用名字而不是提交号：内容相同即可。
pub(crate) async fn diff(
    worktree: &Path,
    base_branch: &str,
) -> Result<(String, String), WorktreeError> {
    let stat = git(worktree, &["diff", "--stat", base_branch]).await?;
    let patch = git(worktree, &["diff", base_branch]).await?;
    Ok((stat, patch))
}

/// 把任务分支合并回原仓库的当前分支。
///
/// 冲突时中止合并并返回 [`WorktreeError::Conflict`]：半合并状态比"合并失败"更糟，
/// 用户下次根本分不清哪些改动已进来。
pub(crate) async fn merge(
    repo: &Path,
    worktree: &Path,
    branch: &str,
    message: &str,
) -> Result<(), WorktreeError> {
    // 分支在克隆里，主仓库没有这条 ref：先把它取回来再合并。
    git(
        repo,
        &[
            "fetch",
            "--quiet",
            &worktree.to_string_lossy(),
            &format!("{branch}:{branch}"),
        ],
    )
    .await?;

    // 跟 `commit` 一样带上固定身份：合并会新建一个 commit，缺 user 配置的机器上会直接失败。
    let result = git(
        repo,
        &[
            "-c",
            &format!("user.name={GIT_NAME}"),
            "-c",
            &format!("user.email={GIT_EMAIL}"),
            "merge",
            "--no-ff",
            "-m",
            message,
            branch,
        ],
    )
    .await;

    match result {
        Ok(_) => Ok(()),
        Err(err) => {
            let text = err.to_string();
            let _ = git(repo, &["merge", "--abort"]).await;
            if text.contains("CONFLICT") || text.contains("conflict") {
                Err(WorktreeError::Conflict(text))
            } else {
                Err(err)
            }
        }
    }
}

/// 在给定目录跑一条 git 命令，返回 stdout；失败时把 stderr 带进错误里。
async fn git(cwd: &Path, args: &[&str]) -> Result<String, WorktreeError> {
    let output = Command::new("git")
        .current_dir(cwd)
        .args(args)
        .output()
        .await
        .map_err(|err| WorktreeError::Git(format!("无法执行 git: {err}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(WorktreeError::Git(if stderr.is_empty() {
            format!("git {} 退出码 {:?}", args.join(" "), output.status.code())
        } else {
            stderr
        }));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn init_repo(dir: &Path) {
        std::fs::create_dir_all(dir).expect("创建目录失败");
        git(dir, &["init", "-q"]).await.expect("git init 失败");
        std::fs::write(dir.join("README.md"), "init\n").expect("写文件失败");
        git(dir, &["add", "-A"]).await.expect("git add 失败");
        git(
            dir,
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@local",
                "commit",
                "-q",
                "-m",
                "init",
            ],
        )
        .await
        .expect("git commit 失败");
    }

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pa-wt-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        dir
    }

    #[tokio::test]
    async fn creates_isolated_worktree_and_merges_back() {
        let root = temp_root("merge");
        let repo = root.join("repo");
        init_repo(&repo).await;

        let workspace = prepare(&repo, &root.join("trees"), "task1")
            .await
            .expect("准备工作树失败");
        assert!(
            workspace.path.join("README.md").is_file(),
            "工作树应含仓库内容"
        );
        // 默认分支名由 git 版本决定（master / main），只断言"不是游离 HEAD"。
        assert!(!workspace.base_branch.is_empty());
        assert_ne!(workspace.base_branch, "HEAD");
        assert!(workspace.config_dir.starts_with(root.join("trees")));

        // 改一个文件并提交：原仓库此刻不应有变化。
        std::fs::write(workspace.path.join("hello.txt"), "ok\n").expect("写文件失败");
        assert!(has_changes(&workspace.path).await.expect("status 失败"));
        assert!(commit(&workspace.path, "agent: hello")
            .await
            .expect("提交失败"));
        assert!(!repo.join("hello.txt").exists(), "合并前原仓库必须保持干净");

        let (stat, patch) = diff(&workspace.path, &workspace.base_branch)
            .await
            .expect("diff 失败");
        assert!(stat.contains("hello.txt"), "stat 应包含改动文件: {stat}");
        assert!(patch.contains("+ok"), "patch 应包含新增内容: {patch}");

        merge(&repo, &workspace.path, &workspace.branch, "merge agent")
            .await
            .expect("合并失败");
        assert_eq!(
            std::fs::read_to_string(repo.join("hello.txt")).expect("读文件失败"),
            "ok\n"
        );
    }

    #[tokio::test]
    async fn commit_without_changes_is_not_an_error() {
        let root = temp_root("nochange");
        let repo = root.join("repo");
        init_repo(&repo).await;

        let workspace = prepare(&repo, &root.join("trees"), "task2")
            .await
            .expect("准备工作树失败");
        assert!(
            !commit(&workspace.path, "agent: nothing")
                .await
                .expect("空提交不应报错"),
            "没有改动时不应产生提交"
        );

        let (stat, patch) = diff(&workspace.path, &workspace.base_branch)
            .await
            .expect("diff 失败");
        assert!(stat.trim().is_empty(), "空改动不应有 stat: {stat}");
        assert!(patch.trim().is_empty(), "空改动不应有 patch: {patch}");
    }

    #[tokio::test]
    async fn reuses_existing_worktree_after_restart() {
        let root = temp_root("reuse");
        let repo = root.join("repo");
        init_repo(&repo).await;

        let first = prepare(&repo, &root.join("trees"), "task3")
            .await
            .expect("第一次准备失败");
        std::fs::write(first.path.join("kept.txt"), "keep\n").expect("写文件失败");

        let second = prepare(&repo, &root.join("trees"), "task3")
            .await
            .expect("第二次准备失败");
        assert_eq!(second.path, first.path);
        assert_eq!(second.branch, first.branch);
        assert!(
            second.path.join("kept.txt").is_file(),
            "复用时应保留已有改动"
        );
    }

    #[tokio::test]
    async fn rejects_detached_head() {
        let root = temp_root("detached");
        let repo = root.join("repo");
        init_repo(&repo).await;
        let head = git(&repo, &["rev-parse", "HEAD"])
            .await
            .expect("rev-parse 失败");
        git(&repo, &["checkout", "-q", head.trim()])
            .await
            .expect("detach 失败");

        let err = prepare(&repo, &root.join("trees"), "task4")
            .await
            .expect_err("游离 HEAD 必须拒绝");
        assert!(matches!(err, WorktreeError::Detached));
        assert_eq!(err.code(), "code_project_denied");
    }

    #[tokio::test]
    async fn rejects_non_git_directory() {
        let root = temp_root("nongit");
        let plain = root.join("plain");
        std::fs::create_dir_all(&plain).expect("创建目录失败");

        let err = prepare(&plain, &root.join("trees"), "task5")
            .await
            .expect_err("非 git 目录必须拒绝");
        assert!(matches!(err, WorktreeError::Repo(_)));
        assert_eq!(err.code(), "code_project_denied");
        assert!(
            err.hint().contains("不是 git 仓库"),
            "hint 要说清是哪一类问题：{}",
            err.hint()
        );
    }

    #[tokio::test]
    async fn rejects_subdirectory_of_a_repo() {
        let root = temp_root("subdir");
        let repo = root.join("repo");
        init_repo(&repo).await;
        let sub = repo.join("src");
        std::fs::create_dir_all(&sub).expect("创建子目录失败");

        // `--is-inside-work-tree` 在子目录里也返回 true：这里必须靠 toplevel 比对拦住，
        // 否则会一路走到 clone，再把用户引向"看 git 日志"。
        let err = prepare(&sub, &root.join("trees"), "task6")
            .await
            .expect_err("仓库子目录必须拒绝");
        assert!(matches!(err, WorktreeError::Repo(_)));
        assert_eq!(err.code(), "code_project_denied");
        let hint = err.hint();
        assert!(hint.contains("不是仓库根目录"), "{hint}");
        assert!(hint.contains("请直接填后者"), "hint 要给出正确路径：{hint}");
    }

    #[tokio::test]
    async fn rejects_repo_without_commits() {
        let root = temp_root("empty");
        let repo = root.join("repo");
        std::fs::create_dir_all(&repo).expect("创建目录失败");
        git(&repo, &["init", "-q"]).await.expect("git init 失败");

        let err = prepare(&repo, &root.join("trees"), "task7")
            .await
            .expect_err("空仓库必须拒绝");
        assert!(matches!(err, WorktreeError::Repo(_)));
        assert_eq!(
            err.code(),
            "code_project_denied",
            "空仓库属于路径问题，不该报 code_failed"
        );
        assert!(
            err.hint().contains("还没有任何提交"),
            "hint 要指出缺的是提交：{}",
            err.hint()
        );
    }

    #[test]
    fn git_failure_hint_carries_the_first_stderr_line() {
        let err = WorktreeError::Git(
            "fatal: repository '/tmp/nope' does not exist\n再后面的行不该进 hint".to_string(),
        );
        let hint = err.hint();
        assert!(hint.contains("fatal: repository"), "{hint}");
        assert!(hint.contains("does not exist"), "{hint}");
        assert!(!hint.contains("再后面的行"), "hint 只放首行：{hint}");
        assert_eq!(
            err.code(),
            "code_failed",
            "真实 git 失败仍是可重试的 code_failed"
        );
    }

    #[test]
    fn long_git_output_is_truncated_in_hint() {
        let err = WorktreeError::Git("x".repeat(HINT_MAX_CHARS + 50));
        let hint = err.hint();
        assert!(hint.ends_with('…'), "超长要截断并给出省略号：{hint}");
        assert!(
            hint.chars().count() <= HINT_MAX_CHARS + "git 报错：".chars().count() + 1,
            "hint 不该原样带出整段输出"
        );
    }
}
