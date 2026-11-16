//! `search_content`：按正则搜文件内容。
//!
//! 不调外部 `rg`：Windows 上不一定装得到，进程超时与 `--json` 解析也都要自己管。
//! 用 `ignore` 遍历 + `regex` 逐行匹配，能力覆盖需求且没有外部依赖。
//!
//! 三个上限同时生效：命中条数、单行字符数、总回填字符数。搜索类工具最常见的
//! 失败不是搜不到，而是搜到太多、把整轮上下文挤爆。

use std::path::Path;
use std::time::Duration;

use globset::{GlobBuilder, GlobMatcher};
use regex::{Regex, RegexBuilder};

use crate::chat::{LocalTool, LocalToolOutcome, ToolSpec};
use crate::local_tools::path_guard::ProjectRoot;
use crate::local_tools::{
    fail, refused, relative_to, truncate_line, walk_files, MAX_SCAN_FILE_BYTES, MAX_SEARCH_CHARS,
};

const SEARCH_TIMEOUT: Duration = Duration::from_secs(10);

const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 100;

/// 正则长度上限。超长模式基本都是把整段文本当查询塞进来。
const MAX_PATTERN_CHARS: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OutputMode {
    Content,
    Files,
    Count,
}

impl OutputMode {
    fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "files" => Self::Files,
            "count" => Self::Count,
            _ => Self::Content,
        }
    }
}

#[derive(Debug)]
pub(crate) struct SearchContentTool {
    root: ProjectRoot,
}

impl SearchContentTool {
    pub(crate) fn new(root: ProjectRoot) -> Self {
        Self { root }
    }
}

#[async_trait::async_trait]
impl LocalTool for SearchContentTool {
    fn spec(&self) -> ToolSpec {
        ToolSpec::search_content()
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let args = match parse(arguments) {
            Ok(args) => args,
            Err(reason) => {
                return fail(
                    format!("参数不合法：{reason}。pattern 是正则，例如 fn\\s+main。"),
                    "search_content:invalid".to_string(),
                );
            }
        };

        let regex = match build_regex(&args.pattern, args.case_sensitive) {
            Ok(regex) => regex,
            Err(reason) => {
                return fail(
                    format!("正则写法不对：{reason}。可以先写最简单的关键词再逐步收紧。"),
                    "search_content:invalid".to_string(),
                );
            }
        };

        let glob = match args.glob.as_deref().map(build_glob).transpose() {
            Ok(glob) => glob,
            Err(reason) => {
                return fail(
                    format!("glob 写法不对：{reason}。例如 *.rs。"),
                    "search_content:invalid".to_string(),
                );
            }
        };

        let base = match self.root.dir(&args.path) {
            Ok(path) => path,
            Err(err) => return refused(&err, "search_content:denied"),
        };

        let root = self.root.root().to_path_buf();
        let scope = self.root.relative(&base);
        let limit = args.limit;
        let context = args.context_lines;
        let mode = args.output_mode;
        let respect_gitignore = args.respect_gitignore;
        let pattern_label = args.pattern.clone();

        let joined = tokio::time::timeout(
            SEARCH_TIMEOUT,
            tokio::task::spawn_blocking(move || {
                collect(
                    &root,
                    &base,
                    &regex,
                    glob.as_ref(),
                    limit,
                    context,
                    mode,
                    respect_gitignore,
                )
            }),
        )
        .await;

        let found = match joined {
            Ok(Ok(found)) => found,
            Ok(Err(err)) => {
                tracing::warn!(%err, "内容搜索线程失败");
                return fail(
                    "搜索失败（执行线程异常），请缩小范围后重试。".to_string(),
                    "search_content:failed".to_string(),
                );
            }
            Err(_) => {
                return fail(
                    format!(
                        "搜索超时（超过 {} 秒）。请缩小 path 范围、加 glob 限定后缀，或把正则写得更具体。",
                        SEARCH_TIMEOUT.as_secs()
                    ),
                    "search_content:timeout".to_string(),
                );
            }
        };

        let content = render(&found, &pattern_label, &scope, mode, context);
        let ok = found.hit_total > 0;

        LocalToolOutcome {
            content,
            sources: Vec::new(),
            ok,
            // 审计只记模式与条数：正则原文可能含用户数据。
            target: format!(
                "search:{}:mode={}:hits={}",
                pattern_label.chars().count(),
                match mode {
                    OutputMode::Content => "content",
                    OutputMode::Files => "files",
                    OutputMode::Count => "count",
                },
                found.hit_total
            ),
            ui: Vec::new(),
        }
    }
}

