//! 会话标题：从用户第一次提问里取一句能认出会话的话。
//!
//! 规则刻意简单，因为标题只是列表里的一行索引：
//! - 短提问（≤ [`DIRECT_CHARS`]）清掉 Markdown 标记后直接用，模型转述只会更差；
//! - 长提问交给模型概括（限定十几个字），超时/失败/未配置模型都退回截断；
//! - 只改标题仍是 [`crate::conversation::DEFAULT_TITLE`] 的会话，用户起过名的一律不碰。
//!
//! 生成放在后台：标题不该占首字延迟，也不该因为模型慢而让回答卡住。

use std::time::Duration;

use sqlx::SqlitePool;

use crate::conversation::{self, ConversationError};
use crate::model::CompletionModel;

/// 提问不超过这个字数就原样当标题。
pub const DIRECT_CHARS: usize = 20;

/// 标题字符上限（含省略号）。列表一行放得下，也塞得进 AppBar。
pub const MAX_TITLE_CHARS: usize = 24;

/// 交给模型的内容上限：标题不需要看完整篇日志。
const PROMPT_CHARS: usize = 500;

/// 概括的等待上限。超过就退回截断，不让后台任务挂太久。
const TITLE_TIMEOUT: Duration = Duration::from_secs(5);

const MODEL_MAX_TOKENS: u32 = 48;

const SYSTEM_PROMPT: &str = "你在给一段对话起标题。只输出标题本身：不要引号、不要书名号、\
不要句末标点、不要解释，不超过 14 个字。若原文是代码或日志，概括它的用途。";

/// 生成标题并在标题仍为占位时落库。
///
/// 返回 `Some(title)` 表示真的写了；`None` 表示不需要（已改名、没有用户消息、
/// 内容全被清空）或生成期间被别人抢先改了名。
pub async fn refresh(
    pool: &SqlitePool,
    model: Option<&dyn CompletionModel>,
    conversation_id: &str,
) -> Result<Option<String>, ConversationError> {
    if !conversation::has_default_title(pool, conversation_id).await? {
        return Ok(None);
    }

    let Some(question) = conversation::first_user_content(pool, conversation_id).await? else {
        return Ok(None);
    };

    let title = generate(model, &question).await;
    if title.is_empty() {
        return Ok(None);
    }

    if conversation::set_title_if_default(pool, conversation_id, &title).await? {
        tracing::debug!(conversation_id, %title, "已生成会话标题");
        Ok(Some(title))
    } else {
        Ok(None)
    }
}

/// 补历史会话标题，返回实际写入的条数。
///
/// 串行执行：数量是"仍是新会话"的那些，通常几条；并发打模型只会让首字更慢。
/// 单条失败只记日志，不中断整批。
pub async fn backfill(
    pool: &SqlitePool,
    model: Option<&dyn CompletionModel>,
) -> Result<usize, ConversationError> {
    let ids = conversation::ids_with_default_title(pool).await?;
    let mut updated = 0;

    for id in ids {
        match refresh(pool, model, &id).await {
            Ok(Some(_)) => updated += 1,
            Ok(None) => {}
            Err(err) => tracing::warn!(%err, conversation_id = %id, "回填会话标题失败"),
        }
    }

    Ok(updated)
}

/// 从一条提问得到标题。永远返回可用文本（内容全空时返回空串）。
pub async fn generate(model: Option<&dyn CompletionModel>, question: &str) -> String {
    let normalized = normalize(question);
    if normalized.is_empty() {
        return String::new();
    }

    if normalized.chars().count() <= DIRECT_CHARS {
        return truncate(&normalized, MAX_TITLE_CHARS);
    }

    let Some(model) = model else {
        return truncate(&normalized, MAX_TITLE_CHARS);
    };

    let prompt = prompt_for(&normalized);
    match tokio::time::timeout(
        TITLE_TIMEOUT,
        model.complete(SYSTEM_PROMPT, &prompt, Some(MODEL_MAX_TOKENS)),
    )
    .await
    {
        Ok(Ok(completion)) => {
            clean(&completion.text).unwrap_or_else(|| truncate(&normalized, MAX_TITLE_CHARS))
        }
        Ok(Err(err)) => {
            tracing::warn!(%err, "概括会话标题失败，退回截断");
            truncate(&normalized, MAX_TITLE_CHARS)
        }
        Err(_) => {
            tracing::warn!("概括会话标题超时，退回截断");
            truncate(&normalized, MAX_TITLE_CHARS)
        }
    }
}

