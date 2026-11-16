//! 项目文件浏览：客户端右侧栏文件树与文本预览的数据来源。
//!
//! 与 [`crate::fs_browse`] 是两个场景，边界不能混用：
//!
//! - `fs_browse` 服务「选项目目录」，边界是配置里的浏览根，只列目录；
//! - 这里服务「浏览已建项目」，边界是该项目自己的根目录，目录与文件都列。
//!
//! 只读、无副作用，因此不写审计：文件树每展开一层都记一条，只会把 `audit_log`
//! 变成浏览历史，反而埋掉真正的写操作。
//!
//! 安全边界与 `fs_browse` 同一套思路：请求路径必须绝对、规范化后落在项目根内；
//! 每个软链接条目再规范化一次并复核包含关系，借链接跳出项目的条目直接不展示。

use std::io::Read;
use std::path::{Path, PathBuf};

use protocol::{ProjectEntry, ProjectEntryKind, ProjectFileContent, ProjectListing};

use crate::project::ProjectError;

/// 单层返回的条目上限。个人项目通常远小于这个数，超出说明该用搜索。
const MAX_ENTRIES: usize = 200;

/// 单层扫描上限：超过它就不再读，避免一个塞了十万文件的目录把请求拖死。
const MAX_SCAN: usize = MAX_ENTRIES * 10;

/// 单次返回的文本上限（字节）。客户端预览不是编辑器，512 KB 足够看一屏上下文。
const MAX_FILE_BYTES: usize = 512 * 1024;

/// 列出一层目录（含文件）。
///
/// `root` 是项目记录里的绝对路径；`raw` 为空时从项目根开始。
/// 返回值里的 `path` 是规范化后的真实路径，客户端下游请求直接回传它。
pub fn list(
    root: &str,
    raw: Option<&str>,
    show_hidden: bool,
) -> Result<ProjectListing, ProjectError> {
    let root = canonical_root(root)?;

    let path = match raw.map(str::trim).filter(|raw| !raw.is_empty()) {
        Some(raw) => canonical_dir(&root, raw)?,
        None => root.clone(),
    };

    if !path.starts_with(&root) {
        return Err(denied(&path, &root));
    }

    let (entries, truncated) = collect(&path, &root, show_hidden)?;

    Ok(ProjectListing {
        path: path.to_string_lossy().to_string(),
        entries,
        truncated,
    })
}

/// 读取一个文本文件。
///
/// 超过 [`MAX_FILE_BYTES`] 时按 UTF-8 字符边界截断；含 NUL 或非法 UTF-8 的文件
/// 视为二进制，返回带可展示提示的 [`ProjectError::Invalid`]——客户端预览区
/// 直接显示这句话，比给出半截乱码有用。
pub fn read_text(root: &str, raw: &str) -> Result<ProjectFileContent, ProjectError> {
    let root = canonical_root(root)?;
    let path = canonical_file(&root, raw)?;

    let size = std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);

    let file = std::fs::File::open(&path)
        .map_err(|err| ProjectError::Invalid(format!("文件不可读（{}）：{err}", path.display())))?;

    // 只读上限 + 1 字节：多读这一个字节就能区分「刚好到上限」与「还有更多」，
    // 不必先把整个大文件塞进内存。
    let mut buffer = Vec::new();
    file.take((MAX_FILE_BYTES + 1) as u64)
        .read_to_end(&mut buffer)
        .map_err(|err| {
            ProjectError::Invalid(format!("读取文件失败（{}）：{err}", path.display()))
        })?;

    let truncated = buffer.len() > MAX_FILE_BYTES;
    let cut = buffer.len().min(MAX_FILE_BYTES);
    let text = decode(&buffer[..cut], truncated, &path)?;

    Ok(ProjectFileContent {
        path: path.to_string_lossy().to_string(),
        size,
        text,
        truncated,
    })
}

/// 内置查看器（图片 / PDF）的单文件上限。
///
/// 64 MB 是按「手机上能整份放进内存、且覆盖常见扫描版 PDF」取的折中：
/// 客户端拿到字节后还要交给解码器/PDFium 再占一份，超了就该另存到本机
/// 用系统应用打开，而不是在这里赌一次 OOM。
pub const MAX_RAW_BYTES: u64 = 64 * 1024 * 1024;

