//! 项目：会话与任务的归属，绑定服务端这台电脑上的一个真实目录。
//!
//! 两条边界都在这里把关，handler 只做参数解析与错误映射：
//!
//! 1. **目录边界**：路径必须落在该模式允许的根目录内（WORK 走 `project.browse_roots`，
//!    CODE 走 `code.allow_roots`）。项目会挂到真实目录上，默认放开等于把整个磁盘暴露给客户端。
//! 2. **模式边界**：Git 项目的目录必须是 git 仓库根且能建分支，因为只有它允许编码任务；
//!    普通项目不做任何 git 检查——生活与办公事务根本不需要仓库。
//!
//! 删除一律软删（`deleted_at`），与 `conversations` / `tasks` 的既有约定保持一致。

use std::path::{Path, PathBuf};
use std::time::Duration;

use protocol::{GitState, Project, ProjectCreate, ProjectMode, ProjectPreflight};
use sqlx::SqlitePool;

use crate::clock::now_ms;
use crate::config::Config;
use crate::ids::new_id;

/// 最多能有多少个活动项目。个人量级足够，同时挡住"脚本刷爆列表"。
pub const MAX_PROJECTS: i64 = 200;

/// 项目名字长度上限（字符数）。
const MAX_NAME_CHARS: usize = 60;

/// git 命令超时。创建时只跑三条只读命令，3 秒足够；卡住说明仓库有问题，不该拖住接口。
const GIT_TIMEOUT: Duration = Duration::from_secs(3);

/// 升级时自动创建的项目名字。
pub const DEFAULT_PROJECT_NAME: &str = "默认项目";

#[derive(Debug, thiserror::Error)]
pub enum ProjectError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
    #[error("项目不存在")]
    NotFound,
    /// 状态冲突。携带的是**可直接展示的中文提示**（含改法）。
    #[error("状态冲突: {0}")]
    Conflict(String),
    /// 参数非法。同样携带可直接展示的提示。
    #[error("参数非法: {0}")]
    Invalid(String),
    /// 目录不被允许（越界、不可访问、不是仓库…）。映射为 `code_project_denied`。
    #[error("目录不可用: {0}")]
    Denied(String),
}

/// 该模式下允许浏览与创建项目的根目录。
///
/// CODE 未配置 `code.allow_roots` 时直接报错：没有白名单就没有任何目录是合法的，
/// 让它"建得出来但派不了任务"比直接拒绝更糟。
pub fn roots_for(config: &Config, mode: ProjectMode) -> Result<Vec<PathBuf>, ProjectError> {
    if mode.allows_code_tasks() && config.code.allow_roots.is_empty() {
        return Err(ProjectError::Denied(
            "Git 项目需要先在服务端配置 code.allow_roots（并打开 code.enabled）：\
             编码任务会改真实文件，不允许默认放开"
                .to_string(),
        ));
    }

    let roots = config.project_roots_for(mode);
    if roots.is_empty() {
        return Err(ProjectError::Denied(
            "服务端没有可浏览的目录：请检查 project.browse_roots 配置".to_string(),
        ));
    }
    Ok(roots)
}

