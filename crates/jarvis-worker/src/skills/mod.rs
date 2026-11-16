//! 内置技能加载与校验。
//!
//! `SKILL.md` 的解析已经下沉到 [`protocol::skill`]——装包时的兼容层（在 service）
//! 也要读同一份格式，两处各写一份必然漂移。这里只做 worker 侧的事：
//! **加载内置技能、校验它与工具注册表是否自洽**。
//!
//! frontmatter 是契约：`required_tools`、`risk_level`、`outputs`、`stop_before`
//! 都要能被代码检查，而不是靠提示词自觉。

use std::collections::HashSet;
use std::path::Path;

use protocol::skill::{SkillSidecar, SIDECAR_NAME};
use protocol::{parse_builtin, SkillManifest, LOCAL_TOOL_WHITELIST};

use crate::tools::ToolRegistry;

/// 已加载的技能。
///
/// 技能来源（`builtin` / `third_party`）记在 `manifest.source` 里，
/// 不在这里重复一份——两份来源字段迟早会不一致。
#[derive(Debug, Clone)]
pub(crate) struct LoadedSkill {
    pub(crate) manifest: SkillManifest,
    /// frontmatter 之后的正文：每步说明、边界与产物要求。
    ///
    /// 它是给模型看的提示词素材，不进 `SkillManifest` 契约——
    /// 服务端不需要正文，进契约只会让 IPC 消息白白变大。
    pub(crate) body: String,
}

/// 技能校验错误。解析错误由 [`protocol::SkillError`] 表达，两者分开：
/// 一个是"文件写错了"，一个是"声明与能力不自洽"，处置方式不同。
#[derive(Debug, thiserror::Error)]
pub(crate) enum SkillError {
    #[error("引用了未注册的工具: {0}")]
    UnknownTool(String),
    #[error("技能声明的风险低于其工具风险: 技能={skill} 工具={tool}")]
    RiskTooLow { skill: String, tool: String },
    #[error("技能没有步骤")]
    NoSteps,
    #[error("技能没有声明产物 outputs")]
    NoOutputs,
}

/// 加载全部内置技能。任一技能非法即跳过并记 error，不影响其他技能。
///
/// `code_enabled` 为 false 时**不加载** `code-task`：能力关闭却把技能列出来，
/// 用户点了只会得到一个 `code_unavailable`，不如一开始就不出现。
///
/// `trip-plan` / `bill-explain` 不在这里：它们已改为随应用分发的外部插件
/// （service 侧 `plugin::seed` 在首次启动时安装）。外部插件才能停用与卸载，
/// 编译进 worker 就永远删不掉，`@` 候选里会一直占位。
pub(crate) fn load_builtin(tools: &ToolRegistry, code_enabled: bool) -> Vec<LoadedSkill> {
    const ALL: &[(&str, &str)] = &[("code-task", include_str!("code-task/SKILL.md"))];
    let entries: &[(&str, &str)] = if code_enabled { ALL } else { &[] };

    let mut loaded = Vec::new();
    for &(name, content) in entries {
        match parse_builtin(content) {
            Ok((manifest, body)) => {
                let skill = LoadedSkill { manifest, body };
                match validate(&skill, tools) {
                    Ok(()) => loaded.push(skill),
                    Err(err) => tracing::error!(skill = name, %err, "技能校验失败，已禁用"),
                }
            }
            Err(err) => tracing::error!(skill = name, %err, "技能解析失败，已禁用"),
        }
    }
    loaded
}

/// 加载全部技能：内置 + 插件安装目录。
///
/// `plugin_dir` 由 service 通过环境变量下发（worker 不读配置文件）。
/// 目录不存在是正常情况——没装过插件时它就不会被创建。
pub(crate) fn load_all(
    tools: &ToolRegistry,
    code_enabled: bool,
    plugin_dir: Option<&Path>,
) -> Vec<LoadedSkill> {
    let mut loaded = load_builtin(tools, code_enabled);

    let Some(plugin_dir) = plugin_dir else {
        return loaded;
    };

    let mut seen: HashSet<String> = loaded
        .iter()
        .map(|skill| skill.manifest.name.clone())
        .collect();

    for skill in load_plugins(tools, plugin_dir) {
        // 同名只留第一条：跨版本残留或手工拷贝都可能造出重复，
        // 加载两份会让技能列表出现重复项，任务派发也可能命中旧的那条。
        if !seen.insert(skill.manifest.name.clone()) {
            tracing::warn!(skill = %skill.manifest.name, "技能名重复，保留先加载的那份");
            continue;
        }
        loaded.push(skill);
    }

    loaded
}

