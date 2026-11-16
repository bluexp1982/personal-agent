//! 技能列表（只读）。
//!
//! 数据来源：worker 在 `hello` 里上报的技能清单。worker 未连接时回退到
//! 内置静态清单——技能随二进制发布，即使执行进程暂时没起来，"它能干什么"
//! 也应当是稳定的。
//!
//! 按项目模式过滤：声明了 `code.exec` 能力的技能（编码任务）只在 Git 项目出现。
//! 判断走能力声明而不是技能名，新增编码类技能不需要再改这里。

use std::collections::HashMap;

use axum::extract::{Query, State};
use axum::Json;
use protocol::{ErrorCode, ProjectMode, Skill, SkillManifest, SkillStatus};
use serde::Deserialize;

use super::error::ApiRejection;
use crate::plugin::store::{self, SkillAnnotation};
use crate::state::AppState;

/// 让一个技能具备"编码任务"性质的能力名。
const CODE_TOOL: &str = "code.exec";

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub mode: Option<String>,
    /// 默认 `false`：`unsupported` 的技能已被过滤（它们只该出现在插件管理页）。
    /// 设为 `true` 一并返回，仅供诊断。
    #[serde(default)]
    pub include_unsupported: bool,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<Vec<Skill>>, ApiRejection> {
    let mode = parse_mode(query.mode.as_deref())?;

    // 插件名、状态与原因只在库里（worker 上报的清单只有契约字段）。
    // 查不到就当空表：技能列表不该因为一次查库失败而整页打不开。
    let annotations = store::skill_annotations(&state.pool)
        .await
        .unwrap_or_default();

    let mut skills: Vec<Skill> = {
        let registry = state
            .skills
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        registry
            .iter()
            // 停用 / 卸载的插件技能立即不出现：worker 的 registry 要到重载后
            // 才更新，这期间只能以库为准。没有标注的若是内置技能（`plugin_id`
            // 为空）照常保留；声明了 `plugin_id` 却查不到，说明包已被卸载。
            .filter(|manifest| match annotations.get(&manifest.name) {
                Some(annotation) => annotation.enabled,
                None => manifest.plugin_id.is_none(),
            })
            .map(|manifest| to_skill(manifest, &annotations))
            .collect()
    };

    if skills.is_empty() {
        skills = builtin_fallback(state.config.code.enabled);
    }

    // 插件技能**始终**从库里补，而不是只在 worker 为空时补。
    //
    // worker 的 registry 只是它启动/重载那一刻的快照：「刚装完还没重载」
    // 「上报里只有内置技能」都会让插件技能凭空消失——用户看到的就是
    // `@` 候选整个空掉，因为前端还会把编码技能过滤掉。库里是安装时的
    // 结论，本来就更权威；同名的以 worker 上报为准（它带执行侧状态）。
    if let Ok(page) = store::list(&state.pool, false).await {
        let mut known: std::collections::HashSet<String> =
            skills.iter().map(|skill| skill.name.clone()).collect();
        for plugin in page.items.into_iter().filter(|plugin| plugin.enabled) {
            for skill in plugin.skills {
                if known.insert(skill.name.clone()) {
                    skills.push(skill);
                }
            }
        }
    }

    // `unsupported` 不进列表：它依赖本机没有的工具，装进去也跑不了。
    // 它只该出现在插件管理页，那里能看到原因。
    if !query.include_unsupported {
        skills.retain(|skill| skill.status != SkillStatus::Unsupported);
    }
    skills.retain(|skill| allowed_in_mode(&skill.required_tools, mode));
    Ok(Json(skills))
}

/// 当前可用技能名。对话引擎用它约束"建议哪件事"，避免模型编出不存在的技能。
///
/// 与 [`list`] 同源：优先 worker 上报，worker 未连接时用内置兜底；同样按模式过滤。
///
/// 比 [`list`] 多一道插件过滤：**只有已启用且可运行的插件技能才进候选**。
/// 把装不了或已停用的技能喂给模型，只会让它建议一些点了就失败的事。
pub(crate) async fn available_names_for(
    state: &AppState,
    mode: Option<ProjectMode>,
) -> Vec<String> {
    let runnable: std::collections::HashSet<String> =
        store::enabled_runnable_skill_names(&state.pool)
            .await
            .unwrap_or_default()
            .into_iter()
            .collect();

    let mut names: Vec<String> = {
        let registry = state
            .skills
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry
            .iter()
            .filter(|manifest| allowed_in_mode(&manifest.required_tools, mode))
            .filter(|manifest| {
                // 内置技能不查库：它们是随二进制发布的，永远可用。
                let source = if manifest.source.trim().is_empty() {
                    protocol::BUILTIN_SOURCE
                } else {
                    manifest.source.as_str()
                };
                source == protocol::BUILTIN_SOURCE || runnable.contains(&manifest.name)
            })
            .map(|manifest| manifest.name.clone())
            .collect()
    };

    if names.is_empty() {
        names = builtin_fallback(state.config.code.enabled)
            .into_iter()
            .filter(|skill| allowed_in_mode(&skill.required_tools, mode))
            .map(|skill| skill.name)
            .collect();
    }

    // 插件技能**始终**追加，而不是 worker 非空就提前返回：registry 只是
    // 快照，刚装完/刚启用还没重载时它里面没有新技能，模型也就不会建议它。
    // 只追加"已启用且可运行"的（`runnable` 就是这份名单）。
    let mut plugin_names: Vec<String> = runnable.into_iter().collect();
    plugin_names.sort();
    for name in plugin_names {
        if !names.iter().any(|existing| existing == &name) {
            names.push(name);
        }
    }

    names
}

