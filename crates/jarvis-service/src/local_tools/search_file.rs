//! `search_file`：按文件名 glob 找文件。
//!
//! 只匹配**路径**，不读内容。`pattern` 不含 `/` 时匹配文件名（`*.rs` 能找到
//! 任意层级的 rs 文件，这是用户的直觉）；含 `/` 时匹配相对路径，`*` 不跨层，
//! 要跨层得写 `**`。

use std::path::Path;
use std::time::Duration;

use globset::{GlobBuilder, GlobMatcher};

use crate::chat::{LocalTool, LocalToolOutcome, ToolSpec};
use crate::local_tools::path_guard::ProjectRoot;
use crate::local_tools::{fail, format_size, refused, relative_to, walk_files};

/// 单次搜索的墙钟上限。超时返回可读失败，而不是让整轮对话挂住。
const SEARCH_TIMEOUT: Duration = Duration::from_secs(8);

const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 200;

#[derive(Debug)]
pub(crate) struct SearchFileTool {
    root: ProjectRoot,
}

impl SearchFileTool {
    pub(crate) fn new(root: ProjectRoot) -> Self {
        Self { root }
    }
}

#[async_trait::async_trait]
impl LocalTool for SearchFileTool {
    fn spec(&self) -> ToolSpec {
        ToolSpec::search_file()
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let args = match parse(arguments) {
            Ok(args) => args,
            Err(reason) => {
                return fail(
                    format!("参数不合法：{reason}。pattern 是 glob，例如 *.rs。"),
                    "search_file:invalid".to_string(),
                );
            }
        };

        let matcher = match build_matcher(&args.pattern) {
            Ok(matcher) => matcher,
            Err(reason) => {
                return fail(
                    format!("glob 写法不对：{reason}。例如 *.rs、src/**/*.toml。"),
                    "search_file:invalid".to_string(),
                );
            }
        };

        let base = match self.root.dir(&args.path) {
            Ok(path) => path,
            Err(err) => return refused(&err, "search_file:denied"),
        };
        let root = self.root.root().to_path_buf();
        let scope = self.root.relative(&base);
        let limit = args.limit;
        let include_hidden = args.include_hidden;
        let pattern = args.pattern.clone();

        let joined = tokio::time::timeout(
            SEARCH_TIMEOUT,
            tokio::task::spawn_blocking(move || {
                collect(&root, &base, &matcher, &pattern, limit, include_hidden)
            }),
        )
        .await;

        let result = match joined {
            Ok(Ok(result)) => result,
            Ok(Err(err)) => {
                tracing::warn!(%err, "文件搜索线程失败");
                return fail(
                    "搜索失败（执行线程异常），请缩小范围后重试。".to_string(),
                    "search_file:failed".to_string(),
                );
            }
            Err(_) => {
                return fail(
                    format!(
                        "搜索超时（超过 {} 秒）。请缩小 path 范围，或把 pattern 写得更具体。",
                        SEARCH_TIMEOUT.as_secs()
                    ),
                    "search_file:timeout".to_string(),
                );
            }
        };

        let content = render(&result, &args.pattern, &scope);
        let ok = !result.items.is_empty();

        LocalToolOutcome {
            content,
            sources: Vec::new(),
            ok,
            target: format!("search_file:{}:hits={}", args.pattern, result.items.len()),
            ui: Vec::new(),
        }
    }
}

struct Args {
    pattern: String,
    path: String,
    limit: usize,
    include_hidden: bool,
}

fn parse(raw: &str) -> Result<Args, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|err| format!("不是合法 JSON（{err}）"))?;

    let pattern = value["pattern"]
        .as_str()
        .map(str::trim)
        .filter(|pattern| !pattern.is_empty())
        .ok_or_else(|| "缺少 pattern".to_string())?
        .to_string();

    Ok(Args {
        pattern,
        path: value["path"]
            .as_str()
            .map(str::trim)
            .unwrap_or_default()
            .to_string(),
        limit: value["limit"]
            .as_u64()
            .unwrap_or(DEFAULT_LIMIT as u64)
            .clamp(1, MAX_LIMIT as u64) as usize,
        include_hidden: value["include_hidden"].as_bool().unwrap_or(false),
    })
}

/// 造一个匹配器。含 `/` 的 glob 匹配相对路径（`*` 不跨层），否则只匹配文件名。
fn build_matcher(pattern: &str) -> Result<GlobMatcher, String> {
    let match_path = pattern.contains('/');

    GlobBuilder::new(pattern)
        .case_insensitive(true)
        .literal_separator(match_path)
        .backslash_escape(true)
        .build()
        .map(|glob| glob.compile_matcher())
        .map_err(|err| err.to_string())
}

