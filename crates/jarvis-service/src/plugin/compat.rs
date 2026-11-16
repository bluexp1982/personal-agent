//! Agent Skills 规范 → 本项目技能的可执行形态。
//!
//! 规范只要求 `name` + `description`，本项目还要求版本、风险、步骤、产物，
//! 并且只认 `web.fetch` / `web.search` / `weather.current` / 四个只读文件工具。
//! 这里的职责就是**把落差填平**，并明确判定「这条技能到底能不能跑」。
//!
//! 三态而不是布尔：
//!
//! - `supported`：可装载可运行。
//! - `degraded`：可运行但有风险（未声明工具、正文却在指挥跑脚本的弱命中）。
//! - `unsupported`：依赖本机没有的工具。**不装载、不进下拉**——
//!   装进去只会让模型假装完成了，比直接拒绝危险得多。
//!
//! 兼容逻辑只在这里实现一次：worker 只读 sidecar，不懂规范、也不懂包形态。

use std::path::Path;

use protocol::skill::{self, FetchTool, SkillSidecar, SIDECAR_NAME};
use protocol::{SkillFetch, SkillManifest, SkillStatus};

use super::manifest::PluginManifest;
use super::{PluginError, MAX_SKILL_BODY_BYTES};

/// 外部技能的来源标记。
const THIRD_PARTY: &str = "third_party";

/// 归一化结果：装包时写进 sidecar，worker 直接消费。
#[derive(Debug, Clone)]
pub(crate) struct NormalizedSkill {
    pub(crate) manifest: SkillManifest,
    pub(crate) status: SkillStatus,
    /// 降级或不支持的可读原因，直接展示给用户。
    pub(crate) reasons: Vec<String>,
    /// 合并后的正文（`SKILL.md` + 配套 md，已截断）。
    pub(crate) body: String,
    /// 规范里的 `description`：说清「做什么、何时用」。
    ///
    /// 不进 `SkillManifest`（那是 IPC 契约，worker 用不上），但要进 sidecar 与库，
    /// 因为管理页与技能列表都要展示它。
    pub(crate) description: Option<String>,
}

/// 一条技能的归一化结果。
pub(crate) fn normalize(
    skill_dir: &Path,
    dir_name: &str,
    plugin: &PluginManifest,
) -> Result<NormalizedSkill, PluginError> {
    let skill_md = skill_dir.join("SKILL.md");
    let raw = std::fs::read_to_string(&skill_md)
        .map_err(|err| PluginError::Invalid(format!("读不到 {}：{err}", skill_md.display())))?;

    let parsed = skill::parse(&raw)
        .map_err(|err| PluginError::Invalid(format!("{dir_name}/SKILL.md 解析失败：{err}")))?;

    let name = parsed
        .scalar("name")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(dir_name)
        .to_string();

    validate_skill_name(&name)?;

    let mut reasons: Vec<String> = Vec::new();

    let (tools, mut status) = map_declared_tools(parsed.scalar("allowed-tools"), &mut reasons);

    // 未声明工具时，正文可能在指挥模型跑脚本。这类包最容易「假装成功」，
    // 所以按强/弱两级兜一遍：强命中直接判不支持，弱命中只警告。
    if parsed.scalar("allowed-tools").is_none() {
        match scan_body_for_tool_usage(parsed.body()) {
            ToolUsageHint::None => {}
            ToolUsageHint::Weak(hits) => {
                // 只从 Supported 抬到 Degraded，不要覆盖已经判定的 Unsupported。
                if status == SkillStatus::Supported {
                    status = SkillStatus::Degraded;
                }
                reasons.push(format!(
                    "未声明 allowed-tools，但正文提到「{}」；若该技能依赖脚本或命令，本机无法执行",
                    hits.join("、")
                ));
            }
            ToolUsageHint::Strong(hits) => {
                status = SkillStatus::Unsupported;
                reasons.push(format!(
                    "正文要求执行「{}」，本机没有通用 shell，脚本类技能无法运行",
                    hits.join("、")
                ));
            }
        }
    }

    let body = merge_body(skill_dir, parsed.body());
    // 步骤优先用 frontmatter 的 `steps`：本项目扩展里它是权威声明，
    // `fetch.step` 也按它对齐。只有 Claude / Codex 那类没写 `steps` 的包，
    // 才回退到从正文 `##` 标题推导。
    //
    // 反过来只认正文标题的话，一个写了 `steps:` + `fetch.step` 的包会因为
    // "标题里没有这一步"被判成 unsupported——包是对的，判据错了。
    let declared_steps = parsed.list("steps");
    let steps = if declared_steps.is_empty() {
        steps_from_body(&body)
    } else {
        declared_steps
    };
    let description = parsed.scalar("description").map(str::to_string);
    let risk_level = if tools.iter().any(|tool| tool == "code.exec") {
        "irreversible_write"
    } else {
        "read"
    };

    // 取资料声明：只有本项目的扩展才会写 `fetch.*`。
    // 合规的 Claude/Codex 技能都不会写，所以这里按工具推导一个默认值——
    // 推导出来的字段在任务输入里缺失时，`gather_reference` 会明说「未提供」，
    // 不会假装查过。
    let fetch = match skill::read_fetch(&parsed, &steps) {
        Ok(declared) => declared.or_else(|| infer_fetch(&tools, &steps)),
        Err(err) => {
            // 半个声明是配置错误：不静默降级，直接判不支持并说清。
            status = SkillStatus::Unsupported;
            reasons.push(format!("取资料声明不完整：{err}"));
            None
        }
    };

    let outputs = {
        let declared = parsed.list("outputs");
        if declared.is_empty() {
            vec!["report".to_string()]
        } else {
            declared
        }
    };

    let triggers = parsed.list("triggers");

    let manifest = SkillManifest {
        name,
        version: parsed
            .scalar("version")
            .map(str::to_string)
            .unwrap_or_else(|| plugin.version.clone()),
        risk_level: risk_level.to_string(),
        triggers,
        required_tools: tools,
        outputs,
        stop_before: parsed.scalar("stop_before").map(str::to_string),
        steps,
        source: THIRD_PARTY.to_string(),
        plugin_id: Some(plugin.id.clone()),
        fetch,
    };

    Ok(NormalizedSkill {
        manifest,
        status,
        reasons,
        body,
        description,
    })
}

