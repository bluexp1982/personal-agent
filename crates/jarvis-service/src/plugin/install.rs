//! zip 的安全解包与原子安装。
//!
//! 三条硬规则，缺一条就等于开了写权限：
//!
//! 1. **路径穿越**用 `zip` 的 `enclosed_name()` 挡住（`../`、绝对路径），
//!    写盘前再核对一次目标仍在临时目录内。
//! 2. **zip 炸弹**用四道上限兜住：包体、文件数、单文件解压后、解压总量。
//! 3. **原子性**：全部解压与校验在 `plugins/.tmp/<token>/` 里完成，
//!    通过后才 `rename` 到 `plugins/<id>/<version>/`；任一步失败只删临时目录。
//!
//! 解包本身不做业务判断：归一化交给 [`super::compat`]，落库交给 [`super::store`]。

use std::path::{Path, PathBuf};

use super::compat::{self, NormalizedSkill};
use super::manifest::{self, Layout, PluginManifest};
use super::{
    PluginError, MAX_ARCHIVE_BYTES, MAX_ENTRIES, MAX_ENTRY_BYTES, MAX_TOTAL_BYTES, PLUGINS_DIR,
};
use crate::archive::{self, ArchiveError, ArchiveLimits};

/// 技能包的解包上限。主题包用另一组（见 `theme::THEME_ARCHIVE_LIMITS`）。
pub(crate) const PLUGIN_ARCHIVE_LIMITS: ArchiveLimits = ArchiveLimits {
    archive: MAX_ARCHIVE_BYTES,
    entries: MAX_ENTRIES,
    entry: MAX_ENTRY_BYTES,
    total: MAX_TOTAL_BYTES,
};

impl From<ArchiveError> for PluginError {
    fn from(error: ArchiveError) -> Self {
        match error {
            ArchiveError::Invalid(message) => Self::Invalid(message),
            ArchiveError::Io(message) => Self::Io(message),
        }
    }
}

/// 已被占用的名字。安装前查出来传进来，避免「装完才发现重名」再回滚。
#[derive(Debug, Default)]
pub(crate) struct Reserved {
    /// 已安装插件的 id。
    pub(crate) plugin_ids: Vec<String>,
    /// 已存在的技能名（内置 + 所有已装插件）。
    pub(crate) skill_names: Vec<String>,
}

impl Reserved {
    fn has_plugin(&self, id: &str) -> bool {
        self.plugin_ids.iter().any(|existing| existing == id)
    }

    fn has_skill(&self, name: &str) -> bool {
        self.skill_names.iter().any(|existing| existing == name)
    }
}

/// 一次成功安装的结果。
#[derive(Debug)]
pub(crate) struct Installed {
    pub(crate) manifest: PluginManifest,
    pub(crate) skills: Vec<NormalizedSkill>,
    pub(crate) dir: PathBuf,
    /// 安装包的 sha256，进审计与库。
    pub(crate) checksum: String,
}

