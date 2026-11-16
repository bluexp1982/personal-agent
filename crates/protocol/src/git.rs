//! Git 面板载荷：变更、diff、提交与历史。
//!
//! 与「建项目时的 git 预检」（[`crate::GitState`] / [`crate::ProjectPreflight`]）分开：
//! 那组字段回答"这个目录能不能建成 Git 项目"，这里回答"仓库现在长什么样"。
//!
//! 时间统一 Unix 毫秒；路径一律是**仓库内相对路径**（`/` 分隔），
//! 不用绝对路径——客户端不需要、也不该拿到服务端的目录布局。
//!
//! 本模块只做数据形状，不含任何 git 调用；真正的命令都在 `jarvis-service` 的 `git` 模块里。

use serde::{Deserialize, Serialize};

/// 单个操作最多带多少条路径。
///
/// 面板是给人点的，正常一次几条；设上限是为了挡住"一次 add 全仓十万文件"这种
/// 会被 git 参数长度和索引写放大拖垮的请求。
pub const MAX_GIT_PATHS: usize = 200;

/// 提交信息长度上限（字符数）。
///
/// 宽到能放下规范的 body，又能挡住几 MB 的粘贴物——那既不是提交信息，
/// 也会把命令行参数撑爆。
pub const MAX_COMMIT_MESSAGE_CHARS: usize = 4000;

/// 单文件 diff 的文本上限（字节）。
///
/// 超过就截断并置 `truncated`：一次性把 20 MB 的 diff 塞进内存再发到手机上，
/// 面板会先被自己的文本渲染拖死。
pub const MAX_DIFF_BYTES: usize = 512 * 1024;

/// 一次请求最多返回多少条提交。
pub const MAX_LOG_LIMIT: u32 = 200;

/// 历史分页的默认条数。
pub const DEFAULT_LOG_LIMIT: u32 = 50;

/// 一个文件在某个侧（暂存区 / 工作区）的状态。
///
/// 取自 `git status --porcelain` 的状态字母，语义与 git 一致：
/// 同一个文件可以同时在「已暂存」与「未暂存」两组出现（暂存后又改了一笔）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitFileState {
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    /// 类型变了（普通文件 ↔ 软链接 ↔ 子模块）。少见，但 git 会报，不该当成"已修改"。
    TypeChanged,
    /// 合并冲突。
    Unmerged,
    Untracked,
}

impl GitFileState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Modified => "modified",
            Self::Added => "added",
            Self::Deleted => "deleted",
            Self::Renamed => "renamed",
            Self::Copied => "copied",
            Self::TypeChanged => "type_changed",
            Self::Unmerged => "unmerged",
            Self::Untracked => "untracked",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "modified" => Some(Self::Modified),
            "added" => Some(Self::Added),
            "deleted" => Some(Self::Deleted),
            "renamed" => Some(Self::Renamed),
            "copied" => Some(Self::Copied),
            "type_changed" => Some(Self::TypeChanged),
            "unmerged" => Some(Self::Unmerged),
            "untracked" => Some(Self::Untracked),
            _ => None,
        }
    }
}

/// 变更列表里的一项。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitFileChange {
    /// 仓库内相对路径（`/` 分隔）。重命名时是**新路径**。
    pub path: String,
    /// 重命名 / 复制的源路径；其余为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub orig_path: Option<String>,
    pub state: GitFileState,
}

/// 仓库正处于哪一种多步操作中间。
///
/// 处在这几种状态时面板**只读**：提交会让用户在半截的现场上再叠一层，
/// 冲突该在终端里解决完再回来。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitOperation {
    Merge,
    Rebase,
    CherryPick,
    Revert,
}

