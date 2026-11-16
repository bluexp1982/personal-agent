//! `read_file`：按行读项目里的文本，图片只回元信息。
//!
//! 两个刻意的取舍：
//!
//! - **带行号**。模型引用代码时要说清"第几行"，让它自己数等于让它出错。
//! - **图片不装懂**。能力边界写进回填文本，而不是返回一段空字符串让模型自由发挥。

use std::io::Read;
use std::path::Path;

use crate::chat::{LocalTool, LocalToolOutcome, ToolSpec};
use crate::local_tools::image::{self, ImageFormat};
use crate::local_tools::path_guard::ProjectRoot;
use crate::local_tools::{fail, format_size, refused};
use crate::project::ProjectError;
use crate::project_files;
use crate::tool_gateway::Source;

/// 不传 `limit` 时的行数。
const DEFAULT_LIMIT: usize = 200;

/// `limit` 的硬上限。
///
/// 1200 行装得下大多数单文件页面（实测一个 674 行的计算器一次读完），
/// 真正的总量还有 [`project_files::MAX_SLICE_CHARS`] 兜着。
const MAX_LIMIT: usize = 1200;

/// 判断图片格式只需要文件头。64 KiB 足够覆盖 JPEG 的 SOF 段与 WebP 的 VP8X。
const HEADER_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub(crate) struct ReadFileTool {
    root: ProjectRoot,
}

impl ReadFileTool {
    pub(crate) fn new(root: ProjectRoot) -> Self {
        Self { root }
    }
}

#[async_trait::async_trait]
impl LocalTool for ReadFileTool {
    fn spec(&self) -> ToolSpec {
        ToolSpec::read_file()
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let args = match parse(arguments) {
            Ok(args) => args,
            Err(reason) => {
                return fail(
                    format!("参数不合法：{reason}。请给出相对项目根的 path。"),
                    "read_file:invalid".to_string(),
                );
            }
        };

        let abs = match self.root.file(&args.path) {
            Ok(path) => path,
            Err(err) => return refused(&err, "read_file:denied"),
        };
        let rel = self.root.relative(&abs);
        let size = std::fs::metadata(&abs)
            .map(|meta| meta.len())
            .unwrap_or_default();

        // 图片先判：文本读取器会把它们当二进制拒绝，而"这是一张图"本身是有效信息。
        if let Some((format, dimensions)) = detect_image(&abs) {
            return LocalToolOutcome {
                content: render_image(&rel, format, dimensions, size),
                sources: vec![Source::doc(rel.clone(), crate::clock::now_ms())],
                ok: true,
                target: format!("file:{rel}:image"),
                ui: Vec::new(),
            };
        }

        let root = self.root.root().to_string_lossy().to_string();
        let absolute = abs.to_string_lossy().to_string();

        match project_files::read_lines(&root, &absolute, args.offset, args.limit) {
            Ok(slice) => {
                let content = render_text(&rel, &slice, size, args.offset);
                LocalToolOutcome {
                    content,
                    sources: vec![Source::doc(rel.clone(), crate::clock::now_ms())],
                    ok: true,
                    target: format!("file:{rel}:{}-{}", slice.start_line, slice.end_line),
                    ui: Vec::new(),
                }
            }
            Err(ProjectError::Denied(reason)) => fail(reason, format!("file:{rel}:denied")),
            Err(ProjectError::Invalid(reason)) => {
                // 二进制不是"出错"而是"读不了"：文案要说清是哪一种。
                let content = if reason.contains("二进制") {
                    format!(
                        "{rel} 不是文本文件（检测到二进制内容），无法读取正文。\
                         如果它是图片，请确认格式是 jpeg/png/gif/webp 之一。"
                    )
                } else {
                    format!("读取 {rel} 失败：{reason}")
                };
                fail(content, format!("file:{rel}:failed"))
            }
            Err(other) => fail(
                format!("读取 {rel} 失败：{other}"),
                format!("file:{rel}:failed"),
            ),
        }
    }
}

struct Args {
    path: String,
    offset: usize,
    limit: usize,
}

fn parse(raw: &str) -> Result<Args, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|err| format!("不是合法 JSON（{err}）"))?;

    let path = value["path"]
        .as_str()
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .ok_or_else(|| "缺少 path".to_string())?
        .to_string();

    let offset = value["offset"].as_u64().unwrap_or(1).max(1) as usize;
    let limit = value["limit"]
        .as_u64()
        .unwrap_or(DEFAULT_LIMIT as u64)
        .clamp(1, MAX_LIMIT as u64) as usize;

    Ok(Args {
        path,
        offset,
        limit,
    })
}