/// 一次原始字节读取的准入结果。
///
/// 只带路径、大小与 MIME，**不带字节**：响应由 handler 流式写出，
/// 服务端没必要为了转发再整份读进内存（参考 `web_preview::files`）。
#[derive(Debug, Clone)]
pub struct RawFile {
    pub path: PathBuf,
    pub size: u64,
    pub mime: &'static str,
}

/// 读取一个文件的原始字节准入信息（图片 / PDF）。
///
/// 与 [`read_text`] 并存而不是合并：那边是「文本预览」，有 512 KB 截断与
/// UTF-8/NUL 校验；这里是「二进制查看器」，要求完整字节与真实 MIME。
/// 两条语义混进一个端点，迟早会出现「PDF 被截断成半个文件」这种事。
///
/// 准入沿用同一套 canonical 边界（`canonicalize + starts_with`），
/// 但**不**加 `ProjectRoot` 的密钥文件名拦截：那条规则服务的是模型无人监督
/// 读取，这里是用户自己在文件树里点开。
pub fn open_raw(root: &str, raw: &str) -> Result<RawFile, ProjectError> {
    let file = resolve_raw(root, raw)?;

    if file.size > MAX_RAW_BYTES {
        return Err(ProjectError::Invalid(format!(
            "文件大小 {} MB，超过内置查看器上限 {} MB，请先另存到本机再用系统应用打开",
            file.size / (1024 * 1024),
            MAX_RAW_BYTES / (1024 * 1024)
        )));
    }

    Ok(file)
}

/// 与 [`open_raw`] 同一套准入，但**不设大小上限**。
///
/// 只服务「另存为 / 系统分享」：上限的本意是拦住"把大文件塞进查看器内存"，
/// 而导出本来就是用户明确要落盘的动作——超过上限就看不到、也存不下来，
/// 用户只会以为服务端坏了。响应是流式的，服务端不会因此多占内存。
pub fn open_raw_for_download(root: &str, raw: &str) -> Result<RawFile, ProjectError> {
    resolve_raw(root, raw)
}

fn resolve_raw(root: &str, raw: &str) -> Result<RawFile, ProjectError> {
    let root = canonical_root(root)?;
    let path = canonical_file(&root, raw)?;
    let size = std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);

    Ok(RawFile {
        mime: raw_mime(&path),
        path,
        size,
    })
}

/// 原始字节响应的 MIME。
///
/// 与 `web_preview::mime` **刻意分开**：那份的语义是「网页能引到的资源」，
/// 把 pdf 放进去等于顺手扩大浏览器面板的暴露面，是另一个决策。
/// 这里只认内置查看器真正渲染的类型，其余一律 `application/octet-stream`
/// （客户端按扩展名路由时就已决定要不要打开，不会再拿它猜类型）。
fn raw_mime(path: &Path) -> &'static str {
    match path
        .extension()
        .map(|ext| ext.to_string_lossy().to_ascii_lowercase())
        .as_deref()
    {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        Some("pdf") => "application/pdf",
        _ => "application/octet-stream",
    }
}

fn canonical_root(root: &str) -> Result<PathBuf, ProjectError> {
    let path = PathBuf::from(root)
        .canonicalize()
        .map_err(|err| ProjectError::Invalid(format!("项目目录不可访问（{root}）：{err}")))?;

    if !path.is_dir() {
        return Err(ProjectError::Invalid(format!(
            "项目目录已不是目录（{}）",
            path.display()
        )));
    }
    Ok(path)
}

fn canonical_dir(root: &Path, raw: &str) -> Result<PathBuf, ProjectError> {
    let path = canonical_within(root, raw)?;
    if !path.is_dir() {
        return Err(ProjectError::Invalid(format!(
            "{} 不是目录",
            path.display()
        )));
    }
    Ok(path)
}

fn canonical_file(root: &Path, raw: &str) -> Result<PathBuf, ProjectError> {
    let path = canonical_within(root, raw)?;
    if !path.is_file() {
        return Err(ProjectError::Invalid(format!(
            "{} 不是文件",
            path.display()
        )));
    }
    Ok(path)
}

