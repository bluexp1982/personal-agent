//! 审批载荷。
//!
//! 一次审批只接受一次决定；超时后由服务端置为 `expired`，任务按失败结束。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalDecision {
    Pending,
    Approved,
    Rejected,
    Expired,
}

impl ApprovalDecision {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
            Self::Rejected => "rejected",
            Self::Expired => "expired",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "pending" => Some(Self::Pending),
            "approved" => Some(Self::Approved),
            "rejected" => Some(Self::Rejected),
            "expired" => Some(Self::Expired),
            _ => None,
        }
    }
}

/// 审批粒度。
///
/// 客户端靠它决定渲染哪张卡，不靠 `action` 字符串前缀匹配——后者太脆。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalScope {
    /// 任务级：跑完了请求合并。
    #[default]
    Task,
    /// 工具级：某一次工具调用执行前的放行/驳回。
    Tool,
}

impl ApprovalScope {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Task => "task",
            Self::Tool => "tool",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "task" => Some(Self::Task),
            "tool" => Some(Self::Tool),
            _ => None,
        }
    }
}

/// 工具级审批附带的可读信息：只放脱敏摘要，不放文件内容与命令原文。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalTool {
    pub name: String,
    pub risk: crate::code_event::RiskLevel,
    /// 已脱敏截断的输入摘要。
    pub digest: String,
    /// 是否提供「本任务内不再询问这类操作」。
    ///
    /// 由 service 按本次命中的规则计算；老服务端写库时按 `false` 兜底，
    /// 客户端据此决定要不要画勾选框。
    #[serde(default)]
    pub rememberable: bool,
}

/// 不影响「要不要问人」的规则：它们只解释影响范围，随时可以自动放行。
pub const SAFE_RULE_NAMES: &[&str] = &[
    "read_only",
    "worktree_write",
    "scratch_delete",
    "local_network",
    "inline_script",
];

/// 不允许「本任务内不再询问」的规则：凭证、提权、越界写。
pub const NON_REMEMBERABLE_RULES: &[&str] = &[
    "sensitive_path",
    "privilege_command",
    "path_outside_worktree",
];

/// 本次调用里真正需要人回答的规则名。
///
/// - 过滤掉 `SAFE_RULE_NAMES`；
/// - 只读命令命中的越界路径不算（CLI 翻自己的历史目录不该弹卡）；
/// - 追加规则（配置里的自定义规则名）也会被算进来，自动档不会因为
///   "规则名不在内置表里"而悄悄放行。
pub fn asking_rule_names(rules: &[String]) -> Vec<String> {
    let read_only = rules.iter().any(|rule| rule == "read_only");
    rules
        .iter()
        .filter(|rule| {
            !SAFE_RULE_NAMES.contains(&rule.as_str())
                && !(read_only && rule.as_str() == "path_outside_worktree")
        })
        .cloned()
        .collect()
}

/// 某条规则能不能被「本任务内不再询问这类操作」记住。
pub fn rule_is_rememberable(rule: &str) -> bool {
    !NON_REMEMBERABLE_RULES.contains(&rule)
}