/// 读文件头判图片格式并尽力取尺寸。
///
/// 只认文件头，**不拿扩展名兜底**：把 `logo.png` 里的一坨文本说成图片，
/// 比说"读不了"更误导。
fn detect_image(path: &Path) -> Option<(ImageFormat, Option<(u32, u32)>)> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut header = vec![0u8; HEADER_BYTES];
    let read = file.read(&mut header).ok()?;
    header.truncate(read);

    let format = image::sniff(&header)?;
    let dimensions = image::dimensions(&header, format);
    Some((format, dimensions))
}

fn render_image(
    rel: &str,
    format: ImageFormat,
    dimensions: Option<(u32, u32)>,
    size: u64,
) -> String {
    let size_text = format_size(size);
    let dimension_text = match dimensions {
        Some((width, height)) => format!("{width}×{height}"),
        None => "尺寸未知".to_string(),
    };

    format!(
        "{rel} 是一张 {label} 图片（{dimension_text}，{size_text}）。\n\
         当前模型不支持读图，我看不到画面内容，只能确认这些元信息。\n\
         需要了解图片内容时，请让用户用文字描述，或改用支持视觉的模型。",
        label = format.label(),
        size_text = size_text,
    )
}

fn render_text(rel: &str, slice: &project_files::FileSlice, size: u64, offset: usize) -> String {
    let size_text = format_size(size);

    if slice.text.is_empty() {
        return match slice.total_lines {
            Some(0) => format!("{rel} 是空文件（0 字节）。"),
            Some(total) => format!(
                "{rel} 只有 {total} 行，起始行 {offset} 已超出末尾。请把 offset 改到 1..{total}。"
            ),
            None => format!("{rel} 从第 {offset} 行开始没有可读内容。"),
        };
    }

    let total = match slice.total_lines {
        Some(total) => format!("共 {total} 行"),
        None => "总行数未统计".to_string(),
    };

    let mut text = format!(
        "文件：{rel}（第 {}-{} 行，{total}，{size_text}）\n{}",
        slice.start_line, slice.end_line, slice.text
    );

    if slice.truncated {
        // 缺口要说清。只说"续读请把 offset 设为 883"，模型对"还缺多少"没有量感，
        // 容易直接判定"这份文件读不完"然后停工——实测它还会顺口编一句
        // "读取类工具已经用尽"，把用户引到完全错误的方向。
        let missing = match slice.total_lines {
            Some(total) => format!("，还有 {} 行没读", total.saturating_sub(slice.end_line)),
            None => String::new(),
        };
        text.push_str(&format!(
            "\n…（这只是第 {}-{} 行{missing}。**必须**用 offset={} 续读到末尾再动手：\
             凭这一段的残缺内容重写整个文件是不允许的；要定位某个词请改用 search_content）",
            slice.start_line,
            slice.end_line,
            slice.end_line + 1
        ));
    }

    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("pa-read-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        dir.canonicalize().expect("规范化失败")
    }

    #[test]
    fn renders_line_numbers_and_total() {
        let dir = temp_root("lines");
        std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\n").expect("写文件失败");

        let root = ProjectRoot::new(&dir.to_string_lossy()).expect("根应可用");
        let file = root.file("a.txt").expect("应可读");
        let slice = project_files::read_lines(
            &root.root().to_string_lossy(),
            &file.to_string_lossy(),
            2,
            2,
        )
        .expect("读取应成功");

        let text = render_text("a.txt", &slice, 14, 2);
        assert!(text.contains("第 2-3 行"), "{text}");
        assert!(text.contains("共 3 行"), "{text}");
        assert!(text.contains("    2| two"), "{text}");
        assert!(text.contains("    3| three"), "{text}");
        assert!(!text.contains("one"), "offset 之前的行不应出现");
    }

    #[test]
    fn eight_hundred_lines_fit_in_one_call() {
        let dir = temp_root("big-page");
        // 882 行 × 37 字符 ≈ 32.6 KiB：旧上限 32 KiB 正好在这里截断，
        // 实测就是这一步让模型判定"这份文件读不完"然后停工。
        let line = "x".repeat(36);
        let body: String = (0..882).map(|_| format!("{line}\n")).collect();
        std::fs::write(dir.join("page.html"), body).expect("写文件失败");

        let root = ProjectRoot::new(&dir.to_string_lossy()).expect("根应可用");
        let file = root.file("page.html").expect("应可读");
        let slice = project_files::read_lines(
            &root.root().to_string_lossy(),
            &file.to_string_lossy(),
            1,
            1200,
        )
        .expect("读取应成功");

        assert!(!slice.truncated, "882 行的页面不该再被切成两段");
        assert_eq!(slice.end_line, 882);
    }

    #[test]
    fn truncation_hint_names_the_gap() {
        let dir = temp_root("truncated-hint");
        // 2000 行 × 40 字符 = 80k 字符，超过 48 KiB 上限。
        let line = "y".repeat(39);
        let body: String = (0..2000).map(|_| format!("{line}\n")).collect();
        std::fs::write(dir.join("big.html"), body).expect("写文件失败");

        let root = ProjectRoot::new(&dir.to_string_lossy()).expect("根应可用");
        let file = root.file("big.html").expect("应可读");
        let slice = project_files::read_lines(
            &root.root().to_string_lossy(),
            &file.to_string_lossy(),
            1,
            1200,
        )
        .expect("读取应成功");

        assert!(slice.truncated, "2000 行必然超限");
        let text = render_text("big.html", &slice, 0, 1);
        assert!(text.contains("还有"), "要说清还缺多少行：{text}");
        assert!(text.contains("必须"), "续读是要求而不是建议：{text}");
        assert!(
            text.contains(&format!("offset={}", slice.end_line + 1)),
            "要给出下一步的确切参数：{text}"
        );
    }

    #[test]
    fn reports_offset_beyond_end() {
        let dir = temp_root("beyond");
        std::fs::write(dir.join("a.txt"), "only\n").expect("写文件失败");

        let root = ProjectRoot::new(&dir.to_string_lossy()).expect("根应可用");
        let file = root.file("a.txt").expect("应可读");
        let slice = project_files::read_lines(
            &root.root().to_string_lossy(),
            &file.to_string_lossy(),
            9,
            10,
        )
        .expect("读取应成功");

        let text = render_text("a.txt", &slice, 5, 9);
        assert!(text.contains("只有 1 行"), "{text}");
    }

    #[test]
    fn image_metadata_is_detected_from_header() {
        let dir = temp_root("image");
        let mut bytes = vec![0u8; 24];
        bytes[..8].copy_from_slice(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        bytes[16..20].copy_from_slice(&100u32.to_be_bytes());
        bytes[20..24].copy_from_slice(&50u32.to_be_bytes());
        std::fs::write(dir.join("logo.png"), &bytes).expect("写文件失败");

        let detected = detect_image(&dir.join("logo.png")).expect("应识别为图片");
        assert_eq!(detected.0, ImageFormat::Png);
        assert_eq!(detected.1, Some((100, 50)));

        let text = render_image("logo.png", detected.0, detected.1, bytes.len() as u64);
        assert!(text.contains("PNG"), "{text}");
        assert!(text.contains("100×50"), "{text}");
        assert!(text.contains("不支持读图"), "{text}");
    }

    #[test]
    fn text_file_named_like_image_is_not_treated_as_image() {
        let dir = temp_root("fake-image");
        std::fs::write(dir.join("logo.png"), "this is text").expect("写文件失败");
        assert!(detect_image(&dir.join("logo.png")).is_none());
    }

    #[test]
    fn parse_defaults_and_clamps() {
        let args = parse(r#"{"path":"src/main.rs"}"#).expect("应通过");
        assert_eq!(args.offset, 1);
        assert_eq!(args.limit, DEFAULT_LIMIT);

        let args = parse(r#"{"path":"a.txt","offset":0,"limit":9999}"#).expect("应通过");
        assert_eq!(args.offset, 1, "offset 至少是 1");
        assert_eq!(args.limit, MAX_LIMIT, "limit 应被夹到上限");

        assert!(parse(r#"{"path":"  "}"#).is_err(), "空路径必须拒绝");
        assert!(parse("{}").is_err(), "缺 path 必须拒绝");
        assert!(parse("nope").is_err(), "非法 JSON 必须拒绝");
    }
}
