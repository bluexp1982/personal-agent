//! 编码任务的模型用量。
//!
//! 权威计数在服务端：CLI 只在 `step_finish` 里报 tokens，而实测最后一步不产生
//! `step_finish`，只信它必然少算。
//!
//! 现实约束是上游不一定回 `usage`。这时按「3 字节 ≈ 1 token」估算，并在审计里标
//! `tokens_estimated=true` —— 估的就是估的，不能让它看起来像账单。
//!
//! 口径为什么从「1 字节 = 1 token」改成「3 字节 ≈ 1 token」：旧口径是 UTF-8 字节数直接
//! 当 token，对英文/代码（≈4 字符/token）和中文（3 字节 ≈ 1 汉字 ≈ 0.7 token）都高估
//! 3~4 倍。实测一次普通编码任务在 14 轮内被算成 40 万 token 而提前失败，
//! 而真实用量远没到。宁可偏高一点（3 而不是 4），但不能高到把正常任务卡死。
//!
//! **缓存命中要扣掉**：编码 CLI 每轮重发全量上下文（协议无状态，改不了），这一大段
//! 前缀通常能命中供应商的前缀缓存。网关会把命中量放在 `usage.prompt_tokens_details.cached_tokens`
//! 里，且**它仍然算在 `prompt_tokens` 内**。按全额计预算等于把"上下文体积"当成"账单"，
//! 实测一条稳定前缀连发三次，第二、三次命中 6144/6352 ≈ 97%，价格却只有零头。
//! 所以：`prompt_tokens` 照实记，预算只算 `prompt - cached`。

use std::collections::HashMap;

#[derive(Debug, Default, Clone, Copy)]
pub struct UsageTotals {
    pub calls: u64,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    /// 其中命中前缀缓存、按折扣计价的部分（上游没回就是 0）。
    pub cached_tokens: u64,
    /// 至少有一次是估算得到的。
    pub estimated: bool,
}

impl UsageTotals {
    /// 计费口径的 token 数：缓存命中的部分不打全价，预算也只按它算。
    pub fn tokens(&self) -> u64 {
        self.prompt_tokens
            .saturating_sub(self.cached_tokens)
            .saturating_add(self.completion_tokens)
    }

    /// 原始上下文体积，只用于展示与排障。
    pub fn raw_tokens(&self) -> u64 {
        self.prompt_tokens + self.completion_tokens
    }
}

/// 一次调用的用量（上游在末帧回的）。
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct UsageSample {
    pub prompt: u64,
    pub completion: u64,
    /// `usage.prompt_tokens_details.cached_tokens`（Anthropic 口径是 `cache_read_input_tokens`）。
    pub cached: u64,
}

#[derive(Debug, Default)]
pub(crate) struct UsageTable {
    totals: HashMap<String, UsageTotals>,
}

/// 上游没给 usage 时，多少字节算一个 token。
const FALLBACK_BYTES_PER_TOKEN: u64 = 3;

/// 字节数 → 估算 token 数。向上取整：只要有内容就至少算 1，避免"发了一堆空请求"不计成本。
pub(crate) fn estimate_tokens(bytes: u64) -> u64 {
    bytes.div_ceil(FALLBACK_BYTES_PER_TOKEN)
}

impl UsageTable {
    /// 记一次调用。`prompt_fallback_bytes` 用于上游没给 usage 时估算 prompt。
    pub(crate) fn record(
        &mut self,
        task_id: &str,
        usage: Option<UsageSample>,
        prompt_fallback_bytes: u64,
        completion_fallback_bytes: u64,
    ) -> UsageTotals {
        let entry = self.totals.entry(task_id.to_string()).or_default();
        entry.calls += 1;

        match usage {
            Some(sample) => {
                entry.prompt_tokens += sample.prompt;
                entry.completion_tokens += sample.completion;
                // 上游偶尔会给出比 prompt 还大的 cached（分块汇总导致），夹住。
                entry.cached_tokens += sample.cached.min(sample.prompt);
            }
            None => {
                entry.prompt_tokens += estimate_tokens(prompt_fallback_bytes);
                entry.completion_tokens += estimate_tokens(completion_fallback_bytes);
                entry.estimated = true;
            }
        }

        *entry
    }

