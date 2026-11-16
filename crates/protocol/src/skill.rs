//! `SKILL.md` 的 frontmatter 解析。
//!
//! 放在 `protocol` 而不是 `jarvis-worker`，是因为**装包时的兼容层**也要读同一份格式：
//! service 必须能独立解析外部技能（补缺省字段、判支持状态、写 sidecar），
//! worker 只消费归一化结果。两处各写一份解析器必然漂移，所以这里只有一份实现。
//!
//! 解析器是**受控的最小实现**而不是 YAML 库：格式只服务技能清单，能对未知结构
//! 直接报错比"宽松解析后静默忽略"更安全。
//!
//! ## 嵌套块
//!
//! Agent Skills 规范允许 `metadata:` 这类嵌套映射。旧实现会把缩进子行当成顶层键
//! 插入，`metadata` 里写 `name: xxx` 甚至会覆盖真实的技能名——所以这里显式区分
//! 「列表项」与「嵌套块」，嵌套内容进独立表，**永不写入顶层**。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::ipc::SkillManifest;

/// 内置技能的来源标记。外部插件由 service 的兼容层填 `third_party`。
pub const BUILTIN_SOURCE: &str = "builtin";

/// 技能的取资料声明。
///
/// 三个键必须同时出现或同时缺省：只写一部分视为配置错误，宁可拒绝加载，
/// 也不静默降级成"不取资料"——那样技能会安静地少掉依据。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkillFetch {
    /// 在哪一步取资料：必须精确等于 `steps` 中的某一项。
    pub step: String,
    /// 从哪个输入字段取。
    pub from: FetchSource,
    /// 用哪个只读工具。
    pub tool: FetchTool,
}

/// 取资料的输入字段来源。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchSource {
    /// 一个网页地址。
    Url,
    /// 一个城市名。
    City,
    /// 一个搜索关键词。
    Query,
    /// 项目内的相对路径。
    Path,
    /// 文件名或内容匹配模式。
    Pattern,
}

impl FetchSource {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Url => "url",
            Self::City => "city",
            Self::Query => "query",
            Self::Path => "path",
            Self::Pattern => "pattern",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim() {
            "url" => Some(Self::Url),
            "city" => Some(Self::City),
            "query" => Some(Self::Query),
            "path" => Some(Self::Path),
            "pattern" => Some(Self::Pattern),
            _ => None,
        }
    }
}

// 线上用 frontmatter 里那套字符串（`url` / `city` / …），
// 不是 serde 默认的 `{"Url":null}`：线上表示要与 SKILL.md 保持一致，
// 否则同一个概念会出现两种写法。
impl Serialize for FetchSource {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for FetchSource {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Self::parse(&raw)
            .ok_or_else(|| serde::de::Error::custom(format!("未知的 fetch.from: {raw}")))
    }
}

/// 取资料可用的只读工具。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchTool {
    /// `web.fetch`：读一个公网页面。
    WebFetch,
    /// `web.search`：关键词搜索。
    WebSearch,
    /// `weather.current`：固定上游的天气。
    Weather,
    /// `read_file`：读项目里一个文本文件。
    ReadFile,
    /// `list_dir`：列项目里一个目录。
    ListDir,
    /// `search_file`：按文件名在项目里找。
    SearchFile,
    /// `search_content`：按内容在项目里搜。
    SearchContent,
}

impl FetchTool {
    /// worker / service 侧共用的工具名（点号或下划线都按这里的写法）。
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::WebFetch => "web.fetch",
            Self::WebSearch => "web.search",
            Self::Weather => "weather.current",
            Self::ReadFile => "read_file",
            Self::ListDir => "list_dir",
            Self::SearchFile => "search_file",
            Self::SearchContent => "search_content",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim() {
            "web.fetch" => Some(Self::WebFetch),
            "web.search" => Some(Self::WebSearch),
            "weather.current" => Some(Self::Weather),
            "read_file" => Some(Self::ReadFile),
            "list_dir" => Some(Self::ListDir),
            "search_file" => Some(Self::SearchFile),
            "search_content" => Some(Self::SearchContent),
            _ => None,
        }
    }

    /// 是否在 service 进程内执行（走 `LocalToolCall` 桥），否则在 worker 本地执行。
    pub const fn is_local_tool(self) -> bool {
        matches!(
            self,
            Self::ReadFile | Self::ListDir | Self::SearchFile | Self::SearchContent
        )
    }

    /// 该工具默认从哪个输入字段取参数。供兼容层推导缺省的 `fetch.from`。
    pub const fn default_source(self) -> FetchSource {
        match self {
            Self::WebFetch => FetchSource::Url,
            Self::Weather => FetchSource::City,
            Self::WebSearch => FetchSource::Query,
            Self::ReadFile | Self::ListDir => FetchSource::Path,
            Self::SearchFile | Self::SearchContent => FetchSource::Pattern,
        }
    }
}