/// 把归一化结果写成 sidecar，worker 只读它。
pub(crate) fn write_sidecar(
    skill_dir: &Path,
    normalized: &NormalizedSkill,
) -> Result<(), PluginError> {
    let sidecar = SkillSidecar {
        manifest: normalized.manifest.clone(),
        status: normalized.status.as_str().to_string(),
        reasons: normalized.reasons.clone(),
        body: normalized.body.clone(),
        description: normalized.description.clone(),
    };

    let raw = serde_json::to_string_pretty(&sidecar)
        .map_err(|err| PluginError::Io(format!("序列化 sidecar 失败：{err}")))?;

    std::fs::write(skill_dir.join(SIDECAR_NAME), raw)
        .map_err(|err| PluginError::Io(format!("写 sidecar 失败：{err}")))
}

/// 技能名按规范校验：1–64，仅 `a-z0-9-`，首尾非 `-`，无 `--`。
fn validate_skill_name(name: &str) -> Result<(), PluginError> {
    if name.is_empty() || name.len() > 64 {
        return Err(PluginError::Invalid(
            "技能 name 长度必须是 1–64".to_string(),
        ));
    }
    if name.starts_with('-') || name.ends_with('-') || name.contains("--") {
        return Err(PluginError::Invalid(format!(
            "技能 name 不能以连字符开头/结尾，也不能含连续连字符: {name}"
        )));
    }
    if !name
        .chars()
        .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-')
    {
        return Err(PluginError::Invalid(format!(
            "技能 name 只能用小写字母、数字与连字符: {name}"
        )));
    }
    Ok(())
}

/// `allowed-tools` → 本机工具名。
///
/// 返回「映射成功的工具」与「初始状态」。出现任何一个映射不上、又不是无害编排类的
/// 工具，整条技能判不支持——半套工具跑出来的结果没有意义。
fn map_declared_tools(
    declared: Option<&str>,
    reasons: &mut Vec<String>,
) -> (Vec<String>, SkillStatus) {
    let Some(declared) = declared else {
        return (Vec::new(), SkillStatus::Supported);
    };

    let mut tools: Vec<String> = Vec::new();
    let mut blocked: Vec<String> = Vec::new();

    for raw in declared.split(|ch: char| ch.is_whitespace() || ch == ',') {
        let token = raw.trim();
        if token.is_empty() {
            continue;
        }
        let bare = strip_tool_args(token);

        match map_one_tool(bare) {
            ToolMapping::Ready(tool) => {
                if !tools.iter().any(|existing| existing == tool) {
                    tools.push(tool.to_string());
                }
            }
            ToolMapping::Ignored => {}
            ToolMapping::Blocked(reason) => blocked.push(reason.to_string()),
        }
    }

    if blocked.is_empty() {
        (tools, SkillStatus::Supported)
    } else {
        for reason in &blocked {
            reasons.push(reason.clone());
        }
        (tools, SkillStatus::Unsupported)
    }
}