/// 新建项目。所有校验都在这里完成（目录、模式、git、名称、上限、唯一性）。
pub async fn create(
    pool: &SqlitePool,
    config: &Config,
    request: &ProjectCreate,
) -> Result<Project, ProjectError> {
    let path = resolve_dir(config, request.mode, &request.path)?;

    if request.mode.allows_code_tasks() {
        let inspection = inspect_git(&path).await?;
        if inspection.state != GitState::Ready {
            // 只有"客户端明确要求初始化"且"确实能修好"才动手；
            // 游离 HEAD 这类问题 init 修不了，硬做只会把现场变得更难解释。
            if !request.init_git || !inspection.state.fixable_by_init() {
                return Err(ProjectError::Denied(inspection.reason.unwrap_or_else(
                    || format!("{} 不能作为 Git 项目", path.display()),
                )));
            }
            initialize_repo(&path, inspection.state).await?;
        }
    }

    let name = normalize_name(request.name.as_deref(), &path)?;
    let path_text = path.to_string_lossy().to_string();

    let active: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM projects WHERE deleted_at IS NULL")
        .fetch_one(pool)
        .await?;
    if active >= MAX_PROJECTS {
        return Err(ProjectError::Conflict(format!(
            "项目数量已达上限（{MAX_PROJECTS} 个）：请先删除不再使用的项目"
        )));
    }

    // 先查一次给出可读提示；并发下仍可能撞唯一索引，插入失败时再查一次兜底。
    if let Some(existing) = find_active_by_path(pool, &path_text).await? {
        return Err(duplicate_path(existing));
    }

    let id = new_id("ws");
    let now = now_ms();
    let insert = sqlx::query(
        "INSERT INTO projects (id, name, mode, path, created_at, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(&id)
    .bind(&name)
    .bind(request.mode.as_str())
    .bind(&path_text)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await;

    if let Err(err) = insert {
        if let Some(existing) = find_active_by_path(pool, &path_text).await? {
            return Err(duplicate_path(existing));
        }
        return Err(err.into());
    }

    tracing::info!(
        project_id = %id,
        mode = request.mode.as_str(),
        path = %path_text,
        "项目已创建"
    );

    get(pool, &id).await?.ok_or(ProjectError::NotFound)
}

/// 列出活动项目。`mode` 为 `None` 时返回全部项目（界面已不再区分模式）。
///
/// 个人量级不分页，上限 [`MAX_PROJECTS`]；两种口径都按 `updated_at DESC, id DESC`
/// 排序，调用方不需要再排一次。
pub async fn list(
    pool: &SqlitePool,
    mode: Option<ProjectMode>,
) -> Result<Vec<Project>, ProjectError> {
    let rows = match mode {
        Some(mode) => {
            sqlx::query_as::<_, ProjectRow>(SQL_LIST_BY_MODE)
                .bind(mode.as_str())
                .bind(MAX_PROJECTS)
                .fetch_all(pool)
                .await?
        }
        None => {
            sqlx::query_as::<_, ProjectRow>(SQL_LIST_ALL)
                .bind(MAX_PROJECTS)
                .fetch_all(pool)
                .await?
        }
    };

    Ok(rows.into_iter().map(project_from_row).collect())
}

pub async fn get(pool: &SqlitePool, id: &str) -> Result<Option<Project>, ProjectError> {
    let row = sqlx::query_as::<_, ProjectRow>(SQL_GET)
        .bind(id)
        .fetch_optional(pool)
        .await?;

    Ok(row.map(project_from_row))
}

/// 取项目模式。任务与会话的能力边界都以它为准，**不接受客户端传模式**。
pub async fn mode_of(pool: &SqlitePool, id: &str) -> Result<Option<ProjectMode>, ProjectError> {
    let raw: Option<String> =
        sqlx::query_scalar("SELECT mode FROM projects WHERE id = ? AND deleted_at IS NULL")
            .bind(id)
            .fetch_optional(pool)
            .await?;

    Ok(raw.as_deref().and_then(ProjectMode::parse))
}

/// 重命名。模式与目录一经创建不可变——改目录等于换一个项目，历史与产物都会失去意义。
pub async fn rename(pool: &SqlitePool, id: &str, name: &str) -> Result<Project, ProjectError> {
    let name = validate_name(name)?;
    let affected = sqlx::query(
        "UPDATE projects SET name = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
    )
    .bind(&name)
    .bind(now_ms())
    .bind(id)
    .execute(pool)
    .await?
    .rows_affected();

    if affected == 0 {
        return Err(ProjectError::NotFound);
    }

    get(pool, id).await?.ok_or(ProjectError::NotFound)
}

/// 逻辑删除项目。
///
/// 只写 `deleted_at`：其下会话、任务、消息、产物全部保留，只是不再从列表里露出。
/// 下仍有**未结束**任务时拒绝——worker 可能正在向它上报事件，删掉会让状态机悬空。
///
/// 检查与写入必须在同一个 `BEGIN IMMEDIATE` 事务里：分开做会出现"检查时都结束了、
/// 写入前又冒出一个 running"的窗口。
pub async fn delete(pool: &SqlitePool, id: &str) -> Result<(), ProjectError> {
    let now = now_ms();
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;

    let exists: Option<String> =
        sqlx::query_scalar("SELECT id FROM projects WHERE id = ? AND deleted_at IS NULL")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
    if exists.is_none() {
        return Err(ProjectError::NotFound);
    }

    let unfinished: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM tasks t JOIN conversations c ON c.id = t.conversation_id \
         WHERE c.project_id = ? AND t.deleted_at IS NULL \
           AND t.state IN ('queued', 'running', 'needs_input', 'needs_approval')",
    )
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;
    if unfinished > 0 {
        return Err(ProjectError::Conflict(
            "项目下还有未结束的任务，请先取消或等它结束再删项目".to_string(),
        ));
    }

    sqlx::query("UPDATE projects SET deleted_at = ?, updated_at = ? WHERE id = ?")
        .bind(now)
        .bind(now)
        .bind(id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(())
}

/// 升级兜底：把还没有归属的历史会话挂到一个「默认项目」上。
///
/// 只在存在 `project_id IS NULL` 的会话时才动手，因此天然幂等：
/// 用户日后删光所有项目也不会被反复重建。
///
/// 没放在 SQL 迁移里，是因为迁移脚本拿不到数据目录的绝对路径（配置决定），
/// 而默认目录必须建在真实可写的位置上。
pub async fn ensure_default(
    pool: &SqlitePool,
    config: &Config,
) -> Result<Option<Project>, ProjectError> {
    let orphans: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM conversations WHERE project_id IS NULL")
            .fetch_one(pool)
            .await?;
    if orphans == 0 {
        return Ok(None);
    }

    let dir = config.project_documents_dir();
    std::fs::create_dir_all(&dir).map_err(|err| {
        ProjectError::Denied(format!(
            "创建默认项目目录失败（{}）：{err}；请检查数据目录权限",
            dir.display()
        ))
    })?;
    let canonical = std::fs::canonicalize(&dir).map_err(|err| {
        ProjectError::Denied(format!("默认项目目录不可访问（{}）：{err}", dir.display()))
    })?;
    let path_text = canonical.to_string_lossy().to_string();

    // 同路径的活动项目可能已经存在（用户手工建过）：复用，不重复插一行。
    let id = match find_active_by_path(pool, &path_text).await? {
        Some(id) => id,
        None => {
            let id = new_id("ws");
            let now = now_ms();
            sqlx::query(
                "INSERT INTO projects (id, name, mode, path, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(DEFAULT_PROJECT_NAME)
            .bind(ProjectMode::Work.as_str())
            .bind(&path_text)
            .bind(now)
            .bind(now)
            .execute(pool)
            .await?;
            id
        }
    };

    let moved = sqlx::query("UPDATE conversations SET project_id = ? WHERE project_id IS NULL")
        .bind(&id)
        .execute(pool)
        .await?
        .rows_affected();

    tracing::info!(
        project_id = %id,
        conversations = moved,
        path = %path_text,
        "历史会话已归入默认项目"
    );

    get(pool, &id).await
}

/// 把客户端传来的路径落成真实目录，并校验它在该模式允许的范围内。
fn resolve_dir(config: &Config, mode: ProjectMode, raw: &str) -> Result<PathBuf, ProjectError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(ProjectError::Invalid(
            "缺少目录路径：请在服务端选一个目录".to_string(),
        ));
    }

    let candidate = PathBuf::from(raw);
    if !candidate.is_absolute() {
        return Err(ProjectError::Invalid(format!(
            "目录路径必须是绝对路径（当前是 \"{raw}\"）；例如 /Users/you/Documents"
        )));
    }

    let path = candidate.canonicalize().map_err(|err| {
        ProjectError::Denied(format!(
            "目录不可访问（{}）：{err}；请确认目录存在且服务进程有权限读取",
            candidate.display()
        ))
    })?;
    if !path.is_dir() {
        return Err(ProjectError::Denied(format!(
            "{} 不是目录；项目只能绑定目录",
            path.display()
        )));
    }

    let roots = roots_for(config, mode)?;
    if !roots.iter().any(|root| path.starts_with(root)) {
        return Err(ProjectError::Denied(format!(
            "{} 不在允许的目录范围内（{}）；请在允许范围内选择，或把它加进服务端配置",
            path.display(),
            roots
                .iter()
                .map(|root| root.display().to_string())
                .collect::<Vec<_>>()
                .join(" / ")
        )));
    }

    Ok(path)
}