/// 扫描 `<plugins>/<id>/<version>/`，读 sidecar。
///
/// **只信 sidecar**，不重新解析 `SKILL.md`：补缺省、映射工具、判三态都是
/// service 装包时做完的事，worker 再做一遍只会出现两套结论。
fn load_plugins(tools: &ToolRegistry, plugins_dir: &Path) -> Vec<LoadedSkill> {
    let Ok(plugins) = std::fs::read_dir(plugins_dir) else {
        return Vec::new();
    };

    let mut loaded = Vec::new();

    for plugin in plugins.flatten() {
        let plugin_path = plugin.path();
        let Some(plugin_name) = plugin_path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        // 跳过 `.tmp` 安装暂存目录。
        if !plugin_path.is_dir() || plugin_name.starts_with('.') {
            continue;
        }

        let Ok(versions) = std::fs::read_dir(&plugin_path) else {
            continue;
        };
        for version in versions.flatten() {
            let version_path = version.path();
            if !version_path.is_dir() {
                continue;
            }
            loaded.extend(load_package_skills(tools, &version_path));
        }
    }

    loaded
}

/// 一个安装目录下的所有技能：根级单技能 + `skills/*/`。
fn load_package_skills(tools: &ToolRegistry, package_root: &Path) -> Vec<LoadedSkill> {
    let mut dirs: Vec<std::path::PathBuf> = Vec::new();

    if package_root.join(SIDECAR_NAME).is_file() {
        dirs.push(package_root.to_path_buf());
    }

    if let Ok(entries) = std::fs::read_dir(package_root.join("skills")) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() && path.join(SIDECAR_NAME).is_file() {
                dirs.push(path);
            }
        }
    }

    dirs.iter()
        .filter_map(|dir| load_sidecar(tools, dir))
        .collect()
}

fn load_sidecar(tools: &ToolRegistry, skill_dir: &Path) -> Option<LoadedSkill> {
    let raw = std::fs::read_to_string(skill_dir.join(SIDECAR_NAME)).ok()?;

    let sidecar: SkillSidecar = match serde_json::from_str(&raw) {
        Ok(sidecar) => sidecar,
        Err(err) => {
            tracing::error!(dir = %skill_dir.display(), %err, "sidecar 解析失败，已跳过");
            return None;
        }
    };

    if !sidecar.is_loadable() {
        // `unsupported` 的技能装在那里但不加载：让模型能用一条跑不了的技能，
        // 只会换来一份"看起来完成了"的空结果。
        tracing::info!(skill = %sidecar.manifest.name, "技能标记为不支持，不加载");
        return None;
    }

    let skill = LoadedSkill {
        manifest: sidecar.manifest,
        body: sidecar.body,
    };

    match validate(&skill, tools) {
        Ok(()) => Some(skill),
        Err(err) => {
            tracing::error!(skill = %skill.manifest.name, %err, "插件技能校验失败，已跳过");
            None
        }
    }
}

/// 校验技能是否可执行。
pub(crate) fn validate(skill: &LoadedSkill, tools: &ToolRegistry) -> Result<(), SkillError> {
    if skill.manifest.steps.is_empty() {
        return Err(SkillError::NoSteps);
    }
    if skill.manifest.outputs.is_empty() {
        return Err(SkillError::NoOutputs);
    }

    let skill_risk = risk_rank(&skill.manifest.risk_level);

    for tool in &skill.manifest.required_tools {
        if !tool_is_known(tool, tools) {
            return Err(SkillError::UnknownTool(tool.clone()));
        }
        let tool_risk = tool_risk_rank(tool);
        if skill_risk < tool_risk {
            return Err(SkillError::RiskTooLow {
                skill: skill.manifest.risk_level.clone(),
                tool: tool.clone(),
            });
        }
    }

    // 取资料声明里的工具同样必须在册：写错一个名字就整条技能不加载，
    // 比"跑起来安静地取不到资料"好排查得多。
    if let Some(fetch) = &skill.manifest.fetch {
        let tool = fetch.tool.as_str();
        if !tool_is_known(tool, tools) {
            return Err(SkillError::UnknownTool(tool.to_string()));
        }
    }

    Ok(())
}

/// 工具是否可用。
///
/// 两类都算"在册"：worker 本地执行的（`web.fetch` 等，由 `ToolRegistry` 登记），
/// 以及经 `LocalToolCall` 桥回服务端执行的只读文件工具（`read_file` 等）。
/// 后者不在 `ToolRegistry` 里，但技能确实能用——漏判会让合规技能被误拒。
fn tool_is_known(tool: &str, tools: &ToolRegistry) -> bool {
    tools.has(tool) || LOCAL_TOOL_WHITELIST.contains(&tool)
}

