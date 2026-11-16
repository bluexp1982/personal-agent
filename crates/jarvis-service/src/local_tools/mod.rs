//! 对话侧的文件工具：`read_file` / `list_dir` / `search_file` / `search_content`、
//! `preview_url`，以及唯一会写盘的那个 `write_file`。
//!
//! 为什么在 service 进程内而不是 worker：
//!
//! - 路径的根（项目目录）在 SQLite 里，worker 既不读配置也不查库；
//! - 准入实现（`project_files`）本来就在 service，搬过去等于复制一份；
//! - 不动 IPC 协议，也就不用处理新旧 worker 混跑。
//!
//! 读工具会把用户磁盘上的内容送进第三方模型的上下文，写工具会改用户的文件，
//! 所以每一条路径都必须过 [`path_guard`]：读走 `file` / `dir`，写走 `resolve_new`。
//! 敏感文件另有名单拦截——写方向比读更严，连隐藏段都不允许。
//!
//! 技能路径（worker 经 IPC 调回来的那批）始终**只有**四个只读工具，
//! 见 `protocol::LOCAL_TOOL_WHITELIST`；写能力只存在于会话侧。

pub(crate) mod image;
pub(crate) mod list_dir;
pub(crate) mod media_gen;
pub(crate) mod path_guard;
pub(crate) mod preview_url;
pub(crate) mod read_file;
pub(crate) mod search_content;
pub(crate) mod search_file;
pub(crate) mod write_file;

use std::path::Path;

use crate::chat::{LocalToolOutcome, LocalToolRegistry};
use crate::local_tools::list_dir::ListDirTool;
use crate::local_tools::path_guard::{GuardError, ProjectRoot};
use crate::local_tools::read_file::ReadFileTool;
use crate::local_tools::search_content::SearchContentTool;
use crate::local_tools::search_file::SearchFileTool;

/// 单个搜索文件的上限：超过它的文件不参与内容搜索。
///
/// 个人项目里的源码通常远小于它；超过的多是产物、数据或压缩文件，
/// 读进来既慢又会把一段二进制当文本匹配。
pub(crate) const MAX_SCAN_FILE_BYTES: u64 = 2 * 1024 * 1024;

/// 搜索类工具的总回填预算（字符）。与 `read_file` 的 8 KiB 同一量级。
pub(crate) const MAX_SEARCH_CHARS: usize = 8 * 1024;

/// 搜索结果里单行文本的保留长度。
pub(crate) const MAX_HIT_LINE_CHARS: usize = 300;

/// 一次会话可用的文件工具集合。
///
/// 持有工具实例本身（而不是在注册时临时构造）：[`LocalToolRegistry`] 只借用，
/// 而这里的结构体活到 `chat::run` 返回之后。
#[derive(Debug)]
pub(crate) struct FileTools {
    read: ReadFileTool,
    list: ListDirTool,
    find_file: SearchFileTool,
    find_content: SearchContentTool,
}

impl FileTools {
    pub(crate) fn new(root: ProjectRoot) -> Self {
        Self {
            read: ReadFileTool::new(root.clone()),
            list: ListDirTool::new(root.clone()),
            find_file: SearchFileTool::new(root.clone()),
            find_content: SearchContentTool::new(root),
        }
    }

    /// 顺序即模型看到的顺序：先"看目录"，再"读文件"，最后"搜"。
    pub(crate) fn register<'a>(&'a self, registry: LocalToolRegistry<'a>) -> LocalToolRegistry<'a> {
        registry
            .with(&self.read)
            .with(&self.list)
            .with(&self.find_file)
            .with(&self.find_content)
    }
}

/// 按名字调一个只读文件工具。
///
/// 这是给 **技能路径**用的入口：worker 不能自己拼路径，只能报一个工具名与参数，
/// 由 service 在这里构造工具、走 [`path_guard`] 的准入再执行。
///
/// 返回 `None` 表示名字不在四个只读工具里——调用方应回一句可读的拒绝，
/// 而不是把未知名字当成"读不到文件"。
pub(crate) async fn call_one(
    root: ProjectRoot,
    tool: &str,
    args: &str,
) -> Option<LocalToolOutcome> {
    use crate::chat::LocalTool;

    let outcome = match tool {
        "read_file" => ReadFileTool::new(root).call(args).await,
        "list_dir" => ListDirTool::new(root).call(args).await,
        "search_file" => SearchFileTool::new(root).call(args).await,
        "search_content" => SearchContentTool::new(root).call(args).await,
        _ => return None,
    };

    Some(outcome)
}

/// 工具失败时的统一回填：`ok=false` + 一句可读的话，绝不中断整轮回答。
pub(crate) fn fail(content: String, target: String) -> LocalToolOutcome {
    LocalToolOutcome {
        content,
        sources: Vec::new(),
        ok: false,
        target,
        ui: Vec::new(),
    }
}

