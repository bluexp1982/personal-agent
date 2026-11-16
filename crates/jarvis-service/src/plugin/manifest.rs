//! 包形态探测与清单解析。
//!
//! Agent Skills 规范只定义「一个目录 + 必需 `SKILL.md`」，**没有定义 zip 布局**，
//! 所以外层结构由本项目自定。这里按生态现状支持四种形态，按序命中即停：
//!
//! 1. Claude 插件：`.claude-plugin/plugin.json` + `skills/<name>/SKILL.md`
//! 2. 本项目原生：`plugin.json` + `skills/<name>/SKILL.md`
//! 3. 无清单：`skills/<name>/SKILL.md`（id 取目录名，版本记 0.0.0）
//! 4. 单技能：根目录 `SKILL.md`（id 取目录名）
//!
//! Claude 与 Codex 打包时常在外面多包一层 `my-skill/`，所以先剥壳再判定。

use serde_json::Value;

use super::{PluginError, PLUGIN_API};
/// 垃圾文件判定与 `archive::extract` 同源：安装时跳过的就是这里探测时忽略的。
pub(crate) use crate::archive::is_junk_path;
use crate::archive::strip_root;

/// 包内布局。所有路径都相对「剥壳后的根」。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Layout {
    /// 被剥掉的顶层目录名；空串表示没剥。
    pub(crate) root: String,
    /// 清单文件路径；无清单形态为 `None`。
    pub(crate) manifest_path: Option<String>,
    /// 技能目录（如 `skills/pdf-extract`；单技能包是空串）。
    pub(crate) skill_dirs: Vec<String>,
}

impl Layout {
    /// 插件 id 的兜底来源：剥壳目录名，没有就用技能目录名。
    pub(crate) fn fallback_id(&self) -> String {
        if !self.root.is_empty() {
            return self.root.clone();
        }
        self.skill_dirs
            .iter()
            .find_map(|dir| {
                dir.strip_prefix("skills/")
                    .map(str::to_string)
                    .or_else(|| (!dir.is_empty()).then(|| dir.clone()))
            })
            .unwrap_or_else(|| "plugin".to_string())
    }
}

/// 插件清单。只读四个字段，其余一律忽略。
///
/// 理由：Claude 的 manifest 字段集没有公开的完整定义（含 `commands` / `agents` /
/// `hooks` / `mcpServers` 等），多读一个字段就多一处会随上游变化而炸的地方。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PluginManifest {
    pub(crate) plugin_api: u32,
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) version: String,
    pub(crate) author: Option<String>,
    pub(crate) description: Option<String>,
}

/// 探测包形态。
///
/// **先按原样判定，认不出来才剥壳再试一次。**
/// 反过来（无条件先剥）会把 `skills/only/SKILL.md` 里的 `skills` 当成外层目录剥掉，
/// 于是"无清单形态"永远识别不出来——所有条目恰好同属一个顶层目录时必然踩到。
pub(crate) fn detect(paths: &[String]) -> Result<Layout, PluginError> {
    // Finder「压缩」带出来的 AppleDouble 垃圾先剔掉：它们会让
    // 「只有一个顶层目录」这个判断失效，用户在自己机器上右键压缩就会被拒。
    let cleaned: Vec<String> = paths
        .iter()
        .filter(|path| !is_junk_path(path))
        .cloned()
        .collect();
    let paths = cleaned.as_slice();

    if let Some(layout) = analyze(paths, "") {
        return Ok(layout);
    }

    let (root, rel) = strip_root(paths);
    if !root.is_empty() {
        if let Some(layout) = analyze(&rel, &root) {
            return Ok(layout);
        }
    }

    Err(PluginError::Invalid(
        "包里既没有 plugin.json 也没有 SKILL.md；支持 Claude 插件目录、含 plugin.json 的目录、\
         skills/*/SKILL.md，或根目录放一个 SKILL.md"
            .to_string(),
    ))
}

/// 在给定根前缀下判断形态；认不出来返回 `None`。
fn analyze(paths: &[String], root: &str) -> Option<Layout> {
    let skill_dirs = collect_skill_dirs(paths);

    let manifest_path = if paths
        .iter()
        .any(|path| path == ".claude-plugin/plugin.json")
    {
        Some(".claude-plugin/plugin.json".to_string())
    } else if paths.iter().any(|path| path == "plugin.json") {
        Some("plugin.json".to_string())
    } else {
        None
    };

    if manifest_path.is_none() && skill_dirs.is_empty() {
        return None;
    }

    Some(Layout {
        root: root.to_string(),
        manifest_path,
        skill_dirs,
    })
}

