//! 回答生成抽象。
//!
//! 两种实现：
//! - [`DeterministicResponder`]：无外部依赖的确定性回答，用于测试与未配置模型时兜底；
//! - [`crate::llm::ModelResponder`]：流式调用 OpenAI 兼容网关。
//!
//! 接口是**流式**的：模型逐 token 产出，会话端点边收边推给客户端，
//! 而不是等整段生成完再返回——否则首字延迟会从 1 秒变成数秒。

use std::fmt::Debug;
use std::pin::Pin;

use futures_util::stream::{self, Stream};

/// 流式 token。错误用 `String` 表达，调用方决定如何呈现给用户。
pub type TokenStream = Pin<Box<dyn Stream<Item = Result<String, String>> + Send>>;

/// 送给模型的一条消息。
#[derive(Debug, Clone)]
pub struct PromptMessage {
    pub role: &'static str,
    pub content: String,
}

impl PromptMessage {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system",
            content: content.into(),
        }
    }

    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user",
            content: content.into(),
        }
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: "assistant",
            content: content.into(),
        }
    }
}

/// 回答生成器。
pub trait Responder: Debug + Send + Sync {
    /// 用于日志与管理面：`deterministic` 或 `model`。
    fn kind(&self) -> &'static str;

    /// 生成回答分片。实现方负责处理网络错误，并以 `Err` 分片结束。
    fn stream(&self, messages: Vec<PromptMessage>) -> TokenStream;
}

/// 确定性实现：无外部依赖、结果可复现。
///
/// 它**不是**模型。回复里明确标注"未核实"，避免把模板回复误当成有依据的答案。
#[derive(Debug, Default)]
pub struct DeterministicResponder;

impl Responder for DeterministicResponder {
    fn kind(&self) -> &'static str {
        "deterministic"
    }

    fn stream(&self, messages: Vec<PromptMessage>) -> TokenStream {
        let last_user = messages
            .iter()
            .rev()
            .find(|message| message.role == "user")
            .map(|message| message.content.clone())
            .unwrap_or_default();

        let reply = format!(
            "收到：{}\n\n（未核实：本回答由确定性实现生成，尚未接入检索或模型。）",
            last_user.trim()
        );

        let chunks = chunk(&reply, 12);
        Box::pin(stream::iter(chunks.into_iter().map(Ok)))
    }
}

/// 按字符数切分，避免把多字节字符切断。
fn chunk(text: &str, size: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    chars
        .chunks(size.max(1))
        .map(|slice| slice.iter().collect::<String>())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;

    async fn collect(responder: &dyn Responder, messages: Vec<PromptMessage>) -> String {
        let mut stream = responder.stream(messages);
        let mut text = String::new();
        while let Some(item) = stream.next().await {
            text.push_str(&item.expect("确定性实现不应出错"));
        }
        text
    }

    #[test]
    fn chunks_reassemble_to_original() {
        let chunks = chunk("一二三四五六七", 3);
        assert_eq!(chunks.concat(), "一二三四五六七");
        assert_eq!(chunks.len(), 3);
    }

    #[tokio::test]
    async fn deterministic_reply_mentions_input_and_source_state() {
        let reply = collect(
            &DeterministicResponder,
            vec![
                PromptMessage::system("你是助理"),
                PromptMessage::user("帮我看下天气"),
            ],
        )
        .await;

        assert!(reply.contains("帮我看下天气"));
        assert!(reply.contains("未核实"));
    }

    #[tokio::test]
    async fn deterministic_reply_uses_last_user_message() {
        let reply = collect(
            &DeterministicResponder,
            vec![
                PromptMessage::user("第一句"),
                PromptMessage::assistant("回答"),
                PromptMessage::user("第二句"),
            ],
        )
        .await;

        assert!(reply.contains("第二句"));
        assert!(!reply.contains("第一句"));
    }

    #[test]
    fn kind_is_stable() {
        assert_eq!(DeterministicResponder.kind(), "deterministic");
    }
}