/// 准入失败的统一文案。
///
/// 越界与敏感文件要把"为什么"说清：只回一句"拒绝"的话，模型会换个写法反复试。
pub(crate) fn refused(error: &GuardError, target: &str) -> LocalToolOutcome {
    let content = match error {
        GuardError::Denied(reason) => format!("{reason}。项目之外的文件我读不到，也不该读。"),
        GuardError::Invalid(reason) => format!("{reason}。请确认路径相对项目根、且确实存在。"),
    };
    fail(content, target.to_string())
}

/// 人类可读的大小。工具回填里给字节数没有意义，模型也不知道 1536 是多大。
pub(crate) fn format_size(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    let value = bytes as f64;

    if bytes < 1024 {
        format!("{bytes} B")
    } else if value < KB * KB {
        format!("{:.1} KB", value / KB)
    } else {
        format!("{:.1} MB", value / (KB * KB))
    }
}

/// 截断说明。它本身也算进长度预算，否则"刚好超一点"的行会被截得更长。
const TRUNCATE_MARKER: &str = " …（此行过长，已截断）";

/// 截断一行文本，超长时补一个说明。
pub(crate) fn truncate_line(line: &str) -> String {
    if line.chars().count() <= MAX_HIT_LINE_CHARS {
        return line.to_string();
    }
    let keep = MAX_HIT_LINE_CHARS.saturating_sub(TRUNCATE_MARKER.chars().count());
    let kept: String = line.chars().take(keep).collect();
    format!("{kept}{TRUNCATE_MARKER}")
}

/// 按配置遍历项目里的文件。
///
/// 用 `ignore` 而不是自己递归 `read_dir`：它自带 `.gitignore` 语义、跳过 `.git`，
/// 与用户在编辑器里看到的"项目文件"是同一批。回调返回 `false` 立即停止遍历。
pub(crate) fn walk_files(
    base: &Path,
    include_hidden: bool,
    respect_gitignore: bool,
    mut on_file: impl FnMut(&Path) -> bool,
) {
    let mut builder = ignore::WalkBuilder::new(base);
    builder
        .hidden(!include_hidden)
        .follow_links(false)
        .threads(1)
        // 不在 git 仓库里的目录也要认 `.gitignore`：项目经常只是普通目录，
        // 而用户写下的忽略规则与是不是仓库无关。
        .require_git(false)
        .git_global(respect_gitignore)
        .git_ignore(respect_gitignore)
        .git_exclude(respect_gitignore)
        .ignore(respect_gitignore)
        .parents(respect_gitignore);

    for entry in builder.build().flatten() {
        let path = entry.path();
        let relative = relative_to(base, path);

        // `.git` 里全是对象与索引，内容搜索没有意义，而且文件数量极大。
        if relative.split('/').any(|part| part == ".git") {
            continue;
        }
        if is_noise_dir(&relative) {
            continue;
        }

        if !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }

        if !on_file(path) {
            return;
        }
    }
}

/// 依赖目录与产物目录：任何层级都不参与搜索。
///
/// 不靠 `.gitignore` 兜这一层，是因为项目里未必有 `.gitignore`（很多项目
/// 只在仓库根写一条 `node_modules/`，而 普通项目可能根本不是仓库）。
const NOISE_ANYWHERE: [&str; 7] = [
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    ".next",
    ".nuxt",
    ".cache",
];

/// 只跳过根下一层的构建产物目录。
///
/// 只认第一层是怕误伤 `src/build/`、`packages/app/dist/` 这类真实源码目录。
const NOISE_AT_ROOT: [&str; 4] = ["target", "dist", "build", "out"];

fn is_noise_dir(relative: &str) -> bool {
    let mut parts = relative.split('/');

    if let Some(first) = parts.next() {
        if NOISE_AT_ROOT.contains(&first) {
            return true;
        }
    }

    relative
        .split('/')
        .any(|part| NOISE_ANYWHERE.contains(&part))
}

/// 相对 `base` 的路径，统一成 `/` 分隔。
pub(crate) fn relative_to(base: &Path, path: &Path) -> String {
    path.strip_prefix(base)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_sizes() {
        assert_eq!(format_size(512), "512 B");
        assert_eq!(format_size(1536), "1.5 KB");
        assert_eq!(format_size(5 * 1024 * 1024), "5.0 MB");
    }

    #[test]
    fn truncates_only_long_lines() {
        assert_eq!(truncate_line("short"), "short");

        let long = "字".repeat(MAX_HIT_LINE_CHARS + 5);
        let text = truncate_line(&long);
        assert!(text.ends_with("已截断）"), "{text}");
        assert!(
            text.chars().count() <= MAX_HIT_LINE_CHARS,
            "截断后不能超过预算（含说明）: {}",
            text.chars().count()
        );
    }
}
