//! 协议转换的共用部分：把上游的 OpenAI Chat SSE 归一成一串"语义增量"。
//!
//! 为什么要有这一层：Codex 只讲 Responses API、Claude Code 只讲 Anthropic
//! Messages API，而网关只有 `/chat/completions`。两个转换器各自去啃 OpenAI 的
//! chunk 结构，迟早会出现"一个修好了另一个还坏着"，所以先归一、再分别渲染。
//!
//! 边界（与方案 9.7 的改写一致）：
//! - **只认已知字段**：`choices[].delta.content` / `delta.tool_calls` / `finish_reason` /
//!   `usage`。其余字段（`reasoning_content`、供应商私有扩展）直接丢弃，不做猜译。
//! - 上游不是 OpenAI 兼容形状时，转换器只能给出空结果；这时候错误会由
//!   `response.completed` 里的 `status` / `error` 表达，而不是静默成功。

/// 上游 chunk 归一到的一条语义增量。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ChatDelta {
    /// 正文增量。
    Text(String),
    /// 一次工具调用的开始：`index` 是上游的序号，`id` 可能与 `name` 同时出现。
    ToolStart {
        index: u32,
        id: String,
        name: String,
    },
    /// 工具参数增量（JSON 字符串片段，可能被切成任意多段）。
    ToolArgs { index: u32, args: String },
    /// 上游给出 `finish_reason`（`stop` / `tool_calls` / `length`）。
    Finish(String),
    /// 上游末帧的用量。缺失时下游按字节估算。
    Usage {
        prompt: u64,
        completion: u64,
        cached: u64,
        /// Responses 语义里 `cached_tokens` 是 input 的子集；Anthropic 需要的是
        /// 非缓存输入，所以这里同时留着两个值。
        reasoning: u64,
    },
}

/// OpenAI Chat SSE → 语义增量。
///
/// 上游可能把一帧切成任意多段（网络分片），所以这里按行缓冲：
/// 只有完整的 `data:` 行才会被解析，残留部分留到下一次 `feed`。
#[derive(Debug, Default)]
pub(crate) struct ChatParser {
    buffer: Vec<u8>,
}

impl ChatParser {
    pub(crate) fn feed(&mut self, chunk: &[u8]) -> Vec<ChatDelta> {
        self.buffer.extend_from_slice(chunk);
        let mut out = Vec::new();

        while let Some(pos) = self.buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line[..line.len().saturating_sub(1)]);
            let line = line.trim_end_matches('\r').trim();
            let Some(payload) = line.strip_prefix("data:") else {
                continue;
            };
            let payload = payload.trim();
            if payload.is_empty() || payload == "[DONE]" {
                continue;
            }
            let Ok(value) = serde_json::from_str::<serde_json::Value>(payload) else {
                // 上游偶发心跳与非 JSON 行：跳过，不让整条流失败。
                continue;
            };
            out.extend(parse_chunk(&value));
        }

        out
    }
}

fn parse_chunk(value: &serde_json::Value) -> Vec<ChatDelta> {
    let mut out = Vec::new();

    if let Some(usage) = value.get("usage").filter(|usage| !usage.is_null()) {
        out.push(ChatDelta::Usage {
            prompt: usage.get("prompt_tokens").and_then(as_u64).unwrap_or(0),
            completion: usage.get("completion_tokens").and_then(as_u64).unwrap_or(0),
            cached: usage
                .pointer("/prompt_tokens_details/cached_tokens")
                .and_then(as_u64)
                .or_else(|| usage.get("prompt_cache_hit_tokens").and_then(as_u64))
                .unwrap_or(0),
            reasoning: usage
                .pointer("/completion_tokens_details/reasoning_tokens")
                .and_then(as_u64)
                .unwrap_or(0),
        });
    }

    let Some(choice) = value
        .get("choices")
        .and_then(|choices| choices.get(0))
        .filter(|choice| !choice.is_null())
    else {
        return out;
    };

    if let Some(delta) = choice.get("delta") {
        if let Some(text) = delta.get("content").and_then(|text| text.as_str()) {
            if !text.is_empty() {
                out.push(ChatDelta::Text(text.to_string()));
            }
        }

        if let Some(calls) = delta.get("tool_calls").and_then(|calls| calls.as_array()) {
            for call in calls {
                let index = call.get("index").and_then(as_u64).unwrap_or(0) as u32;
                let id = call
                    .get("id")
                    .and_then(|id| id.as_str())
                    .unwrap_or_default()
                    .to_string();
                let name = call
                    .pointer("/function/name")
                    .and_then(|name| name.as_str())
                    .unwrap_or_default()
                    .to_string();
                if !name.is_empty() {
                    out.push(ChatDelta::ToolStart { index, id, name });
                }
                if let Some(args) = call
                    .pointer("/function/arguments")
                    .and_then(|args| args.as_str())
                {
                    if !args.is_empty() {
                        out.push(ChatDelta::ToolArgs {
                            index,
                            args: args.to_string(),
                        });
                    }
                }
            }
        }
    }

    if let Some(reason) = choice
        .get("finish_reason")
        .and_then(|reason| reason.as_str())
    {
        out.push(ChatDelta::Finish(reason.to_string()));
    }

    out
}