struct Args {
    pattern: String,
    path: String,
    glob: Option<String>,
    context_lines: usize,
    output_mode: OutputMode,
    case_sensitive: bool,
    respect_gitignore: bool,
    limit: usize,
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

    if pattern.chars().count() > MAX_PATTERN_CHARS {
        return Err(format!("pattern 超过 {MAX_PATTERN_CHARS} 字符"));
    }

    let glob = value["glob"]
        .as_str()
        .map(str::trim)
        .filter(|glob| !glob.is_empty())
        .map(str::to_string);

    Ok(Args {
        pattern,
        path: value["path"]
            .as_str()
            .map(str::trim)
            .unwrap_or_default()
            .to_string(),
        glob,
        context_lines: value["context_lines"].as_u64().unwrap_or(0).clamp(0, 3) as usize,
        output_mode: OutputMode::parse(value["output_mode"].as_str().unwrap_or("content")),
        case_sensitive: value["case_sensitive"].as_bool().unwrap_or(false),
        respect_gitignore: value["respect_gitignore"].as_bool().unwrap_or(true),
        limit: value["limit"]
            .as_u64()
            .unwrap_or(DEFAULT_LIMIT as u64)
            .clamp(1, MAX_LIMIT as u64) as usize,
    })
}

fn build_regex(pattern: &str, case_sensitive: bool) -> Result<Regex, String> {
    RegexBuilder::new(pattern)
        .case_insensitive(!case_sensitive)
        // 内容搜索通常是"某一行里有没有"，让 `.` 跨行只会带来意外。
        .dot_matches_new_line(false)
        .size_limit(4 * 1024 * 1024)
        .build()
        .map_err(|err| err.to_string())
}

/// glob 过滤：连同"匹配文件名还是相对路径"一起带上。
///
/// 分开存是因为 `GlobMatcher` 不暴露 pattern 是否含 `/`，而这两种口径的
/// 匹配对象完全不同（文件名 vs 相对路径）。
struct GlobFilter {
    matcher: GlobMatcher,
    match_path: bool,
}

fn build_glob(pattern: &str) -> Result<GlobFilter, String> {
    let match_path = pattern.contains('/');
    GlobBuilder::new(pattern)
        .case_insensitive(true)
        .literal_separator(match_path)
        .build()
        .map(|glob| GlobFilter {
            matcher: glob.compile_matcher(),
            match_path,
        })
        .map_err(|err| err.to_string())
}

/// 一个文件里的命中。
struct FileHits {
    relative: String,
    /// 命中行的行号（1-based）。
    lines: Vec<usize>,
    /// 正文切片，`text[0]` 对应第 `first_line` 行。
    text: Vec<String>,
    first_line: usize,
}

struct Found {
    files: Vec<FileHits>,
    hit_total: usize,
    truncated: bool,
    skipped_large: usize,
}

#[allow(clippy::too_many_arguments)]
fn collect(
    root: &Path,
    base: &Path,
    regex: &Regex,
    glob: Option<&GlobFilter>,
    limit: usize,
    context: usize,
    mode: OutputMode,
    respect_gitignore: bool,
) -> Found {
    let mut files: Vec<FileHits> = Vec::new();
    let mut hit_total = 0usize;
    let mut truncated = false;
    let mut skipped_large = 0usize;

    walk_files(base, false, respect_gitignore, |path| {
        if let Some(filter) = glob {
            if !matches_glob(base, path, filter) {
                return true;
            }
        }

        let size = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
        if size > MAX_SCAN_FILE_BYTES {
            skipped_large += 1;
            return true;
        }

        let Ok(bytes) = std::fs::read(path) else {
            return true;
        };
        if bytes.contains(&0) {
            return true;
        }
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return true;
        };

        let lines: Vec<&str> = text.lines().collect();
        let mut hits: Vec<usize> = Vec::new();
        for (index, line) in lines.iter().enumerate() {
            if regex.is_match(line) {
                hits.push(index + 1);
            }
        }
        if hits.is_empty() {
            return true;
        }

        let relative = relative_to(root, path);
        hit_total += hits.len();

        match mode {
            OutputMode::Content => {
                // 只保留当前文件需要的上下文范围，避免把整文件都留在内存里。
                let first_line = hits
                    .iter()
                    .min()
                    .copied()
                    .unwrap_or(1)
                    .saturating_sub(context)
                    .max(1);
                let last_line = hits.iter().max().copied().unwrap_or(1) + context;
                let slice: Vec<String> = lines
                    .iter()
                    .enumerate()
                    .filter(|(index, _)| {
                        let line_no = index + 1;
                        line_no >= first_line && line_no <= last_line
                    })
                    .map(|(_, line)| line.to_string())
                    .collect();

                files.push(FileHits {
                    relative,
                    lines: hits,
                    text: slice,
                    first_line,
                });

                if hit_total >= limit {
                    truncated = true;
                    return false;
                }
            }
            OutputMode::Files | OutputMode::Count => {
                files.push(FileHits {
                    relative,
                    lines: hits,
                    text: Vec::new(),
                    first_line: 1,
                });

                // 到上限就停；还有没有别的文件未知，所以标截断。
                if files.len() >= limit {
                    truncated = true;
                    return false;
                }
            }
        }

        true
    });

    files.sort_by(|left, right| left.relative.cmp(&right.relative));

    Found {
        files,
        hit_total,
        truncated,
        skipped_large,
    }
}

