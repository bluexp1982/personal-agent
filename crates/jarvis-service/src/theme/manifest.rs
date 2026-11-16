//! `theme.json` 的定位与解析。
//!
//! 包的形态只有一种：**根目录（或唯一外层目录）里放一个 `theme.json`**。
//! 不做多种生态形态探测——主题包是本项目自定的格式，没有兼容包袱，
//! 少一种形态就少一处"用户按文档打包却被判成不合法"的可能。
//!
//! 字段口径：
//!
//! - 必填：`id` / `name` / `version` / `brightness`；
//! - 可选：`author` / `description` / `colors`，以及 `colors` 里的每一个格子；
//! - 未知字段**忽略**：上游加字段不该让老版本装不上，这一点与技能包一致。

use serde::Deserialize;

use super::{ThemeError, RESERVED_IDS, THEME_API, THEME_MANIFEST};
use crate::archive::strip_root;
use protocol::{ThemeBrightness, ThemeColors};

/// 解析后的清单。颜色保持稀疏：`Some` 即"这个包改了这一格"。
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ThemeManifest {
    pub(crate) theme_api: u32,
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) version: String,
    pub(crate) author: Option<String>,
    pub(crate) description: Option<String>,
    pub(crate) brightness: ThemeBrightness,
    pub(crate) colors: ThemeColors,
}

