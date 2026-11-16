//! Git 面板的领域层：所有 git 命令都在这里跑。
//!
//! 为什么是 CLI 而不是 libgit2 / gix：仓库本来就要能被用户在终端里用，
//! CLI 保证 hooks、`.gitignore`、`.gitattributes`、`core.autocrlf` 全部与命令行一致；
//! 代价是每次调用一个子进程，所以只做面板需要的读操作，不做全仓扫描。
//!
//! 两条边界：
//! 1. **路径**：客户端只传仓库内相对路径，绝对路径、`..`、`.git` 内部一律拒绝；
//!    文件存在时再按真实路径确认一次没有软链接逃逸。
//! 2. **状态**：merge / rebase / cherry-pick / revert 中间态只读不写，
//!    否则用户会在半截现场上再叠一层，冲突更难收拾。
//!
//! 本模块不碰数据库、不写审计：那是 `api::git` 的事。

use std::path::{Component, Path, PathBuf};
use std::process::{Output, Stdio};
use std::time::Duration;

use protocol::{
    GitCommitResult, GitCommitSummary, GitCommitsPage, GitDiffReport, GitFileChange, GitFileState,
    GitOperation, GitStatusReport, DEFAULT_LOG_LIMIT, MAX_COMMIT_MESSAGE_CHARS, MAX_DIFF_BYTES,
    MAX_GIT_PATHS, MAX_LOG_LIMIT,
};

/// 只读命令的超时。
///
/// 比建项目时的 3 秒宽一点（那个只跑三条 rev-parse），但也不该等太久：
/// 五秒还没出结果的 `git status` 基本就是索引坏了或仓库在慢速磁盘上。
const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// 写命令的超时：`git add` 大仓库、`git commit` 跑 hooks 都可能慢。
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

/// 提交身份兜底。
///
/// 与 `project::initialize_repo` 用同一套值：机器上没配 `user.name` 时，
/// 让提交因为"你是谁"失败，比替用户编一个身份更糟——但也不该冒充用户本人，
/// 所以名字写死成 agent，用户配好自己的身份后自然就换回来了。
const FALLBACK_NAME: &str = "personal-agent";
const FALLBACK_EMAIL: &str = "agent@local";

#[derive(Debug, thiserror::Error)]
pub enum GitError {
    /// 目录不是仓库、路径越界、参数非法：改输入才能继续（映射 `code_project_denied` / `invalid_request`）。
    #[error("{0}")]
    Denied(String),
    /// 状态冲突：中间态、索引锁、没有可提交的内容（映射 `conflict`）。
    #[error("{0}")]
    Blocked(String),
    /// git 本身失败或超时（映射 `code_failed`）。
    #[error("{0}")]
    Failed(String),
}

impl GitError {
    /// 面向用户的处置提示。领域层只给"为什么"，"怎么办"在这里统一。
    pub fn hint(&self) -> String {
        match self {
            Self::Denied(reason) | Self::Blocked(reason) => reason.clone(),
            Self::Failed(reason) => format!("{reason}；请确认服务端已安装 git 且仓库可用"),
        }
    }
}

/// 仓库当前状态。
pub async fn status(root: &Path) -> Result<GitStatusReport, GitError> {
    let root = canonical_root(root)?;

    let Some(toplevel) = repo_toplevel(&root).await? else {
        return Ok(GitStatusReport::not_a_repo(format!(
            "{} 不是 Git 仓库",
            root.display()
        )));
    };

    if toplevel != root {
        return Ok(GitStatusReport::not_a_repo(format!(
            "{} 属于仓库 {}，但本身不是仓库根",
            root.display(),
            toplevel.display()
        )));
    }

    // 空仓库也有分支名：`symbolic-ref` 在 HEAD 还没有提交时就可用。
    // 只用 `rev-parse --abbrev-ref HEAD` 会把"还没提交"和"游离 HEAD"混成一件事。
    let symbolic = run(
        &root,
        &["symbolic-ref", "--short", "-q", "HEAD"],
        READ_TIMEOUT,
        true,
    )
    .await?;
    let branch = if symbolic.status.success() {
        let name = String::from_utf8_lossy(&symbolic.stdout).trim().to_string();
        if name.is_empty() {
            None
        } else {
            Some(name)
        }
    } else {
        None
    };

    let out = run(
        &root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        READ_TIMEOUT,
        true,
    )
    .await?;
    let porcelain = stdout_bytes(out, "status --porcelain")?;
    let (staged, unstaged, untracked) = parse_status(&porcelain);

    let head = head_summary(&root).await?;
    let detached = branch.is_none() && head.is_some();
    let operation = detect_operation(&root).await;

    Ok(GitStatusReport {
        repo: true,
        branch,
        detached,
        head,
        operation,
        reason: None,
        staged,
        unstaged,
        untracked,
    })
}