/// 预检：目录是否就能建成 Git 项目；不能的话，卡在哪一步、能不能现场修好。
///
/// 与 [`create`] 共用同一套检查（[`resolve_dir`] + [`inspect_git`]），
/// 不会出现"预检说行、创建说不行"的两套判定。
pub async fn preflight(
    config: &Config,
    mode: ProjectMode,
    raw_path: &str,
) -> Result<ProjectPreflight, ProjectError> {
    let path = resolve_dir(config, mode, raw_path)?;
    let path_text = path.to_string_lossy().to_string();

    if !mode.allows_code_tasks() {
        // 普通模式与 git 无关：不需要预检，也不该显示任何"仓库"字样。
        return Ok(ProjectPreflight {
            path: path_text,
            mode,
            ready: true,
            git: GitState::NotApplicable,
            git_detail: None,
            can_init: false,
            reason: None,
        });
    }

    let inspection = inspect_git(&path).await?;
    Ok(ProjectPreflight {
        path: path_text,
        mode,
        ready: inspection.state == GitState::Ready,
        can_init: inspection.state.fixable_by_init(),
        git: inspection.state,
        git_detail: inspection.detail,
        reason: inspection.reason,
    })
}

/// 一次 git 体检的结果。
struct GitInspection {
    state: GitState,
    /// `nested` 时是所属仓库路径，`ready` 时是当前分支。
    detail: Option<String>,
    /// 不可用时给用户看的原因与改法（`ready` 时为空）。
    reason: Option<String>,
}