/// `Bash(git:*)` → `Bash`。
fn strip_tool_args(token: &str) -> &str {
    token.split_once('(').map_or(token, |(head, _)| head.trim())
}

enum ToolMapping {
    Ready(&'static str),
    Ignored,
    Blocked(String),
}

fn map_one_tool(name: &str) -> ToolMapping {
    match name {
        // 只读、能在本机执行。
        "WebFetch" => ToolMapping::Ready("web.fetch"),
        "WebSearch" => ToolMapping::Ready("web.search"),
        "Read" => ToolMapping::Ready("read_file"),
        "Grep" => ToolMapping::Ready("search_content"),
        "Glob" => ToolMapping::Ready("search_file"),
        "LS" | "List" => ToolMapping::Ready("list_dir"),

        // 产生动作或改文件：本机没有通用 shell，写操作也没有可用的审批通道。
        "Bash" | "BashOutput" | "KillShell" => {
            ToolMapping::Blocked("依赖 Bash：本机没有通用 shell，脚本类技能无法运行".to_string())
        }
        "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => {
            ToolMapping::Blocked("需要写文件：本机技能路径没有写操作与审批通道".to_string())
        }

        // 宿主内部编排，不产生外部动作，缺了也不影响这条技能跑。
        "Task" | "TodoWrite" | "Skill" | "SlashCommand" | "Agent" => ToolMapping::Ignored,

        other => ToolMapping::Blocked(format!(
            "依赖未支持的工具 {other}：本机只能执行只读查询与读文件"
        )),
    }
}

/// 未声明 `allowed-tools` 时对正文的启发式扫描结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ToolUsageHint {
    None,
    /// 可能依赖脚本/命令，但文案不一定可靠，只警告。
    Weak(Vec<String>),
    /// 明确写了命令或脚本路径，几乎不可能是纯提示词。
    Strong(Vec<String>),
}

/// 扫正文找「其实要跑命令」的痕迹。
///
/// 是启发式就一定会误判，所以分两级：强命中（反引号里的命令、`scripts/` 路径）
/// 几乎不会错，直接判不支持；弱命中（「运行脚本」这类措辞）可能是普通描述，
/// 只标降级。否定语境（「不要运行脚本」）要排除，否则会把一份讲注意事项的技能误杀。
pub(crate) fn scan_body_for_tool_usage(body: &str) -> ToolUsageHint {
    let mut strong: Vec<String> = Vec::new();

    // 1. 反引号或代码块里的命令形态。
    for span in inline_code_spans(body) {
        let first = span.split_whitespace().next().unwrap_or_default();
        if is_command_word(first) {
            strong.push(span.chars().take(40).collect());
        }
        if looks_like_script_path(first) {
            strong.push(span.chars().take(40).collect());
        }
    }

    // 2. 正文直接引用了 scripts/ 下的脚本。
    if body.contains("scripts/") {
        strong.push("scripts/ 目录下的脚本".to_string());
    }

    // 3. Claude 的 `!`cmd`` 动态命令注入。
    if body.lines().any(|line| line.trim_start().starts_with("!`")) {
        strong.push("!`命令` 动态注入".to_string());
    }

    if !strong.is_empty() {
        strong.sort();
        strong.dedup();
        return ToolUsageHint::Strong(strong);
    }

    // 4. 弱命中：动词 + 脚本/命令，且不在否定语境里。
    let mut weak: Vec<String> = Vec::new();
    for keyword in [
        "运行脚本",
        "执行脚本",
        "运行命令",
        "执行命令",
        "命令行",
        "run the script",
        "execute the command",
    ] {
        if body.contains(keyword) && !is_negated(body, keyword) {
            weak.push(keyword.to_string());
        }
    }

    if weak.is_empty() {
        ToolUsageHint::None
    } else {
        weak.sort();
        weak.dedup();
        ToolUsageHint::Weak(weak)
    }
}