/// 线缆上的原始形状：全部可选，缺什么由 [`read_manifest`] 报错或兜底。
#[derive(Debug, Deserialize)]
struct RawManifest {
    #[serde(default)]
    theme_api: Option<u32>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    version: Option<String>,
    /// 两种写法都见过：直接给字符串，或给 `{ "name": ... }`。
    #[serde(default)]
    author: Option<AuthorValue>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    brightness: Option<String>,
    /// 颜色由 `protocol::ThemeColor` 在反序列化时校验，脏值直接失败。
    #[serde(default)]
    colors: ThemeColors,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum AuthorValue {
    Text(String),
    Object { name: Option<String> },
}

/// 找到包根：优先根目录的 `theme.json`，其次剥掉唯一的外层目录。
///
/// 返回的是**相对 `work_dir` 的根前缀**（空串表示就是 `work_dir` 本身）。
pub(crate) fn locate_root(paths: &[String]) -> Result<String, ThemeError> {
    let cleaned: Vec<String> = paths
        .iter()
        .filter(|path| !crate::archive::is_junk_path(path))
        .cloned()
        .collect();

    if cleaned.iter().any(|path| path == THEME_MANIFEST) {
        return Ok(String::new());
    }

    let (root, rel) = strip_root(&cleaned);
    if !root.is_empty() && rel.iter().any(|path| path == THEME_MANIFEST) {
        return Ok(root);
    }

    Err(ThemeError::Invalid(format!(
        "包里没有 {THEME_MANIFEST}；主题包是「一个目录 + 一份 {THEME_MANIFEST}」的 zip"
    )))
}

/// 解析清单。字段缺失一律给出可读原因，而不是让 serde 的英文报错直接蹦到界面上。
pub(crate) fn read_manifest(raw: &str) -> Result<ThemeManifest, ThemeError> {
    let parsed: RawManifest = serde_json::from_str(raw)
        .map_err(|err| ThemeError::Invalid(format!("{THEME_MANIFEST} 不是合法 JSON：{err}")))?;

    let theme_api = parsed.theme_api.unwrap_or(THEME_API);
    if theme_api != THEME_API {
        return Err(ThemeError::Invalid(format!(
            "这个包要求 theme_api={theme_api}，本机支持 {THEME_API}；请升级应用后再装"
        )));
    }

    let id = require_text(parsed.id, "id")?;
    validate_id(&id)?;

    let name = require_text(parsed.name, "name")?;
    if name.chars().count() > 64 {
        return Err(ThemeError::Invalid("name 不能超过 64 个字符".to_string()));
    }

    let version = require_text(parsed.version, "version")?;
    if version.chars().count() > 32 {
        return Err(ThemeError::Invalid(
            "version 不能超过 32 个字符".to_string(),
        ));
    }

    let author = optional_text(parsed.author.map(|value| match value {
        AuthorValue::Text(text) => text,
        AuthorValue::Object { name } => name.unwrap_or_default(),
    }));
    if author
        .as_ref()
        .is_some_and(|text| text.chars().count() > 128)
    {
        return Err(ThemeError::Invalid(
            "author 不能超过 128 个字符".to_string(),
        ));
    }

    let description = optional_text(parsed.description);
    if description
        .as_ref()
        .is_some_and(|text| text.chars().count() > 512)
    {
        return Err(ThemeError::Invalid(
            "description 不能超过 512 个字符".to_string(),
        ));
    }

    let brightness_raw = require_text(parsed.brightness, "brightness")?;
    let brightness = ThemeBrightness::parse(&brightness_raw).ok_or_else(|| {
        ThemeError::Invalid(format!(
            "brightness 只能是 light 或 dark，实际是 {brightness_raw}"
        ))
    })?;

    Ok(ThemeManifest {
        theme_api,
        id,
        name,
        version,
        author,
        description,
        brightness,
        colors: parsed.colors,
    })
}

fn require_text(value: Option<String>, field: &str) -> Result<String, ThemeError> {
    let text = value
        .map(|text| text.trim().to_string())
        .unwrap_or_default();
    if text.is_empty() {
        return Err(ThemeError::Invalid(format!(
            "{THEME_MANIFEST} 缺少必填字段 {field}"
        )));
    }
    Ok(text)
}

fn optional_text(value: Option<String>) -> Option<String> {
    value
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

/// 主题 id 校验。
///
/// 白名单字符集而不是黑名单：id 会被拼进安装路径（`themes/<id>/`），
/// 放过一个 `/` 或 `..` 就等于给了任意目录写权限。
fn validate_id(id: &str) -> Result<(), ThemeError> {
    if id.is_empty() || id.len() > 64 {
        return Err(ThemeError::Invalid("主题 id 长度必须是 1–64".to_string()));
    }
    if id.starts_with('.') {
        return Err(ThemeError::Invalid(format!("主题 id 不能以点开头: {id}")));
    }
    if !id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
    {
        return Err(ThemeError::Invalid(format!(
            "主题 id 只能用字母、数字、点、下划线与连字符: {id}"
        )));
    }
    if RESERVED_IDS.contains(&id) {
        return Err(ThemeError::Invalid(format!(
            "主题 id {} 是客户端保留字（内置主题代号），换一个名字",
            id
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::ThemeColor;

    fn manifest(json: &str) -> Result<ThemeManifest, ThemeError> {
        read_manifest(json)
    }

    #[test]
    fn reads_minimal_manifest() {
        let parsed =
            manifest(r##"{"id":"nightfall","name":"夜幕","version":"1.0.0","brightness":"dark"}"##)
                .expect("应解析成功");

        assert_eq!(parsed.id, "nightfall");
        assert_eq!(parsed.brightness, ThemeBrightness::Dark);
        assert_eq!(parsed.theme_api, THEME_API);
        assert!(parsed.colors.is_sparse(), "没写颜色就是完全稀疏");
    }

    #[test]
    fn reads_sparse_colors_and_author_object() {
        let parsed = manifest(
            r##"{
                "id": "warm-paper",
                "name": "暖纸",
                "version": "0.2.0",
                "brightness": "light",
                "author": { "name": "阿吉", "email": "a@b.c" },
                "description": "偏暖的纸感浅色",
                "colors": {
                    "seed": "#C2410C",
                    "text": { "tertiary": "#9A8C7C" },
                    "status": { "success": "#166534" }
                }
            }"##,
        )
        .expect("应解析成功");

        assert_eq!(parsed.author.as_deref(), Some("阿吉"));
        assert_eq!(parsed.colors.seed.map(ThemeColor::argb), Some(0xFFC2_410C));
        assert_eq!(
            parsed
                .colors
                .text
                .as_ref()
                .and_then(|text| text.tertiary)
                .map(ThemeColor::argb),
            Some(0xFF9A_8C7C)
        );
    }

    #[test]
    fn ignores_unknown_fields() {
        let parsed = manifest(
            r##"{"id":"x","name":"X","version":"1","brightness":"light","wallpaper":"a.png"}"##,
        )
        .expect("未知字段应被忽略");
        assert_eq!(parsed.id, "x");
    }

    #[test]
    fn rejects_missing_required_fields() {
        for field in ["id", "name", "version", "brightness"] {
            let json = match field {
                "id" => r#"{"name":"X","version":"1","brightness":"light"}"#,
                "name" => r#"{"id":"x","version":"1","brightness":"light"}"#,
                "version" => r#"{"id":"x","name":"X","brightness":"light"}"#,
                _ => r#"{"id":"x","name":"X","version":"1"}"#,
            };
            let error = manifest(json).expect_err(field);
            assert!(
                matches!(error, ThemeError::Invalid(_)),
                "{field} 缺失应被拒"
            );
        }
    }

    #[test]
    fn rejects_bad_brightness_and_bad_color() {
        assert!(matches!(
            manifest(r##"{"id":"x","name":"X","version":"1","brightness":"dim"}"##),
            Err(ThemeError::Invalid(_))
        ));
        assert!(matches!(
            manifest(
                r##"{"id":"x","name":"X","version":"1","brightness":"light","colors":{"seed":"blue"}}"##
            ),
            Err(ThemeError::Invalid(_))
        ));
    }

    #[test]
    fn rejects_future_api_version() {
        let error = manifest(
            r##"{"id":"x","name":"X","version":"1","brightness":"light","theme_api":99}"##,
        )
        .expect_err("应拒绝");
        assert!(matches!(error, ThemeError::Invalid(_)));
    }

    /// id 会拼进安装路径，放过一个 `/` 就是任意目录写。
    #[test]
    fn id_rejects_path_escapes_and_reserved_names() {
        for bad in [
            "../evil", "a/b", "a\\b", ".hidden", "a b", "light", "dark", "system", "custom",
        ] {
            let json = format!(
                r##"{{"id":"{}","name":"X","version":"1","brightness":"light"}}"##,
                bad.replace('\\', "\\\\")
            );
            assert!(manifest(&json).is_err(), "应拒绝非法 id: {bad}");
        }
    }

    #[test]
    fn locate_root_accepts_wrapped_directory() {
        let paths = vec![
            "nightfall/theme.json".to_string(),
            "nightfall/README.md".to_string(),
        ];
        assert_eq!(locate_root(&paths).expect("应识别"), "nightfall");

        let paths = vec!["theme.json".to_string(), "README.md".to_string()];
        assert_eq!(locate_root(&paths).expect("应识别"), "");

        let paths = vec!["README.md".to_string()];
        assert!(matches!(locate_root(&paths), Err(ThemeError::Invalid(_))));
    }

    #[test]
    fn locate_root_ignores_finder_artifacts() {
        let paths = vec![
            "__MACOSX/._theme.json".to_string(),
            "theme.json".to_string(),
        ];
        assert_eq!(locate_root(&paths).expect("应识别"), "");
    }
}