/// Git 项目的 git 前置条件：仓库根、有提交、非游离 HEAD。
///
/// 返回状态而不是直接报错：`missing` / `nested` / `no_commits` 三种都能靠一次初始化修好，
/// 客户端据此决定要不要弹"要不要初始化"的确认框。
async fn inspect_git(path: &Path) -> Result<GitInspection, ProjectError> {
    let toplevel = match git(path, &["rev-parse", "--show-toplevel"]).await {
        Ok(output) => output,
        Err(GitError::Unavailable(reason)) => return Err(ProjectError::Denied(reason)),
        Err(GitError::Failed(_)) => {
            return Ok(GitInspection {
                state: GitState::Missing,
                detail: None,
                reason: Some(format!(
                    "{} 还不是 Git 仓库；初始化后它会成为一个独立仓库",
                    path.display()
                )),
            })
        }
    };

    let toplevel = toplevel.trim();
    let toplevel = std::fs::canonicalize(toplevel).unwrap_or_else(|_| PathBuf::from(toplevel));
    if toplevel != path {
        return Ok(GitInspection {
            state: GitState::Nested,
            detail: Some(toplevel.display().to_string()),
            reason: Some(format!(
                "{} 属于仓库 {}，但本身不是仓库根；初始化后它会成为独立仓库",
                path.display(),
                toplevel.display()
            )),
        });
    }

    // 空仓库也要在这里挡住：没有任何提交时 `rev-parse --verify HEAD` 直接失败，
    // 留到任务执行时报出来就只是 code_failed，用户看不出"只是还没 commit"。
    match git(path, &["rev-parse", "--verify", "HEAD"]).await {
        Ok(_) => {}
        Err(GitError::Unavailable(reason)) => return Err(ProjectError::Denied(reason)),
        Err(GitError::Failed(_)) => {
            return Ok(GitInspection {
                state: GitState::NoCommits,
                detail: None,
                reason: Some(format!(
                    "{} 还没有任何提交；初始化会补一个空提交（不改动任何文件）",
                    path.display()
                )),
            })
        }
    }

    let branch = match git(path, &["rev-parse", "--abbrev-ref", "HEAD"]).await {
        Ok(output) => output,
        Err(GitError::Unavailable(reason)) => return Err(ProjectError::Denied(reason)),
        Err(GitError::Failed(reason)) => {
            return Err(ProjectError::Denied(format!(
                "无法读取 {} 的当前分支：{reason}",
                path.display()
            )))
        }
    };
    let branch = branch.trim().to_string();
    if branch.is_empty() || branch == "HEAD" {
        return Ok(GitInspection {
            state: GitState::Detached,
            detail: None,
            reason: Some(format!(
                "{} 的 HEAD 处于游离状态；请先在仓库里切到一个分支（这一步不能用初始化修好）",
                path.display()
            )),
        });
    }

    Ok(GitInspection {
        state: GitState::Ready,
        detail: Some(branch),
        reason: None,
    })
}