/// 关键词前面一小段里是否出现否定词。
fn is_negated(body: &str, keyword: &str) -> bool {
    let Some(index) = body.find(keyword) else {
        return false;
    };
    let start = index.saturating_sub(12);
    let window = &body[start..index];
    [
        "不要",
        "无需",
        "不用",
        "别",
        "禁止",
        "no need to",
        "do not",
        "don't",
    ]
    .iter()
    .any(|negation| window.contains(negation))
}

/// 取出反引号与 ``` 代码块里的片段。
fn inline_code_spans(body: &str) -> Vec<&str> {
    let mut spans = Vec::new();

    // ``` 代码块：整块内容按行收集。
    let mut in_fence = false;
    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            let content = trimmed.trim_start_matches('$').trim();
            if !content.is_empty() {
                spans.push(content);
            }
        }
    }

    // 行内反引号：按奇偶切分。
    for chunk in body.split('`').skip(1).step_by(2) {
        let content = chunk.trim();
        if !content.is_empty() && !content.contains('\n') {
            spans.push(content);
        }
    }

    spans
}

fn is_command_word(word: &str) -> bool {
    matches!(
        word,
        "python"
            | "python3"
            | "bash"
            | "sh"
            | "zsh"
            | "node"
            | "npm"
            | "pnpm"
            | "yarn"
            | "bun"
            | "curl"
            | "wget"
            | "git"
            | "docker"
            | "make"
            | "uv"
            | "pip"
            | "pip3"
    )
}

fn looks_like_script_path(word: &str) -> bool {
    word.ends_with(".sh")
        || word.ends_with(".py")
        || word.ends_with(".js")
        || word.contains("scripts/")
}

/// 合并配套文档：`SKILL.md` 正文 + 同级与 `references/` 下的 `.md`。
///
/// 规范建议长内容拆到配套文件、模型按需读；但 worker 没有按需读文件的能力，
/// 所以这里一次性并进正文，并用总长上限兜住上下文成本。
fn merge_body(skill_dir: &Path, body: &str) -> String {
    let mut merged = body.trim().to_string();

    for extra in collect_reference_files(skill_dir) {
        let Ok(text) = std::fs::read_to_string(&extra) else {
            continue;
        };
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        merged.push_str("\n\n---\n\n");
        merged.push_str(text);
    }

    if merged.len() > MAX_SKILL_BODY_BYTES {
        // 按字符边界截断：产物是给人看的文本，半个汉字比少几段更难接受。
        let mut kept = String::new();
        let mut used = 0usize;
        for ch in merged.chars() {
            if used + ch.len_utf8() > MAX_SKILL_BODY_BYTES {
                break;
            }
            kept.push(ch);
            used += ch.len_utf8();
        }
        kept.push_str("\n\n…（正文超过上限，已截断）");
        return kept;
    }

    merged
}

fn collect_reference_files(skill_dir: &Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();

    let Ok(entries) = std::fs::read_dir(skill_dir) else {
        return files;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file()
            && has_md_extension(&path)
            && path.file_name().is_some_and(|name| name != "SKILL.md")
        {
            files.push(path);
        }
    }

    let references = skill_dir.join("references");
    if let Ok(entries) = std::fs::read_dir(&references) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && has_md_extension(&path) {
                files.push(path);
            }
        }
    }

    files.sort();
    files
}

fn has_md_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("md"))
}

/// 没有显式 `fetch` 声明时，按工具推一个：取第一个可执行工具与它的默认字段。
///
/// 推导不会造成"假装查过"：目标字段在任务输入里缺失时，`gather_reference`
/// 会明确写「未提供」，而不是编造一段内容。
fn infer_fetch(tools: &[String], steps: &[String]) -> Option<SkillFetch> {
    // 优先网络查询：`url` / `query` 这类字段在人填的任务输入里更常见，
    // 而文件路径通常得由用户显式给出。两个都没有时才退到读文件。
    const PRIORITY: &[FetchTool] = &[
        FetchTool::WebFetch,
        FetchTool::WebSearch,
        FetchTool::Weather,
        FetchTool::ReadFile,
        FetchTool::ListDir,
        FetchTool::SearchFile,
        FetchTool::SearchContent,
    ];

    let step = steps.first()?.clone();
    let available: Vec<FetchTool> = tools
        .iter()
        .filter_map(|name| FetchTool::parse(name))
        .collect();
    let tool = PRIORITY
        .iter()
        .find(|candidate| available.contains(candidate))?;

    Some(SkillFetch {
        step,
        from: tool.default_source(),
        tool: *tool,
    })
}

