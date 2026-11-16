//! 主题包的原子安装。
//!
//! 流程与技能包一致，但落位更简单：没有版本目录，同 id 直接覆盖。
//!
//! 1. 解压到 `themes/.tmp/<token>/`（安全规则全部来自 [`crate::archive`]）。
//! 2. 定位并解析 `theme.json`；任何字段不合法都在这里被拒。
//! 3. `rename` 到 `themes/<id>/`。目标已存在时先删旧目录——主题是"同 id 即同
//!    主题的新版本"，留两份没有意义，还会让 `rename` 失败。
//!
//! 任一步失败只删临时目录，`themes/` 下的正式目录不受影响。

use std::path::{Path, PathBuf};

use super::manifest::{self, ThemeManifest};
use super::{ThemeError, THEMES_DIR, THEME_ARCHIVE_LIMITS, THEME_MANIFEST, THEME_TMP_DIR};
use crate::archive;

/// 一次成功安装的结果。
#[derive(Debug)]
pub(crate) struct Installed {
    pub(crate) manifest: ThemeManifest,
    pub(crate) dir: PathBuf,
    /// 安装包 sha256，进审计与库。
    pub(crate) checksum: String,
}

/// 安装一个主题包。
///
/// `themes_root` 是 `{data_dir}/themes`；临时目录建在它下面，保证与最终位置
/// 同设备，`rename` 才是原子的。
pub(crate) fn install(bytes: &[u8], themes_root: &Path) -> Result<Installed, ThemeError> {
    let checksum = archive::hex_sha256(bytes);

    let tmp_root = themes_root.join(THEME_TMP_DIR);
    std::fs::create_dir_all(&tmp_root)
        .map_err(|err| ThemeError::Io(format!("创建临时目录失败：{err}")))?;

    let work_dir = tmp_root.join(super::random_token());
    std::fs::create_dir_all(&work_dir)
        .map_err(|err| ThemeError::Io(format!("创建临时目录失败：{err}")))?;

    // 从这里开始任何失败都要清掉临时目录，否则 `.tmp` 会越攒越多。
    let result = install_into(bytes, &work_dir, themes_root);
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&work_dir);
    }

    let mut installed = result?;
    installed.checksum = checksum;
    Ok(installed)
}

fn install_into(
    bytes: &[u8],
    work_dir: &Path,
    themes_root: &Path,
) -> Result<Installed, ThemeError> {
    let paths = archive::extract(bytes, work_dir, THEME_ARCHIVE_LIMITS)?;

    let root = manifest::locate_root(&paths)?;
    let package_root = if root.is_empty() {
        work_dir.to_path_buf()
    } else {
        let path = work_dir.join(&root);
        if !path.is_dir() {
            return Err(ThemeError::Invalid(format!("包里缺少顶层目录 {root}")));
        }
        path
    };

    let manifest_path = package_root.join(THEME_MANIFEST);
    let raw = std::fs::read_to_string(&manifest_path)
        .map_err(|err| ThemeError::Invalid(format!("读不到 {}：{err}", manifest_path.display())))?;
    let parsed = manifest::read_manifest(&raw)?;

    // 原子落位：`themes/<id>/`。同 id 覆盖安装，先清旧目录。
    let dest = themes_root.join(&parsed.id);
    if dest.exists() {
        std::fs::remove_dir_all(&dest)
            .map_err(|err| ThemeError::Io(format!("清理旧主题目录失败：{err}")))?;
    }
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| ThemeError::Io(format!("创建主题目录失败：{err}")))?;
    }

    std::fs::rename(&package_root, &dest)
        .map_err(|err| ThemeError::Io(format!("落盘失败：{err}")))?;

    // 剥过壳时，临时目录里还留着一层空壳，一并清掉。
    let _ = std::fs::remove_dir_all(work_dir);

    Ok(Installed {
        manifest: parsed,
        dir: dest,
        checksum: String::new(),
    })
}

/// 删掉 `themes/<id>/` 整个目录。
///
/// 目录可能已经被手工删掉：不存在不算失败，记录仍要清掉。
pub(crate) fn remove_theme_dir(themes_root: &Path, id: &str) -> Result<(), ThemeError> {
    let dir = themes_root.join(id);
    if dir.exists() {
        std::fs::remove_dir_all(&dir)
            .map_err(|err| ThemeError::Io(format!("删除主题目录失败：{err}")))?;
    }
    Ok(())
}