/// 初始化提交使用的身份。
///
/// 固定值而不是读用户 git 配置：初始化是**服务端**替用户做的动作，机器上没配
/// `user.name` 时用继承反而会失败；这类提交也不该冒充用户本人。
const INIT_NAME: &str = "personal-agent";
const INIT_EMAIL: &str = "agent@local";

/// 一次性项目默认分支名。写死是为了不依赖用户的 `init.defaultBranch` 配置。
const INIT_BRANCH: &str = "main";

/// 把目录初始化成可用的 Git 项目目录。
///
/// 只做两件事：缺仓库就 `git init`（分支固定 main），然后**一个空提交**。
/// 刻意不写 README、不改 `.gitignore`、不 `add` 目录里已有的文件——
/// 初始化不该在用户目录里凭空多出内容，也不该把别人的改动顺手提交进去。
/// 空提交是必须的：没有提交的分支建不出任务分支。
async fn initialize_repo(path: &Path, state: GitState) -> Result<(), ProjectError> {
    if state != GitState::NoCommits {
        match git(path, &["init", "-b", INIT_BRANCH]).await {
            Ok(_) => {}
            Err(GitError::Unavailable(reason)) => return Err(ProjectError::Denied(reason)),
            // 老版本 git 没有 `-b`：退回普通 init 再显式把 HEAD 指到 main。
            // 这一步失败也不致命（用它的默认分支名即可），后续只要 HEAD 在某个分支上就行。
            Err(GitError::Failed(_)) => {
                git(path, &["init"]).await.map_err(|err| match err {
                    GitError::Unavailable(reason) | GitError::Failed(reason) => {
                        ProjectError::Denied(format!(
                            "初始化 {} 失败：{reason}；请确认服务进程对该目录有写权限",
                            path.display()
                        ))
                    }
                })?;
                let _ = git(
                    path,
                    &["symbolic-ref", "HEAD", &format!("refs/heads/{INIT_BRANCH}")],
                )
                .await;
            }
        }
    }

    git(
        path,
        &[
            "-c",
            &format!("user.name={INIT_NAME}"),
            "-c",
            &format!("user.email={INIT_EMAIL}"),
            "commit",
            "--allow-empty",
            "-q",
            "-m",
            "chore: 初始化项目",
        ],
    )
    .await
    .map_err(|err| match err {
        GitError::Unavailable(reason) | GitError::Failed(reason) => ProjectError::Denied(format!(
            "初始化 {} 时创建首个提交失败：{reason}；请确认服务进程对该目录有写权限",
            path.display()
        )),
    })?;

    tracing::info!(path = %path.display(), from = state.as_str(), "已初始化项目仓库");
    Ok(())
}

/// git 命令失败的两种情况要分开：装没装 git 和仓库本身有问题，给用户的改法完全不同。
enum GitError {
    Unavailable(String),
    Failed(String),
}