/// 单个文件或某次提交的 diff。
///
/// 三个来源互斥：`commit` 有值就看某次提交（`path` 可选，为空即整次提交），
/// 否则看工作区（`staged = false`）或暂存区（`staged = true`），此时 `path` 必填。
pub async fn diff(
    root: &Path,
    path: Option<&str>,
    staged: bool,
    commit: Option<&str>,
) -> Result<GitDiffReport, GitError> {
    let root = canonical_root(root)?;
    ensure_repo(&root).await?;

    match commit {
        Some(raw) => {
            let hash = resolve_commit(&root, raw).await?;
            let valid = match path {
                Some(raw) => Some(validate_path(&root, raw)?),
                None => None,
            };
            commit_diff(&root, &hash, valid.as_deref()).await
        }
        None => {
            let raw = path.ok_or_else(|| GitError::Denied("缺少文件路径".to_string()))?;
            let valid = validate_path(&root, raw)?;
            worktree_diff(&root, &valid, staged).await
        }
    }
}

/// 暂存若干文件。
pub async fn stage(root: &Path, paths: &[String]) -> Result<GitStatusReport, GitError> {
    let root = canonical_root(root)?;
    ensure_repo(&root).await?;
    let paths = validate_paths(&root, paths)?;

    let mut args = vec!["add", "--"];
    args.extend(paths.iter().map(String::as_str));
    let out = run(&root, &args, WRITE_TIMEOUT, false).await?;
    stdout_text(out, "add")?;

    status(&root).await
}

/// 取消暂存。
pub async fn unstage(root: &Path, paths: &[String]) -> Result<GitStatusReport, GitError> {
    let root = canonical_root(root)?;
    ensure_repo(&root).await?;
    let paths = validate_paths(&root, paths)?;

    let mut args = vec!["reset", "-q", "HEAD", "--"];
    args.extend(paths.iter().map(String::as_str));
    let out = run(&root, &args, WRITE_TIMEOUT, false).await?;
    if out.status.success() {
        return status(&root).await;
    }

    // 空仓库没有 HEAD，`reset HEAD` 必然失败；此时暂存区里全是新文件，
    // 把它们从索引里摘出去就够了（文件本身不动）。
    if head_missing(&root).await? {
        let mut rm = vec!["rm", "--cached", "-q", "--"];
        rm.extend(paths.iter().map(String::as_str));
        let out = run(&root, &rm, WRITE_TIMEOUT, false).await?;
        stdout_text(out, "rm --cached")?;
        return status(&root).await;
    }

    Err(failure(&out, "reset"))
}

/// 撤销若干已跟踪文件的改动。
///
/// 语义是 `git checkout HEAD -- <path>`：索引与工作区**一起**回到 HEAD，
/// 也就是这个文件已暂存和未暂存的改动都会消失。这一步不可恢复，客户端必须二次确认。
///
/// 只处理 HEAD 里存在的文件：未跟踪文件与已暂存的新文件不在 HEAD 里，
/// 撤销它们等于删除磁盘文件，本轮刻意不做（列表里会标注"新文件不受影响"）。
pub async fn discard(root: &Path, paths: &[String]) -> Result<GitStatusReport, GitError> {
    let root = canonical_root(root)?;
    ensure_repo(&root).await?;
    let paths = validate_paths(&root, paths)?;

    let mut tracked = Vec::new();
    if !head_missing(&root).await? {
        let mut check = vec!["ls-tree", "-z", "--name-only", "HEAD", "--"];
        check.extend(paths.iter().map(String::as_str));
        let out = run(&root, &check, READ_TIMEOUT, true).await?;
        if out.status.success() {
            let listed = String::from_utf8_lossy(&out.stdout).to_string();
            let present: std::collections::HashSet<&str> =
                listed.split('\0').filter(|item| !item.is_empty()).collect();
            tracked = paths
                .iter()
                .filter(|path| present.contains(path.as_str()))
                .cloned()
                .collect();
        }
    }

    if tracked.is_empty() {
        return Err(GitError::Blocked(
            "没有可撤销的改动：选中的都是新文件，撤销不会删除它们".to_string(),
        ));
    }

    let mut args = vec!["checkout", "HEAD", "--"];
    args.extend(tracked.iter().map(String::as_str));
    let out = run(&root, &args, WRITE_TIMEOUT, false).await?;
    if !out.status.success() {
        return Err(failure(&out, "checkout HEAD"));
    }

    status(&root).await
}