/// 安装一个技能包。
///
/// `plugins_root` 是 `{data_dir}/plugins`；临时目录建在它下面，保证与最终位置
/// 同设备，`rename` 才是原子的。
pub(crate) fn install(
    bytes: &[u8],
    plugins_root: &Path,
    reserved: &Reserved,
) -> Result<Installed, PluginError> {
    // 体积校验在 `archive::extract` 里统一做（技能包与主题包共用一份上限逻辑）；
    // 这里只先算校验和，空包与超限包都会在真正解包时被拒。
    let checksum = archive::hex_sha256(bytes);

    let tmp_root = plugins_root.join(super::PLUGIN_TMP_DIR);
    std::fs::create_dir_all(&tmp_root)
        .map_err(|err| PluginError::Io(format!("创建临时目录失败：{err}")))?;

    let work_dir = tmp_root.join(super::random_token());
    std::fs::create_dir_all(&work_dir)
        .map_err(|err| PluginError::Io(format!("创建临时目录失败：{err}")))?;

    // 从这里开始任何失败都要清掉临时目录，否则 `.tmp` 会越攒越多。
    let result = install_into(bytes, &work_dir, plugins_root, reserved);
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
    plugins_root: &Path,
    reserved: &Reserved,
) -> Result<Installed, PluginError> {
    let extracted = archive::extract(bytes, work_dir, PLUGIN_ARCHIVE_LIMITS)?;

    let layout = manifest::detect(&extracted)?;
    if layout.skill_dirs.is_empty() {
        return Err(PluginError::Invalid(
            "包里没有任何技能：至少要有一个 SKILL.md".to_string(),
        ));
    }

    let package_root = if layout.root.is_empty() {
        work_dir.to_path_buf()
    } else {
        let root = work_dir.join(&layout.root);
        if !root.is_dir() {
            return Err(PluginError::Invalid(format!(
                "包里缺少顶层目录 {}",
                layout.root
            )));
        }
        root
    };

    let plugin = load_manifest(&package_root, &layout)?;

    if reserved.has_plugin(&plugin.id) {
        return Err(PluginError::Conflict(format!(
            "插件 {} 已安装；先卸载再装新版本",
            plugin.id
        )));
    }

    let mut skills: Vec<NormalizedSkill> = Vec::new();
    for dir in &layout.skill_dirs {
        let skill_dir = if dir.is_empty() {
            package_root.clone()
        } else {
            package_root.join(dir)
        };
        let dir_name = skill_dir
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(&plugin.id)
            .to_string();

        let normalized = compat::normalize(&skill_dir, &dir_name, &plugin)?;

        if reserved.has_skill(&normalized.manifest.name) {
            return Err(PluginError::Conflict(format!(
                "技能 {} 已存在（内置或其它插件）；改名后再装",
                normalized.manifest.name
            )));
        }
        // 同一个包里两条技能同名也要拦：后写的那条会静静覆盖前一条。
        if skills
            .iter()
            .any(|existing| existing.manifest.name == normalized.manifest.name)
        {
            return Err(PluginError::Conflict(format!(
                "包内有两个同名技能 {}",
                normalized.manifest.name
            )));
        }

        compat::write_sidecar(&skill_dir, &normalized)?;
        skills.push(normalized);
    }

    // 原子落位：`plugins/<id>/<version>/`。
    let version_dir = plugins_root.join(&plugin.id).join(&plugin.version);
    if version_dir.exists() {
        // 同 id 同版本但库里没有记录（例如上次装到一半崩了）：清掉重装，
        // 留着只会让 `rename` 失败，而失败信息对用户毫无意义。
        std::fs::remove_dir_all(&version_dir)
            .map_err(|err| PluginError::Io(format!("清理残留目录失败：{err}")))?;
    }
    if let Some(parent) = version_dir.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| PluginError::Io(format!("创建插件目录失败：{err}")))?;
    }

    std::fs::rename(&package_root, &version_dir)
        .map_err(|err| PluginError::Io(format!("落盘失败：{err}")))?;

    // 剥过壳时，临时目录里还留着一层空壳，一并清掉。
    let _ = std::fs::remove_dir_all(work_dir);

    Ok(Installed {
        manifest: plugin,
        skills,
        dir: version_dir,
        checksum: String::new(),
    })
}

/// 读清单：有 `plugin.json` 就用它，没有就按目录名推断。
fn load_manifest(package_root: &Path, layout: &Layout) -> Result<PluginManifest, PluginError> {
    let Some(relative) = layout.manifest_path.as_deref() else {
        // 单技能包（根目录就是 SKILL.md）没有目录名可用，id 取 frontmatter 的 name。
        // 否则所有这类包都会叫 `plugin`，第二个就撞 id。
        if layout.skill_dirs.len() == 1 && layout.skill_dirs[0].is_empty() {
            if let Some(name) = read_skill_name(&package_root.join("SKILL.md")) {
                return manifest::inferred_manifest(&name);
            }
        }
        return manifest::inferred_manifest(&layout.fallback_id());
    };

    let path = package_root.join(relative);
    let raw = std::fs::read_to_string(&path)
        .map_err(|err| PluginError::Invalid(format!("读不到清单 {}：{err}", path.display())))?;
    manifest::read_manifest(&raw, &layout.fallback_id())
}