/// 收集技能目录。
///
/// 两层都认：`skills/<name>/SKILL.md`（规范推荐）与根级 `SKILL.md`
/// （Claude 插件允许单个技能直接放在插件根）。更深的层级不算——规范只规定一层。
fn collect_skill_dirs(rel: &[String]) -> Vec<String> {
    let mut dirs: Vec<String> = Vec::new();

    for path in rel {
        if path == "SKILL.md" {
            dirs.push(String::new());
            continue;
        }
        let Some(rest) = path.strip_prefix("skills/") else {
            continue;
        };
        let Some(name) = rest.strip_suffix("/SKILL.md") else {
            continue;
        };
        if !name.is_empty() && !name.contains('/') {
            dirs.push(format!("skills/{name}"));
        }
    }

    dirs.sort();
    dirs.dedup();
    dirs
}

/// 解析 `plugin.json`。字段缺失一律走兜底，不因为一个可选字段缺失就拒绝整包。
pub(crate) fn read_manifest(raw: &str, fallback_id: &str) -> Result<PluginManifest, PluginError> {
    let value: Value = serde_json::from_str(raw)
        .map_err(|err| PluginError::Invalid(format!("plugin.json 不是合法 JSON: {err}")))?;

    let Some(object) = value.as_object() else {
        return Err(PluginError::Invalid(
            "plugin.json 顶层必须是对象".to_string(),
        ));
    };

    let plugin_api = object
        .get("plugin_api")
        .and_then(Value::as_u64)
        .map_or(PLUGIN_API, |value| value as u32);

    if plugin_api != PLUGIN_API {
        return Err(PluginError::Invalid(format!(
            "这个包要求 plugin_api={plugin_api}，本机支持 {PLUGIN_API}；请升级应用后再装"
        )));
    }

    let id = object
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback_id)
        .to_string();

    validate_id(&id)?;

    let name = object
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(&id)
        .to_string();

    let version = object
        .get("version")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("0.0.0")
        .to_string();

    // `author` 两种写法都见过：直接给字符串，或给 `{ "name": ... }`。
    let author = object.get("author").and_then(|value| match value {
        Value::String(text) => Some(text.trim().to_string()),
        Value::Object(map) => map
            .get("name")
            .and_then(Value::as_str)
            .map(|text| text.trim().to_string()),
        _ => None,
    });

    let description = object
        .get("description")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);

    Ok(PluginManifest {
        plugin_api,
        id,
        name,
        version,
        author,
        description,
    })
}

/// 无清单形态的清单：id 取目录名，版本记 `0.0.0`。
pub(crate) fn inferred_manifest(id: &str) -> Result<PluginManifest, PluginError> {
    validate_id(id)?;
    Ok(PluginManifest {
        plugin_api: PLUGIN_API,
        id: id.to_string(),
        name: id.to_string(),
        version: "0.0.0".to_string(),
        author: None,
        description: None,
    })
}

