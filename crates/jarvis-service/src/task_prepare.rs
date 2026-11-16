//! 派任务前的参数解析：把用户的一句人话变成技能的 `input`。
//!
//! 只服务会话里的 `@技能` 入口——任务页有自己的表单，不需要这一层。
//!
//! 两条硬规则：
//!
//! 1. **`text` 永远保留原话**：技能正文总能读到用户的表述，不会因为解析失败
//!    就丢掉上下文。
//! 2. **不猜字段**：没有模型、超时、输出不可解析时，只塞 `text`，绝不抽 URL
//!    或认城市。正则抓第一个链接在多链接、举例链接、非地址意图上都会给错值，
//!    而错值会被技能当成真的用下去——比"未获取"更糟。
//!
//! 解析成功后由 [`PreparedTaskInput::missing`] 说明"技能声明要的字段还差哪些"，
//! 界面据此提示，而不是静默降级。

use std::collections::BTreeSet;
use std::time::Duration;

use protocol::skill::FetchSource;
use protocol::{PrepareSource, PreparedTaskInput, SkillManifest};
use serde_json::{Map, Value};

use crate::model::CompletionModel;

/// 单次解析的等待上限。
///
/// 必须小于 `llm.timeout_ms`（非流式请求上限）：否则 HTTP 客户端先超时，
/// 真实原因（网关慢还是没网）就分不清了。解析只是锦上添花，慢一点不如早点退回原文。
const PREPARE_TIMEOUT: Duration = Duration::from_secs(8);

/// 解析只需要输出一个小对象，300 token 足够；给多了只是纵容模型啰嗦。
const MAX_TOKENS: u32 = 300;

/// 解析一句话，得到任务的 `input`。**永远返回可用结果。**
pub async fn prepare(
    model: Option<&dyn CompletionModel>,
    skill: &SkillManifest,
    text: &str,
) -> PreparedTaskInput {
    let text = text.trim();

    // 没有取资料声明就没有可解析的字段：为一次注定为空的抽取花模型调用不值。
    let Some(fetch) = skill.fetch.as_ref() else {
        return fallback(skill, text, Vec::new());
    };

    let field = fetch.from.as_str();

    let Some(model) = model else {
        return fallback(skill, text, vec![field.to_string()]);
    };

    let (system, prompt) = build_prompt(skill, fetch.from, text);

    let attempt = tokio::time::timeout(
        PREPARE_TIMEOUT,
        model.complete(&system, &prompt, Some(MAX_TOKENS)),
    )
    .await;

    let parsed = match attempt {
        Ok(Ok(completion)) => parse_fields(&completion.text, fetch.from),
        Ok(Err(err)) => {
            tracing::warn!(%err, skill = %skill.name, "参数解析失败，退回只带原文");
            None
        }
        Err(_) => {
            tracing::warn!(skill = %skill.name, "参数解析超时，退回只带原文");
            None
        }
    };

    let Some(mut object) = parsed else {
        return fallback(skill, text, vec![field.to_string()]);
    };

    // 原话由服务端强制写入，不信模型有没有照做。
    object.insert("text".to_string(), Value::String(text.to_string()));

    let missing = missing_fields(skill, &object);

    PreparedTaskInput {
        skill: skill.name.clone(),
        input: Value::Object(object),
        source: PrepareSource::Model,
        missing,
    }
}

/// 只带原文的结果。
fn fallback(skill: &SkillManifest, text: &str, missing: Vec<String>) -> PreparedTaskInput {
    let mut object = Map::new();
    object.insert("text".to_string(), Value::String(text.to_string()));

    // `missing` 由调用方给出，因为"为什么缺"分两种：没有可解析字段（空）与
    // 解析失败（缺那一项）。这里不再重新计算，避免两处口径不一致。
    let missing = if missing.is_empty() {
        missing_fields(skill, &object)
    } else {
        missing
    };

    PreparedTaskInput {
        skill: skill.name.clone(),
        input: Value::Object(object),
        source: PrepareSource::Fallback,
        missing,
    }
}

/// 技能声明需要、但 `object` 里没有的字段。
///
/// 与 `source` 解耦：模型解析成功也可能漏字段，那同样要提示。
fn missing_fields(skill: &SkillManifest, object: &Map<String, Value>) -> Vec<String> {
    let Some(fetch) = skill.fetch.as_ref() else {
        return Vec::new();
    };

    let field = fetch.from.as_str();
    let present = object
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .is_some_and(|value| !value.is_empty());

    if present {
        Vec::new()
    } else {
        vec![field.to_string()]
    }
}

