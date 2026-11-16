//! `list_dir`：列一层目录。
//!
//! 直接包装 [`crate::project_files::list`]：条目上限、目录优先排序、软链接越界
//! 不展示这些规则都已经在那里，这里只负责把模型给相对路径转成绝对路径、再把结果
//! 渲染成一段模型好读的文本。

use crate::chat::{LocalTool, LocalToolOutcome, ToolSpec};
use crate::local_tools::path_guard::ProjectRoot;
use crate::local_tools::{fail, format_size, refused};
use crate::project::ProjectError;
use crate::project_files;
use protocol::ProjectEntryKind;

#[derive(Debug)]
pub(crate) struct ListDirTool {
    root: ProjectRoot,
}

impl ListDirTool {
    pub(crate) fn new(root: ProjectRoot) -> Self {
        Self { root }
    }
}

#[async_trait::async_trait]
impl LocalTool for ListDirTool {
    fn spec(&self) -> ToolSpec {
        ToolSpec::list_dir()
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let args = match parse(arguments) {
            Ok(args) => args,
            Err(reason) => {
                return fail(
                    format!("参数不合法：{reason}。path 应相对项目根，省略表示根目录。"),
                    "list_dir:invalid".to_string(),
                );
            }
        };

        let abs = match self.root.dir(&args.path) {
            Ok(path) => path,
            Err(err) => return refused(&err, "list_dir:denied"),
        };
        let rel = self.root.relative(&abs);
        // 根目录的标签必须是 "." 而不是项目名：写成 `code-001/` 时模型会把它
        // 当路径前缀抄进 `write_file`，于是项目里凭空多一层同名目录。
        let label = if rel.is_empty() {
            ".".to_string()
        } else {
            rel.clone()
        };

        let root = self.root.root().to_string_lossy().to_string();
        let absolute = abs.to_string_lossy().to_string();

        match project_files::list(&root, Some(&absolute), args.include_hidden) {
            Ok(listing) => {
                let content = render(&label, &listing);
                LocalToolOutcome {
                    content,
                    // 目录本身不作为来源：它是导航，不是引用。
                    sources: Vec::new(),
                    ok: true,
                    target: format!("dir:{rel}"),
                    ui: Vec::new(),
                }
            }
            Err(ProjectError::Denied(reason)) => fail(reason, format!("dir:{rel}:denied")),
            Err(other) => fail(
                format!("列出 {label} 失败：{other}"),
                format!("dir:{rel}:failed"),
            ),
        }
    }
}

struct Args {
    path: String,
    include_hidden: bool,
}

fn parse(raw: &str) -> Result<Args, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|err| format!("不是合法 JSON（{err}）"))?;

    let path = value["path"]
        .as_str()
        .map(str::trim)
        .unwrap_or_default()
        .to_string();

    Ok(Args {
        path,
        include_hidden: value["include_hidden"].as_bool().unwrap_or(false),
    })
}

fn render(label: &str, listing: &protocol::ProjectListing) -> String {
    if listing.entries.is_empty() {
        return format!("目录：{label}\n（空目录，没有可列出的项）");
    }

    let mut text = format!("目录：{label}（共 {} 项）\n", listing.entries.len());

    for entry in &listing.entries {
        match entry.kind {
            ProjectEntryKind::Dir => text.push_str(&format!("[目录] {}/\n", entry.name)),
            ProjectEntryKind::File => {
                let size = entry
                    .size
                    .map(format_size)
                    .unwrap_or_else(|| "大小未知".to_string());
                text.push_str(&format!("[文件] {} ({size})\n", entry.name));
            }
        }
    }

    if listing.truncated {
        text.push_str("（只显示了一部分：该目录条目过多，请改用 search_file 定位）\n");
    }

    text.push_str("提示：只列一层，不递归；要看子目录请再调用 list_dir 并传它的 path。");
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::ProjectEntry;

    fn listing(entries: Vec<ProjectEntry>, truncated: bool) -> protocol::ProjectListing {
        protocol::ProjectListing {
            path: "/tmp/x".to_string(),
            entries,
            truncated,
        }
    }

    fn entry(name: &str, kind: ProjectEntryKind, size: Option<u64>) -> ProjectEntry {
        ProjectEntry {
            name: name.to_string(),
            path: format!("/tmp/x/{name}"),
            kind,
            size,
        }
    }

    #[test]
    fn renders_dirs_before_files_with_size() {
        let text = render(
            "src",
            &listing(
                vec![
                    entry("api", ProjectEntryKind::Dir, None),
                    entry("main.rs", ProjectEntryKind::File, Some(1536)),
                ],
                false,
            ),
        );

        assert!(text.contains("共 2 项"), "{text}");
        assert!(text.contains("[目录] api/"), "{text}");
        assert!(text.contains("[文件] main.rs (1.5 KB)"), "{text}");
        assert!(text.contains("只列一层"), "{text}");
    }

    #[test]
    fn renders_empty_and_truncated() {
        let empty = render("src", &listing(Vec::new(), false));
        assert!(empty.contains("空目录"), "{empty}");

        let truncated = render(
            "src",
            &listing(vec![entry("a.rs", ProjectEntryKind::File, Some(1))], true),
        );
        assert!(truncated.contains("只显示了一部分"), "{truncated}");
    }

    #[test]
    fn parse_defaults_to_root_and_hidden_off() {
        let args = parse("{}").expect("应通过");
        assert!(args.path.is_empty(), "省略 path 表示根目录");
        assert!(!args.include_hidden);

        let args = parse(r#"{"path":" src ","include_hidden":true}"#).expect("应通过");
        assert_eq!(args.path, "src");
        assert!(args.include_hidden);
    }
}