const fn risk_rank(level: &str) -> u8 {
    match level.as_bytes() {
        b"read" => 0,
        b"reversible_write" => 1,
        b"irreversible_write" => 2,
        _ => 0,
    }
}

/// 工具风险表。新增工具时必须同步这里，否则技能校验会漏判。
///
/// 未列出的工具按最高风险处理：漏填的后果是"技能被拒"，而不是"危险操作被放行"。
const fn tool_risk_rank(tool: &str) -> u8 {
    match tool.as_bytes() {
        // 只读：出网读页面、查天气、搜关键词，以及读项目文件。
        b"web.search" | b"web.fetch" | b"weather.current" => 0,
        // 读本地文件不外发（除模型上下文），仍是只读，与上面同档。
        b"read_file" | b"list_dir" | b"search_file" | b"search_content" => 0,
        // 编码任务会改文件、跑命令：即使它只在 worktree 内活动，也按不可逆写处理。
        b"code.exec" => 2,
        _ => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"---
name: demo
version: 0.1.0
risk_level: read
triggers: ["出行"]
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

    fn loaded(content: &str) -> LoadedSkill {
        let (manifest, body) = parse_builtin(content).expect("解析失败");
        LoadedSkill { manifest, body }
    }

    #[test]
    fn rejects_unknown_tool() {
        let skill = loaded(&SAMPLE.replace("web.fetch", "browser.click"));
        let tools = ToolRegistry::new();
        assert!(matches!(
            validate(&skill, &tools),
            Err(SkillError::UnknownTool(_))
        ));
    }

    #[test]
    fn accepts_valid_skill() {
        let skill = loaded(SAMPLE);
        let tools = ToolRegistry::new();
        assert!(validate(&skill, &tools).is_ok());
    }

    /// 文件工具不在 `ToolRegistry` 里，但技能确实能用（经桥回服务端执行）。
    /// 漏判会让所有「读文件」类的外部技能在校验阶段被误拒。
    #[test]
    fn local_file_tools_are_accepted_even_though_registry_lacks_them() {
        let content = r#"---
name: reader
version: 0.1.0
risk_level: read
required_tools:
  - read_file
outputs: [report]
fetch.step: 查资料
fetch.from: path
fetch.tool: read_file
steps:
  - 查资料
---
正文
"#;
        let skill = loaded(content);
        let tools = ToolRegistry::new();
        assert!(validate(&skill, &tools).is_ok());
    }

    #[test]
    fn fetch_declaration_with_unknown_tool_is_rejected() {
        let content = r#"---
name: broken
version: 0.1.0
risk_level: read
outputs: [report]
fetch.step: 查资料
fetch.from: url
fetch.tool: browser.click
steps:
  - 查资料
---
正文
"#;
        // 解析阶段就拒（工具名不在枚举里），不会走到 validate。
        assert!(parse_builtin(content).is_err());
    }

    /// 内置只剩编码技能。
    ///
    /// `trip-plan` / `bill-explain` 已改为随应用分发的外部插件：它们要能
    /// 停用、能卸载，编译进 worker 就永远删不掉。所以这里只剩 `code-task`，
    /// 且它仍受能力开关控制。
    #[test]
    fn builtin_skills_are_only_code_task() {
        let tools = ToolRegistry::new();
        assert!(
            load_builtin(&tools, false).is_empty(),
            "编码能力关闭时不该有任何内置技能"
        );

        let skills = load_builtin(&tools, true);
        let names: Vec<&str> = skills
            .iter()
            .map(|skill| skill.manifest.name.as_str())
            .collect();
        assert_eq!(names, vec!["code-task"]);
        assert!(skills.iter().all(|skill| !skill.manifest.steps.is_empty()));
        // 正文是模型提示词的唯一来源：为空等于技能"只有骨架没有说明"。
        assert!(skills.iter().all(|skill| !skill.body.is_empty()));
        // 内置技能一律标 builtin，外部插件标 third_party。
        assert!(skills
            .iter()
            .all(|skill| skill.manifest.source == protocol::BUILTIN_SOURCE));
    }

    fn sidecar_json(name: &str, status: &str) -> String {
        serde_json::json!({
            "manifest": {
                "name": name,
                "version": "1.0.0",
                "risk_level": "read",
                "outputs": ["report"],
                "steps": ["执行"],
                "source": "third_party",
                "plugin_id": "com.example.demo"
            },
            "status": status,
            "reasons": [],
            "body": "插件技能的正文"
        })
        .to_string()
    }

    fn write_plugin_skill(root: &Path, plugin: &str, version: &str, skill: &str, json: &str) {
        let dir = root.join(plugin).join(version).join("skills").join(skill);
        std::fs::create_dir_all(&dir).expect("建目录失败");
        std::fs::write(dir.join(SIDECAR_NAME), json).expect("写 sidecar 失败");
    }

    #[test]
    fn loads_plugin_skills_from_the_installed_directory() {
        let temp = tempfile::tempdir().expect("临时目录");
        write_plugin_skill(
            temp.path(),
            "com.example.weekly",
            "1.0.0",
            "weekly-digest",
            &sidecar_json("weekly-digest", "supported"),
        );

        let tools = ToolRegistry::new();
        // 能力开启：要有内置技能在场，才验证得出"内置 + 插件"一起加载。
        let skills = load_all(&tools, true, Some(temp.path()));

        let names: Vec<&str> = skills
            .iter()
            .map(|skill| skill.manifest.name.as_str())
            .collect();
        assert!(names.contains(&"code-task"), "内置技能仍在");
        assert!(names.contains(&"weekly-digest"), "插件技能应被加载");

        let plugin = skills
            .iter()
            .find(|skill| skill.manifest.name == "weekly-digest")
            .expect("应找到插件技能");
        assert_eq!(plugin.manifest.source, "third_party");
        assert_eq!(
            plugin.manifest.plugin_id.as_deref(),
            Some("com.example.demo")
        );
        assert_eq!(plugin.body, "插件技能的正文");
    }

    /// `unsupported` 的技能装在磁盘上但不加载：让模型看见一条跑不了的技能，
    /// 只会换来一份"看起来完成了"的空结果。
    #[test]
    fn unsupported_skill_is_not_loaded() {
        let temp = tempfile::tempdir().expect("临时目录");
        write_plugin_skill(
            temp.path(),
            "com.example.shell",
            "1.0.0",
            "sheller",
            &sidecar_json("sheller", "unsupported"),
        );

        let tools = ToolRegistry::new();
        let skills = load_all(&tools, false, Some(temp.path()));

        assert!(!skills.iter().any(|skill| skill.manifest.name == "sheller"));
    }

    /// 插件技能与内置技能同名时保留内置：后者随二进制发布，
    /// 被一个装错了的包顶掉会让人以为"code-task 坏了"。
    #[test]
    fn plugin_cannot_shadow_a_builtin_skill() {
        let temp = tempfile::tempdir().expect("临时目录");
        write_plugin_skill(
            temp.path(),
            "com.example.fake",
            "1.0.0",
            "code-task",
            &sidecar_json("code-task", "supported"),
        );

        let tools = ToolRegistry::new();
        // 能力开启才有内置 code-task 可被"挤占"。
        let skills = load_all(&tools, true, Some(temp.path()));

        let hits = skills
            .iter()
            .filter(|skill| skill.manifest.name == "code-task")
            .count();
        assert_eq!(hits, 1, "同名技能只能出现一次");

        let code = skills
            .iter()
            .find(|skill| skill.manifest.name == "code-task")
            .expect("应存在");
        assert_eq!(code.manifest.source, protocol::BUILTIN_SOURCE);
    }

    #[test]
    fn missing_plugin_directory_is_not_an_error() {
        let tools = ToolRegistry::new();
        let skills = load_all(&tools, false, Some(Path::new("/nonexistent/plugins")));
        assert!(
            skills.is_empty(),
            "示例技能已改为外部插件，没有插件目录时不该凭空出现技能"
        );
    }

    #[test]
    fn code_task_only_loads_when_the_capability_is_enabled() {
        let tools = ToolRegistry::new();

        let disabled = load_builtin(&tools, false);
        assert!(
            !disabled
                .iter()
                .any(|skill| skill.manifest.name == "code-task"),
            "能力关闭时不该出现 code-task"
        );

        let enabled = load_builtin(&tools, true);
        let code_task = enabled
            .iter()
            .find(|skill| skill.manifest.name == "code-task")
            .expect("能力开启时应加载 code-task");

        assert_eq!(code_task.manifest.risk_level, "irreversible_write");
        assert_eq!(code_task.manifest.required_tools, vec!["code.exec"]);
        assert_eq!(
            code_task.manifest.outputs,
            vec!["change_summary", "diff"],
            "产物种类必须与服务端校验一致"
        );
        assert!(code_task.manifest.stop_before.is_some(), "必须停在合并前");
        assert!(!code_task.body.is_empty());
    }
}