fn as_u64(value: &serde_json::Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_i64().map(|v| v.max(0) as u64))
}

/// 上游 chunk 里工具调用的累计状态：渲染器要等参数拼完才能给下游一个完整调用。
#[derive(Debug, Default, Clone)]
pub(crate) struct ToolCall {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) arguments: String,
}

impl ToolCall {
    /// 把一条增量合并进来。`started` 表示这一次是否刚刚拿到名字。
    pub(crate) fn absorb(&mut self, delta: &ChatDelta) -> bool {
        match delta {
            ChatDelta::ToolStart { id, name, .. } => {
                if self.id.is_empty() && !id.is_empty() {
                    self.id = id.clone();
                }
                if self.name.is_empty() && !name.is_empty() {
                    self.name = name.clone();
                    return true;
                }
                false
            }
            ChatDelta::ToolArgs { args, .. } => {
                self.arguments.push_str(args);
                false
            }
            _ => false,
        }
    }
}

/// 渲染器：语义增量 → 目标协议的字节流。
pub(crate) trait Renderer: Send {
    fn push(&mut self, deltas: &[ChatDelta]) -> Vec<u8>;
    /// 流结束：补齐收尾事件（`response.completed` / `message_stop`）。
    fn finish(&mut self) -> Vec<u8>;
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn chunk(delta: serde_json::Value) -> String {
        format!(
            "data: {}\n\n",
            serde_json::json!({
                "id": "chatcmpl-1",
                "object": "chat.completion.chunk",
                "model": "m",
                "choices": [{ "index": 0, "delta": delta, "finish_reason": null }]
            })
        )
    }

    #[test]
    fn text_and_tool_calls_are_normalised() {
        let mut parser = ChatParser::default();
        let mut deltas = parser
            .feed(chunk(serde_json::json!({"role": "assistant", "content": "好的"})).as_bytes());
        deltas.extend(
            parser.feed(
                chunk(serde_json::json!({"tool_calls": [{
                    "index": 0, "id": "call_1", "type": "function",
                    "function": {"name": "exec_command", "arguments": "{\"cmd\":"}
                }]}))
                .as_bytes(),
            ),
        );
        deltas.extend(
            parser.feed(
                chunk(serde_json::json!({"tool_calls": [{
                    "index": 0, "function": {"arguments": "\"ls\"}"}
                }]}))
                .as_bytes(),
            ),
        );

        assert!(matches!(&deltas[0], ChatDelta::Text(text) if text == "好的"));
        assert!(matches!(
            &deltas[1],
            ChatDelta::ToolStart { index: 0, name, .. } if name == "exec_command"
        ));
        assert!(matches!(&deltas[2], ChatDelta::ToolArgs { args, .. } if args == "{\"cmd\":"));
        assert!(matches!(&deltas[3], ChatDelta::ToolArgs { args, .. } if args == "\"ls\"}"));
    }

    #[test]
    fn frames_split_across_chunks_are_buffered() {
        let mut parser = ChatParser::default();
        let raw = chunk(serde_json::json!({"content": "跨帧"}));
        let (head, tail) = raw.split_at(raw.len() / 2);
        assert!(parser.feed(head.as_bytes()).is_empty(), "半帧不该被解析");
        let deltas = parser.feed(tail.as_bytes());
        assert!(matches!(&deltas[0], ChatDelta::Text(text) if text == "跨帧"));
    }

    #[test]
    fn usage_and_finish_reason_are_reported() {
        let mut parser = ChatParser::default();
        let raw =
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\
                   \"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4,\
                   \"prompt_tokens_details\":{\"cached_tokens\":6}}}\n\n";
        let deltas = parser.feed(raw.as_bytes());
        assert!(deltas.contains(&ChatDelta::Finish("tool_calls".to_string())));
        assert!(deltas.contains(&ChatDelta::Usage {
            prompt: 10,
            completion: 4,
            cached: 6,
            reasoning: 0
        }));
    }

    #[test]
    fn broken_lines_are_skipped_not_fatal() {
        let mut parser = ChatParser::default();
        let deltas = parser.feed(b"data: not json\n\ndata: {\"choices\":[]}\n\n");
        assert!(deltas.is_empty());
    }

    #[test]
    fn tool_call_accumulates_until_complete() {
        let mut call = ToolCall::default();
        assert!(call.absorb(&ChatDelta::ToolStart {
            index: 0,
            id: "call_1".into(),
            name: "exec_command".into(),
        }));
        call.absorb(&ChatDelta::ToolArgs {
            index: 0,
            args: "{\"cmd\":".into(),
        });
        call.absorb(&ChatDelta::ToolArgs {
            index: 0,
            args: "\"ls\"}".into(),
        });
        assert_eq!(call.id, "call_1");
        assert_eq!(call.arguments, "{\"cmd\":\"ls\"}");
    }
}