/// 从正文的 `##` 标题抽步骤。抽不到就退化成单步「执行」。
fn steps_from_body(body: &str) -> Vec<String> {
    let mut steps: Vec<String> = Vec::new();

    for line in body.lines() {
        let Some(title) = line.strip_prefix("## ") else {
            continue;
        };
        let title = title.trim();
        if title.is_empty() || is_noise_title(title) {
            continue;
        }
        steps.push(title.to_string());
        if steps.len() >= 8 {
            break;
        }
    }

    if steps.is_empty() {
        steps.push("执行".to_string());
    }

    steps
}

/// 「资源 / 示例 / 边界」这类标题是说明段，不是执行步骤。
fn is_noise_title(title: &str) -> bool {
    let lowered = title.to_lowercase();
    [
        "资源",
        "参考",
        "示例",
        "边界",
        "说明",
        "注意",
        "resources",
        "reference",
        "examples",
        "notes",
    ]
    .iter()
    .any(|noise| lowered.contains(noise))
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::skill::FetchSource;

    fn plugin() -> PluginManifest {
        PluginManifest {
            plugin_api: 1,
            id: "com.example.demo".to_string(),
            name: "demo".to_string(),
            version: "1.0.0".to_string(),
            author: None,
            description: None,
        }
    }

    fn write_skill(dir: &Path, content: &str) -> std::path::PathBuf {
        let skill_dir = dir.join("skills").join("demo");
        std::fs::create_dir_all(&skill_dir).expect("建目录失败");
        std::fs::write(skill_dir.join("SKILL.md"), content).expect("写 SKILL.md 失败");
        skill_dir
    }

    fn minimal() -> &'static str {
        "---\nname: demo\ndescription: 做点事\n---\n正文说明\n"
    }

    #[test]
    fn fills_defaults_for_spec_compliant_skill() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(temp.path(), minimal());

        let normalized = normalize(&dir, "demo", &plugin()).expect("应归一化成功");

        assert_eq!(normalized.status, SkillStatus::Supported);
        assert_eq!(normalized.manifest.version, "1.0.0", "取插件版本");
        assert_eq!(normalized.manifest.risk_level, "read");
        assert_eq!(normalized.manifest.outputs, vec!["report"]);
        assert_eq!(normalized.manifest.steps, vec!["执行"]);
        assert_eq!(normalized.manifest.source, THIRD_PARTY);
        assert_eq!(
            normalized.manifest.plugin_id.as_deref(),
            Some("com.example.demo")
        );
    }

    #[test]
    fn maps_read_only_tools_to_local_names() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: demo\ndescription: x\nallowed-tools: Read Grep Glob WebFetch\n---\n正文\n",
        );

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功");

        assert_eq!(normalized.status, SkillStatus::Supported);
        assert_eq!(
            normalized.manifest.required_tools,
            // 按声明顺序，不去重排序：顺序对排查"这条技能到底声明了什么"有用。
            vec!["read_file", "search_content", "search_file", "web.fetch"]
        );
        let fetch = normalized.manifest.fetch.expect("应推导出 fetch");
        assert_eq!(fetch.tool, FetchTool::WebFetch);
        assert_eq!(fetch.from, FetchSource::Url);
    }

    #[test]
    fn bash_dependency_is_unsupported_with_reason() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: demo\ndescription: x\nallowed-tools: Bash(git:*) Read\n---\n正文\n",
        );

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功归一化");

        assert_eq!(normalized.status, SkillStatus::Unsupported);
        assert!(
            normalized
                .reasons
                .iter()
                .any(|reason| reason.contains("Bash")),
            "原因里要写清是 Bash: {:?}",
            normalized.reasons
        );
    }

    #[test]
    fn write_tools_are_unsupported() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: demo\ndescription: x\nallowed-tools: Write Edit\n---\n正文\n",
        );

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功");
        assert_eq!(normalized.status, SkillStatus::Unsupported);
        assert!(normalized
            .reasons
            .iter()
            .any(|reason| reason.contains("写文件")));
    }

    #[test]
    fn orchestration_tools_are_ignored_not_blocked() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: demo\ndescription: x\nallowed-tools: Task TodoWrite WebFetch\n---\n正文\n",
        );

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功");
        assert_eq!(normalized.status, SkillStatus::Supported);
        assert_eq!(normalized.manifest.required_tools, vec!["web.fetch"]);
    }

    /// frontmatter 写了 `steps` 时以它为准：`fetch.step` 按它对齐，
    /// 正文标题只是给人读的说明。
    ///
    /// 反过来只认正文标题时，一个把步骤写在 frontmatter 里的包会因为
    /// "标题里没有这一步"被判成 unsupported——包本身完全正确。
    #[test]
    fn declared_steps_win_over_body_headings() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: demo\ndescription: 查天气\nversion: 1.0.0\nrisk_level: read\n\
             outputs: [report]\nsteps:\n  - 解析需求\n  - 查询参考信息\n\
             fetch.step: 查询参考信息\nfetch.from: city\nfetch.tool: weather.current\n---\n\
             ## 步骤说明\n\n1. 有城市就查天气。\n",
        );

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功归一化");

        assert_eq!(
            normalized.status,
            SkillStatus::Supported,
            "步骤声明完整时不该被判不支持: {:?}",
            normalized.reasons
        );
        assert_eq!(
            normalized.manifest.steps,
            vec!["解析需求", "查询参考信息"],
            "以 frontmatter 的步骤为准"
        );
        let fetch = normalized.manifest.fetch.expect("应保留 fetch 声明");
        assert_eq!(fetch.step, "查询参考信息");
    }

    /// 没写 allowed-tools、正文却在指挥跑脚本——这是最容易「假装成功」的一类。
    #[test]
    fn undeclared_shell_command_in_body_is_unsupported() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: demo\ndescription: x\n---\n运行 `python scripts/extract.py` 提取文本。\n",
        );

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功");
        assert_eq!(normalized.status, SkillStatus::Unsupported);
        assert!(normalized
            .reasons
            .iter()
            .any(|reason| reason.contains("shell")));
    }

    #[test]
    fn weak_hint_only_degrades() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: demo\ndescription: x\n---\n如果用户给了文件，可以执行脚本处理。\n",
        );

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功");
        assert_eq!(normalized.status, SkillStatus::Degraded);
        assert!(!normalized.reasons.is_empty());
    }

    /// 否定语境不能误判：这份技能恰恰是在说「别跑脚本」。
    #[test]
    fn negated_shell_mention_is_not_flagged() {
        assert_eq!(
            scan_body_for_tool_usage("不要运行脚本，也不要用命令行，只整理用户给的文本。"),
            ToolUsageHint::None
        );
    }

    #[test]
    fn plain_prompt_skill_is_clean() {
        assert_eq!(
            scan_body_for_tool_usage("## 步骤\n1. 读一遍\n2. 写成纪要\n"),
            ToolUsageHint::None
        );
    }

    #[test]
    fn steps_come_from_headings_and_skip_noise() {
        assert_eq!(
            steps_from_body("## 收集信息\n## 分析\n## 参考资源\n## 边界\n## 输出\n"),
            vec!["收集信息", "分析", "输出"]
        );
    }

    #[test]
    fn references_are_merged_into_body() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(temp.path(), minimal());
        std::fs::create_dir_all(dir.join("references")).expect("建 references");
        std::fs::write(dir.join("references/api.md"), "接口细节").expect("写");

        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功");
        assert!(normalized.body.contains("接口细节"));
        assert!(normalized.body.contains("正文说明"));
    }

    #[test]
    fn sidecar_roundtrips() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(temp.path(), minimal());
        let normalized = normalize(&dir, "demo", &plugin()).expect("应成功");

        write_sidecar(&dir, &normalized).expect("写 sidecar 失败");

        let raw = std::fs::read_to_string(dir.join(SIDECAR_NAME)).expect("读 sidecar");
        let sidecar: SkillSidecar = serde_json::from_str(&raw).expect("解析 sidecar");
        assert_eq!(sidecar.status(), SkillStatus::Supported);
        assert_eq!(sidecar.manifest.name, "demo");
        assert!(sidecar.body.contains("正文说明"));
    }

    #[test]
    fn rejects_name_with_uppercase() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(
            temp.path(),
            "---\nname: Demo-Skill\ndescription: x\n---\n正文\n",
        );
        assert!(matches!(
            normalize(&dir, "demo", &plugin()),
            Err(PluginError::Invalid(_))
        ));
    }

    #[test]
    fn rejects_consecutive_dashes_in_name() {
        let temp = tempfile::tempdir().expect("临时目录");
        let dir = write_skill(temp.path(), "---\nname: a--b\ndescription: x\n---\n正文\n");
        assert!(normalize(&dir, "demo", &plugin()).is_err());
    }
}
