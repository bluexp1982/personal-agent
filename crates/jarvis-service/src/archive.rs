//! zip 的安全解包。
//!
//! 技能包与主题包共用同一份实现：**安全代码只允许有一份**。复制粘贴出来的
//! 第二份迟早会漏掉一条规则（例如新加一种符号链接形态），而漏掉的代价是
//! 任意目录写权限。
//!
//! 三条硬规则，缺一条就等于开了写权限：
//!
//! 1. **路径穿越**用 `zip` 的 `enclosed_name()` 挡住（`../`、绝对路径），
//!    写盘前再核对一次目标仍在临时目录内。
//! 2. **zip 炸弹**用四道上限兜住：包体、文件数、单文件解压后、解压总量。
//!   上限由调用方给（[`ArchiveLimits`]），因为技能包与主题包的体积差一个量级。
//! 3. **垃圾文件**（`__MACOSX/` 与 `._*`）不落盘：它们在探测阶段还会破坏
//!    「只有一个顶层目录」的判断。
//!
//! 解包不做业务判断：技能包的归一化交给 `plugin::compat`，主题包的
//! `theme.json` 校验交给 `theme::manifest`。

use std::io::{Cursor, Read, Write};
use std::path::Path;

/// 解包过程中允许的最大值。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ArchiveLimits {
    /// 整个 zip 的字节数。
    pub(crate) archive: usize,
    /// 条目数上限，防「几万个小文件」把 inode 吃光。
    pub(crate) entries: usize,
    /// 单个条目解压后的上限。
    pub(crate) entry: u64,
    /// 解压总量上限，防 zip 炸弹。
    pub(crate) total: u64,
}

/// 解包失败。由调用方映射成自己的错误类型（`PluginError` / `ThemeError`），
/// 这样两边的错误码与提示词可以各自措辞，安全规则却只有一份。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ArchiveError {
    /// 包本身不合法：不是 zip、含危险路径、超限。
    Invalid(String),
    /// 本机磁盘问题，不是用户装错了包。
    Io(String),
}

impl ArchiveError {
    fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid(message.into())
    }

    fn io(message: impl Into<String>) -> Self {
        Self::Io(message.into())
    }
}

/// 解压到 `work_dir`，返回包内所有文件的相对路径（`/` 分隔）。
///
/// 调用方保证 `work_dir` 是**本次安装独占**的临时目录：任何失败都只需要删掉它。
pub(crate) fn extract(
    bytes: &[u8],
    work_dir: &Path,
    limits: ArchiveLimits,
) -> Result<Vec<String>, ArchiveError> {
    if bytes.is_empty() {
        return Err(ArchiveError::invalid("安装包是空的"));
    }
    if bytes.len() > limits.archive {
        return Err(ArchiveError::invalid(format!(
            "安装包 {} 字节，超过上限 {} 字节",
            bytes.len(),
            limits.archive
        )));
    }

    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|err| ArchiveError::invalid(format!("不是合法的 zip：{err}")))?;

    if archive.len() > limits.entries {
        return Err(ArchiveError::invalid(format!(
            "包里有 {} 个条目，超过上限 {}",
            archive.len(),
            limits.entries
        )));
    }

    let mut paths: Vec<String> = Vec::new();
    let mut total: u64 = 0;

    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|err| ArchiveError::invalid(format!("读取第 {index} 个条目失败：{err}")))?;

        // 拒绝 `../`、绝对路径与 NUL。`enclosed_name` 已经把危险形态挡在外面，
        // 这里再取一次是因为后面所有落盘路径都由它派生。
        let Some(relative) = entry.enclosed_name() else {
            // `name()` 自己也可能失败（编码坏了），兜底成一句可读的说明，
            // 不要为了拼错误信息再抛一个错。
            let shown = entry
                .name()
                .map(|name| name.to_string())
                .unwrap_or_else(|_| "<无法读取条目名>".to_string());
            return Err(ArchiveError::invalid(format!(
                "包内含不安全的路径：{shown}"
            )));
        };

        let relative = relative.to_string_lossy().replace('\\', "/");

        // Finder 压缩带进来的 `__MACOSX/` 与 `._*` 不落盘：它们不是包内容，
        // 写进去只会在安装目录里留一堆点开头的垃圾文件。
        if is_junk_path(&relative) {
            continue;
        }

        if entry.is_dir() {
            continue;
        }

        if is_symlink(entry.unix_mode()) {
            return Err(ArchiveError::invalid(format!("包内含符号链接：{relative}")));
        }

        if entry.size() > limits.entry {
            return Err(ArchiveError::invalid(format!(
                "{relative} 解压后 {} 字节，超过单文件上限",
                entry.size()
            )));
        }
        total = total.saturating_add(entry.size());
        if total > limits.total {
            return Err(ArchiveError::invalid("包解压后总大小超过上限"));
        }

        let target = work_dir.join(&relative);
        if !target.starts_with(work_dir) {
            return Err(ArchiveError::invalid(format!("包内含越界路径：{relative}")));
        }

        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| ArchiveError::io(format!("创建目录失败：{err}")))?;
        }

        let mut buffer: Vec<u8> = Vec::with_capacity(entry.size() as usize);
        entry
            .read_to_end(&mut buffer)
            .map_err(|err| ArchiveError::invalid(format!("解压失败：{err}")))?;

        let mut file = std::fs::File::create(&target)
            .map_err(|err| ArchiveError::io(format!("写文件失败：{err}")))?;
        file.write_all(&buffer)
            .map_err(|err| ArchiveError::io(format!("写文件失败：{err}")))?;

        paths.push(relative);
    }

    if paths.is_empty() {
        return Err(ArchiveError::invalid("包里没有文件"));
    }

    Ok(paths)
}