/// 插件 id 校验。
///
/// 白名单字符集而不是黑名单：id 会被拼进安装路径（`plugins/<id>/<version>/`），
/// 放过一个 `/` 或 `..` 就等于给了任意目录写权限。
fn validate_id(id: &str) -> Result<(), PluginError> {
    if id.is_empty() || id.len() > 64 {
        return Err(PluginError::Invalid("插件 id 长度必须是 1–64".to_string()));
    }
    if id.starts_with('.') {
        return Err(PluginError::Invalid(format!("插件 id 不能以点开头: {id}")));
    }
    if !id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
    {
        return Err(PluginError::Invalid(format!(
            "插件 id 只能用小写字母、数字、点、下划线与连字符: {id}"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_string()).collect()
    }

    #[test]
    fn detects_claude_plugin_shape() {
        let layout = detect(&paths(&[
            ".claude-plugin/plugin.json",
            "skills/review/SKILL.md",
            "skills/fancy/SKILL.md",
        ]))
        .expect("应识别为 Claude 插件");

        assert_eq!(
            layout.manifest_path.as_deref(),
            Some(".claude-plugin/plugin.json")
        );
        assert_eq!(layout.skill_dirs, vec!["skills/fancy", "skills/review"]);
    }

    #[test]
    fn detects_native_shape() {
        let layout = detect(&paths(&["plugin.json", "skills/digest/SKILL.md"])).expect("应识别");
        assert_eq!(layout.manifest_path.as_deref(), Some("plugin.json"));
        assert_eq!(layout.skill_dirs, vec!["skills/digest"]);
    }

    #[test]
    fn detects_manifest_less_shape() {
        let layout = detect(&paths(&["skills/only/SKILL.md"])).expect("应识别");
        assert!(layout.manifest_path.is_none());
        assert_eq!(layout.skill_dirs, vec!["skills/only"]);
    }

    #[test]
    fn detects_single_skill_shape() {
        let layout = detect(&paths(&["SKILL.md", "reference.md"])).expect("应识别");
        assert_eq!(layout.skill_dirs, vec![""]);
        assert!(layout.manifest_path.is_none());
    }

    /// Claude 与 Codex 打包时常在外面多包一层目录，必须先剥壳再判定，
    /// 否则「单技能包」会被当成「根目录没有 SKILL.md」而拒掉。
    #[test]
    fn strips_single_root_directory() {
        let layout =
            detect(&paths(&["my-skill/SKILL.md", "my-skill/examples.md"])).expect("应识别");

        assert_eq!(layout.root, "my-skill");
        assert_eq!(layout.skill_dirs, vec![""]);
        assert_eq!(layout.fallback_id(), "my-skill");
    }

    /// macOS 的 Finder「压缩」会塞进 `__MACOSX/` 与 `._*`。
    /// 它们让「只有一个顶层目录」不成立，如果不剔掉，用户在 Finder 里
    /// 右键压缩出来的包会一律被判成「不是技能包」。
    #[test]
    fn finder_artifacts_do_not_break_detection() {
        let layout = detect(&paths(&[
            "site-brief/",
            "__MACOSX/._site-brief",
            "site-brief/SKILL.md",
            "__MACOSX/site-brief/._SKILL.md",
        ]))
        .expect("Finder 压缩的包应能识别");

        assert_eq!(layout.root, "site-brief");
        assert_eq!(layout.skill_dirs, vec![""]);
        assert_eq!(layout.fallback_id(), "site-brief");
    }

    #[test]
    fn junk_detection_only_matches_packaging_artifacts() {
        assert!(is_junk_path("__MACOSX/._site-brief"));
        assert!(is_junk_path("__MACOSX/site-brief/._SKILL.md"));
        assert!(is_junk_path("site-brief/._SKILL.md"));
        assert!(is_junk_path(".DS_Store"));

        // 正常文件不能被误杀：以点开头的普通文件（如 .env.example）要保留。
        assert!(!is_junk_path("site-brief/SKILL.md"));
        assert!(!is_junk_path("skills/a/.env.example"));
        assert!(!is_junk_path("skills/a/_.md"));
    }

    #[test]
    fn root_manifest_prevents_stripping() {
        let layout = detect(&paths(&["plugin.json", "skills/a/SKILL.md"])).expect("应识别");
        assert_eq!(layout.root, "");
    }

    #[test]
    fn rejects_unknown_shape() {
        assert!(matches!(
            detect(&paths(&["README.md", "notes.txt"])),
            Err(PluginError::Invalid(_))
        ));
    }

    #[test]
    fn manifest_reads_only_known_fields() {
        let raw = r#"{
            "name": "com.example.weekly",
            "version": "1.2.0",
            "description": "周报助手",
            "author": { "name": "someone", "email": "x@y.z" },
            "commands": ["./commands"],
            "hooks": "./hooks.json",
            "mcpServers": {"a": {}}
        }"#;

        let manifest = read_manifest(raw, "fallback").expect("应解析成功");
        assert_eq!(manifest.id, "com.example.weekly");
        assert_eq!(manifest.version, "1.2.0");
        assert_eq!(manifest.author.as_deref(), Some("someone"));
        assert_eq!(manifest.description.as_deref(), Some("周报助手"));
        assert_eq!(manifest.plugin_api, PLUGIN_API);
    }

    #[test]
    fn manifest_accepts_string_author_and_missing_fields() {
        let manifest = read_manifest(r#"{ "name": "demo", "author": "me" }"#, "x").expect("应解析");
        assert_eq!(manifest.author.as_deref(), Some("me"));
        assert_eq!(manifest.version, "0.0.0", "缺版本时记 0.0.0");
        assert!(manifest.description.is_none());
    }

    #[test]
    fn manifest_without_name_falls_back_to_directory() {
        let manifest = read_manifest(r#"{ "version": "1.0.0" }"#, "my-skill").expect("应解析");
        assert_eq!(manifest.id, "my-skill");
        assert_eq!(manifest.name, "my-skill");
    }

    #[test]
    fn manifest_rejects_future_api_version() {
        let error =
            read_manifest(r#"{ "name": "demo", "plugin_api": 99 }"#, "x").expect_err("应拒绝");
        assert!(matches!(error, PluginError::Invalid(_)));
    }

    /// id 会拼进安装路径，放过一个 `/` 就是任意目录写。
    ///
    /// 空字符串不在其列：那是"没写 name"，走目录名兜底，不是非法 id。
    #[test]
    fn id_rejects_path_escapes() {
        for bad in ["../evil", "a/b", "a\\b", ".hidden", "a b"] {
            assert!(
                read_manifest(
                    &format!(r#"{{ "name": "{}" }}"#, bad.replace('\\', "\\\\")),
                    "x"
                )
                .map(|_| ())
                .is_err(),
                "应拒绝非法 id: {bad}"
            );
        }
    }

    #[test]
    fn inferred_manifest_uses_directory_name() {
        let manifest = inferred_manifest("weekly-digest").expect("应成功");
        assert_eq!(manifest.id, "weekly-digest");
        assert_eq!(manifest.version, "0.0.0");
    }
}
