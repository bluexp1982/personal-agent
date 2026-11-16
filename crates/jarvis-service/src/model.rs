//! 任务侧的非流式模型调用抽象。
//!
//! 对话与任务的需求不同，刻意分成两个接口：
//! - 对话要**流式**（首字延迟决定体感），且需要 `tool_calls`，见 [`crate::chat::ChatModel`]；
//! - 任务每步只取最后一段文本，非流式能直接拿到 `usage`，预算记账不必靠估算。
//!
//! 两者都由 [`crate::llm::LlmClient`] 实现，但调用方拿不到彼此的能力，
//! 避免"任务里顺手用了流式"或"对话里误用了非流式"这种边界模糊。

use std::future::Future;
use std::pin::Pin;

/// 一次非流式调用的结果。
#[derive(Debug, Clone, Default)]
pub struct Completion {
    pub text: String,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    /// 网关未返回 `usage` 时为 `true`，此时 token 数是按字符估算的。
    pub tokens_estimated: bool,
    /// 上游给的结束原因（`stop` / `length` / …）。
    ///
    /// 摘要必须能区分"写完了"和"被输出上限截断"：两者都可能是非空文本，
    /// 但后者只是半截，拿去当上下文会误导后续每一轮。
    pub finish_reason: Option<String>,
}

pub type CompletionFuture<'a> =
    Pin<Box<dyn Future<Output = Result<Completion, String>> + Send + 'a>>;

pub trait CompletionModel: std::fmt::Debug + Send + Sync {
    /// 一次非流式生成。失败返回面向开发者的一句话，调用方据此降级。
    fn complete(&self, system: &str, prompt: &str, max_tokens: Option<u32>)
        -> CompletionFuture<'_>;

    /// 带推理档位的一次非流式生成。
    ///
    /// 默认实现忽略 `effort` 直接转调 [`Self::complete`]：只有明确需要
    /// "关掉思考"的调用方（会话摘要）才覆写它，其余调用方与测试假模型零改动。
    ///
    /// 为什么摘要要关：思考 token 与正文**共用** `max_tokens`，会思考的模型
    /// 在小上限下会把额度全花在思维链上，正文为空但 HTTP 仍是 200
    /// （`llm.rs` 的 `probe()` 早就记录过同一现象）。
    fn complete_with_effort(
        &self,
        system: &str,
        prompt: &str,
        max_tokens: Option<u32>,
        effort: Option<&'static str>,
    ) -> CompletionFuture<'_> {
        let _ = effort;
        self.complete(system, prompt, max_tokens)
    }
}

/// 保守的 token 估算：按"1 字符 ≈ 1 token"算。
///
/// 中文场景下 1 个汉字通常就是 1 个 token，英文会高估 4 倍左右。
/// 预算宁可高估——低估的结果是账单超出预期，而不是少花钱。
pub fn estimate_tokens(text: &str) -> u32 {
    let chars = text.chars().count();
    u32::try_from(chars.max(1)).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimate_is_at_least_one() {
        assert_eq!(estimate_tokens(""), 1);
        assert_eq!(estimate_tokens("你好"), 2);
        assert_eq!(estimate_tokens("hello"), 5);
    }
}