impl GitOperation {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Merge => "merge",
            Self::Rebase => "rebase",
            Self::CherryPick => "cherry_pick",
            Self::Revert => "revert",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "merge" => Some(Self::Merge),
            "rebase" => Some(Self::Rebase),
            "cherry_pick" => Some(Self::CherryPick),
            "revert" => Some(Self::Revert),
            _ => None,
        }
    }

    /// 给用户看的中文名（拼进提示语里）。
    pub const fn label(self) -> &'static str {
        match self {
            Self::Merge => "merge",
            Self::Rebase => "rebase",
            Self::CherryPick => "cherry-pick",
            Self::Revert => "revert",
        }
    }
}

/// 一条提交的概要。面板的历史列表与分支栏都用它。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitCommitSummary {
    /// 完整 40 位 sha。
    pub hash: String,
    /// git 自己截的短 sha（长度随仓库规模变，别自己 cut）。
    pub short_hash: String,
    /// 首行标题（`%s`）。
    pub subject: String,
    /// 作者名（`%an`）。邮箱不下发：面板不展示，少一处个人信息暴露面。
    pub author: String,
    /// 作者时间，Unix 毫秒。
    pub time_ms: i64,
}

/// 仓库当前状态：分支、三组变更、进行中的操作。
///
/// `repo = false` 是**正常返回**而不是错误：普通项目目录、`nested` 目录
/// 都会走这里，客户端据此画"不是 Git 仓库"的空态，而不是弹一个红色报错。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitStatusReport {
    /// 项目目录本身是不是一个 git 仓库根。
    pub repo: bool,
    /// 当前分支名；游离 HEAD 或还没有任何提交时为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// HEAD 游离（不在任何分支上）。
    pub detached: bool,
    /// HEAD 指向的提交；空仓库时为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<GitCommitSummary>,
    /// 进行中的多步操作；正常状态为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation: Option<GitOperation>,
    /// `repo = false` 时说明原因（不是仓库 / 属于别的仓库），其余为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// 已暂存（索引相对 HEAD）。
    #[serde(default)]
    pub staged: Vec<GitFileChange>,
    /// 未暂存（工作区相对索引）。
    #[serde(default)]
    pub unstaged: Vec<GitFileChange>,
    /// 未跟踪。
    #[serde(default)]
    pub untracked: Vec<GitFileChange>,
}

impl GitStatusReport {
    /// 一个"不是仓库"的占位报告。
    pub fn not_a_repo(reason: impl Into<String>) -> Self {
        Self {
            repo: false,
            branch: None,
            detached: false,
            head: None,
            operation: None,
            reason: Some(reason.into()),
            staged: Vec::new(),
            unstaged: Vec::new(),
            untracked: Vec::new(),
        }
    }

    /// 三组变更的条数合计。分支栏上的胶囊数字用它。
    pub fn change_count(&self) -> usize {
        self.staged.len() + self.unstaged.len() + self.untracked.len()
    }

    /// 工作区干净：没有变更，也没有进行中的操作。
    pub fn is_clean(&self) -> bool {
        self.repo && self.change_count() == 0
    }
}

/// 单个文件（或某次提交）的 diff。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitDiffReport {
    /// 请求里的相对路径；整次提交的 diff 时为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// 看的是暂存区（`--cached`）。
    pub staged: bool,
    /// 看的是某次提交（`git show`）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// 统一格式的 diff 文本；二进制文件为空。
    pub text: String,
    /// 文本被截断（超过 [`MAX_DIFF_BYTES`]）。
    #[serde(default)]
    pub truncated: bool,
    /// 二进制文件：没有可渲染的文本。
    #[serde(default)]
    pub binary: bool,
    /// 新增行数（二进制为 0）。
    #[serde(default)]
    pub additions: u64,
    /// 删除行数。
    #[serde(default)]
    pub deletions: u64,
}

/// 一次带动多个路径的操作（暂存 / 取消暂存 / 撤销）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitPathsRequest {
    /// 仓库内相对路径，1..=[`MAX_GIT_PATHS`] 条。
    pub paths: Vec<String>,
}

/// 提交请求。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitCommitRequest {
    /// 提交信息（含 body）；会被 `-m` 原样传给 git。
    pub message: String,
}

