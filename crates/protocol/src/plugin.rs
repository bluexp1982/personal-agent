//! 技能包（外部技能）的对外类型。
//!
//! 与 `api-spec/openapi.yaml` 的 `Plugin` / `PluginPage` / `PluginStateUpdate` 对应。
//! 只放数据结构，不含安装逻辑——那是 `jarvis-service` 的事。

use serde::{Deserialize, Serialize};

use crate::task::Skill;

/// 一个已安装的技能包。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plugin {
    /// 插件标识。取自 `plugin.json` 的 `name`，无清单时用包内顶层目录名。
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// 停用后其技能立即从 `/api/skills`、新建任务下拉与对话建议里消失。
    pub enabled: bool,
    /// Unix 毫秒时间戳。
    pub installed_at: i64,
    pub updated_at: i64,
    /// 该插件提供的技能（含不支持的那些，管理页要展示原因）。
    pub skills: Vec<Skill>,
}

/// 插件列表与「改动是否已生效」的标记。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PluginPage {
    pub items: Vec<Plugin>,
    /// 刚安装、启停或卸载过，但执行进程还有任务在跑：改动要等空闲后生效。
    ///
    /// 客户端据此提示「已安装，当前任务结束后生效」，
    /// 而不是让用户以为马上能用。
    pub pending_reload: bool,
}

impl PluginPage {
    pub fn empty() -> Self {
        Self {
            items: Vec::new(),
            pending_reload: false,
        }
    }
}

/// 启停插件的请求体。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginStateUpdate {
    pub enabled: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plugin_page_roundtrips() {
        let page = PluginPage {
            items: vec![Plugin {
                id: "com.example.demo".to_string(),
                name: "demo".to_string(),
                version: "1.0.0".to_string(),
                author: None,
                description: Some("演示".to_string()),
                enabled: true,
                installed_at: 1,
                updated_at: 2,
                skills: Vec::new(),
            }],
            pending_reload: true,
        };

        let raw = serde_json::to_string(&page).expect("序列化失败");
        assert!(raw.contains(r#""pending_reload":true"#));
        assert!(!raw.contains("author"), "空 author 不应上线缆");
        assert_eq!(
            serde_json::from_str::<PluginPage>(&raw).expect("解析失败"),
            page
        );
    }

    #[test]
    fn state_update_defaults_are_strict() {
        assert!(serde_json::from_str::<PluginStateUpdate>(r#"{"enabled":false}"#).is_ok());
        assert!(serde_json::from_str::<PluginStateUpdate>(r#"{}"#).is_err());
    }
}