fn build_prompt(skill: &SkillManifest, from: FetchSource, text: &str) -> (String, String) {
    let system = "你是任务参数解析器。只输出一个 JSON 对象，不要解释、不要代码围栏。".to_string();

    let field_hint = match from {
        FetchSource::Url => "url：一个完整的网页地址，必须以 http:// 或 https:// 开头",
        FetchSource::City => "city：一个城市名（只要地名，不要省份与说明）",
        FetchSource::Query => "query：一个搜索关键词",
        FetchSource::Path => "path：一个项目内的相对路径",
        FetchSource::Pattern => "pattern：一个文件名或内容匹配模式",
    };

    let field = from.as_str();

    // 技能没有 `description` 字段（那是插件的 sidecar 才有的），
    // 用 triggers 与 steps 交代"这个技能处理什么"已经够判断。
    let triggers = if skill.triggers.is_empty() {
        String::new()
    } else {
        format!("\n适用场景：{}", skill.triggers.join("、"))
    };
    let steps = if skill.steps.is_empty() {
        String::new()
    } else {
        format!("\n技能步骤：{}", skill.steps.join(" / "))
    };

    let prompt = format!(
        "技能：{name}{triggers}{steps}\n\
         \n需要从用户这句话里取出：\n- {field_hint}\n\
         \n用户原话：{text}\n\
         \n只输出形如 {{\"{field}\": \"...\"}} 的 JSON 对象。\n\
         如果原话里没有这个信息，输出 {{}}，不要编造，不要猜测。",
        name = skill.name,
    );

    (system, prompt)
}

/// 从模型输出里取出白名单字段。
///
/// 照 `memory/extract.rs` 的做法：剥 ```json 围栏、非对象视为失败、
/// 逐字段取字符串、空值丢弃。**只认技能声明的那一个字段**——放开任意键的话，
/// 模型会编出技能根本不读的字段，`missing` 也就失去意义了。
fn parse_fields(raw: &str, from: FetchSource) -> Option<Map<String, Value>> {
    let cleaned = strip_code_fence(raw);
    let value: Value = serde_json::from_str(&cleaned).ok()?;
    let object = value.as_object()?;

    let field = from.as_str();
    let value = object
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;

    let mut out = Map::new();
    out.insert(field.to_string(), Value::String(value.to_string()));
    Some(out)
}

/// 模型偶尔会把 JSON 包在 ```json 里。
fn strip_code_fence(raw: &str) -> String {
    let trimmed = raw.trim();
    if !trimmed.starts_with("```") {
        return trimmed.to_string();
    }
    let without_open = trimmed
        .trim_start_matches("```json")
        .trim_start_matches("```");
    without_open.trim_end_matches("```").trim().to_string()
}