async fn git(dir: &Path, args: &[&str]) -> Result<String, GitError> {
    let output = tokio::time::timeout(
        GIT_TIMEOUT,
        tokio::process::Command::new("git")
            .current_dir(dir)
            .args(args)
            .output(),
    )
    .await;

    match output {
        Err(_) => Err(GitError::Unavailable(format!(
            "git {} 超过 {} 秒没有响应：请检查仓库是否位于慢速磁盘",
            args.join(" "),
            GIT_TIMEOUT.as_secs()
        ))),
        Ok(Err(err)) => Err(GitError::Unavailable(format!(
            "无法执行 git（{err}）：请确认服务端已安装 git 并在 PATH 里"
        ))),
        Ok(Ok(output)) if !output.status.success() => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Err(GitError::Failed(if stderr.is_empty() {
                format!("git {} 退出码 {:?}", args.join(" "), output.status.code())
            } else {
                stderr
            }))
        }
        Ok(Ok(output)) => Ok(String::from_utf8_lossy(&output.stdout).to_string()),
    }
}

async fn find_active_by_path(
    pool: &SqlitePool,
    path: &str,
) -> Result<Option<String>, ProjectError> {
    let id: Option<String> =
        sqlx::query_scalar("SELECT id FROM projects WHERE path = ? AND deleted_at IS NULL")
            .bind(path)
            .fetch_optional(pool)
            .await?;
    Ok(id)
}

fn duplicate_path(existing_id: String) -> ProjectError {
    ProjectError::Conflict(format!(
        "这个目录已经是一个活动项目（{existing_id}）：请直接使用它，或先删掉旧的项目"
    ))
}

/// 名字：显式给了就用它，没给就取目录名。空串按"没给"处理。
fn normalize_name(raw: Option<&str>, path: &Path) -> Result<String, ProjectError> {
    match raw.map(str::trim).filter(|name| !name.is_empty()) {
        Some(name) => validate_name(name),
        None => {
            let from_dir = path
                .file_name()
                .map(|name| name.to_string_lossy().trim().to_string())
                .filter(|name| !name.is_empty())
                .unwrap_or_else(|| DEFAULT_PROJECT_NAME.to_string());
            validate_name(&from_dir)
        }
    }
}

fn validate_name(raw: &str) -> Result<String, ProjectError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(ProjectError::Invalid("项目名字不能为空".to_string()));
    }
    if name.chars().count() > MAX_NAME_CHARS {
        return Err(ProjectError::Invalid(format!(
            "项目名字过长（上限 {MAX_NAME_CHARS} 字），请改短一些"
        )));
    }
    Ok(name.to_string())
}

/// 列表 SQL。计数用相关子查询一次取回，避免客户端为每个项目再问一次（N+1）。
///
/// 写成完整的静态字面量而不是拼接：sqlx 0.9 只接受 `&'static str`，
/// 拼接出的动态 SQL 需要 `AssertSqlSafe` 显式绕过检查——没必要为此多开一道口子。
/// 带模式与不带模式各一份，避免在查询里拼 `WHERE` 片段。
const SQL_LIST_ALL: &str = "\
SELECT w.id, w.name, w.mode, w.path, w.created_at, w.updated_at, \
       (SELECT COUNT(*) FROM conversations c \
          WHERE c.project_id = w.id AND c.deleted_at IS NULL) AS conversation_count, \
       (SELECT COUNT(*) FROM tasks t JOIN conversations tc ON tc.id = t.conversation_id \
          WHERE tc.project_id = w.id AND t.deleted_at IS NULL AND tc.deleted_at IS NULL) \
         AS task_count \
  FROM projects w \
 WHERE w.deleted_at IS NULL \
 ORDER BY w.updated_at DESC, w.id DESC LIMIT ?";