/// 提交已暂存的内容。
pub async fn commit(root: &Path, message: &str) -> Result<GitCommitResult, GitError> {
    let root = canonical_root(root)?;
    ensure_repo(&root).await?;

    let message = message.trim();
    if message.is_empty() {
        return Err(GitError::Blocked("提交信息不能为空".to_string()));
    }
    if message.chars().count() > MAX_COMMIT_MESSAGE_CHARS {
        return Err(GitError::Denied(format!(
            "提交信息最多 {MAX_COMMIT_MESSAGE_CHARS} 字"
        )));
    }

    // 中间态的提交要拒绝：用户此时提交，会把"正在合并"变成一条普通提交，
    // 现场反而更难收拾。提示写清在哪一步、去哪做完。
    if let Some(operation) = detect_operation(&root).await {
        return Err(GitError::Blocked(format!(
            "仓库正在 {} 中间状态：请在终端完成后再回来提交",
            operation.label()
        )));
    }

    let before = status(&root).await?;
    if before.staged.is_empty() {
        return Err(GitError::Blocked(
            "没有已暂存的内容：先暂存要提交的文件".to_string(),
        ));
    }

    let mut cmd = base_command(&root, false);
    cmd.args(["commit", "-q", "-m", message]);
    if !has_identity(&root).await? {
        tracing::warn!("仓库没有配置提交身份，本次提交使用 {FALLBACK_NAME} <{FALLBACK_EMAIL}>");
        cmd.env("GIT_AUTHOR_NAME", FALLBACK_NAME)
            .env("GIT_AUTHOR_EMAIL", FALLBACK_EMAIL)
            .env("GIT_COMMITTER_NAME", FALLBACK_NAME)
            .env("GIT_COMMITTER_EMAIL", FALLBACK_EMAIL);
    }
    let out = execute(cmd, "commit -m", WRITE_TIMEOUT).await?;
    stdout_text(out, "commit")?;

    let Some(commit) = head_summary(&root).await? else {
        return Err(GitError::Failed("提交成功但读不到 HEAD".to_string()));
    };

    Ok(GitCommitResult {
        commit,
        status: status(&root).await?,
    })
}

/// 提交历史（新到旧）。
pub async fn history(
    root: &Path,
    limit: Option<u32>,
    skip: Option<u32>,
) -> Result<GitCommitsPage, GitError> {
    let root = canonical_root(root)?;
    ensure_repo(&root).await?;

    let limit = limit.unwrap_or(DEFAULT_LOG_LIMIT).clamp(1, MAX_LOG_LIMIT);
    let skip = skip.unwrap_or(0);

    if head_missing(&root).await? {
        return Ok(GitCommitsPage {
            commits: Vec::new(),
            has_more: false,
        });
    }

    // 多取一条判断"还有更早的"，避免多一次 count 查询。
    let count = (limit + 1).to_string();
    let offset = skip.to_string();
    let out = run(
        &root,
        &[
            "log",
            "--format=%H%x1f%h%x1f%an%x1f%at%x1f%s",
            "-z",
            "-n",
            &count,
            "--skip",
            &offset,
        ],
        READ_TIMEOUT,
        true,
    )
    .await?;
    let raw = stdout_text(out, "log")?;

    let mut commits: Vec<GitCommitSummary> =
        raw.split('\0').filter_map(parse_commit_record).collect();
    let has_more = commits.len() > limit as usize;
    commits.truncate(limit as usize);

    Ok(GitCommitsPage { commits, has_more })
}

// ---------------------------------------------------------------------------
// 子进程
// ---------------------------------------------------------------------------

fn base_command(dir: &Path, read: bool) -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("git");
    cmd.current_dir(dir)
        // 永不挂 pager、永不着色：输出要按行解析，颜色转义会污染 diff。
        .arg("-c")
        .arg("core.pager=cat")
        .arg("-c")
        .arg("color.ui=false")
        // 中文路径不转义成 `\346\226\207`，解析与展示都省一层。
        .arg("-c")
        .arg("core.quotepath=false")
        // 任何情况下都不要向用户索要凭据：本轮不做远程操作，卡在密码提示上等于挂死。
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .stdin(Stdio::null())
        .kill_on_drop(true);

    if read {
        // 只读命令不刷新索引锁：面板打开时轮不到它去写 `.git/index`。
        cmd.env("GIT_OPTIONAL_LOCKS", "0");
    }

    cmd
}