/// 规范化一个路径并复核它仍在 `root` 内。
///
/// 抽出这一层是因为文件工具（`local_tools`）要用同一套规则解析模型给的路径：
/// 复制一份 `canonicalize + starts_with` 就等于有两个边界，迟早会不一致。
///
/// 相对路径按 [root] 解析：文件树的调用方给的是绝对路径，而会话产物卡只
/// 知道"项目内相对路径"（`write_file` 回执里的 `path` 就是这一种），
/// 让它为了打开一个文件先去问一次项目目录没有意义。越界仍然由
/// `canonicalize + starts_with` 收掉——`../../etc/passwd` 拼到根上之后
/// 照样落在根外。
pub(crate) fn canonical_within(root: &Path, raw: &str) -> Result<PathBuf, ProjectError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(ProjectError::Invalid("缺少文件路径".to_string()));
    }

    let candidate = PathBuf::from(raw);
    let candidate = if candidate.is_absolute() {
        candidate
    } else {
        root.join(candidate)
    };

    let path = candidate.canonicalize().map_err(|err| {
        ProjectError::Invalid(format!("路径不可访问（{}）：{err}", candidate.display()))
    })?;

    if !path.starts_with(root) {
        return Err(denied(&path, root));
    }
    Ok(path)
}

/// 一次按行读取的结果。
///
/// `text` 已经带 `行号| ` 前缀：模型引用代码时要能说清"第几行"，
/// 让它在回填里自己数行号是难为它。
#[derive(Debug, Clone)]
pub struct FileSlice {
    /// 带行号前缀的正文。
    pub text: String,
    pub start_line: usize,
    /// 最后一行（含）。从 `offset` 开始但文件更短时，等于实际总行数。
    pub end_line: usize,
    /// 文件总行数。因为行数上限提前收手时为 `None`（不为了报个数再扫一遍）。
    pub total_lines: Option<usize>,
    /// 是否还有没读进来的内容。
    pub truncated: bool,
}

/// 单行最多保留多少字符。压缩后的 JS 一行能有几十万字符，不截断会顶掉整段预算。
pub const MAX_LINE_CHARS: usize = 400;

/// 一次回填的正文上限（字符）。约 48k token，够装下一份八百多行的页面。
///
/// 取值是"实测撞到过的最大页面"：882 行的 `hourglass.html` 在 32 KiB 处被截断，
/// 模型读到的是一份残缺文件，最后既没有续读也没有动手，只回了一句
/// "读取类工具已经用尽"——实际额度还剩 95 次。截断对模型的影响不是"多读一次"，
/// 而是它会直接判定这件事做不成。
///
/// 再往上加就要权衡上下文：一份 96 KiB 的文件会挤掉大半个窗口。
pub const MAX_SLICE_CHARS: usize = 48 * 1024;

/// 跳过的字节上限：`offset` 给得很大时，不能为了跳过而把几百 MB 读一遍。
const MAX_SKIP_BYTES: u64 = 8 * 1024 * 1024;

/// 为统计总行数最多再读多少字节。超过就报"未知"，不为一个数字读完整文件。
const MAX_COUNT_REST_BYTES: u64 = 1024 * 1024;