impl Serialize for FetchTool {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for FetchTool {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Self::parse(&raw)
            .ok_or_else(|| serde::de::Error::custom(format!("未知的 fetch.tool: {raw}")))
    }
}

/// sidecar 文件名。安装在技能目录里，与 `SKILL.md` 同级。
///
/// service 装包时写、worker 启动时读：兼容判定（补缺省、映射工具、判三态）
/// 全部在 service 做完，worker 只消费结论，不懂 `allowed-tools` 与包形态。
pub const SIDECAR_NAME: &str = ".pa-skill.json";

/// sidecar 内容。worker 只信这个文件，不重新解析 `SKILL.md`。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SkillSidecar {
    pub manifest: SkillManifest,
    /// `supported` / `degraded` / `unsupported`
    pub status: String,
    #[serde(default)]
    pub reasons: Vec<String>,
    /// 合并后的正文（`SKILL.md` + 配套 md，已截断）。
    #[serde(default)]
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

impl SkillSidecar {
    /// 解析状态。未知取值按 `unsupported` 处理：宁可少装一条技能，
    /// 也不要让一条状态写坏的技能跑出「假装完成」的结果。
    pub fn status(&self) -> crate::task::SkillStatus {
        crate::task::SkillStatus::parse(&self.status)
            .unwrap_or(crate::task::SkillStatus::Unsupported)
    }

    /// 是否应该被 worker 装载。
    pub fn is_loadable(&self) -> bool {
        self.status() != crate::task::SkillStatus::Unsupported
    }
}

/// frontmatter 里的一条字段值。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Field {
    Scalar(String),
    List(Vec<String>),
}

/// 解析结果：顶层字段、嵌套块、正文。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Frontmatter {
    fields: HashMap<String, Field>,
    /// `metadata:` 这类嵌套映射，按父键归组。**永不写入 [`Self::fields`]**。
    nested: HashMap<String, HashMap<String, String>>,
    body: String,
}

impl Frontmatter {
    /// 取一个标量字段。列表或缺失都返回 `None`。
    pub fn scalar(&self, key: &str) -> Option<&str> {
        match self.fields.get(key) {
            Some(Field::Scalar(value)) if !value.is_empty() => Some(value),
            _ => None,
        }
    }

    /// 取一个列表字段。标量会被当作单元素列表，与旧实现保持一致。
    pub fn list(&self, key: &str) -> Vec<String> {
        match self.fields.get(key) {
            Some(Field::List(items)) => items.clone(),
            Some(Field::Scalar(value)) if !value.is_empty() => vec![value.clone()],
            _ => Vec::new(),
        }
    }

    /// 字段是否存在（哪怕是空占位）。
    pub fn contains(&self, key: &str) -> bool {
        self.fields.contains_key(key)
    }

    /// 取嵌套块。`metadata:` 用得上。
    pub fn nested_map(&self, key: &str) -> Option<&HashMap<String, String>> {
        self.nested.get(key)
    }

