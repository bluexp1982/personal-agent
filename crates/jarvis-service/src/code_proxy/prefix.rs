//! 前缀稳定性检查。
//!
//! 缓存能不能命中，完全取决于"每轮请求的静态前缀是否逐字节一致"。前缀一变，
//! 后面所有内容都失效——而这件事从外面看不出来，只表现为"账单忽然变大 / 任务突然变慢"。
//! 所以这里不猜，直接盯：把每个任务的第一条 system 消息与工具定义做成指纹，
//! 变了就记一条审计。这是排查"为什么缓存没命中"的入口。
//!
//! 注意：只做**观测**，不改请求。粘合上下文、裁剪历史都是 CLI 的职责，
//! 代理擅自改写请求会造成"账单对了、输出疯了"这种更难查的问题。

use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};

/// 每个任务上一次见过的前缀指纹。
#[derive(Debug, Default)]
pub(crate) struct PrefixWatch {
    last: HashMap<String, u64>,
}

impl PrefixWatch {
    /// 记一次指纹。前缀变了（且之前有基线）时返回上一次的指纹。
    pub(crate) fn observe(&mut self, task_id: &str, fingerprint: u64) -> Option<u64> {
        match self.last.insert(task_id.to_string(), fingerprint) {
            Some(previous) if previous != fingerprint => Some(previous),
            _ => None,
        }
    }

    /// 新一轮执行重新建立基线（重试时 CLI 会重新拼系统提示，不该误报）。
    pub(crate) fn forget(&mut self, task_id: &str) {
        self.last.remove(task_id);
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.last.len()
    }
}

/// 请求里"可缓存前缀"的指纹：工具定义 + 第一条 system/developer 消息。
///
/// 取这两段是因为它们在一次会话里本该完全不变；历史消息本来就每轮都在长，
/// 拿它做指纹没有意义。body 不是 JSON 对象时返回 `None`（没什么可检查的）。
pub(crate) fn fingerprint(body: &[u8]) -> Option<u64> {
    let value = serde_json::from_slice::<serde_json::Value>(body).ok()?;
    let object = value.as_object()?;

    let tools = object.get("tools");
    let system = object
        .get("messages")
        .and_then(|messages| messages.get(0))
        .filter(|first| {
            matches!(
                first.get("role").and_then(serde_json::Value::as_str),
                Some("system") | Some("developer")
            )
        });

    if tools.is_none() && system.is_none() {
        return None;
    }

    // 用 serde_json 自己的序列化做规范化：Value 的 Map 默认有序，
    // 同样的内容必然得到同样的字节，不受字段书写顺序影响。
    let tools_bytes = tools.and_then(|value| serde_json::to_vec(value).ok());
    let system_bytes = system.and_then(|value| serde_json::to_vec(value).ok());

    let mut hasher = DefaultHasher::new();
    tools_bytes.hash(&mut hasher);
    system_bytes.hash(&mut hasher);
    Some(hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(system: &str, tools: bool) -> Vec<u8> {
        let mut value = serde_json::json!({
            "model": "deepseek-v4.1-flash",
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": "开始"}
            ]
        });
        if tools {
            value["tools"] = serde_json::json!([
                {"type": "function", "function": {"name": "Read"}}
            ]);
        }
        serde_json::to_vec(&value).expect("序列化失败")
    }

    #[test]
    fn same_prefix_has_the_same_fingerprint() {
        assert_eq!(
            fingerprint(&body("你是代码助手", true)),
            fingerprint(&body("你是代码助手", true))
        );
    }

    #[test]
    fn changed_system_prompt_changes_the_fingerprint() {
        assert_ne!(
            fingerprint(&body("你是代码助手", true)),
            fingerprint(&body("你是代码助手，现在是 12:03", true)),
            "系统提示里塞时间戳是最常见的缓存杀手"
        );
    }

    #[test]
    fn changed_tools_change_the_fingerprint() {
        assert_ne!(
            fingerprint(&body("你是代码助手", true)),
            fingerprint(&body("你是代码助手", false)),
            "工具集合变了，前缀也就不一样了"
        );
    }

    #[test]
    fn history_growth_does_not_change_it() {
        let short = body("你是代码助手", true);
        let mut value: serde_json::Value = serde_json::from_slice(&short).expect("解析失败");
        value["messages"]
            .as_array_mut()
            .expect("消息应为数组")
            .push(serde_json::json!({"role": "assistant", "content": "好的"}));
        let longer = serde_json::to_vec(&value).expect("序列化失败");
        assert_eq!(
            fingerprint(&short),
            fingerprint(&longer),
            "历史增长不影响前缀"
        );
    }

    #[test]
    fn garbage_and_empty_requests_are_ignored() {
        assert!(fingerprint(b"not json").is_none());
        assert!(fingerprint(b"{}").is_none());
        // 没有 system 也没有 tools：没有可比较的前缀。
        assert!(fingerprint(br#"{"messages":[{"role":"user","content":"hi"}]}"#).is_none());
    }

    #[test]
    fn watch_reports_only_real_changes() {
        let mut watch = PrefixWatch::default();
        assert_eq!(watch.observe("task_1", 7), None, "第一次只建立基线");
        assert_eq!(watch.observe("task_1", 7), None, "没变就不报");
        assert_eq!(watch.observe("task_1", 9), Some(7), "变了要报出旧值");
        assert_eq!(watch.observe("task_1", 9), None, "报过一次就换基线");
        watch.forget("task_1");
        assert_eq!(watch.len(), 0);
    }
}