    pub(crate) fn get(&self, task_id: &str) -> UsageTotals {
        self.totals.get(task_id).copied().unwrap_or_default()
    }

    pub(crate) fn forget(&mut self, task_id: &str) {
        self.totals.remove(task_id);
    }

    pub(crate) fn snapshot(&self) -> Vec<(String, UsageTotals)> {
        let mut rows: Vec<(String, UsageTotals)> = self
            .totals
            .iter()
            .map(|(task, totals)| (task.clone(), *totals))
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0));
        rows
    }
}

/// 流式响应里旁路累积用量。
///
/// 只做"够用"的解析：认 `usage` 字段与 `choices[].delta.content` 的字符数。
/// 其它字段一律忽略——代理不该因为上游多给一个字段就中断转发。
#[derive(Debug, Default)]
pub(crate) struct UsageParser {
    buffer: String,
    prompt: Option<u64>,
    completion: Option<u64>,
    cached: Option<u64>,
    content_chars: u64,
}

impl UsageParser {
    pub(crate) fn feed(&mut self, chunk: &[u8]) {
        self.buffer.push_str(&String::from_utf8_lossy(chunk));

        // 只处理完整的行；半行留到下一次。
        while let Some(index) = self.buffer.find('\n') {
            let line: String = self.buffer.drain(..=index).collect();
            self.consume_line(line.trim());
        }
    }

    /// 流结束后处理残留的半行。
    pub(crate) fn finish(&mut self) {
        let rest = std::mem::take(&mut self.buffer);
        self.consume_line(rest.trim());
    }

    /// 真实用量（上游给了才有）。
    pub(crate) fn usage(&self) -> Option<UsageSample> {
        if self.prompt.is_none() && self.completion.is_none() && self.cached.is_none() {
            return None;
        }
        Some(UsageSample {
            prompt: self.prompt.unwrap_or(0),
            completion: self.completion.unwrap_or(0),
            cached: self.cached.unwrap_or(0),
        })
    }

    /// 估算用的正文字符数（累加 assistant 的增量内容）。
    pub(crate) fn content_chars(&self) -> u64 {
        self.content_chars
    }