/// 按行读取一个文本文件。
///
/// `offset` 是 1-based 行号，`limit` 是行数。三个上限同时生效：行数、单行字符数、
/// 总字符数——三者任一触发都把 `truncated` 置位，让模型知道该换 `offset` 而不是重试。
pub fn read_lines(
    root: &str,
    raw: &str,
    offset: usize,
    limit: usize,
) -> Result<FileSlice, ProjectError> {
    let root = canonical_root(root)?;
    let path = canonical_file(&root, raw)?;

    let file = std::fs::File::open(&path)
        .map_err(|err| ProjectError::Invalid(format!("文件不可读（{}）：{err}", path.display())))?;
    let mut reader = std::io::BufReader::new(file);
    let mut buf = Vec::new();
    let mut line_no = 0usize;
    let mut skipped = 0u64;
    let mut text = String::new();
    let mut chars = 0usize;
    let mut read = 0usize;
    let mut truncated = false;
    // 每个 break 点都会重新赋值；初始的 `None` 只在"读到末尾"那条路径上有意义，
    // 而那条路径自己会写成 `Some`，所以这里允许"赋值后未被读"。
    #[allow(unused_assignments)]
    let mut total_lines = None;
    let offset = offset.max(1);

    loop {
        buf.clear();
        let bytes = std::io::BufRead::read_until(&mut reader, b'\n', &mut buf)
            .map_err(|err| ProjectError::Invalid(format!("读取文件失败：{err}")))?;

        if bytes == 0 {
            total_lines = Some(line_no);
            break;
        }

        line_no += 1;

        // 二进制：文本文件里不该出现 NUL。先判再跳，跳过区里也可能有。
        if buf.contains(&0) {
            return Err(binary(&path));
        }

        if line_no < offset {
            skipped = skipped.saturating_add(bytes as u64);
            if skipped > MAX_SKIP_BYTES {
                return Err(ProjectError::Invalid(format!(
                    "起始行 {} 太靠后（已跳过超过 {} MB），请改用 search_content 定位",
                    offset,
                    MAX_SKIP_BYTES / (1024 * 1024)
                )));
            }
            continue;
        }

        if read >= limit {
            truncated = true;
            // 顺带把剩余行数数出来：模型要靠"共 N 行"决定怎么续读。
            // 只在剩余部分不大时做，否则宁可报"未知"也不为一行数字读完整文件。
            total_lines = count_rest(&mut reader, line_no, &buf);
            break;
        }

        let line = match std::str::from_utf8(strip_eol(&buf)) {
            Ok(line) => line,
            Err(_) => return Err(binary(&path)),
        };

        let mut piece = format!("{:>5}| {line}", line_no);
        if let Some(trimmed) = truncate_line(line) {
            piece = format!("{:>5}| {trimmed}", line_no);
        }
        // `\n` 也算进预算：否则一行刚好卡在上限时下一行会溢出。
        let cost = piece.chars().count() + 1;
        if chars + cost > MAX_SLICE_CHARS {
            truncated = true;
            // 与行数上限同样的处理：把"还差多少"算出来。
            // 只报"截断了"而不说缺多少，模型容易判定"这份文件读不完"然后停工。
            total_lines = count_rest(&mut reader, line_no, &buf);
            break;
        }

        chars += cost;
        text.push_str(&piece);
        text.push('\n');
        read += 1;
    }

    if read == 0 && total_lines == Some(0) {
        return Ok(FileSlice {
            text: String::new(),
            start_line: offset,
            end_line: offset.saturating_sub(1),
            total_lines,
            truncated: false,
        });
    }

    Ok(FileSlice {
        text,
        start_line: offset,
        end_line: offset + read.saturating_sub(1),
        total_lines,
        truncated,
    })
}

/// 统计"当前行之后还有多少行"，返回文件总行数。
///
/// `current` 是当前这一行的原始字节（已经读出来了，只是没进正文）。
/// 剩余部分超过 [`MAX_COUNT_REST_BYTES`] 时放弃：为报一个数字去读几十 MB 不值。
fn count_rest(
    reader: &mut std::io::BufReader<std::fs::File>,
    current_line: usize,
    current: &[u8],
) -> Option<usize> {
    let mut count = 0usize;
    let mut used = current.len() as u64;
    let mut scratch = Vec::new();

    loop {
        scratch.clear();
        let bytes = std::io::BufRead::read_until(reader, b'\n', &mut scratch).ok()?;
        if bytes == 0 {
            return Some(current_line + count);
        }
        used += bytes as u64;
        if used > MAX_COUNT_REST_BYTES {
            return None;
        }
        count += 1;
    }
}

fn strip_eol(buf: &[u8]) -> &[u8] {
    let mut end = buf.len();
    if end > 0 && buf[end - 1] == b'\n' {
        end -= 1;
    }
    if end > 0 && buf[end - 1] == b'\r' {
        end -= 1;
    }
    &buf[..end]
}