/// 这次审批是否值得给用户一个"记住"的选项。
///
/// 只要有一条规则不可记住（例如删除里同时含越界路径），就不提供：
/// 勾了也只能少问一部分，反而让用户以为自己已经全放开了。
pub fn rememberable_for(rules: &[String]) -> bool {
    let asking = asking_rule_names(rules);
    !asking.is_empty() && asking.iter().all(|rule| rule_is_rememberable(rule))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Approval {
    pub id: String,
    pub task_id: String,
    /// 动作标识，如 `submit_form` / `code.tool_use` / `merge_changes`。
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// 面向用户的影响说明：金额、范围、是否不可撤销。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub impact: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub previews: Vec<String>,
    /// 纯增量字段：老客户端忽略，老服务端写库时按 `task` 兜底。
    #[serde(default)]
    pub scope: ApprovalScope,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<ApprovalTool>,
    pub expires_at: i64,
    pub decision: ApprovalDecision,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApproveAction {
    Approve,
    Reject,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApproveRequest {
    pub approval_id: String,
    pub decision: ApproveAction,
    /// 「本任务内不再询问这类操作」。仅工具级审批有效，老客户端不带该字段。
    #[serde(default)]
    pub remember: bool,
    /// 记住多久。缺省按「本任务内」，与只有 `remember` 的老客户端语义一致。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remember_scope: Option<crate::memory::GrantScope>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decision_roundtrip() {
        for decision in [
            ApprovalDecision::Pending,
            ApprovalDecision::Approved,
            ApprovalDecision::Rejected,
            ApprovalDecision::Expired,
        ] {
            assert_eq!(ApprovalDecision::parse(decision.as_str()), Some(decision));
        }
    }

    #[test]
    fn scope_defaults_to_task_for_old_payloads() {
        let raw = r#"{"id":"apr_1","task_id":"t1","action":"merge_changes",
            "expires_at":1,"decision":"pending"}"#;
        let approval: Approval = serde_json::from_str(raw).expect("老载荷应可解析");
        assert_eq!(approval.scope, ApprovalScope::Task);
        assert!(approval.tool.is_none());
    }

    #[test]
    fn tool_scope_roundtrips() {
        let approval = Approval {
            id: "apr_2".to_string(),
            task_id: "t1".to_string(),
            action: "code.tool_use".to_string(),
            target: Some("call_3".to_string()),
            impact: Some("不可逆操作".to_string()),
            previews: vec!["rm -rf build".to_string()],
            scope: ApprovalScope::Tool,
            tool: Some(ApprovalTool {
                name: "Bash".to_string(),
                risk: crate::code_event::RiskLevel::IrreversibleWrite,
                digest: "rm -rf build".to_string(),
                rememberable: true,
            }),
            expires_at: 1,
            decision: ApprovalDecision::Pending,
        };
        let value = serde_json::to_value(&approval).expect("序列化失败");
        assert_eq!(value["scope"], "tool");
        assert_eq!(value["tool"]["name"], "Bash");
        assert_eq!(value["tool"]["risk"], "irreversible_write");
        assert_eq!(ApprovalScope::parse("tool"), Some(ApprovalScope::Tool));
        assert_eq!(ApprovalScope::parse("bogus"), None);
    }

    #[test]
    fn approve_request_serializes_action() {
        let request = ApproveRequest {
            approval_id: "apr_1".to_string(),
            decision: ApproveAction::Approve,
            remember: false,
            remember_scope: None,
        };
        let value = serde_json::to_value(&request).expect("序列化失败");
        assert_eq!(value["decision"], "approve");

        // 老客户端不带 remember：必须能解析，且默认不放宽。
        let old: ApproveRequest =
            serde_json::from_str(r#"{"approval_id":"apr_1","decision":"approve"}"#)
                .expect("老载荷应可解析");
        assert!(!old.remember);

        // 老服务端写库的 tool_json 没有 rememberable：默认不提供勾选。
        let old_tool: ApprovalTool = serde_json::from_str(
            r#"{"name":"Bash","risk":"irreversible_write","digest":"rm -rf build"}"#,
        )
        .expect("老载荷应可解析");
        assert!(!old_tool.rememberable);
    }

    #[test]
    fn asking_rules_ignore_safe_markers_and_read_only_outside_paths() {
        let names = |rules: &[&str]| {
            asking_rule_names(
                &rules
                    .iter()
                    .map(|rule| (*rule).to_string())
                    .collect::<Vec<_>>(),
            )
        };

        // 只读 + 越界路径：CLI 翻自己的历史目录，不该弹卡。
        assert!(names(&["read_only", "path_outside_worktree"]).is_empty());
        // 越界写：要问。
        assert_eq!(
            names(&["path_outside_worktree"]),
            vec!["path_outside_worktree".to_string()]
        );
        // 可逆标记不参与"要不要问人"。
        assert!(names(&["worktree_write", "inline_script"]).is_empty());
        // 配置里的自定义规则名也算要问：不能因为不在内置表里就悄悄放行。
        assert_eq!(names(&["touch_legacy"]), vec!["touch_legacy".to_string()]);
        // 凭证读同时带 read_only：仍然是敏感路径。
        assert_eq!(
            names(&["read_only", "sensitive_path"]),
            vec!["sensitive_path".to_string()]
        );
    }

    #[test]
    fn rememberable_excludes_secrets_privilege_and_outside_writes() {
        let rules = |names: &[&str]| {
            names
                .iter()
                .map(|name| (*name).to_string())
                .collect::<Vec<_>>()
        };
        assert!(rememberable_for(&rules(&["install_command"])));
        assert!(rememberable_for(&rules(&["dangerous_script"])));
        assert!(!rememberable_for(&rules(&["sensitive_path"])));
        assert!(!rememberable_for(&rules(&["privilege_command"])));
        assert!(!rememberable_for(&rules(&["path_outside_worktree"])));
        // 混合命中：一条不可记住就整体不提供勾选。
        assert!(!rememberable_for(&rules(&[
            "delete_command",
            "path_outside_worktree"
        ])));
        assert!(!rememberable_for(&rules(&[])));
        assert!(rule_is_rememberable("install_command"));
        assert!(!rule_is_rememberable("sensitive_path"));
    }
}