async fn execute(
    mut cmd: tokio::process::Command,
    label: &str,
    timeout: Duration,
) -> Result<Output, GitError> {
    match tokio::time::timeout(timeout, cmd.output()).await {
        Err(_) => Err(GitError::Failed(format!(
            "git {label} 超过 {} 秒没有响应",
            timeout.as_secs()
        ))),
        Ok(Err(err)) => Err(GitError::Failed(format!(
            "无法执行 git（{err}）：请确认服务端已安装 git 并在 PATH 里"
        ))),
        Ok(Ok(output)) => Ok(output),
    }
}

async fn run(dir: &Path, args: &[&str], timeout: Duration, read: bool) -> Result<Output, GitError> {
    let mut cmd = base_command(dir, read);
    cmd.args(args);
    execute(cmd, &args.join(" "), timeout).await
}

fn failure(out: &Output, label: &str) -> GitError {
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();

    // 索引锁是并发写操作的唯一"排队"信号：不编译成用户看不懂的英文。
    if stderr.contains("index.lock") {
        return GitError::Blocked("另一个 git 操作正在进行（index.lock）：请稍后重试".to_string());
    }
    if stderr.contains("Please tell me who you are") || stderr.contains("unable to auto-detect") {
        return GitError::Blocked(
            "服务端没有配置 git 提交身份：请执行 git config user.name 与 user.email".to_string(),
        );
    }

    if stderr.is_empty() {
        GitError::Failed(format!("git {label} 退出码 {:?}", out.status.code()))
    } else {
        GitError::Failed(stderr)
    }
}

fn stdout_text(out: Output, label: &str) -> Result<String, GitError> {
    if !out.status.success() {
        return Err(failure(&out, label));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

fn stdout_bytes(out: Output, label: &str) -> Result<Vec<u8>, GitError> {
    if !out.status.success() {
        return Err(failure(&out, label));
    }
    Ok(out.stdout)
}

// ---------------------------------------------------------------------------
// 仓库探测
// ---------------------------------------------------------------------------

fn canonical_root(root: &Path) -> Result<PathBuf, GitError> {
    std::fs::canonicalize(root).map_err(|err| GitError::Denied(format!("项目目录不可用：{err}")))
}

/// 目录所属仓库根；不是仓库时返回 `None`（不是错误）。
async fn repo_toplevel(dir: &Path) -> Result<Option<PathBuf>, GitError> {
    let out = run(dir, &["rev-parse", "--show-toplevel"], READ_TIMEOUT, true).await?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        if stderr.contains("not a git repository") || stderr.contains("not a git dir") {
            return Ok(None);
        }
        // git 没装、目录被删这类：与"不是仓库"不是一回事，要如实报出去。
        return Err(failure(&out, "rev-parse --show-toplevel"));
    }

    let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok(Some(
        std::fs::canonicalize(&raw).unwrap_or_else(|_| PathBuf::from(raw)),
    ))
}

/// 写操作入口的闸：必须是仓库根，否则命令会跑去改父仓库。
async fn ensure_repo(root: &Path) -> Result<(), GitError> {
    match repo_toplevel(root).await? {
        None => Err(GitError::Denied("该项目目录不是 Git 仓库".to_string())),
        Some(toplevel) if toplevel != root => Err(GitError::Denied(format!(
            "项目目录属于仓库 {}，本身不是仓库根",
            toplevel.display()
        ))),
        Some(_) => Ok(()),
    }
}

async fn head_missing(dir: &Path) -> Result<bool, GitError> {
    let out = run(
        dir,
        &["rev-parse", "--verify", "--quiet", "HEAD"],
        READ_TIMEOUT,
        true,
    )
    .await?;
    Ok(!out.status.success())
}

async fn has_identity(dir: &Path) -> Result<bool, GitError> {
    let out = run(dir, &["var", "GIT_AUTHOR_IDENT"], READ_TIMEOUT, true).await?;
    Ok(out.status.success() && !out.stdout.is_empty())
}

async fn head_summary(dir: &Path) -> Result<Option<GitCommitSummary>, GitError> {
    let out = run(
        dir,
        &["log", "-1", "--format=%H%x1f%h%x1f%an%x1f%at%x1f%s"],
        READ_TIMEOUT,
        true,
    )
    .await?;
    // 空仓库的 `git log` 是失败：这里不是错误，只是"还没有提交"。
    if !out.status.success() {
        return Ok(None);
    }
    Ok(parse_commit_record(&String::from_utf8_lossy(&out.stdout)))
}

/// `.git` 目录下有没有多步操作的标记文件。
async fn detect_operation(dir: &Path) -> Option<GitOperation> {
    let out = run(
        dir,
        &["rev-parse", "--absolute-git-dir"],
        READ_TIMEOUT,
        true,
    )
    .await
    .ok()?;
    if !out.status.success() {
        return None;
    }
    let git_dir = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim().to_string());

    // rebase 最优先：rebase 过程中也会写 MERGE_HEAD，先判断它才不会误报成 merge。
    if git_dir.join("rebase-merge").exists() || git_dir.join("rebase-apply").exists() {
        return Some(GitOperation::Rebase);
    }
    if git_dir.join("MERGE_HEAD").exists() {
        return Some(GitOperation::Merge);
    }
    if git_dir.join("CHERRY_PICK_HEAD").exists() {
        return Some(GitOperation::CherryPick);
    }
    if git_dir.join("REVERT_HEAD").exists() {
        return Some(GitOperation::Revert);
    }
    None
}