/// 是否是 macOS 打包时混进来的元数据。
///
/// 两族都来自 Finder 的「压缩」：`__MACOSX/` 目录（里面是资源分支镜像），
/// 以及任意目录下以 `._` 开头的 AppleDouble 文件。它们不是包内容，
/// 在探测阶段还会破坏「只有一个顶层目录」的判断——在 Finder 里右键压缩
/// 是最自然的操作，不该因此被判成「不是技能包」。
pub(crate) fn is_junk_path(path: &str) -> bool {
    path.split('/')
        .any(|segment| segment == "__MACOSX" || segment == ".DS_Store" || segment.starts_with("._"))
}

/// 只有一层顶层目录时剥掉它。
///
/// 判定条件是「所有条目都以同一段开头」：只要出现一个根级文件（如 `theme.json`）
/// 就说明没壳，原样返回。
pub(crate) fn strip_root(paths: &[String]) -> (String, Vec<String>) {
    let mut prefix: Option<&str> = None;

    for path in paths {
        let Some((head, _rest)) = path.split_once('/') else {
            return (String::new(), paths.to_vec());
        };
        match prefix {
            None => prefix = Some(head),
            Some(existing) if existing != head => return (String::new(), paths.to_vec()),
            Some(_) => {}
        }
    }

    let Some(head) = prefix else {
        return (String::new(), paths.to_vec());
    };

    let stripped = paths
        .iter()
        .map(|path| path[head.len() + 1..].to_string())
        .collect();

    (head.to_string(), stripped)
}

/// zip 里的符号链接在 unix mode 高位标记；放进来等于给了任意读权限。
fn is_symlink(mode: Option<u32>) -> bool {
    const S_IFMT: u32 = 0o170000;
    const S_IFLNK: u32 = 0o120000;
    mode.is_some_and(|mode| mode & S_IFMT == S_IFLNK)
}

/// 安装包的 sha256，进审计与库。
pub(crate) fn hex_sha256(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};

    let digest = Sha256::digest(bytes);
    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(text, "{byte:02x}");
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn zip_bytes(entries: &[(&str, &str)]) -> Vec<u8> {
        let mut buffer = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut buffer);
            let options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            for (path, content) in entries {
                writer.start_file(*path, options).expect("写条目失败");
                writer.write_all(content.as_bytes()).expect("写内容失败");
            }
            writer.finish().expect("收尾失败");
        }
        buffer.into_inner()
    }

    const TEST_LIMITS: ArchiveLimits = ArchiveLimits {
        archive: 1024 * 1024,
        entries: 16,
        entry: 256 * 1024,
        total: 1024 * 1024,
    };

    #[test]
    fn extracts_and_skips_junk() {
        let temp = tempfile::tempdir().expect("临时目录");
        let bytes = zip_bytes(&[
            ("theme/theme.json", "{}"),
            ("theme/._theme.json", "junk"),
            ("__MACOSX/._theme.json", "junk"),
            ("theme/.DS_Store", "junk"),
        ]);

        let paths = extract(&bytes, temp.path(), TEST_LIMITS).expect("应解包成功");
        assert_eq!(paths, vec!["theme/theme.json".to_string()]);
        assert!(temp.path().join("theme/theme.json").is_file());
        assert!(!temp.path().join("__MACOSX").exists());
    }

    #[test]
    fn rejects_path_traversal() {
        let temp = tempfile::tempdir().expect("临时目录");
        let bytes = zip_bytes(&[("../escaped.txt", "boom")]);

        let error = extract(&bytes, temp.path(), TEST_LIMITS).expect_err("应拒绝");
        assert!(matches!(error, ArchiveError::Invalid(_)));
    }

    #[test]
    fn rejects_oversized_archive() {
        let temp = tempfile::tempdir().expect("临时目录");
        let huge = vec![0u8; TEST_LIMITS.archive + 1];
        let error = extract(&huge, temp.path(), TEST_LIMITS).expect_err("应拒绝");
        assert!(matches!(error, ArchiveError::Invalid(_)));
    }

    #[test]
    fn rejects_too_many_entries() {
        let temp = tempfile::tempdir().expect("临时目录");
        let entries: Vec<(String, String)> = (0..TEST_LIMITS.entries + 1)
            .map(|index| (format!("f{index}.txt"), "x".to_string()))
            .collect();
        let refs: Vec<(&str, &str)> = entries
            .iter()
            .map(|(path, content)| (path.as_str(), content.as_str()))
            .collect();
        let bytes = zip_bytes(&refs);

        let error = extract(&bytes, temp.path(), TEST_LIMITS).expect_err("应拒绝");
        assert!(matches!(error, ArchiveError::Invalid(_)));
    }

    #[test]
    fn rejects_empty_payload() {
        let temp = tempfile::tempdir().expect("临时目录");
        let error = extract(b"", temp.path(), TEST_LIMITS).expect_err("应拒绝");
        assert!(matches!(error, ArchiveError::Invalid(_)));
    }

    #[test]
    fn strips_single_root_directory_only_when_shared() {
        let (root, rest) = strip_root(&["a/x".to_string(), "a/y".to_string()]);
        assert_eq!(root, "a");
        assert_eq!(rest, vec!["x".to_string(), "y".to_string()]);

        let (root, rest) = strip_root(&["theme.json".to_string(), "a/y".to_string()]);
        assert!(root.is_empty());
        assert_eq!(rest.len(), 2);
    }

    #[test]
    fn junk_detection_only_matches_packaging_artifacts() {
        assert!(is_junk_path("__MACOSX/._x"));
        assert!(is_junk_path("a/._SKILL.md"));
        assert!(is_junk_path(".DS_Store"));
        assert!(!is_junk_path("a/SKILL.md"));
        assert!(!is_junk_path("a/.env.example"));
    }
}