struct Hit {
    relative: String,
    size: u64,
}

struct Hits {
    items: Vec<Hit>,
    truncated: bool,
}

fn collect(
    root: &Path,
    base: &Path,
    matcher: &GlobMatcher,
    pattern: &str,
    limit: usize,
    include_hidden: bool,
) -> Hits {
    let match_path = pattern.contains('/');
    let mut items: Vec<Hit> = Vec::new();
    let mut truncated = false;

    walk_files(base, include_hidden, true, |path| {
        let relative = relative_to(root, path);
        let candidate = if match_path {
            relative_to(base, path)
        } else {
            path.file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_default()
        };

        if !matcher.is_match(&candidate) {
            return true;
        }

        let size = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
        items.push(Hit { relative, size });

        if items.len() >= limit {
            // 到上限就停：再走下去只是白扫目录，结果也会被截断。
            truncated = true;
            return false;
        }
        true
    });

    items.sort_by(|left, right| left.relative.cmp(&right.relative));
    Hits { items, truncated }
}

fn render(hits: &Hits, pattern: &str, scope: &str) -> String {
    if hits.items.is_empty() {
        let place = if scope.is_empty() {
            "项目".to_string()
        } else {
            format!("{scope}/")
        };
        return format!(
            "在 {place} 里没有找到匹配 {pattern} 的文件。\n\
             可以换个更宽的 glob（例如只写扩展名 *.rs），或确认目录是否正确。"
        );
    }

    let mut text = format!("匹配 {pattern} 的文件（{} 个）：\n", hits.items.len());
    for hit in &hits.items {
        text.push_str(&format!("{} ({})\n", hit.relative, format_size(hit.size)));
    }

    if hits.truncated {
        text.push_str("（结果已截断，可能还有更多：请缩小 path 或把 pattern 写具体）\n");
    }
    text.push_str("找到文件后用 read_file 读内容；要找文件里的文本请用 search_content。");

    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("pa-search-file-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src").join("api")).expect("建目录失败");
        std::fs::create_dir_all(dir.join("node_modules").join("pkg")).expect("建目录失败");
        std::fs::write(dir.join("README.md"), "readme").expect("写文件失败");
        std::fs::write(dir.join("src").join("main.rs"), "fn main() {}").expect("写文件失败");
        std::fs::write(dir.join("src").join("api").join("mod.rs"), "pub mod x;")
            .expect("写文件失败");
        std::fs::write(
            dir.join("node_modules").join("pkg").join("index.js"),
            "module.exports = {}",
        )
        .expect("写文件失败");
        dir.canonicalize().expect("规范化失败")
    }

    #[test]
    fn extension_pattern_matches_all_levels() {
        let root = temp_root("ext");
        let matcher = build_matcher("*.rs").expect("glob 应合法");
        let hits = collect(&root, &root, &matcher, "*.rs", 50, false);

        let names: Vec<&str> = hits.items.iter().map(|hit| hit.relative.as_str()).collect();
        assert_eq!(names, vec!["src/api/mod.rs", "src/main.rs"]);
        assert!(!hits.truncated);
    }

    #[test]
    fn path_pattern_respects_separator() {
        let root = temp_root("path");
        let matcher = build_matcher("src/*.rs").expect("glob 应合法");
        let hits = collect(&root, &root, &matcher, "src/*.rs", 50, false);

        let names: Vec<&str> = hits.items.iter().map(|hit| hit.relative.as_str()).collect();
        assert_eq!(names, vec!["src/main.rs"], "* 不应跨目录");
    }

    #[test]
    fn skips_dependency_noise_and_caps_results() {
        let root = temp_root("cap");
        let matcher = build_matcher("*.js").expect("glob 应合法");

        // 没有 .gitignore 也要跳过 node_modules：它是依赖目录，不是项目代码。
        let hits = collect(&root, &root, &matcher, "*.js", 50, false);
        assert!(
            hits.items.is_empty(),
            "node_modules 必须被跳过: {:?}",
            hits.items
                .iter()
                .map(|hit| &hit.relative)
                .collect::<Vec<_>>()
        );

        let matcher = build_matcher("*.rs").expect("glob 应合法");
        let hits = collect(&root, &root, &matcher, "*.rs", 1, false);
        assert_eq!(hits.items.len(), 1);
        assert!(hits.truncated, "到上限必须标记截断");
    }

    #[test]
    fn renders_empty_with_next_step() {
        let hits = Hits {
            items: Vec::new(),
            truncated: false,
        };
        let text = render(&hits, "*.kt", "");
        assert!(text.contains("没有找到"), "{text}");
        assert!(text.contains("换个更宽的 glob"), "{text}");
    }
}