/// 缺失字段去重后的稳定顺序（当前最多一个，留好扩展位）。
#[allow(dead_code)]
fn dedup(mut fields: Vec<String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    fields.retain(|field| seen.insert(field.clone()));
    fields
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Completion;
    use std::pin::Pin;

    /// 固定回复的假模型。
    #[derive(Debug)]
    struct FixedModel {
        reply: Result<String, String>,
    }

    impl CompletionModel for FixedModel {
        fn complete(
            &self,
            _system: &str,
            _prompt: &str,
            _max_tokens: Option<u32>,
        ) -> Pin<Box<dyn std::future::Future<Output = Result<Completion, String>> + Send + '_>>
        {
            let reply = self.reply.clone();
            Box::pin(async move {
                reply.map(|text| Completion {
                    text,
                    prompt_tokens: 10,
                    completion_tokens: 5,
                    tokens_estimated: false,
                    finish_reason: None,
                })
            })
        }
    }

    fn skill_with_fetch(name: &str, from: FetchSource) -> SkillManifest {
        SkillManifest {
            name: name.to_string(),
            version: "1.0.0".to_string(),
            risk_level: "read".to_string(),
            triggers: vec!["网页".to_string()],
            required_tools: vec!["web.fetch".to_string()],
            outputs: vec!["report".to_string()],
            stop_before: None,
            steps: vec!["读取".to_string(), "归纳".to_string()],
            source: "builtin".to_string(),
            plugin_id: None,
            fetch: Some(protocol::skill::SkillFetch {
                step: "读取".to_string(),
                from,
                tool: protocol::skill::FetchTool::WebFetch,
            }),
        }
    }

    fn skill_without_fetch() -> SkillManifest {
        let mut skill = skill_with_fetch("bill-explain", FetchSource::Url);
        skill.fetch = None;
        skill
    }

    #[tokio::test]
    async fn model_output_fills_the_declared_field() {
        let model = FixedModel {
            reply: Ok(r#"{"url":"https://example.com/a"}"#.to_string()),
        };
        let skill = skill_with_fetch("site-brief", FetchSource::Url);

        let prepared = prepare(Some(&model), &skill, "  读取 https://example.com/a ").await;

        assert_eq!(prepared.source, PrepareSource::Model);
        assert_eq!(prepared.input["url"], "https://example.com/a");
        // 原话永远保留，且是 trim 过的。
        assert_eq!(prepared.input["text"], "读取 https://example.com/a");
        assert!(prepared.missing.is_empty());
    }

    #[tokio::test]
    async fn fenced_json_is_accepted() {
        let model = FixedModel {
            reply: Ok("```json\n{\"city\":\"上海\"}\n```".to_string()),
        };
        let skill = skill_with_fetch("trip-plan", FetchSource::City);

        let prepared = prepare(Some(&model), &skill, "下周去上海").await;

        assert_eq!(prepared.source, PrepareSource::Model);
        assert_eq!(prepared.input["city"], "上海");
    }

    /// 解析失败时**只带原文**：不抽 URL、不认城市。
    #[tokio::test]
    async fn unparsable_output_falls_back_to_the_raw_text_only() {
        for reply in [
            Ok("我看了一下，这应该是一个网页地址".to_string()),
            Ok("{}".to_string()),
            Ok(r#"{"url":"   "}"#.to_string()),
            Err("模型返回 500".to_string()),
        ] {
            let model = FixedModel { reply };
            let skill = skill_with_fetch("site-brief", FetchSource::Url);

            let prepared = prepare(Some(&model), &skill, "读取 https://example.com/a").await;

            assert_eq!(prepared.source, PrepareSource::Fallback);
            assert_eq!(
                prepared.input["text"], "读取 https://example.com/a",
                "原话必须保留"
            );
            assert!(
                prepared.input.get("url").is_none(),
                "兜底不许猜字段: {:?}",
                prepared.input
            );
            assert_eq!(prepared.missing, vec!["url".to_string()], "缺口要报出来");
        }
    }

    #[tokio::test]
    async fn no_model_falls_back_without_guessing() {
        let skill = skill_with_fetch("site-brief", FetchSource::Url);
        let prepared = prepare(None, &skill, "读取 https://example.com/a").await;

        assert_eq!(prepared.source, PrepareSource::Fallback);
        assert_eq!(
            prepared.input.to_string(),
            r#"{"text":"读取 https://example.com/a"}"#
        );
        assert_eq!(prepared.missing, vec!["url".to_string()]);
    }

    /// 没有取资料声明的技能没有可解析字段：直接兜底，不花掉一次模型调用。
    #[tokio::test]
    async fn skill_without_fetch_never_calls_the_model() {
        let model = FixedModel {
            reply: Err("不该被调用".to_string()),
        };
        let skill = skill_without_fetch();

        let prepared = prepare(Some(&model), &skill, "这笔账单扣了两次").await;

        assert_eq!(prepared.source, PrepareSource::Fallback);
        assert_eq!(prepared.input["text"], "这笔账单扣了两次");
        assert!(prepared.missing.is_empty(), "没声明字段就没有缺口");
    }

    /// 模型给了不认识的键：不透传，只认声明的那一个。
    #[tokio::test]
    async fn unknown_fields_are_dropped() {
        let model = FixedModel {
            reply: Ok(r#"{"url":"https://a.com","city":"上海","evil":{"x":1}}"#.to_string()),
        };
        let skill = skill_with_fetch("site-brief", FetchSource::Url);

        let prepared = prepare(Some(&model), &skill, "看看 https://a.com").await;

        assert_eq!(prepared.input["url"], "https://a.com");
        assert!(prepared.input.get("city").is_none());
        assert!(prepared.input.get("evil").is_none());
    }
}