fn matches_glob(base: &Path, path: &Path, filter: &GlobFilter) -> bool {
    // 与 `search_file` 同一口径：不带 `/` 的 glob 匹配文件名，带 `/` 的匹配相对路径。
    let candidate = if filter.match_path {
        relative_to(base, path)
    } else {
        path.file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default()
    };
    filter.matcher.is_match(candidate)
}

fn render(found: &Found, pattern: &str, scope: &str, mode: OutputMode, context: usize) -> String {
    if found.files.is_empty() {
        let place = if scope.is_empty() {
            "项目".to_string()
        } else {
            format!("{scope}/")
        };
        let mut text = format!(
            "在 {place} 里没有找到匹配 /{pattern}/ 的内容。\n\
             可以放宽正则（去掉锚点与分组）、确认 path 是否正确，\
             或者把 respect_gitignore 设为 false 再试一次。"
        );
        if found.skipped_large > 0 {
            text.push_str(&format!(
                "\n另有 {} 个超过 {} 的文件未参与搜索。",
                found.skipped_large,
                crate::local_tools::format_size(MAX_SCAN_FILE_BYTES)
            ));
        }
        return text;
    }

    let mut text = String::new();
    let mut budget = MAX_SEARCH_CHARS;
    let mut truncated = found.truncated;

    match mode {
        OutputMode::Content => {
            text.push_str(&format!(
                "匹配 /{pattern}/ 的行（{} 处，{} 个文件）：\n",
                found.hit_total,
                found.files.len()
            ));

            'files: for file in &found.files {
                for line_no in &file.lines {
                    // `text` 是切片，下标相对切片首行而不是文件首行。
                    let Some(index) = line_no.checked_sub(file.first_line) else {
                        continue;
                    };
                    let line = file.text.get(index).map(String::as_str).unwrap_or("");

                    if context > 0 {
                        for offset in 1..=context {
                            if let Some(prev) = index.checked_sub(offset) {
                                let value = format!(
                                    "{}:{}- {}\n",
                                    file.relative,
                                    line_no - offset,
                                    truncate_line(
                                        file.text.get(prev).map(String::as_str).unwrap_or("")
                                    )
                                );
                                budget = match spend(budget, &value) {
                                    Some(left) => left,
                                    None => {
                                        truncated = true;
                                        break 'files;
                                    }
                                };
                                text.push_str(&value);
                            }
                        }
                    }

                    let value = format!("{}:{}: {}\n", file.relative, line_no, truncate_line(line));
                    budget = match spend(budget, &value) {
                        Some(left) => left,
                        None => {
                            truncated = true;
                            break 'files;
                        }
                    };
                    text.push_str(&value);

                    if context > 0 {
                        for offset in 1..=context {
                            let next = index + offset;
                            if let Some(value) = file.text.get(next) {
                                let piece = format!(
                                    "{}:{}+ {}\n",
                                    file.relative,
                                    line_no + offset,
                                    truncate_line(value)
                                );
                                budget = match spend(budget, &piece) {
                                    Some(left) => left,
                                    None => {
                                        truncated = true;
                                        break 'files;
                                    }
                                };
                                text.push_str(&piece);
                            }
                        }
                    }
                }
            }
        }
        OutputMode::Files => {
            text.push_str(&format!(
                "包含 /{pattern}/ 的文件（{} 个）：\n",
                found.files.len()
            ));
            for file in &found.files {
                let value = format!("{}（{} 处）\n", file.relative, file.lines.len());
                budget = match spend(budget, &value) {
                    Some(left) => left,
                    None => {
                        truncated = true;
                        break;
                    }
                };
                text.push_str(&value);
            }
        }
        OutputMode::Count => {
            text.push_str(&format!(
                "包含 /{pattern}/ 的文件（{} 个）命中行数：\n",
                found.files.len()
            ));
            for file in &found.files {
                let value = format!("{}: {}\n", file.relative, file.lines.len());
                budget = match spend(budget, &value) {
                    Some(left) => left,
                    None => {
                        truncated = true;
                        break;
                    }
                };
                text.push_str(&value);
            }
        }
    }

    if truncated {
        text.push_str("（结果已截断：请缩小 path/glob 范围，或把正则写具体）\n");
    }
    if found.skipped_large > 0 {
        text.push_str(&format!(
            "（另有 {} 个超过 {} 的文件未参与搜索）\n",
            found.skipped_large,
            crate::local_tools::format_size(MAX_SCAN_FILE_BYTES)
        ));
    }
    text.push_str("定位到行之后用 read_file 读上下文（传 offset 与 limit）。");

    text
}