/// 构造安装根（`{data_dir}/themes`）。目录不存在时建出来。
pub(crate) fn ensure_themes_root(themes_root: &Path) -> Result<(), ThemeError> {
    std::fs::create_dir_all(themes_root)
        .map_err(|err| ThemeError::Io(format!("创建 {THEMES_DIR} 目录失败：{err}")))
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};

    use super::*;
    use crate::theme::{MAX_ARCHIVE_BYTES, THEME_TMP_DIR};
    use protocol::ThemeBrightness;

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

    const THEME_JSON: &str =
        r##"{"id":"nightfall","name":"夜幕","version":"1.0.0","brightness":"dark"}"##;

    #[test]
    fn installs_wrapped_package() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");
        let bytes = zip_bytes(&[
            ("nightfall/theme.json", THEME_JSON),
            ("nightfall/README.md", "说明"),
        ]);

        let installed = install(&bytes, &root).expect("应安装成功");
        assert_eq!(installed.manifest.id, "nightfall");
        assert_eq!(installed.manifest.brightness, ThemeBrightness::Dark);
        assert_eq!(installed.checksum.len(), 64);
        assert!(installed.dir.join(THEME_MANIFEST).is_file());
        assert!(installed.dir.join("README.md").is_file());
    }

    #[test]
    fn installs_root_level_package() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");
        let bytes = zip_bytes(&[("theme.json", THEME_JSON)]);

        let installed = install(&bytes, &root).expect("应安装成功");
        assert!(installed.dir.join(THEME_MANIFEST).is_file());
    }

    #[test]
    fn reinstall_same_id_overwrites() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");

        let first = zip_bytes(&[("theme.json", THEME_JSON)]);
        install(&first, &root).expect("首次安装");

        let second = zip_bytes(&[(
            "theme.json",
            r##"{"id":"nightfall","name":"夜幕 2","version":"2.0.0","brightness":"dark"}"##,
        )]);
        let installed = install(&second, &root).expect("覆盖安装");

        assert_eq!(installed.manifest.name, "夜幕 2");
        let dirs: Vec<_> = std::fs::read_dir(&root)
            .expect("列目录")
            .flatten()
            .filter(|entry| entry.path().is_dir())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name != THEME_TMP_DIR)
            .collect();
        assert_eq!(dirs, vec!["nightfall".to_string()], "同 id 不该留第二份");
    }

    #[test]
    fn rejects_package_without_manifest() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");
        let bytes = zip_bytes(&[("README.md", "只有说明")]);

        let error = install(&bytes, &root).expect_err("应拒绝");
        assert!(matches!(error, ThemeError::Invalid(_)));
    }

    #[test]
    fn rejects_non_zip_payload() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");
        let error = install(b"not a zip", &root).expect_err("应拒绝");
        assert!(matches!(error, ThemeError::Invalid(_)));
    }

    #[test]
    fn rejects_oversized_archive() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");
        let huge = vec![0u8; MAX_ARCHIVE_BYTES + 1];
        let error = install(&huge, &root).expect_err("应拒绝");
        assert!(matches!(error, ThemeError::Invalid(_)));
    }

    #[test]
    fn failed_install_leaves_no_temp_directory() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");
        let bytes = zip_bytes(&[("README.md", "没有清单")]);

        let _ = install(&bytes, &root);

        let leftovers: Vec<_> = std::fs::read_dir(root.join(THEME_TMP_DIR))
            .map(|entries| entries.flatten().collect())
            .unwrap_or_default();
        assert!(leftovers.is_empty(), "临时目录应被清理: {leftovers:?}");
    }

    #[test]
    fn remove_theme_dir_is_idempotent() {
        let temp = tempfile::tempdir().expect("临时目录");
        let root = temp.path().join("themes");
        let bytes = zip_bytes(&[("theme.json", THEME_JSON)]);
        let installed = install(&bytes, &root).expect("应安装成功");

        remove_theme_dir(&root, &installed.manifest.id).expect("删除");
        assert!(!installed.dir.exists());
        // 再删一次不该报错：目录可能已被手工清理。
        remove_theme_dir(&root, &installed.manifest.id).expect("重复删除");
    }
}