    fn consume_line(&mut self, line: &str) {
        let Some(payload) = line.strip_prefix("data:") else {
            return;
        };
        let payload = payload.trim();
        if payload.is_empty() || payload == "[DONE]" {
            return;
        }

        let Ok(value) = serde_json::from_str::<serde_json::Value>(payload) else {
            // 单帧解析失败不能影响转发：直接跳过。
            return;
        };

        if let Some(usage) = value.get("usage") {
            if let Some(prompt) = usage
                .get("prompt_tokens")
                .and_then(serde_json::Value::as_u64)
            {
                self.prompt = Some(prompt);
            }
            if let Some(completion) = usage
                .get("completion_tokens")
                .and_then(serde_json::Value::as_u64)
            {
                self.completion = Some(completion);
            }
            // 两种口径都认：OpenAI 兼容网关给 `prompt_tokens_details.cached_tokens`，
            // 直接对接 Anthropic 形态时是 `cache_read_input_tokens`。
            let cached = usage
                .get("prompt_tokens_details")
                .and_then(|details| details.get("cached_tokens"))
                .and_then(serde_json::Value::as_u64)
                .or_else(|| {
                    usage
                        .get("cache_read_input_tokens")
                        .and_then(serde_json::Value::as_u64)
                });
            if let Some(cached) = cached {
                self.cached = Some(cached);
            }
        }

        if let Some(text) = value
            .get("choices")
            .and_then(|choices| choices.get(0))
            .and_then(|choice| choice.get("delta"))
            .and_then(|delta| delta.get("content"))
            .and_then(serde_json::Value::as_str)
        {
            self.content_chars += text.chars().count() as u64;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAMES: &str = concat!(
        "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"世界\"}}]}\n\n",
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":2}}\n\n",
        "data: [DONE]\n\n",
    );

    #[test]
    fn parses_usage_and_content_chars() {
        let mut parser = UsageParser::default();
        parser.feed(FRAMES.as_bytes());
        parser.finish();

        let usage = parser.usage().expect("应有用量");
        assert_eq!((usage.prompt, usage.completion, usage.cached), (11, 2, 0));
        assert_eq!(parser.content_chars(), 4);
    }

    #[test]
    fn handles_frames_split_across_chunks() {
        let mut parser = UsageParser::default();
        for byte in FRAMES.as_bytes().chunks(7) {
            parser.feed(byte);
        }
        parser.finish();

        let usage = parser.usage().expect("跨块的帧应能拼回来");
        assert_eq!((usage.prompt, usage.completion), (11, 2));
    }

    #[test]
    fn parses_cached_tokens_from_both_dialects() {
        let mut parser = UsageParser::default();
        parser.feed(
            b"data: {\"usage\":{\"prompt_tokens\":6352,\"completion_tokens\":86,\"prompt_tokens_details\":{\"cached_tokens\":6144}}}\n\n",
        );
        parser.finish();
        let usage = parser.usage().expect("应有用量");
        assert_eq!(usage.cached, 6144);
        assert_eq!(usage.prompt, 6352);

        let mut parser = UsageParser::default();
        parser.feed(
            b"data: {\"usage\":{\"input_tokens\":100,\"output_tokens\":5,\"cache_read_input_tokens\":80}}\n\n",
        );
        parser.finish();
        assert_eq!(
            parser.usage().expect("应有用量").cached,
            80,
            "Anthropic 口径也要认"
        );
    }

    #[test]
    fn cached_tokens_are_not_billed_at_full_price() {
        let mut table = UsageTable::default();
        let totals = table.record(
            "t1",
            Some(UsageSample {
                prompt: 6352,
                completion: 86,
                cached: 6144,
            }),
            0,
            0,
        );
        assert_eq!(totals.raw_tokens(), 6438, "体积照实记");
        assert_eq!(totals.tokens(), 294, "预算只算没命中缓存的部分 + 输出");
    }

    #[test]
    fn missing_usage_is_reported_as_none() {
        let mut parser = UsageParser::default();
        parser.feed(b"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n");
        parser.finish();
        assert!(parser.usage().is_none(), "没给就是没给，不能编");
    }

    #[test]
    fn fallback_estimate_is_bytes_over_three_not_bytes() {
        let mut table = UsageTable::default();
        // 30 万字节的中文请求体：旧口径算 30 万 token，新口径约 10 万。
        let totals = table.record("task_1", None, 300_000, 0);
        assert_eq!(totals.prompt_tokens, 100_000);
        assert!(totals.estimated, "估的必须标出来");

        // 极少量的内容也不能算成 0：发出去就是花了钱。
        let totals = table.record("task_2", None, 1, 0);
        assert_eq!(totals.prompt_tokens, 1);
    }

    #[test]
    fn real_usage_wins_over_the_estimate() {
        let mut table = UsageTable::default();
        table.record("task_1", None, 30_000, 30);
        let totals = table.record(
            "task_1",
            Some(UsageSample {
                prompt: 120,
                completion: 8,
                cached: 0,
            }),
            30_000,
            30,
        );
        assert_eq!(totals.prompt_tokens, 10_120, "真实值累加，不覆盖");
        assert_eq!(totals.completion_tokens, 18);
        assert!(totals.estimated, "只要有一次是估的，整条就要标出来");
    }

    #[test]
    fn broken_frames_are_skipped() {
        let mut parser = UsageParser::default();
        parser.feed(b"data: not-json\n\ndata: {\"usage\":{\"prompt_tokens\":3}}\n\n");
        parser.finish();
        let usage = parser.usage().expect("应有用量");
        assert_eq!((usage.prompt, usage.completion), (3, 0));
    }

    #[test]
    fn table_accumulates_and_marks_estimates() {
        let mut table = UsageTable::default();

        let first = table.record(
            "t1",
            Some(UsageSample {
                prompt: 10,
                completion: 5,
                cached: 0,
            }),
            0,
            0,
        );
        assert_eq!(first.calls, 1);
        assert!(!first.estimated);

        let second = table.record("t1", None, 100, 20);
        assert_eq!(second.calls, 2);
        assert!(second.estimated, "有一次估算就要标记");
        // 15（真实）+ ceil(100/3)=34 + ceil(20/3)=7：按 3 字节 ≈ 1 token 估，不再是 1:1。
        assert_eq!(second.tokens(), 56);

        assert_eq!(table.get("t2").calls, 0, "未出现的任务不应有记录");
        table.forget("t1");
        assert!(table.snapshot().is_empty());
    }
}
