//! 项目与目录浏览载荷。字段与 `api-spec/openapi.yaml` 一致。
//!
//! 项目是「会话与任务」的归属：它绑定服务端机器上的一个真实目录。
//! 模式（`code` / `work`）决定这个目录能不能承接 Git 与编码任务：
//! 只有 Git 项目允许派发编码任务，普通项目只做生活与办公事务。
//!
//! 时间统一 Unix 毫秒；字段一旦发布不改语义，只能新增。

use serde::{Deserialize, Serialize};

/// 项目模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProjectMode {
    /// 编程：绑定 git 仓库目录，允许编码任务（隔离工作树、补丁、审批后合并）。
    Code,
    /// 事务：绑定任意目录，不提供任何 Git 能力。
    Work,
}

impl ProjectMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Code => "code",
            Self::Work => "work",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "code" => Some(Self::Code),
            "work" => Some(Self::Work),
            _ => None,
        }
    }

    /// 该模式下是否允许编码任务（唯一会执行 Git 操作的能力）。
    ///
    /// 服务端以此为准，不信任客户端传入的模式：模式永远取自项目记录。
    pub const fn allows_code_tasks(self) -> bool {
        matches!(self, Self::Code)
    }
}

/// 项目。`conversation_count` / `task_count` 是列表页要用的计数，随记录一起下发，
/// 客户端不再为每个项目各发一次请求。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub mode: ProjectMode,
    /// 服务端机器上的绝对路径（规范化后的真实路径）。
    pub path: String,
    pub conversation_count: i64,
    pub task_count: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 新建项目。`name` 留空时由服务端取目录名。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectCreate {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub mode: ProjectMode,
    pub path: String,
    /// Git 模式：目录还不是可用仓库时，允许服务端执行初始化（`git init` + 一个空提交）。
    ///
    /// 默认 `false`：往用户磁盘上写东西属于"改真实环境"，必须由人在确认框里点一次，
    /// 不能因为客户端调用了创建接口就顺手做掉。
    #[serde(default)]
    pub init_git: bool,
}

/// 重命名项目。本期只允许改名字，模式与路径一经创建不可变。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectUpdate {
    pub name: String,
}

/// Git 项目目录的 git 前置状态。
///
/// 客户端据此决定界面怎么写：能不能直接建、要不要先问一句"要不要初始化"。
/// `missing` / `nested` / `no_commits` 都能用一次初始化修好，其余不行。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitState {
    /// 已是仓库根，且有提交、非游离 HEAD：可以直接创建。
    Ready,
    /// 目录本身不是仓库（也不属于任何仓库）。
    Missing,
    /// 目录属于别的仓库，但本身不是仓库根。
    Nested,
    /// 是仓库根，但还没有任何提交。
    NoCommits,
    /// HEAD 游离：初始化修不了。
    Detached,
    /// 与 git 无关（普通模式）。
    NotApplicable,
}

impl GitState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Missing => "missing",
            Self::Nested => "nested",
            Self::NoCommits => "no_commits",
            Self::Detached => "detached",
            Self::NotApplicable => "not_applicable",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "ready" => Some(Self::Ready),
            "missing" => Some(Self::Missing),
            "nested" => Some(Self::Nested),
            "no_commits" => Some(Self::NoCommits),
            "detached" => Some(Self::Detached),
            "not_applicable" => Some(Self::NotApplicable),
            _ => None,
        }
    }

    /// 能否用「`git init` + 一个空提交」修好。
    pub const fn fixable_by_init(self) -> bool {
        matches!(self, Self::Missing | Self::Nested | Self::NoCommits)
    }
}

/// 建项目之前的预检结果：目录是否可用、卡在哪一步、能不能现场修好。
///
/// 单独一个端点而不是让客户端去解析创建失败的错误：`code_project_denied` 同时
/// 覆盖越界、没权限、不是仓库、游离 HEAD 四种情况，只有服务端分得清哪一种可修。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectPreflight {
    /// 规范化后的真实路径（客户端展示它，避免回显带 `..` 的写法）。
    pub path: String,
    pub mode: ProjectMode,
    /// 能否直接创建。
    pub ready: bool,
    pub git: GitState,
    /// `nested` 时是所属仓库路径，`ready` 时是当前分支；其余为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_detail: Option<String>,
    /// 可以带 `init_git: true` 重试（客户端据此弹确认框）。
    pub can_init: bool,
    /// 面向用户的原因与改法；`ready` 时为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// 目录条目类型。`repo` 表示该目录本身是 git 仓库根，可直接建成 Git 项目。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DirKind {
    Dir,
    Repo,
}

/// 目录浏览器的一个条目。只返回目录，不返回文件——项目只认目录。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub kind: DirKind,
}

/// 目录浏览结果。
///
/// `roots` 每次随响应下发，客户端不必自己猜允许的起点；
/// `parent` 在根目录处省略，客户端据此禁用「上一级」。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirListing {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default)]
    pub roots: Vec<String>,
    #[serde(default)]
    pub entries: Vec<DirEntry>,
}

/// 项目文件树里的条目类型。
///
/// 与 [`DirKind`] 是两个概念：`DirKind` 属于「选项目目录」的浏览器，
/// 这里属于「浏览已建项目」的文件树，只区分目录与普通文件。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProjectEntryKind {
    Dir,
    File,
}

/// 项目文件树的一个条目。文件带 `size`，目录不带。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectEntry {
    pub name: String,
    /// 规范化的绝对路径。客户端下游请求（展开子目录、预览文件）直接用它回传，
    /// 不自己拼路径——macOS 的 `/var` 与 Windows 的分隔符都会对不上。
    pub path: String,
    pub kind: ProjectEntryKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
}