    /// frontmatter 之后的正文（已 trim）。
    pub fn body(&self) -> &str {
        &self.body
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SkillError {
    #[error("缺少 frontmatter")]
    NoFrontmatter,
    #[error("frontmatter 未闭合")]
    UnclosedFrontmatter,
    #[error("字段格式非法: {0}")]
    BadFormat(String),
    #[error("缺少必填字段: {0}")]
    MissingField(&'static str),
    #[error("risk_level 取值非法: {0}")]
    BadRiskLevel(String),
    #[error("取资料声明不完整：fetch.step / fetch.from / fetch.tool 必须同时出现")]
    PartialFetch,
    #[error("取资料声明的步骤不在 steps 中: {0}")]
    UnknownFetchStep(String),
    #[error("取资料的输入字段取值非法: {0}")]
    BadFetchFrom(String),
    #[error("取资料的工具取值非法: {0}")]
    BadFetchTool(String),
}

/// 解析 `SKILL.md`，只做格式解析，不校验业务约束。
///
/// 外部技能的兼容层用它做宽松读取（规范只要求 `name` + `description`）。
pub fn parse(content: &str) -> Result<Frontmatter, SkillError> {
    let (fields, nested) = parse_frontmatter(content)?;
    Ok(Frontmatter {
        fields,
        nested,
        body: body_after_frontmatter(content),
    })
}

/// 解析内置技能：严格校验 `name` / `version` / `risk_level`，并读取取资料声明。
///
/// 外部技能**不要**走这里——它们缺 `version` / `risk_level` 是合法的，
/// 由 service 的兼容层补齐后再写 sidecar。
pub fn parse_builtin(content: &str) -> Result<(SkillManifest, String), SkillError> {
    let parsed = parse(content)?;

    let name = parsed
        .scalar("name")
        .ok_or(SkillError::MissingField("name"))?
        .to_string();
    let version = parsed
        .scalar("version")
        .ok_or(SkillError::MissingField("version"))?
        .to_string();
    let risk_level = parsed
        .scalar("risk_level")
        .ok_or(SkillError::MissingField("risk_level"))?
        .to_string();

    if !matches!(
        risk_level.as_str(),
        "read" | "reversible_write" | "irreversible_write"
    ) {
        return Err(SkillError::BadRiskLevel(risk_level));
    }

    let steps = parsed.list("steps");
    let fetch = read_fetch(&parsed, &steps)?;

    let manifest = SkillManifest {
        name,
        version,
        risk_level,
        triggers: parsed.list("triggers"),
        required_tools: parsed.list("required_tools"),
        outputs: parsed.list("outputs"),
        stop_before: parsed.scalar("stop_before").map(str::to_string),
        steps,
        source: BUILTIN_SOURCE.to_string(),
        plugin_id: None,
        fetch,
    };

    Ok((manifest, parsed.body().to_string()))
}

/// 从已解析的 frontmatter 读取 `fetch.*` 三键。
///
/// 三键同时缺省返回 `None`；只写一部分返回 [`SkillError::PartialFetch`]。
/// 这是刻意从严：半个声明跑起来只会安静地不取资料，用户看不出问题在哪。
pub fn read_fetch(
    parsed: &Frontmatter,
    steps: &[String],
) -> Result<Option<SkillFetch>, SkillError> {
    let step = parsed.scalar("fetch.step");
    let from = parsed.scalar("fetch.from");
    let tool = parsed.scalar("fetch.tool");

    let present = [step.is_some(), from.is_some(), tool.is_some()];
    if present.iter().all(|value| !value) {
        return Ok(None);
    }
    if !present.iter().all(|value| *value) {
        return Err(SkillError::PartialFetch);
    }

    let step = step.unwrap_or_default().to_string();
    let from_raw = from.unwrap_or_default();
    let tool_raw = tool.unwrap_or_default();

    if !steps.iter().any(|candidate| candidate == &step) {
        return Err(SkillError::UnknownFetchStep(step));
    }

    let from = FetchSource::parse(from_raw)
        .ok_or_else(|| SkillError::BadFetchFrom(from_raw.to_string()))?;
    let tool =
        FetchTool::parse(tool_raw).ok_or_else(|| SkillError::BadFetchTool(tool_raw.to_string()))?;

    Ok(Some(SkillFetch { step, from, tool }))
}

/// 取 frontmatter 之后的正文。
fn body_after_frontmatter(content: &str) -> String {
    let mut opened = false;
    let mut offset = 0usize;

    for line in content.split_inclusive('\n') {
        if line.trim() == "---" {
            if opened {
                // 跳过闭合行本身，正文从它的下一行开始。
                return content
                    .get(offset + line.len()..)
                    .unwrap_or_default()
                    .trim()
                    .to_string();
            }
            opened = true;
        }
        offset += line.len();
    }

    String::new()
}

/// 当前正在归集的顶层键及其形态。
#[derive(Debug)]
struct CurrentKey {
    key: String,
    /// `true` 表示后续缩进行属于嵌套块；`false` 表示还可以追加列表项。
    nested: bool,
}

/// 顶层字段 + 嵌套块。拆出来只是为了签名可读（clippy 也不喜欢裸嵌套泛型）。
type ParsedFields = (
    HashMap<String, Field>,
    HashMap<String, HashMap<String, String>>,
);

fn parse_frontmatter(content: &str) -> Result<ParsedFields, SkillError> {
    let mut lines = content.lines();

    // 允许文件以空行开头，但第一个非空行必须是 `---`
    let first = lines
        .by_ref()
        .find(|line| !line.trim().is_empty())
        .ok_or(SkillError::NoFrontmatter)?;
    if first.trim() != "---" {
        return Err(SkillError::NoFrontmatter);
    }

    let mut fields: HashMap<String, Field> = HashMap::new();
    let mut nested: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut current: Option<CurrentKey> = None;
    let mut closed = false;

    for line in lines {
        let trimmed = line.trim();

        if trimmed == "---" {
            closed = true;
            break;
        }
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let indented = line.len() != line.trim_start().len();

        // 缩进的 `- item` 属于上一个键的列表
        if let Some(item) = trimmed.strip_prefix("- ") {
            let Some(key) = current.as_ref().filter(|slot| !slot.nested) else {
                return Err(SkillError::BadFormat(format!(
                    "列表项缺少归属字段: {trimmed}"
                )));
            };
            match fields.get_mut(&key.key) {
                Some(Field::List(items)) => items.push(unquote(item)),
                _ => {
                    fields.insert(key.key.clone(), Field::List(vec![unquote(item)]));
                }
            }
            continue;
        }

        // 缩进的 `k: v` 属于嵌套块（规范的 `metadata:`）。
        // **不写入顶层**：旧实现会把它当顶层键，`metadata` 里的 `name` 会覆盖真实技能名。
        if indented {
            let Some(key) = current.as_ref() else {
                return Err(SkillError::BadFormat(format!(
                    "缩进行缺少归属字段: {trimmed}"
                )));
            };
            let (name, value) = trimmed
                .split_once(':')
                .ok_or_else(|| SkillError::BadFormat(format!("无法解析行: {trimmed}")))?;
            nested
                .entry(key.key.clone())
                .or_default()
                .insert(name.trim().to_string(), unquote(value));

            // 转成嵌套态：后续缩进行一律归入这里，不再追加列表项。
            if let Some(key) = current.as_mut() {
                key.nested = true;
            }
            continue;
        }

        let (key, value) = trimmed
            .split_once(':')
            .ok_or_else(|| SkillError::BadFormat(format!("无法解析行: {trimmed}")))?;
        let key = key.trim().to_string();
        let value = value.trim();

        if value.is_empty() {
            // 后续可能是缩进列表，也可能是嵌套块，先占位为空列表
            fields.insert(key.clone(), Field::List(Vec::new()));
            current = Some(CurrentKey { key, nested: false });
        } else if let Some(items) = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')) {
            let list = items
                .split(',')
                .map(str::trim)
                .filter(|item| !item.is_empty())
                .map(unquote)
                .collect();
            fields.insert(key.clone(), Field::List(list));
            current = Some(CurrentKey { key, nested: false });
        } else {
            fields.insert(key.clone(), Field::Scalar(unquote(value)));
            current = Some(CurrentKey { key, nested: false });
        }
    }

    if !closed {
        return Err(SkillError::UnclosedFrontmatter);
    }
    Ok((fields, nested))
}

fn unquote(value: &str) -> String {
    let trimmed = value.trim();
    let trimmed = trimmed
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .or_else(|| {
            trimmed
                .strip_prefix('\'')
                .and_then(|value| value.strip_suffix('\''))
        })
        .unwrap_or(trimmed);
    trimmed.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"---
name: demo
version: 0.1.0
risk_level: read
triggers: ["出行", "差旅"]
required_tools:
  - web.fetch
outputs: [plan_table]
stop_before: 提交前确认
steps:
  - 解析
  - 查询
---
正文
"#;

    #[test]
    fn parses_inline_and_block_lists() {
        let (manifest, _) = parse_builtin(SAMPLE).expect("解析失败");

        assert_eq!(manifest.name, "demo");
        assert_eq!(manifest.triggers, vec!["出行", "差旅"]);
        assert_eq!(manifest.required_tools, vec!["web.fetch"]);
        assert_eq!(manifest.outputs, vec!["plan_table"]);
        assert_eq!(manifest.stop_before.as_deref(), Some("提交前确认"));
        assert_eq!(manifest.steps.len(), 2);
        assert_eq!(manifest.source, BUILTIN_SOURCE);
        assert!(manifest.fetch.is_none(), "没有 fetch 声明时必须是 None");
    }

    #[test]
    fn rejects_missing_frontmatter() {
        assert_eq!(parse("# 只有正文"), Err(SkillError::NoFrontmatter));
    }

    #[test]
    fn rejects_unclosed_frontmatter() {
        let content = "---\nname: x\nversion: 1\n";
        assert_eq!(parse(content), Err(SkillError::UnclosedFrontmatter));
    }

    #[test]
    fn rejects_missing_required_field() {
        let content = "---\nname: x\nversion: 1\n---\n";
        assert_eq!(
            parse_builtin(content),
            Err(SkillError::MissingField("risk_level"))
        );
    }

    #[test]
    fn body_excludes_frontmatter() {
        let (_, body) = parse_builtin(SAMPLE).expect("解析失败");
        assert_eq!(body, "正文");
    }

    /// 规范允许 `metadata:` 嵌套映射。旧实现会把缩进子行当顶层键，
    /// metadata 里的 `name` 会覆盖真实技能名——这条用例锁死修复。
    #[test]
    fn nested_block_never_leaks_into_top_level_fields() {
        let content = r#"---
name: real-name
description: 真实描述
metadata:
  name: hacked
  version: 9.9.9
  author: someone
steps:
  - 执行
---
正文
"#;

        let parsed = parse(content).expect("解析失败");

        assert_eq!(parsed.scalar("name"), Some("real-name"), "'name' 被覆盖");
        assert_eq!(parsed.scalar("description"), Some("真实描述"));
        assert!(
            parsed.scalar("version").is_none(),
            "'version' 不该从 metadata 里漏出来"
        );

        let meta = parsed.nested_map("metadata").expect("metadata 应被收集");
        assert_eq!(meta.get("name").map(String::as_str), Some("hacked"));
        assert_eq!(meta.get("version").map(String::as_str), Some("9.9.9"));
    }

    #[test]
    fn list_after_nested_block_is_rejected_not_silently_dropped() {
        let content = r#"---
metadata:
  author: someone
steps:
  - 执行
---
正文
"#;
        // `steps` 是新的顶层键，必须能被正常读取（嵌套块不能吞掉后面的键）。
        let parsed = parse(content).expect("解析失败");
        assert_eq!(parsed.list("steps"), vec!["执行"]);
    }

    #[test]
    fn fetch_declaration_requires_all_three_keys() {
        let complete = r#"---
name: demo
version: 0.1.0
risk_level: read
outputs: [report]
fetch.step: 查资料
fetch.from: url
fetch.tool: web.fetch
steps:
  - 查资料
---
正文
"#;
        let (manifest, _) = parse_builtin(complete).expect("完整声明应通过");
        let fetch = manifest.fetch.expect("应有 fetch");
        assert_eq!(fetch.step, "查资料");
        assert_eq!(fetch.from, FetchSource::Url);
        assert_eq!(fetch.tool, FetchTool::WebFetch);

        let partial = complete.replace("fetch.tool: web.fetch\n", "");
        assert_eq!(parse_builtin(&partial), Err(SkillError::PartialFetch));
    }

    #[test]
    fn fetch_step_must_exist_in_steps() {
        let content = r#"---
name: demo
version: 0.1.0
risk_level: read
outputs: [report]
fetch.step: 不存在的步骤
fetch.from: url
fetch.tool: web.fetch
steps:
  - 查资料
---
正文
"#;
        assert!(matches!(
            parse_builtin(content),
            Err(SkillError::UnknownFetchStep(_))
        ));
    }

    #[test]
    fn fetch_tool_and_source_roundtrip() {
        for tool in [
            FetchTool::WebFetch,
            FetchTool::WebSearch,
            FetchTool::Weather,
            FetchTool::ReadFile,
            FetchTool::ListDir,
            FetchTool::SearchFile,
            FetchTool::SearchContent,
        ] {
            assert_eq!(FetchTool::parse(tool.as_str()), Some(tool));
        }
        for source in [
            FetchSource::Url,
            FetchSource::City,
            FetchSource::Query,
            FetchSource::Path,
            FetchSource::Pattern,
        ] {
            assert_eq!(FetchSource::parse(source.as_str()), Some(source));
        }
    }

    #[test]
    fn local_tools_are_flagged_for_the_bridge() {
        assert!(FetchTool::ReadFile.is_local_tool());
        assert!(FetchTool::SearchContent.is_local_tool());
        assert!(!FetchTool::WebFetch.is_local_tool());
        assert_eq!(FetchTool::ReadFile.default_source(), FetchSource::Path);
        assert_eq!(FetchTool::SearchFile.default_source(), FetchSource::Pattern);
    }
}