async fn is_untracked(dir: &Path, path: &str) -> Result<bool, GitError> {
    let out = run(
        dir,
        &["ls-files", "--error-unmatch", "--", path],
        READ_TIMEOUT,
        true,
    )
    .await?;
    // 子目录里也可能有未跟踪文件，`--error-unmatch` 精确到路径，不会误判。
    Ok(!out.status.success())
}

async fn resolve_commit(dir: &Path, raw: &str) -> Result<String, GitError> {
    let raw = raw.trim();
    if raw.len() < 4 || raw.len() > 40 || !raw.chars().all(|item| item.is_ascii_hexdigit()) {
        return Err(GitError::Denied("提交标识不合法".to_string()));
    }

    // 先限死成十六进制再交给 rev-parse：revspec 能触发 `@{...}`、`--upload-pack` 这类花样。
    let spec = format!("{raw}^{{commit}}");
    let out = run(
        dir,
        &["rev-parse", "--verify", "--quiet", &spec],
        READ_TIMEOUT,
        true,
    )
    .await?;
    if !out.status.success() {
        return Err(GitError::Denied(format!("提交 {raw} 不存在")));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

// ---------------------------------------------------------------------------
// diff
// ---------------------------------------------------------------------------

async fn worktree_diff(root: &Path, path: &str, staged: bool) -> Result<GitDiffReport, GitError> {
    // 未跟踪文件不在索引里，`git diff` 对它们一片空白；整文件都是新增，
    // 这里自己拼一份，否则"看新文件改了什么"这个最常见的动作会没有输出。
    if !staged && is_untracked(root, path).await? {
        return untracked_diff(root, path).await;
    }

    let mut numstat = vec!["diff", "--no-color", "--numstat"];
    if staged {
        numstat.push("--cached");
    }
    numstat.extend(["--", path]);
    let out = run(root, &numstat, READ_TIMEOUT, true).await?;
    let (additions, deletions, binary) = parse_numstat(&stdout_text(out, "diff --numstat")?);

    if binary {
        return Ok(GitDiffReport {
            path: Some(path.to_string()),
            staged,
            commit: None,
            text: String::new(),
            truncated: false,
            binary: true,
            additions: 0,
            deletions: 0,
        });
    }

    let mut patch = vec!["diff", "--no-color", "--no-ext-diff"];
    if staged {
        patch.push("--cached");
    }
    patch.extend(["--", path]);
    let out = run(root, &patch, READ_TIMEOUT, true).await?;
    let raw = stdout_text(out, "diff")?;
    let (text, truncated) = truncate_text(raw);

    Ok(GitDiffReport {
        path: Some(path.to_string()),
        staged,
        commit: None,
        text,
        truncated,
        binary: false,
        additions,
        deletions,
    })
}

async fn commit_diff(
    root: &Path,
    hash: &str,
    path: Option<&str>,
) -> Result<GitDiffReport, GitError> {
    let mut numstat = vec!["show", "--no-color", "--numstat", "--format=", hash];
    if let Some(path) = path {
        numstat.extend(["--", path]);
    }
    let out = run(root, &numstat, READ_TIMEOUT, true).await?;
    let (additions, deletions, binary) = parse_numstat(&stdout_text(out, "show --numstat")?);

    if binary {
        return Ok(GitDiffReport {
            path: path.map(str::to_string),
            staged: false,
            commit: Some(hash.to_string()),
            text: String::new(),
            truncated: false,
            binary: true,
            additions: 0,
            deletions: 0,
        });
    }

    let mut patch = vec!["show", "--no-color", "--no-ext-diff", "--format=", hash];
    if let Some(path) = path {
        patch.extend(["--", path]);
    }
    let out = run(root, &patch, READ_TIMEOUT, true).await?;
    let raw = stdout_text(out, "show")?;
    let (text, truncated) = truncate_text(raw);

    Ok(GitDiffReport {
        path: path.map(str::to_string),
        staged: false,
        commit: Some(hash.to_string()),
        text,
        truncated,
        binary: false,
        additions,
        deletions,
    })
}

/// 未跟踪文件：整份内容按新增行渲染。
async fn untracked_diff(root: &Path, path: &str) -> Result<GitDiffReport, GitError> {
    use tokio::io::AsyncReadExt;

    let full = root.join(path);
    let file = tokio::fs::File::open(&full)
        .await
        .map_err(|err| GitError::Denied(format!("{path} 打不开：{err}")))?;

    // 只读到上限为止：新文件可能是几个 G 的日志，不能整份塞进内存。
    let mut buffer = Vec::new();
    file.take(MAX_DIFF_BYTES as u64 + 1)
        .read_to_end(&mut buffer)
        .await
        .map_err(|err| GitError::Denied(format!("{path} 读取失败：{err}")))?;

    if buffer.iter().any(|byte| *byte == 0) {
        return Ok(GitDiffReport {
            path: Some(path.to_string()),
            staged: false,
            commit: None,
            text: String::new(),
            truncated: false,
            binary: true,
            additions: 0,
            deletions: 0,
        });
    }

    let (body, truncated) = truncate_text(String::from_utf8_lossy(&buffer).to_string());
    let line_count = body.lines().count();
    let mut text = String::with_capacity(body.len() + 64);
    text.push_str(&format!("@@ -0,0 +1,{line_count} @@\n"));
    for line in body.lines() {
        text.push('+');
        text.push_str(line);
        text.push('\n');
    }

    Ok(GitDiffReport {
        path: Some(path.to_string()),
        staged: false,
        commit: None,
        text,
        truncated,
        binary: false,
        additions: line_count as u64,
        deletions: 0,
    })
}

/// `--numstat` 的一行：`增\t删\t路径`，二进制文件是 `-\t-\t路径`。
fn parse_numstat(raw: &str) -> (u64, u64, bool) {
    let mut additions = 0;
    let mut deletions = 0;
    let mut binary = false;

    for line in raw.lines() {
        let mut parts = line.split('\t');
        let added = parts.next().unwrap_or("");
        let removed = parts.next().unwrap_or("");
        if added == "-" || removed == "-" {
            binary = true;
            continue;
        }
        additions += added.parse::<u64>().unwrap_or(0);
        deletions += removed.parse::<u64>().unwrap_or(0);
    }

    (additions, deletions, binary)
}

fn truncate_text(text: String) -> (String, bool) {
    if text.len() <= MAX_DIFF_BYTES {
        return (text, false);
    }
    let mut cut = MAX_DIFF_BYTES;
    while cut > 0 && !text.is_char_boundary(cut) {
        cut -= 1;
    }
    (text[..cut].to_string(), true)
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

/// 解析 `git status --porcelain=v1 -z`。
///
/// 返回（已暂存、未暂存、未跟踪）。同一个文件可以同时出现在前两组：
/// 暂存后又改了一笔，git 就是会报两条。
fn parse_status(raw: &[u8]) -> (Vec<GitFileChange>, Vec<GitFileChange>, Vec<GitFileChange>) {
    let mut staged = Vec::new();
    let mut unstaged = Vec::new();
    let mut untracked = Vec::new();

    let mut parts = raw.split(|byte| *byte == 0);
    while let Some(entry) = parts.next() {
        // 最短也要 "XY p"：两个状态字母 + 空格 + 至少一个字节的路径。
        if entry.len() < 4 {
            continue;
        }
        let x = entry[0] as char;
        let y = entry[1] as char;
        let path = String::from_utf8_lossy(&entry[3..]).to_string();
        if path.is_empty() {
            continue;
        }

        // 重命名 / 复制在 `-z` 下把源路径放在后一个 NUL 分隔段里。
        let mut orig_path = None;
        if matches!(x, 'R' | 'C') || matches!(y, 'R' | 'C') {
            if let Some(next) = parts.next() {
                let source = String::from_utf8_lossy(next).to_string();
                if !source.is_empty() {
                    orig_path = Some(source);
                }
            }
        }

        if x == '?' && y == '?' {
            untracked.push(GitFileChange {
                path,
                orig_path: None,
                state: GitFileState::Untracked,
            });
            continue;
        }
        // `!!` 是被忽略的文件：没让它报，出现了也当可见性之外的东西直接跳过。
        if x == '!' {
            continue;
        }

        if is_unmerged_pair(x, y) {
            unstaged.push(GitFileChange {
                path,
                orig_path,
                state: GitFileState::Unmerged,
            });
            continue;
        }

        if x != ' ' {
            staged.push(GitFileChange {
                path: path.clone(),
                orig_path: orig_path.clone(),
                state: state_of(x),
            });
        }
        if y != ' ' {
            unstaged.push(GitFileChange {
                path,
                orig_path,
                state: state_of(y),
            });
        }
    }

    (staged, unstaged, untracked)
}

/// 冲突的七个组合，加两个含 `U` 的单边。
fn is_unmerged_pair(x: char, y: char) -> bool {
    if x == 'U' || y == 'U' {
        return true;
    }
    matches!((x, y), ('A', 'A') | ('D', 'D'))
}

fn state_of(letter: char) -> GitFileState {
    match letter {
        'A' => GitFileState::Added,
        'D' => GitFileState::Deleted,
        'R' => GitFileState::Renamed,
        'C' => GitFileState::Copied,
        'T' => GitFileState::TypeChanged,
        'U' => GitFileState::Unmerged,
        _ => GitFileState::Modified,
    }
}

/// 解析 `%H\x1f%h\x1f%an\x1f%at\x1f%s`。
fn parse_commit_record(raw: &str) -> Option<GitCommitSummary> {
    let raw = raw.trim_start_matches(['\n', '\0']);
    if raw.is_empty() {
        return None;
    }

    let mut parts = raw.split('\u{1f}');
    let hash = parts.next()?.trim().to_string();
    let short_hash = parts.next().unwrap_or("").trim().to_string();
    let author = parts.next().unwrap_or("").to_string();
    let seconds = parts
        .next()
        .unwrap_or("0")
        .trim()
        .parse::<i64>()
        .unwrap_or(0);
    let subject = parts.next().unwrap_or("").trim_end().to_string();

    if hash.is_empty() {
        return None;
    }

    Some(GitCommitSummary {
        hash,
        short_hash,
        subject,
        author,
        time_ms: seconds.saturating_mul(1000),
    })
}

// ---------------------------------------------------------------------------
// 路径
// ---------------------------------------------------------------------------

fn validate_paths(root: &Path, paths: &[String]) -> Result<Vec<String>, GitError> {
    if paths.is_empty() {
        return Err(GitError::Denied("至少选一个文件".to_string()));
    }
    if paths.len() > MAX_GIT_PATHS {
        return Err(GitError::Denied(format!(
            "一次最多操作 {MAX_GIT_PATHS} 个文件"
        )));
    }

    let mut seen = std::collections::HashSet::new();
    let mut valid = Vec::with_capacity(paths.len());
    for raw in paths {
        let path = validate_path(root, raw)?;
        if seen.insert(path.clone()) {
            valid.push(path);
        }
    }
    Ok(valid)
}

/// 把客户端给的路径收敛成"仓库内相对路径"。
///
/// 拒绝绝对路径、`..`、盘符与 `.git` 内部：这些都会让 `git add` 跳出工作区。
/// 文件存在时再按真实路径确认一次，挡住"仓库里有个指向外面的软链接"。
fn validate_path(root: &Path, raw: &str) -> Result<String, GitError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(GitError::Denied("缺少文件路径".to_string()));
    }
    if raw.len() > 4096 {
        return Err(GitError::Denied("文件路径过长".to_string()));
    }

    let candidate = Path::new(raw);
    if candidate.is_absolute() {
        return Err(GitError::Denied("只接受仓库内的相对路径".to_string()));
    }

    let mut clean = PathBuf::new();
    for component in candidate.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => {
                let part = part.to_string_lossy();
                if part.eq_ignore_ascii_case(".git") {
                    return Err(GitError::Denied("不能操作 .git 内部路径".to_string()));
                }
                clean.push(part.as_ref());
            }
            // `..`、根、盘符：一律拒绝，不给"先拼再校验"留缝。
            _ => return Err(GitError::Denied("路径不能包含 .. 或盘符".to_string())),
        }
    }

    if clean.as_os_str().is_empty() {
        return Err(GitError::Denied("缺少文件路径".to_string()));
    }

    let joined = root.join(&clean);
    if let Ok(real) = std::fs::canonicalize(&joined) {
        if !real.starts_with(root) {
            return Err(GitError::Denied(format!(
                "{} 指向仓库外的位置",
                clean.display()
            )));
        }
    }

    // git 认 `/` 分隔：Windows 上传进来的反斜杠在这里统一掉。
    Ok(clean.to_string_lossy().replace('\\', "/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_modified_both_sides() {
        let raw = b"MM src/main.rs\0";
        let (staged, unstaged, untracked) = parse_status(raw);
        assert_eq!(staged.len(), 1);
        assert_eq!(unstaged.len(), 1);
        assert!(untracked.is_empty());
        assert_eq!(staged[0].path, "src/main.rs");
        assert_eq!(staged[0].state, GitFileState::Modified);
        assert_eq!(unstaged[0].state, GitFileState::Modified);
    }

    #[test]
    fn parses_untracked_and_ignored() {
        let raw = b"?? notes.txt\0!! target/\0";
        let (staged, unstaged, untracked) = parse_status(raw);
        assert!(staged.is_empty());
        assert!(unstaged.is_empty());
        assert_eq!(untracked.len(), 1);
        assert_eq!(untracked[0].state, GitFileState::Untracked);
    }

    #[test]
    fn parses_rename_with_source() {
        let raw = b"R  src/new.rs\0src/old.rs\0";
        let (staged, _, _) = parse_status(raw);
        assert_eq!(staged.len(), 1);
        assert_eq!(staged[0].path, "src/new.rs");
        assert_eq!(staged[0].orig_path.as_deref(), Some("src/old.rs"));
        assert_eq!(staged[0].state, GitFileState::Renamed);
    }

    #[test]
    fn parses_conflict_as_unmerged() {
        let raw = b"UU src/main.rs\0";
        let (staged, unstaged, _) = parse_status(raw);
        assert!(staged.is_empty(), "冲突不进已暂存组");
        assert_eq!(unstaged.len(), 1);
        assert_eq!(unstaged[0].state, GitFileState::Unmerged);
    }

    #[test]
    fn parses_deleted_in_index() {
        let raw = b"D  gone.rs\0";
        let (staged, unstaged, _) = parse_status(raw);
        assert_eq!(staged[0].state, GitFileState::Deleted);
        assert!(unstaged.is_empty());
    }

    #[test]
    fn numstat_sums_lines() {
        let (added, removed, binary) = parse_numstat("3\t1\tsrc/a.rs\n10\t0\tsrc/b.rs\n");
        assert_eq!(added, 13);
        assert_eq!(removed, 1);
        assert!(!binary);
    }

    #[test]
    fn numstat_flags_binary() {
        let (_, _, binary) = parse_numstat("-\t-\tlogo.png\n");
        assert!(binary);
    }

    #[test]
    fn truncate_keeps_char_boundary() {
        let text = "中".repeat(10);
        let (cut, truncated) = truncate_text(format!("{text}{}", "x".repeat(MAX_DIFF_BYTES)));
        assert!(truncated);
        assert!(cut.len() <= MAX_DIFF_BYTES);
        assert!(std::str::from_utf8(cut.as_bytes()).is_ok());
    }

    #[test]
    fn commit_record_parses_fields() {
        let record = "abc123\u{1f}abc\u{1f}张三\u{1f}1700000000\u{1f}feat: 面板\n";
        let commit = parse_commit_record(record).expect("应能解析");
        assert_eq!(commit.hash, "abc123");
        assert_eq!(commit.short_hash, "abc");
        assert_eq!(commit.author, "张三");
        assert_eq!(commit.time_ms, 1_700_000_000_000);
        assert_eq!(commit.subject, "feat: 面板");
    }

    #[test]
    fn commit_record_rejects_empty() {
        assert!(parse_commit_record("").is_none());
        assert!(parse_commit_record("\0\n").is_none());
    }

    #[test]
    fn rejects_dotdot_absolute_and_git_internal() {
        let root = std::env::temp_dir();
        for raw in ["../etc/passwd", "/etc/passwd", ".git/config", "a/../../b"] {
            assert!(validate_path(&root, raw).is_err(), "{raw} 应该被拒绝");
        }
    }

    #[test]
    fn accepts_relative_path_and_normalizes_separator() {
        let root = std::env::temp_dir();
        assert_eq!(
            validate_path(&root, "./src/main.rs").expect("应通过"),
            "src/main.rs"
        );
        assert_eq!(
            validate_path(&root, "src\\main.rs").expect("应通过"),
            "src/main.rs"
        );
    }

    #[test]
    fn rejects_empty_paths_request() {
        let root = std::env::temp_dir();
        assert!(validate_paths(&root, &[]).is_err());
    }

    #[test]
    fn dedupes_repeated_paths() {
        let root = std::env::temp_dir();
        let paths = vec!["a.rs".to_string(), "a.rs".to_string(), "b.rs".to_string()];
        let valid = validate_paths(&root, &paths).expect("应通过");
        assert_eq!(valid, vec!["a.rs", "b.rs"]);
    }
}