/// 超长行截断，返回 `Some(截断后文本)`；不需要截断时返回 `None`。
///
/// 说明文字也算进 [`MAX_LINE_CHARS`]，否则"刚好超一点"的行会被截得更长。
fn truncate_line(line: &str) -> Option<String> {
    if line.chars().count() <= MAX_LINE_CHARS {
        return None;
    }
    const MARKER: &str = " …（此行过长，已截断）";
    let keep = MAX_LINE_CHARS.saturating_sub(MARKER.chars().count());
    let kept: String = line.chars().take(keep).collect();
    Some(format!("{kept}{MARKER}"))
}

fn denied(path: &Path, root: &Path) -> ProjectError {
    ProjectError::Denied(format!(
        "{} 不在项目目录 {} 内",
        path.display(),
        root.display()
    ))
}

fn binary(path: &Path) -> ProjectError {
    ProjectError::Invalid(format!(
        "{} 是二进制文件（或不是 UTF-8 文本），无法预览",
        path.display()
    ))
}

fn collect(
    path: &Path,
    root: &Path,
    show_hidden: bool,
) -> Result<(Vec<ProjectEntry>, bool), ProjectError> {
    let reader = std::fs::read_dir(path)
        .map_err(|err| ProjectError::Invalid(format!("目录不可读（{}）：{err}", path.display())))?;

    let mut entries: Vec<ProjectEntry> = Vec::new();
    let mut overflow = false;

    for item in reader {
        let Ok(item) = item else { continue };
        if entries.len() >= MAX_SCAN {
            overflow = true;
            break;
        }

        let name = item.file_name().to_string_lossy().to_string();
        // 隐藏项由客户端开关决定；默认不展示 `.git`、`.DS_Store` 这类噪音。
        if !show_hidden && name.starts_with('.') {
            continue;
        }

        let Ok(file_type) = item.file_type() else {
            continue;
        };

        // 只有软链接需要再规范化一次：普通条目继承的已经是规范化父路径，
        // 逐个 canonicalize 会让 200 条目录多出 200 次系统调用。
        let target = if file_type.is_symlink() {
            match item.path().canonicalize() {
                Ok(real) if real.starts_with(root) => real,
                // 越界或悬空的软链接：不展示，否则浏览等于绕过了项目边界。
                _ => continue,
            }
        } else {
            item.path()
        };

        let (kind, size) = if target.is_dir() {
            (ProjectEntryKind::Dir, None)
        } else if target.is_file() {
            let size = target.metadata().ok().map(|meta| meta.len());
            (ProjectEntryKind::File, size)
        } else {
            // FIFO、socket、设备文件：既不能展开也不能预览，直接跳过。
            continue;
        };

        entries.push(ProjectEntry {
            name,
            path: target.to_string_lossy().to_string(),
            kind,
            size,
        });
    }

    // 目录优先，再按名称大小写不敏感升序；完全同名时用原始名称兜底保证稳定。
    entries.sort_by(|left, right| {
        rank(left.kind)
            .cmp(&rank(right.kind))
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
            .then_with(|| left.name.cmp(&right.name))
    });

    let truncated = overflow || entries.len() > MAX_ENTRIES;
    entries.truncate(MAX_ENTRIES);
    Ok((entries, truncated))
}

const fn rank(kind: ProjectEntryKind) -> u8 {
    match kind {
        ProjectEntryKind::Dir => 0,
        ProjectEntryKind::File => 1,
    }
}