/// 从 `SKILL.md` 里取 `name`。读不到或解析失败都返回 `None`，
/// 由调用方回退到目录名——这里不该因为一次探测失败就拒掉整包。
fn read_skill_name(path: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(path).ok()?;
    let parsed = protocol::skill::parse(&raw).ok()?;
    parsed
        .scalar("name")
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}

/// 卸载：删掉 `plugins/<id>/` 整个目录。
pub(crate) fn remove_plugin_dir(
    plugins_root: &Path,
    id: &str,
    version: &str,
) -> Result<(), PluginError> {
    // 先删版本目录，再尝试删空的 id 目录（失败说明还有别的版本，留着）。
    let version_dir = plugins_root.join(id).join(version);
    if version_dir.exists() {
        std::fs::remove_dir_all(&version_dir)
            .map_err(|err| PluginError::Io(format!("删除插件目录失败：{err}")))?;
    }
    let _ = std::fs::remove_dir(plugins_root.join(id));
    Ok(())
}

/// 构造安装根（`{data_dir}/plugins`）。目录不存在时建出来。
pub(crate) fn ensure_plugins_root(plugins_root: &Path) -> Result<(), PluginError> {
    std::fs::create_dir_all(plugins_root)
        .map_err(|err| PluginError::Io(format!("创建 {PLUGINS_DIR} 目录失败：{err}")))
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};

    use super::*;

    /// 造一个 zip。`entries` 是 (路径, 内容)。
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

    fn temp_root() -> tempfile::TempDir {
        tempfile::tempdir().expect("临时目录")
    }

    #[test]
    fn installs_single_skill_package_wrapped_in_a_directory() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[
            (
                "pdf-digest/SKILL.md",
                "---\nname: pdf-digest\ndescription: 总结 PDF\n---\n正文\n",
            ),
            ("pdf-digest/reference.md", "细节"),
        ]);

        let installed = install(&bytes, &plugins, &Reserved::default()).expect("应安装成功");

        assert_eq!(installed.manifest.id, "pdf-digest");
        assert_eq!(installed.skills.len(), 1);
        assert!(installed.dir.join("SKILL.md").is_file());
        assert!(installed.dir.join(".pa-skill.json").is_file());
        assert_eq!(installed.checksum.len(), 64);
        // 临时目录不能残留。
        assert!(!plugins
            .join(super::super::PLUGIN_TMP_DIR)
            .join("x")
            .exists());
    }

    #[test]
    fn installs_native_multi_skill_package() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[
            (
                "plugin.json",
                r#"{"name":"com.example.pack","version":"2.0.0"}"#,
            ),
            (
                "skills/one/SKILL.md",
                "---\nname: one\ndescription: 一\n---\n正文\n",
            ),
            (
                "skills/two/SKILL.md",
                "---\nname: two\ndescription: 二\n---\n正文\n",
            ),
        ]);

        let installed = install(&bytes, &plugins, &Reserved::default()).expect("应安装成功");
        assert_eq!(installed.manifest.id, "com.example.pack");
        assert_eq!(installed.manifest.version, "2.0.0");
        assert_eq!(installed.skills.len(), 2);
        assert!(installed.dir.join("skills/one/.pa-skill.json").is_file());
    }

    #[test]
    fn rejects_existing_plugin_id() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[("SKILL.md", "---\nname: demo\ndescription: x\n---\n正文\n")]);

        let reserved = Reserved {
            plugin_ids: vec!["demo".to_string()],
            skill_names: Vec::new(),
        };

        let error = install(&bytes, &plugins, &reserved).expect_err("应拒绝");
        assert!(matches!(error, PluginError::Conflict(_)));
    }

    #[test]
    fn rejects_skill_name_collision() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[(
            "SKILL.md",
            "---\nname: trip-plan\ndescription: x\n---\n正文\n",
        )]);

        let reserved = Reserved {
            plugin_ids: Vec::new(),
            skill_names: vec!["trip-plan".to_string()],
        };

        let error = install(&bytes, &plugins, &reserved).expect_err("应拒绝重名技能");
        assert!(matches!(error, PluginError::Conflict(_)));
    }

    #[test]
    fn rejects_duplicate_skill_names_inside_one_package() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[
            (
                "skills/a/SKILL.md",
                "---\nname: dup\ndescription: x\n---\n正文\n",
            ),
            (
                "skills/b/SKILL.md",
                "---\nname: dup\ndescription: x\n---\n正文\n",
            ),
        ]);

        let error = install(&bytes, &plugins, &Reserved::default()).expect_err("应拒绝");
        assert!(matches!(error, PluginError::Conflict(_)));
    }

    /// zip slip：`../` 必须被挡在写盘之前。
    #[test]
    fn rejects_path_traversal_entries() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[
            ("../escaped.txt", "boom"),
            ("SKILL.md", "---\nname: demo\ndescription: x\n---\n正文\n"),
        ]);

        let error = install(&bytes, &plugins, &Reserved::default()).expect_err("应拒绝");
        assert!(matches!(error, PluginError::Invalid(_)));
        assert!(!temp.path().join("escaped.txt").exists(), "不能写到包外");
    }

    #[test]
    fn rejects_package_without_skill() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[("README.md", "只有说明")]);

        let error = install(&bytes, &plugins, &Reserved::default()).expect_err("应拒绝");
        assert!(matches!(error, PluginError::Invalid(_)));
    }

    #[test]
    fn rejects_non_zip_payload() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let error =
            install(b"not a zip at all", &plugins, &Reserved::default()).expect_err("应拒绝");
        assert!(matches!(error, PluginError::Invalid(_)));
    }

    #[test]
    fn rejects_oversized_archive() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let huge = vec![0u8; MAX_ARCHIVE_BYTES + 1];
        let error = install(&huge, &plugins, &Reserved::default()).expect_err("应拒绝");
        assert!(matches!(error, PluginError::Invalid(_)));
    }

    #[test]
    fn failed_install_leaves_no_temp_directory() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[("README.md", "没有技能")]);

        let _ = install(&bytes, &plugins, &Reserved::default());

        let tmp = plugins.join(super::super::PLUGIN_TMP_DIR);
        let leftovers: Vec<_> = std::fs::read_dir(&tmp)
            .map(|entries| entries.flatten().collect())
            .unwrap_or_default();
        assert!(leftovers.is_empty(), "临时目录应被清理: {leftovers:?}");
    }

    #[test]
    fn unsupported_skill_still_installs_with_sidecar_status() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[(
            "SKILL.md",
            "---\nname: sheller\ndescription: x\nallowed-tools: Bash\n---\n正文\n",
        )]);

        let installed = install(&bytes, &plugins, &Reserved::default()).expect("应装机成功");
        assert_eq!(
            installed.skills[0].status,
            protocol::SkillStatus::Unsupported
        );

        let raw =
            std::fs::read_to_string(installed.dir.join(".pa-skill.json")).expect("读 sidecar");
        let sidecar: protocol::skill::SkillSidecar =
            serde_json::from_str(&raw).expect("解析 sidecar");
        assert_eq!(sidecar.status(), protocol::SkillStatus::Unsupported);
        assert!(!sidecar.reasons.is_empty());
    }

    #[test]
    fn remove_plugin_dir_deletes_version_directory() {
        let temp = temp_root();
        let plugins = temp.path().join("plugins");
        let bytes = zip_bytes(&[("SKILL.md", "---\nname: demo\ndescription: x\n---\n正文\n")]);
        let installed = install(&bytes, &plugins, &Reserved::default()).expect("应成功");

        remove_plugin_dir(
            &plugins,
            &installed.manifest.id,
            &installed.manifest.version,
        )
        .expect("删除失败");

        assert!(!installed.dir.exists());
    }
}