/// 去掉 Markdown 标记、链接地址与多余空白，得到可以当标题的一行文本。
pub fn normalize(text: &str) -> String {
    let mut parts: Vec<String> = Vec::new();

    for raw in text.lines() {
        let line = raw.trim();
        // 代码围栏本身没有信息量，里面的内容留着（可能是唯一的线索）。
        if line.is_empty() || line.starts_with("```") || line.starts_with("~~~") {
            continue;
        }

        let stripped = strip_marks(strip_line_prefix(line));
        let compact = collapse_spaces(&stripped);
        if !compact.is_empty() {
            parts.push(compact);
        }
    }

    parts.join(" ")
}

/// 清洗模型输出。返回 `None` 表示模型没给出可用标题。
pub fn clean(raw: &str) -> Option<String> {
    let first = raw.lines().map(str::trim).find(|line| !line.is_empty())?;
    let mut title = strip_tail_punct(first);

    for prefix in ["会话标题：", "会话标题:", "标题：", "标题:"] {
        if let Some(rest) = title.strip_prefix(prefix) {
            title = rest.trim().to_string();
            break;
        }
    }

    // 模型常写成 “标题。” 或 《标题》：先清尾部标点才剥得掉外层引号，
    // 剥完可能又露出句号，所以再清一次。
    title = strip_tail_punct(&strip_wrappers(&title));
    title = collapse_spaces(&title);

    if title.is_empty() {
        return None;
    }
    Some(truncate(&title, MAX_TITLE_CHARS))
}

fn strip_tail_punct(text: &str) -> String {
    text.trim_end_matches(['。', '.', '，', ',', '；', ';', '！', '!', '：', ':'])
        .trim()
        .to_string()
}

fn strip_wrappers(text: &str) -> String {
    for (open, close) in [
        ('"', '"'),
        ('\'', '\''),
        ('“', '”'),
        ('‘', '’'),
        ('《', '》'),
        ('「', '」'),
        ('『', '』'),
    ] {
        if text.chars().count() >= 2 && text.starts_with(open) && text.ends_with(close) {
            let start = open.len_utf8();
            let end = text.len() - close.len_utf8();
            return text[start..end].trim().to_string();
        }
    }
    text.to_string()
}

/// 按字符截断，超出时用省略号收尾（总长不超过 `max`）。
pub fn truncate(text: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut truncated: String = text.chars().take(max - 1).collect();
    truncated.push('…');
    truncated
}

fn prompt_for(question: &str) -> String {
    // 先截断再拼提示：超长粘贴内容是常态，别把整篇日志送进模型。
    let clipped = truncate(question, PROMPT_CHARS);
    format!("用户的第一条提问：\n{clipped}")
}

/// 去掉行首的标题井号、引用符与列表符号。
fn strip_line_prefix(line: &str) -> &str {
    let mut rest = line.trim_start();

    let hashes = rest.chars().take_while(|item| *item == '#').count();
    if hashes > 0 && rest[hashes..].starts_with(' ') {
        rest = rest[hashes..].trim_start();
    }

    while let Some(stripped) = rest.strip_prefix('>') {
        rest = stripped.trim_start();
    }

    for mark in ["- ", "* ", "+ "] {
        if let Some(stripped) = rest.strip_prefix(mark) {
            rest = stripped.trim_start();
            break;
        }
    }

    let digits = rest
        .chars()
        .take_while(|item| item.is_ascii_digit())
        .count();
    if digits > 0 {
        let after = &rest[digits..];
        if let Some(stripped) = after
            .strip_prefix(". ")
            .or_else(|| after.strip_prefix(") "))
        {
            rest = stripped.trim_start();
        }
    }

    rest
}

/// 去掉行内标记，保留链接文字。
fn strip_marks(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;

    while index < chars.len() {
        // [文字](地址) → 文字；![图注](地址) → 图注
        if chars[index] == '[' {
            if let Some(close) = find_char(&chars, index + 1, ']') {
                if chars.get(close + 1) == Some(&'(') {
                    if let Some(end) = find_char(&chars, close + 2, ')') {
                        if out.ends_with('!') {
                            out.pop();
                        }
                        out.extend(chars[index + 1..close].iter());
                        index = end + 1;
                        continue;
                    }
                }
            }
        }

        // 裸地址是噪音：标题要说"讲了什么"，不是"引用了哪一页"。
        if chars[index] == 'h'
            && (starts_with(&chars, index, "https://") || starts_with(&chars, index, "http://"))
        {
            while index < chars.len() && !chars[index].is_whitespace() {
                index += 1;
            }
            continue;
        }

        if matches!(chars[index], '`' | '*' | '_' | '~' | '#' | '>') {
            index += 1;
            continue;
        }

        out.push(chars[index]);
        index += 1;
    }

    out
}