/// 把字节解码成可展示文本。
///
/// 唯一容忍的非法 UTF-8 是「我们主动截断时切在多字节字符中间」：
/// 此时无效字节一定落在尾部且不超过 3 个。其余非法序列按二进制处理。
fn decode(bytes: &[u8], truncated: bool, path: &Path) -> Result<String, ProjectError> {
    if bytes.contains(&0) {
        return Err(binary(path));
    }

    match std::str::from_utf8(bytes) {
        Ok(text) => Ok(text.to_string()),
        Err(err) => {
            let valid = err.valid_up_to();
            let invalid_tail = bytes.len() - valid;
            if truncated && invalid_tail < 4 {
                std::str::from_utf8(&bytes[..valid])
                    .map(str::to_string)
                    .map_err(|_| binary(path))
            } else {
                Err(binary(path))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pa-ws-files-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        dir.canonicalize().expect("规范化失败")
    }

    fn root_str(root: &Path) -> String {
        root.to_string_lossy().to_string()
    }

    #[test]
    fn lists_dirs_before_files_and_hides_dot_entries() {
        let root = temp_root("list");
        std::fs::create_dir_all(root.join("src")).expect("建目录失败");
        std::fs::write(root.join("Cargo.toml"), "x").expect("写文件失败");
        std::fs::write(root.join(".gitignore"), "target\n").expect("写隐藏文件失败");

        let listing = list(&root_str(&root), None, false).expect("应成功");
        let names: Vec<&str> = listing.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["src", "Cargo.toml"], "目录优先、隐藏项默认不列");
        assert_eq!(listing.entries[0].kind, ProjectEntryKind::Dir);
        assert!(listing.entries[0].size.is_none(), "目录不带大小");
        assert_eq!(listing.entries[1].kind, ProjectEntryKind::File);
        assert_eq!(listing.entries[1].size, Some(1));
        assert!(!listing.truncated);
        assert_eq!(listing.path, root_str(&root), "根列表返回规范化路径");
    }

    #[test]
    fn show_hidden_includes_dot_entries() {
        let root = temp_root("hidden");
        std::fs::create_dir_all(root.join(".git")).expect("建目录失败");
        std::fs::write(root.join(".gitignore"), "x").expect("写文件失败");

        let listing = list(&root_str(&root), None, true).expect("应成功");
        let names: Vec<&str> = listing.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec![".git", ".gitignore"]);
    }

    #[test]
    fn rejects_path_outside_project() {
        let root = temp_root("outside");
        let err = list(&root_str(&root), Some("/"), false).expect_err("越界必须拒绝");
        assert!(matches!(err, ProjectError::Denied(_)), "{err}");
    }

    /// 相对路径按根解析：会话产物卡只知道 `write_file` 回执里的相对路径。
    #[test]
    fn relative_path_resolves_against_root() {
        let root = temp_root("relative");
        std::fs::create_dir_all(root.join("artifacts")).expect("建目录失败");
        std::fs::write(root.join("artifacts").join("a.png"), b"png").expect("写文件失败");

        let listing = list(&root_str(&root), Some("artifacts"), false).expect("相对路径应可用");
        assert_eq!(listing.entries[0].name, "a.png");

        let raw = open_raw(&root_str(&root), "artifacts/a.png").expect("相对路径取字节应可用");
        assert_eq!(raw.size, 3);
    }

    /// 相对路径不能借此越界：拼到根上之后仍要落在根内。
    #[test]
    fn relative_path_cannot_escape_root() {
        let root = temp_root("relative-escape");
        std::fs::write(root.join("a.txt"), "x").expect("写文件失败");
        let err = list(&root_str(&root), Some("../"), false).expect_err("越界必须拒绝");
        assert!(matches!(err, ProjectError::Denied(_)), "{err}");
    }

    #[test]
    fn subdirectory_uses_returned_path() {
        let root = temp_root("sub");
        std::fs::create_dir_all(root.join("inner")).expect("建目录失败");
        std::fs::write(root.join("inner").join("a.txt"), "hello").expect("写文件失败");

        let first = list(&root_str(&root), None, false).expect("应成功");
        let inner = first.entries[0].path.clone();
        let listing = list(&root_str(&root), Some(&inner), false).expect("应成功");
        assert_eq!(listing.entries[0].name, "a.txt");
        assert_eq!(listing.entries[0].size, Some(5));
    }

    #[test]
    fn reads_utf8_text() {
        let root = temp_root("read");
        let file = root.join("note.md");
        std::fs::write(&file, "hello 世界\n").expect("写文件失败");

        let content = read_text(&root_str(&root), &file.to_string_lossy()).expect("读取应成功");
        assert_eq!(content.text, "hello 世界\n");
        assert_eq!(content.size, 13);
        assert!(!content.truncated);
    }

    #[test]
    fn truncates_large_files_on_char_boundary() {
        let root = temp_root("large");
        let file = root.join("big.txt");
        // 每个汉字 3 字节，上限处必然切在多字节字符中间。
        let body = "界".repeat(MAX_FILE_BYTES);
        std::fs::write(&file, &body).expect("写文件失败");

        let content = read_text(&root_str(&root), &file.to_string_lossy()).expect("读取应成功");
        assert!(content.truncated);
        assert!(content.text.len() <= MAX_FILE_BYTES);
        assert!(
            content.text.chars().all(|ch| ch == '界'),
            "截断不能留下半个字符"
        );
        assert_eq!(content.size, body.len() as u64, "size 是完整文件大小");
    }

    #[test]
    fn rejects_binary_files() {
        let root = temp_root("binary");
        let file = root.join("image.bin");
        std::fs::write(&file, [0xFF, 0xFE, 0x00, 0x01]).expect("写文件失败");

        let err = read_text(&root_str(&root), &file.to_string_lossy()).expect_err("二进制必须拒绝");
        assert!(matches!(err, ProjectError::Invalid(_)), "{err}");
    }

    #[test]
    fn rejects_file_outside_project() {
        let root = temp_root("file-outside");
        let err = read_text(&root_str(&root), "/etc/hosts").expect_err("越界必须拒绝");
        assert!(matches!(err, ProjectError::Denied(_)), "{err}");
    }

    #[test]
    fn read_lines_numbers_and_slices() {
        let root = temp_root("slice");
        let file = root.join("code.rs");
        std::fs::write(&file, "line1\nline2\nline3\nline4\n").expect("写文件失败");

        let slice = read_lines(&root_str(&root), &file.to_string_lossy(), 2, 2).expect("应成功");
        assert_eq!(slice.start_line, 2);
        assert_eq!(slice.end_line, 3);
        assert_eq!(slice.total_lines, Some(4));
        assert!(slice.truncated, "第 4 行还没读，必须标截断");
        assert!(slice.text.contains("    2| line2"), "{}", slice.text);
        assert!(slice.text.contains("    3| line3"), "{}", slice.text);
        assert!(!slice.text.contains("line1"), "{}", slice.text);
    }

    #[test]
    fn read_lines_marks_truncated_when_more_remains() {
        let root = temp_root("slice-more");
        let file = root.join("code.rs");
        let body: String = (1..=10).map(|n| format!("line{n}\n")).collect();
        std::fs::write(&file, body).expect("写文件失败");

        let slice = read_lines(&root_str(&root), &file.to_string_lossy(), 1, 3).expect("应成功");
        assert_eq!(slice.end_line, 3);
        assert!(slice.truncated, "还有第 4 行时必须标截断");
        assert_eq!(
            slice.total_lines,
            Some(10),
            "剩余部分很小时应顺带数出总行数"
        );
    }

    #[test]
    fn read_lines_handles_crlf_and_missing_trailing_newline() {
        let root = temp_root("crlf");
        let file = root.join("code.rs");
        std::fs::write(&file, "a\r\nb").expect("写文件失败");

        let slice = read_lines(&root_str(&root), &file.to_string_lossy(), 1, 10).expect("应成功");
        assert_eq!(slice.total_lines, Some(2));
        assert!(slice.text.contains("    1| a"), "{}", slice.text);
        assert!(
            !slice.text.contains('\r'),
            "回车不应出现在回填里: {:?}",
            slice.text
        );
    }

    #[test]
    fn read_lines_rejects_binary_and_escape() {
        let root = temp_root("slice-binary");
        let binary = root.join("blob.bin");
        std::fs::write(&binary, [0x41, 0x00, 0x42]).expect("写文件失败");

        let err = read_lines(&root_str(&root), &binary.to_string_lossy(), 1, 10)
            .expect_err("二进制必须拒绝");
        assert!(matches!(err, ProjectError::Invalid(_)), "{err}");

        let err = read_lines(&root_str(&root), "/etc/hosts", 1, 10).expect_err("越界必须拒绝");
        assert!(matches!(err, ProjectError::Denied(_)), "{err}");
    }

    #[test]
    fn read_lines_truncates_long_lines_within_budget() {
        let root = temp_root("slice-long");
        let file = root.join("min.js");
        std::fs::write(&file, "x".repeat(MAX_LINE_CHARS * 2)).expect("写文件失败");

        let slice = read_lines(&root_str(&root), &file.to_string_lossy(), 1, 10).expect("应成功");
        assert!(slice.text.contains("已截断"), "{}", slice.text);
        for line in slice.text.lines() {
            assert!(
                line.chars().count() <= MAX_LINE_CHARS + 8,
                "单行超预算: {}",
                line.chars().count()
            );
        }
    }

    #[test]
    fn open_raw_reports_size_and_mime() {
        let root = temp_root("raw");
        let image = root.join("photo.PNG");
        std::fs::write(&image, [0x89, 0x50, 0x4E, 0x47]).expect("写文件失败");

        let raw = open_raw(&root_str(&root), &image.to_string_lossy()).expect("应成功");
        assert_eq!(raw.size, 4);
        assert_eq!(raw.mime, "image/png", "扩展名大小写不该影响 MIME");
        assert_eq!(raw.path, image.canonicalize().expect("规范化失败"));
    }

    #[test]
    fn open_raw_maps_known_types_and_falls_back_to_octet_stream() {
        let root = temp_root("raw-mime");
        for (name, expected) in [
            ("a.pdf", "application/pdf"),
            ("b.jpeg", "image/jpeg"),
            ("c.gif", "image/gif"),
            ("d.webp", "image/webp"),
            ("e.bmp", "image/bmp"),
            ("Makefile", "application/octet-stream"),
            ("x.bin", "application/octet-stream"),
        ] {
            let file = root.join(name);
            std::fs::write(&file, b"x").expect("写文件失败");
            let raw = open_raw(&root_str(&root), &file.to_string_lossy()).expect("应成功");
            assert_eq!(raw.mime, expected, "{name} 的 MIME 不对");
        }
    }

    #[test]
    fn open_raw_rejects_oversized_file_with_visible_hint() {
        let root = temp_root("raw-large");
        let file = root.join("huge.pdf");
        // 稀疏文件：只改元数据，不真的写 64 MB 进磁盘。
        let handle = std::fs::File::create(&file).expect("建文件失败");
        handle.set_len(MAX_RAW_BYTES + 1).expect("设置文件长度失败");
        drop(handle);

        let err = open_raw(&root_str(&root), &file.to_string_lossy()).expect_err("超限必须拒绝");
        let ProjectError::Invalid(hint) = err else {
            panic!("超限应报 Invalid：{err}");
        };
        assert!(hint.contains("另存"), "提示要能直接展示：{hint}");
        assert!(hint.contains("64 MB"), "提示要写明上限：{hint}");
    }

    #[test]
    fn open_raw_for_download_skips_size_cap() {
        let root = temp_root("raw-download");
        let file = root.join("big.pdf");
        let handle = std::fs::File::create(&file).expect("建文件失败");
        handle.set_len(MAX_RAW_BYTES + 1).expect("设置文件长度失败");
        drop(handle);

        // 预览必须拒绝、导出必须能取——两条语义各自成立。
        assert!(open_raw(&root_str(&root), &file.to_string_lossy()).is_err());
        let raw = open_raw_for_download(&root_str(&root), &file.to_string_lossy())
            .expect("导出不该受查看器上限限制");
        assert_eq!(raw.mime, "application/pdf");
        assert!(raw.size > MAX_RAW_BYTES);
    }

    #[test]
    fn open_raw_rejects_directory_and_escape() {
        let root = temp_root("raw-guard");
        std::fs::create_dir_all(root.join("inner")).expect("建目录失败");

        let err = open_raw(&root_str(&root), &root.join("inner").to_string_lossy())
            .expect_err("目录不能当文件读");
        assert!(matches!(err, ProjectError::Invalid(_)), "{err}");

        let err = open_raw(&root_str(&root), "/etc/hosts").expect_err("越界必须拒绝");
        assert!(matches!(err, ProjectError::Denied(_)), "{err}");
    }
}