/// 项目某一层目录的浏览结果。
///
/// `truncated` 表示该层条目超过上限（服务端约定 200 条），
/// 客户端据此提示「只显示了一部分」，而不是让人误以为目录里就这么多。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectListing {
    pub path: String,
    #[serde(default)]
    pub entries: Vec<ProjectEntry>,
    #[serde(default)]
    pub truncated: bool,
}

/// 项目内的一个文本文件。
///
/// `size` 是磁盘上的完整大小，`text` 可能被截断（`truncated = true`）；
/// 两者分开才能让客户端显示「共 3.2 MB，仅显示前 512 KB」。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectFileContent {
    pub path: String,
    pub size: u64,
    pub text: String,
    #[serde(default)]
    pub truncated: bool,
}

/// 项目内网页的预览地址。
///
/// `url` 里有预览站的随机端口与访问令牌，**只用于加载**：它不该出现在地址栏，
/// 也不该被复制出去。`display` 是给人看的那一份（项目目录名 + 相对路径）。
///
/// 由服务端生成而不是客户端自己拼：令牌只在服务端，客户端永远不该知道它。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreviewTarget {
    pub url: String,
    pub display: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_roundtrip() {
        for mode in [ProjectMode::Code, ProjectMode::Work] {
            assert_eq!(ProjectMode::parse(mode.as_str()), Some(mode));
        }
        assert_eq!(ProjectMode::parse("CODE"), None);
        assert_eq!(ProjectMode::parse("text"), None);
    }

    #[test]
    fn only_code_allows_code_tasks() {
        assert!(ProjectMode::Code.allows_code_tasks());
        assert!(!ProjectMode::Work.allows_code_tasks());
    }

    #[test]
    fn project_serializes_mode_lowercase() {
        let project = Project {
            id: "ws_1".to_string(),
            name: "个人事务".to_string(),
            mode: ProjectMode::Work,
            path: "/Users/you/Documents".to_string(),
            conversation_count: 2,
            task_count: 1,
            created_at: 1,
            updated_at: 2,
        };
        let value = serde_json::to_value(&project).expect("序列化失败");
        assert_eq!(value["mode"], "work");
        assert_eq!(value["conversation_count"], 2);
    }

    #[test]
    fn create_request_defaults_name_to_none() {
        let request: ProjectCreate =
            serde_json::from_str(r#"{"mode":"code","path":"/tmp/repo"}"#).expect("解析失败");
        assert!(request.name.is_none());
        assert_eq!(request.mode, ProjectMode::Code);
        assert!(
            !request.init_git,
            "初始化必须显式要求：默认不做任何写盘动作"
        );
    }

    #[test]
    fn git_state_roundtrip_and_fixability() {
        for state in [
            GitState::Ready,
            GitState::Missing,
            GitState::Nested,
            GitState::NoCommits,
            GitState::Detached,
            GitState::NotApplicable,
        ] {
            assert_eq!(GitState::parse(state.as_str()), Some(state));
        }
        assert_eq!(GitState::parse("nope"), None);

        for state in [GitState::Missing, GitState::Nested, GitState::NoCommits] {
            assert!(state.fixable_by_init(), "{state:?} 应可初始化修好");
        }
        for state in [GitState::Ready, GitState::Detached, GitState::NotApplicable] {
            assert!(!state.fixable_by_init(), "{state:?} 不该走初始化");
        }
    }

    #[test]
    fn preflight_serializes_git_state_and_omits_empty_detail() {
        let preflight = ProjectPreflight {
            path: "/Users/you/work/demo".to_string(),
            mode: ProjectMode::Code,
            ready: false,
            git: GitState::Missing,
            git_detail: None,
            can_init: true,
            reason: Some("还不是 Git 仓库".to_string()),
        };
        let value = serde_json::to_value(&preflight).expect("序列化失败");
        assert_eq!(value["git"], "missing");
        assert_eq!(value["can_init"], true);
        assert!(value.get("git_detail").is_none(), "空字段应整个省略");
    }

    #[test]
    fn dir_listing_omits_parent_at_root() {
        let listing = DirListing {
            path: "/Users/you".to_string(),
            parent: None,
            roots: vec!["/Users/you".to_string()],
            entries: vec![DirEntry {
                name: "code".to_string(),
                path: "/Users/you/code".to_string(),
                kind: DirKind::Repo,
            }],
        };
        let value = serde_json::to_value(&listing).expect("序列化失败");
        assert!(value.get("parent").is_none(), "根目录不该下发 parent");
        assert_eq!(value["entries"][0]["kind"], "repo");
    }

    #[test]
    fn project_entry_serializes_kind_and_optional_size() {
        let listing = ProjectListing {
            path: "/Users/you/code".to_string(),
            entries: vec![
                ProjectEntry {
                    name: "src".to_string(),
                    path: "/Users/you/code/src".to_string(),
                    kind: ProjectEntryKind::Dir,
                    size: None,
                },
                ProjectEntry {
                    name: "main.rs".to_string(),
                    path: "/Users/you/code/main.rs".to_string(),
                    kind: ProjectEntryKind::File,
                    size: Some(1024),
                },
            ],
            truncated: false,
        };
        let value = serde_json::to_value(&listing).expect("序列化失败");
        assert_eq!(value["entries"][0]["kind"], "dir");
        assert!(value["entries"][0].get("size").is_none(), "目录不带 size");
        assert_eq!(value["entries"][1]["kind"], "file");
        assert_eq!(value["entries"][1]["size"], 1024);
    }

    #[test]
    fn file_content_defaults_truncated_to_false() {
        let content: ProjectFileContent =
            serde_json::from_str(r#"{"path":"/tmp/a.txt","size":3,"text":"abc"}"#)
                .expect("解析失败");
        assert_eq!(content.text, "abc");
        assert!(!content.truncated);
    }
}