fn parse_mode(raw: Option<&str>) -> Result<Option<ProjectMode>, ApiRejection> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(raw) => ProjectMode::parse(raw).map(Some).ok_or_else(|| {
            ApiRejection::new(
                ErrorCode::InvalidRequest,
                "unknown project mode",
                "模式取值应为 code 或 work",
            )
        }),
        None => Ok(None),
    }
}

/// 该技能在给定模式下是否可用。`None`（不带 mode）表示不过滤。
fn allowed_in_mode(required_tools: &[String], mode: Option<ProjectMode>) -> bool {
    match mode {
        // 普通项目不提供任何 Git / 编码能力，编码技能连出现都不该出现。
        Some(ProjectMode::Work) => !required_tools.iter().any(|tool| tool == CODE_TOOL),
        Some(ProjectMode::Code) | None => true,
    }
}

/// worker 上报的清单 → 对外技能描述。
///
/// `source` 空值按 `builtin` 处理：老 worker 不带这个字段，语义上就是内置技能。
/// `plugin_name` 与 `description` 来自装包时的归一化结果，worker 不知道——
/// 这一层先留空，由插件管理面在后续查询里补齐（见 `plugin::store`）。
fn to_skill(manifest: &SkillManifest, annotations: &HashMap<String, SkillAnnotation>) -> Skill {
    let source = if manifest.source.trim().is_empty() {
        protocol::BUILTIN_SOURCE.to_string()
    } else {
        manifest.source.clone()
    };

    // 插件技能的来源与状态以库里为准：worker 只上报契约字段，
    // 而"这条技能属于哪个插件、能不能跑"是装包时的结论。
    let annotation = annotations.get(&manifest.name);

    Skill {
        name: manifest.name.clone(),
        version: manifest.version.clone(),
        source,
        risk_level: manifest.risk_level.clone(),
        required_tools: manifest.required_tools.clone(),
        plugin_id: manifest.plugin_id.clone(),
        plugin_name: annotation.map(|item| item.plugin_name.clone()),
        description: annotation.and_then(|item| item.description.clone()),
        status: annotation.map_or(SkillStatus::Supported, |item| item.status),
        reasons: annotation.map_or_else(Vec::new, |item| item.reasons.clone()),
    }
}

/// 内置技能的静态描述。worker 未连接时用它兜底，保证界面不空。
fn builtin_skill(name: &str, version: &str, risk: &str, tools: &[&str]) -> Skill {
    Skill {
        name: name.to_string(),
        version: version.to_string(),
        source: protocol::BUILTIN_SOURCE.to_string(),
        risk_level: risk.to_string(),
        required_tools: tools.iter().map(|tool| (*tool).to_string()).collect(),
        plugin_id: None,
        plugin_name: None,
        description: None,
        status: SkillStatus::Supported,
        reasons: Vec::new(),
    }
}

/// worker 未连接时的兜底列表。与 `jarvis-worker/skills/*/SKILL.md` 保持一致。
///
/// `code-task` 只在能力启用时出现：能力关掉却把技能列出来，用户点了只会拿到
/// `code_unavailable`，不如一开始就不显示。
///
/// 只剩 `code-task`：`trip-plan` / `bill-explain` 已改为随应用分发的示例插件
/// （见 `plugin::seed`）。它们的真实状态在库与磁盘里，由调用方"从库里补插件
/// 技能"那一支给出——这里再硬编码一份，同名技能就会出现两条。
///
/// 插件技能**不进兜底**：它们的可用性取决于磁盘上的实际状态，
/// worker 没连上时谎报一份清单只会让用户点到注定失败的选项。
fn builtin_fallback(code_enabled: bool) -> Vec<Skill> {
    if !code_enabled {
        return Vec::new();
    }
    vec![builtin_skill(
        "code-task",
        "0.1.0",
        "irreversible_write",
        &[CODE_TOOL],
    )]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tools(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_string()).collect()
    }

    #[test]
    fn work_mode_hides_code_skills() {
        let code = tools(&["code.exec"]);
        assert!(!allowed_in_mode(&code, Some(ProjectMode::Work)));
        assert!(allowed_in_mode(&code, Some(ProjectMode::Code)));
        assert!(allowed_in_mode(&code, None), "不带 mode 时不过滤");
    }

    #[test]
    fn read_only_skills_are_available_in_both_modes() {
        let web = tools(&["web.fetch"]);
        assert!(allowed_in_mode(&web, Some(ProjectMode::Work)));
        assert!(allowed_in_mode(&web, Some(ProjectMode::Code)));
        assert!(allowed_in_mode(&[], Some(ProjectMode::Work)));
    }

    #[test]
    fn fallback_contains_code_task_only_when_enabled() {
        let enabled = builtin_fallback(true);
        assert!(enabled.iter().any(|skill| skill.name == "code-task"));

        let disabled = builtin_fallback(false);
        assert!(!disabled.iter().any(|skill| skill.name == "code-task"));
    }
}