fn find_char(chars: &[char], from: usize, target: char) -> Option<usize> {
    chars
        .get(from..)?
        .iter()
        .position(|item| *item == target)
        .map(|offset| from + offset)
}

fn starts_with(chars: &[char], from: usize, pattern: &str) -> bool {
    pattern
        .chars()
        .enumerate()
        .all(|(offset, expected)| chars.get(from + offset) == Some(&expected))
}

fn collapse_spaces(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending_space = false;

    for item in text.chars() {
        if item.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(item);
    }

    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::CompletionFuture;

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
        ) -> CompletionFuture<'_> {
            let reply = self.reply.clone();
            Box::pin(async move {
                reply.map(|text| crate::model::Completion {
                    text,
                    ..crate::model::Completion::default()
                })
            })
        }
    }

    #[test]
    fn strips_markdown_and_keeps_link_text() {
        let normalized = normalize(
            "## 帮我看看\n\n- **上海** 明天天气\n- 参考 [文档](https://example.com/a?b=1)",
        );
        assert_eq!(normalized, "帮我看看 上海 明天天气 参考 文档");
    }

    #[test]
    fn strips_ordered_list_and_quote_prefixes() {
        assert_eq!(normalize("> 1. 先做什么"), "先做什么");
        assert_eq!(normalize("3) 再来一步"), "再来一步");
    }

    #[test]
    fn bare_urls_are_dropped() {
        assert_eq!(
            normalize("这个页面 https://example.com/x 讲什么"),
            "这个页面 讲什么"
        );
    }

    #[test]
    fn short_question_is_used_as_is() {
        assert_eq!(normalize("明天上海天气"), "明天上海天气");
    }

    #[tokio::test]
    async fn short_question_skips_model() {
        let model = FixedModel {
            reply: Ok("不该被用到".to_string()),
        };
        let title = generate(Some(&model), "明天上海天气").await;
        assert_eq!(title, "明天上海天气");
    }

    #[tokio::test]
    async fn long_question_uses_model_and_cleans_output() {
        let model = FixedModel {
            reply: Ok("“上海出差穿搭建议”。".to_string()),
        };
        let title = generate(
            Some(&model),
            "下周三去上海出差三天，帮我看看该带什么衣服，顺便看看会不会下雨",
        )
        .await;
        assert_eq!(title, "上海出差穿搭建议");
    }

    #[tokio::test]
    async fn model_failure_falls_back_to_truncation() {
        let model = FixedModel {
            reply: Err("网关超时".to_string()),
        };
        let title = generate(
            Some(&model),
            "下周三去上海出差三天，帮我看看该带什么衣服，顺便看看会不会下雨",
        )
        .await;
        assert!(title.ends_with('…'), "应退回截断：{title}");
        assert_eq!(title.chars().count(), MAX_TITLE_CHARS);
    }

    #[tokio::test]
    async fn missing_model_falls_back_to_truncation() {
        let title = generate(
            None,
            "第一行很长很长的提问，长到必须截断才行，否则列表放不下",
        )
        .await;
        assert!(title.ends_with('…'));
        assert_eq!(title.chars().count(), MAX_TITLE_CHARS);
    }

    #[test]
    fn clean_rejects_blank_and_handles_prefix() {
        assert!(clean("   ").is_none());
        assert_eq!(clean("标题：整理周报").as_deref(), Some("整理周报"));
        assert_eq!(clean("《周报整理》").as_deref(), Some("周报整理"));
    }

    #[test]
    fn truncate_keeps_total_length() {
        assert_eq!(truncate("一二三四", 4), "一二三四");
        assert_eq!(truncate("一二三四五", 4), "一二三…");
        assert_eq!(truncate("任意", 0), "");
    }

    #[test]
    fn empty_question_yields_nothing() {
        assert!(normalize("").is_empty());
        assert!(normalize("```\n**\n```").is_empty());
    }
}