const SQL_LIST_BY_MODE: &str = "\
SELECT w.id, w.name, w.mode, w.path, w.created_at, w.updated_at, \
       (SELECT COUNT(*) FROM conversations c \
          WHERE c.project_id = w.id AND c.deleted_at IS NULL) AS conversation_count, \
       (SELECT COUNT(*) FROM tasks t JOIN conversations tc ON tc.id = t.conversation_id \
          WHERE tc.project_id = w.id AND t.deleted_at IS NULL AND tc.deleted_at IS NULL) \
         AS task_count \
  FROM projects w \
 WHERE w.deleted_at IS NULL AND w.mode = ? \
 ORDER BY w.updated_at DESC, w.id DESC LIMIT ?";

/// 详情 SQL。与列表同构，只是过滤键换成 id，客户端拿到的项目形状永远一致。
const SQL_GET: &str = "\
SELECT w.id, w.name, w.mode, w.path, w.created_at, w.updated_at, \
       (SELECT COUNT(*) FROM conversations c \
          WHERE c.project_id = w.id AND c.deleted_at IS NULL) AS conversation_count, \
       (SELECT COUNT(*) FROM tasks t JOIN conversations tc ON tc.id = t.conversation_id \
          WHERE tc.project_id = w.id AND t.deleted_at IS NULL AND tc.deleted_at IS NULL) \
         AS task_count \
  FROM projects w \
 WHERE w.id = ? AND w.deleted_at IS NULL";

#[derive(Debug, sqlx::FromRow)]
struct ProjectRow {
    id: String,
    name: String,
    mode: String,
    path: String,
    conversation_count: i64,
    task_count: i64,
    created_at: i64,
    updated_at: i64,
}

fn project_from_row(row: ProjectRow) -> Project {
    Project {
        id: row.id,
        name: row.name,
        mode: ProjectMode::parse(&row.mode).unwrap_or(ProjectMode::Work),
        path: row.path,
        conversation_count: row.conversation_count,
        task_count: row.task_count,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_with_roots(roots: Vec<PathBuf>) -> Config {
        let mut config = Config::default();
        config.project.browse_roots = roots;
        config
    }

    #[test]
    fn absolute_path_is_required() {
        let config = Config::default();
        let err =
            resolve_dir(&config, ProjectMode::Work, "relative/dir").expect_err("相对路径必须拒绝");
        assert!(matches!(err, ProjectError::Invalid(_)));
    }

    #[test]
    fn path_outside_roots_is_denied() {
        let inside = std::env::temp_dir();
        let outside = PathBuf::from("/");
        let config = config_with_roots(vec![inside.clone()]);
        // 允许范围内的自己可以过（/tmp 规范化后可能与 temp_dir 不同，用规范化结果比较）
        let canonical = inside.canonicalize().expect("临时目录应存在");
        assert!(resolve_dir(&config, ProjectMode::Work, &canonical.to_string_lossy()).is_ok());

        let err = resolve_dir(&config, ProjectMode::Work, &outside.to_string_lossy())
            .expect_err("根目录不在白名单时必须拒绝");
        assert!(matches!(err, ProjectError::Denied(_)));
    }

    #[test]
    fn code_mode_requires_allow_roots() {
        let mut config = Config::default();
        config.code.allow_roots.clear();
        let err = roots_for(&config, ProjectMode::Code).expect_err("没有白名单必须拒绝");
        let hint = err.to_string();
        assert!(hint.contains("code.allow_roots"), "{hint}");
        assert!(hint.contains("不允许默认放开"), "{hint}");
        // 普通模式不受编码白名单影响
        assert!(roots_for(&config, ProjectMode::Work).is_ok());
    }

    #[test]
    fn name_defaults_to_directory_name() {
        let name = normalize_name(None, Path::new("/Users/you/Documents")).expect("应取目录名");
        assert_eq!(name, "Documents");

        let explicit = normalize_name(Some("  工作  "), Path::new("/tmp/x")).expect("应取显式名");
        assert_eq!(explicit, "工作");
    }

    #[test]
    fn oversized_name_is_rejected() {
        let long = "字".repeat(MAX_NAME_CHARS + 1);
        let err = validate_name(&long).expect_err("超长必须拒绝");
        assert!(matches!(err, ProjectError::Invalid(_)));
    }
}