/// 扣预算：不够时返回 `None`，调用方据此停止并标记截断。
fn spend(budget: usize, piece: &str) -> Option<usize> {
    let cost = piece.chars().count();
    budget.checked_sub(cost)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("pa-search-content-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).expect("建目录失败");
        std::fs::write(
            dir.join("src").join("main.rs"),
            "fn main() {\n    // TODO: 收尾\n    run();\n}\n",
        )
        .expect("写文件失败");
        std::fs::write(dir.join("src").join("lib.rs"), "pub fn run() {}\n").expect("写文件失败");
        std::fs::write(dir.join("README.md"), "todo list\n").expect("写文件失败");
        dir.canonicalize().expect("规范化失败")
    }

    #[test]
    fn finds_case_insensitive_by_default() {
        let root = temp_root("ci");
        let regex = build_regex("todo", false).expect("正则应合法");
        let found = collect(&root, &root, &regex, None, 50, 0, OutputMode::Content, true);

        assert_eq!(found.hit_total, 2, "main.rs 与 README 各一处");
        let text = render(&found, "todo", "", OutputMode::Content, 0);
        assert!(text.contains("src/main.rs:2:"), "{text}");
        assert!(text.contains("README.md:1:"), "{text}");
    }

    #[test]
    fn case_sensitive_and_glob_filter() {
        let root = temp_root("glob");
        let regex = build_regex("TODO", true).expect("正则应合法");
        let glob = build_glob("*.rs").expect("glob 应合法");
        let found = collect(
            &root,
            &root,
            &regex,
            Some(&glob),
            50,
            0,
            OutputMode::Content,
            true,
        );

        assert_eq!(found.hit_total, 1, "只有 main.rs 里的大写 TODO");
    }

    #[test]
    fn context_lines_are_rendered() {
        let root = temp_root("context");
        let regex = build_regex("TODO", true).expect("正则应合法");
        let found = collect(&root, &root, &regex, None, 50, 1, OutputMode::Content, true);

        let text = render(&found, "TODO", "", OutputMode::Content, 1);
        assert!(text.contains("src/main.rs:1- fn main() {"), "{text}");
        assert!(text.contains("src/main.rs:3+     run();"), "{text}");
    }

    #[test]
    fn files_and_count_modes() {
        let root = temp_root("modes");
        let regex = build_regex("fn", false).expect("正则应合法");

        let found = collect(&root, &root, &regex, None, 50, 0, OutputMode::Files, true);
        let text = render(&found, "fn", "", OutputMode::Files, 0);
        assert!(text.contains("src/main.rs（1 处）"), "{text}");
        assert!(text.contains("src/lib.rs（1 处）"), "{text}");

        let found = collect(&root, &root, &regex, None, 50, 0, OutputMode::Count, true);
        let text = render(&found, "fn", "", OutputMode::Count, 0);
        assert!(text.contains("src/main.rs: 1"), "{text}");
    }

    #[test]
    fn respects_limit_and_marks_truncated() {
        let root = temp_root("limit");
        let regex = build_regex("fn", false).expect("正则应合法");
        let found = collect(&root, &root, &regex, None, 1, 0, OutputMode::Content, true);

        assert_eq!(found.hit_total, 1);
        assert!(found.truncated, "到上限必须标记截断");
    }

    #[test]
    fn rejects_bad_regex_with_reason() {
        let error = build_regex("([a-", false).expect_err("非法正则应报错");
        assert!(!error.is_empty());
    }

    #[test]
    fn skips_binary_and_large_files() {
        let root = temp_root("skip");
        std::fs::write(root.join("blob.bin"), [0xFFu8, 0x00, 0x01]).expect("写文件失败");
        let regex = build_regex("fn", false).expect("正则应合法");
        let found = collect(&root, &root, &regex, None, 50, 0, OutputMode::Content, true);

        assert!(
            found
                .files
                .iter()
                .all(|file| !file.relative.ends_with(".bin")),
            "二进制文件不应参与"
        );
    }
}