/// 提交结果：新提交 + 提交后的最新状态。
///
/// 状态一起回是为了省掉一次往返：面板提交完必须立刻重画变更列表。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitCommitResult {
    pub commit: GitCommitSummary,
    pub status: GitStatusReport,
}

/// 提交历史的一页。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitCommitsPage {
    #[serde(default)]
    pub commits: Vec<GitCommitSummary>,
    /// 还有更早的提交（客户端据此显示"加载更多"）。
    #[serde(default)]
    pub has_more: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_state_roundtrip() {
        for state in [
            GitFileState::Modified,
            GitFileState::Added,
            GitFileState::Deleted,
            GitFileState::Renamed,
            GitFileState::Copied,
            GitFileState::TypeChanged,
            GitFileState::Unmerged,
            GitFileState::Untracked,
        ] {
            assert_eq!(GitFileState::parse(state.as_str()), Some(state));
        }
        assert_eq!(GitFileState::parse("M"), None, "协议不走单字母");
    }

    #[test]
    fn operation_roundtrip() {
        for op in [
            GitOperation::Merge,
            GitOperation::Rebase,
            GitOperation::CherryPick,
            GitOperation::Revert,
        ] {
            assert_eq!(GitOperation::parse(op.as_str()), Some(op));
        }
        assert_eq!(GitOperation::parse("stash"), None);
    }

    #[test]
    fn not_a_repo_is_clean_and_empty() {
        let report = GitStatusReport::not_a_repo("目录不是仓库");
        assert!(!report.repo);
        assert_eq!(report.change_count(), 0);
        assert!(!report.is_clean(), "不是仓库不能被当成「干净」");
    }

    #[test]
    fn status_omits_empty_optional_fields() {
        let report = GitStatusReport {
            repo: true,
            branch: Some("main".to_string()),
            detached: false,
            head: None,
            operation: None,
            reason: None,
            staged: vec![GitFileChange {
                path: "src/main.rs".to_string(),
                orig_path: None,
                state: GitFileState::Modified,
            }],
            unstaged: Vec::new(),
            untracked: Vec::new(),
        };
        let value = serde_json::to_value(&report).expect("序列化失败");
        assert_eq!(value["branch"], "main");
        assert_eq!(value["staged"][0]["state"], "modified");
        assert!(value.get("reason").is_none(), "空字段应整个省略");
        assert!(value.get("head").is_none());
        assert_eq!(report.change_count(), 1);
    }

    #[test]
    fn rename_keeps_source_path() {
        let change = GitFileChange {
            path: "src/new.rs".to_string(),
            orig_path: Some("src/old.rs".to_string()),
            state: GitFileState::Renamed,
        };
        let value = serde_json::to_value(&change).expect("序列化失败");
        assert_eq!(value["orig_path"], "src/old.rs");
        assert_eq!(value["state"], "renamed");
        assert_eq!(value["path"], "src/new.rs");
    }

    #[test]
    fn paths_request_keeps_order() {
        let request: GitPathsRequest =
            serde_json::from_str(r#"{"paths":["a.rs","b/c.rs"]}"#).expect("解析失败");
        assert_eq!(request.paths, vec!["a.rs", "b/c.rs"]);
    }

    #[test]
    fn commit_request_parses_message() {
        let request: GitCommitRequest =
            serde_json::from_str(r#"{"message":"feat: 加 git 面板"}"#).expect("解析失败");
        assert_eq!(request.message, "feat: 加 git 面板");
    }

    #[test]
    fn diff_report_defaults_flags() {
        let report: GitDiffReport =
            serde_json::from_str(r#"{"staged":false,"text":"@@ -1 +1 @@"}"#).expect("解析失败");
        assert!(!report.truncated);
        assert!(!report.binary);
        assert_eq!(report.additions, 0);
        assert!(report.path.is_none());
    }

    #[test]
    fn commits_page_defaults_empty() {
        let page: GitCommitsPage = serde_json::from_str("{}").expect("解析失败");
        assert!(page.commits.is_empty());
        assert!(!page.has_more);
    }
}
