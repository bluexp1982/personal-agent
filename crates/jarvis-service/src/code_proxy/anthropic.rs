//! Anthropic **Messages API** → OpenAI **Chat Completions** 的转换（Claude Code 用）。
//!
//! Claude Code 只讲 Anthropic 协议；本项目的模型出口只有 `/chat/completions`。
//! 所以与 `responses.rs` 同一思路：只映射已知字段，转换后仍走同一条上游、
//! 同一套令牌 / 白名单 / 预算 / 记账。
//!
//! 丢弃项（记 debug）：`thinking`、`cache_control`、`metadata`、`system` 里的
//! 非 text 块。网关按请求体自动做前缀缓存，不需要 `cache_control` 的显式标记，
//! 但**不会**因为丢弃它而改变命中行为。

use serde_json::{json, Value};

use super::translate::{ChatDelta, Renderer, ToolCall};

/// Anthropic 请求 → Chat 请求体。
pub(crate) fn to_chat(raw: &[u8]) -> Result<Vec<u8>, String> {
    let request: Value =
        serde_json::from_slice(raw).map_err(|err| format!("请求体不是合法 JSON：{err}"))?;
    let model = request
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if model.is_empty() {
        return Err("Messages 请求缺少 model".to_string());
    }

    let mut messages: Vec<Value> = Vec::new();
    if let Some(system) = request.get("system") {
        let text = blocks_text(system);
        if !text.is_empty() {
            messages.push(json!({"role": "system", "content": text}));
        }
    }

    if let Some(list) = request.get("messages").and_then(Value::as_array) {
        for message in list {
            let role = message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("user");
            match message.get("content") {
                Some(Value::String(text)) => {
                    messages.push(json!({"role": role, "content": text}));
                }
                Some(Value::Array(parts)) => {
                    push_blocks(&mut messages, role, parts);
                }
                _ => {}
            }
        }
    }

    let mut tools: Vec<Value> = Vec::new();
    if let Some(list) = request.get("tools").and_then(Value::as_array) {
        for tool in list {
            let name = tool.get("name").and_then(Value::as_str).unwrap_or("");
            if name.is_empty() {
                continue;
            }
            // Anthropic 的工具定义是平铺的（name/description/input_schema），
            // chat 协议是 `function` 包一层；不转换会被上游 400。
            tools.push(json!({
                "type": "function",
                "function": {
                    "name": name,
                    "description": tool.get("description").cloned().unwrap_or(Value::Null),
                    "parameters": tool.get("input_schema").cloned()
                        .unwrap_or_else(|| json!({"type": "object", "properties": {}})),
                }
            }));
        }
    }

    let mut body = json!({
        "model": model,
        "messages": messages,
        "stream": request.get("stream").and_then(Value::as_bool).unwrap_or(false),
    });
    if let Some(max_tokens) = request.get("max_tokens") {
        body["max_tokens"] = max_tokens.clone();
    }
    for key in ["temperature", "top_p"] {
        if let Some(value) = request.get(key) {
            body[key] = value.clone();
        }
    }
    if let Some(stops) = request.get("stop_sequences") {
        body["stop"] = stops.clone();
    }
    if !tools.is_empty() {
        body["tools"] = Value::Array(tools);
        if let Some(choice) = request.get("tool_choice") {
            body["tool_choice"] = match choice.get("type").and_then(Value::as_str) {
                Some("any") => json!("required"),
                Some("tool") => json!({
                    "type": "function",
                    "function": {"name": choice.get("name").and_then(Value::as_str).unwrap_or("")}
                }),
                _ => json!("auto"),
            };
        }
    }
    if body["stream"].as_bool().unwrap_or(false) {
        body["stream_options"] = json!({"include_usage": true});
    }

    serde_json::to_vec(&body).map_err(|err| format!("构造 chat 请求失败：{err}"))
}

/// 一条 Anthropic 消息的 content 数组 → 若干条 chat 消息。
///
/// 关键差异：Anthropic 把 `tool_result` 放在 **user** 消息里，chat 协议要求
/// 单独的 `role: "tool"` 消息；同一个数组里可能既有文本又有多个结果。
fn push_blocks(messages: &mut Vec<Value>, role: &str, parts: &[Value]) {
    let mut text = String::new();
    let mut tool_calls: Vec<Value> = Vec::new();

    for part in parts {
        match part.get("type").and_then(Value::as_str).unwrap_or("text") {
            "text" => {
                if let Some(chunk) = part.get("text").and_then(Value::as_str) {
                    text.push_str(chunk);
                }
            }
            "tool_use" => {
                let id = part.get("id").and_then(Value::as_str).unwrap_or("");
                let name = part.get("name").and_then(Value::as_str).unwrap_or("");
                if id.is_empty() || name.is_empty() {
                    continue;
                }
                tool_calls.push(json!({
                    "id": id,
                    "type": "function",
                    "function": {
                        "name": name,
                        "arguments": part.get("input").map(|input| input.to_string())
                            .unwrap_or_else(|| "{}".to_string()),
                    }
                }));
            }
            "tool_result" => {
                // 先把前面攒的文本落盘，再紧跟 tool 消息：顺序错了模型会看不懂。
                flush_text(messages, role, std::mem::take(&mut text));
                let call_id = part
                    .get("tool_use_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if call_id.is_empty() {
                    continue;
                }
                messages.push(json!({
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": blocks_text(part.get("content").unwrap_or(&Value::Null)),
                }));
            }
            _ => {}
        }
    }

    if !tool_calls.is_empty() {
        flush_text(messages, role, std::mem::take(&mut text));
        messages.push(json!({
            "role": "assistant",
            "content": Value::Null,
            "tool_calls": tool_calls
        }));
    }
    flush_text(messages, role, text);
}

fn flush_text(messages: &mut Vec<Value>, role: &str, text: String) {
    if text.is_empty() {
        return;
    }
    messages.push(json!({"role": role, "content": text}));
}

fn blocks_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| {
                part.get("text")
                    .and_then(Value::as_str)
                    .or_else(|| part.as_str())
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// Chat SSE → Anthropic SSE。
pub(crate) struct StreamRenderer {
    model: String,
    message_id: String,
    started: bool,
    /// 当前打开的 content block 下标，以及它是文本还是某个工具调用。
    open: Option<OpenBlock>,
    next_index: u32,
    tools: Vec<(u32, ToolCall)>,
    finish_reason: Option<String>,
    prompt_tokens: u64,
    completion_tokens: u64,
    cached_tokens: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OpenBlock {
    Text,
    Tool(u32),
}

impl StreamRenderer {
    pub(crate) fn new(model: &str, message_id: &str) -> Self {
        Self {
            model: model.to_string(),
            message_id: message_id.to_string(),
            started: false,
            open: None,
            next_index: 0,
            tools: Vec::new(),
            finish_reason: None,
            prompt_tokens: 0,
            completion_tokens: 0,
            cached_tokens: 0,
        }
    }

    fn ensure_started(&mut self, out: &mut Vec<u8>) {
        if self.started {
            return;
        }
        self.started = true;
        emit(
            out,
            "message_start",
            json!({"type": "message_start", "message": {
                "id": self.message_id,
                "type": "message",
                "role": "assistant",
                "model": self.model,
                "content": [],
                "stop_reason": Value::Null,
                "stop_sequence": Value::Null,
                "usage": {"input_tokens": 0, "output_tokens": 0}
            }}),
        );
    }

    fn close_block(&mut self, out: &mut Vec<u8>) {
        if let Some(open) = self.open.take() {
            let index = self.block_index(open);
            emit(
                out,
                "content_block_stop",
                json!({"type": "content_block_stop", "index": index}),
            );
        }
    }

    fn block_index(&self, open: OpenBlock) -> u32 {
        match open {
            OpenBlock::Text => 0,
            OpenBlock::Tool(_) => self.next_index,
        }
    }

    fn open_text(&mut self, out: &mut Vec<u8>) {
        if self.open == Some(OpenBlock::Text) {
            return;
        }
        self.close_block(out);
        self.open = Some(OpenBlock::Text);
        emit(
            out,
            "content_block_start",
            json!({"type": "content_block_start", "index": 0,
                   "content_block": {"type": "text", "text": ""}}),
        );
    }

    fn open_tool(&mut self, out: &mut Vec<u8>, position: usize) {
        let (index, call) = self.tools[position].clone();
        if self.open == Some(OpenBlock::Tool(index)) {
            return;
        }
        self.close_block(out);
        self.open = Some(OpenBlock::Tool(index));
        emit(
            out,
            "content_block_start",
            json!({"type": "content_block_start", "index": self.next_index,
                   "content_block": {"type": "tool_use", "id": call_id_of(&call),
                                     "name": call.name, "input": {}}}),
        );
    }
}

impl Renderer for StreamRenderer {
    fn push(&mut self, deltas: &[ChatDelta]) -> Vec<u8> {
        let mut out = Vec::new();
        for delta in deltas {
            match delta {
                ChatDelta::Text(text) => {
                    self.ensure_started(&mut out);
                    self.open_text(&mut out);
                    emit(
                        &mut out,
                        "content_block_delta",
                        json!({"type": "content_block_delta", "index": 0,
                               "delta": {"type": "text_delta", "text": text}}),
                    );
                }
                ChatDelta::ToolStart { index, .. } | ChatDelta::ToolArgs { index, .. } => {
                    self.ensure_started(&mut out);
                    let position = match self.tools.iter().position(|(slot, _)| slot == index) {
                        Some(position) => position,
                        None => {
                            self.tools.push((*index, ToolCall::default()));
                            self.tools.len() - 1
                        }
                    };
                    let opened = self.tools[position].1.absorb(delta);
                    if opened {
                        // 工具块的下标在打开时分配一次，之后固定。
                        self.next_index = match self.open {
                            Some(OpenBlock::Text) => 1,
                            Some(OpenBlock::Tool(current)) => current + 1,
                            None => 0,
                        };
                        self.open_tool(&mut out, position);
                    }
                    if let ChatDelta::ToolArgs { args, .. } = delta {
                        let index = match self.open {
                            Some(OpenBlock::Tool(value)) => value,
                            _ => self.next_index,
                        };
                        emit(
                            &mut out,
                            "content_block_delta",
                            json!({"type": "content_block_delta", "index": index,
                                   "delta": {"type": "input_json_delta",
                                             "partial_json": args}}),
                        );
                    }
                }
                ChatDelta::Finish(reason) => self.finish_reason = Some(reason.clone()),
                ChatDelta::Usage {
                    prompt,
                    completion,
                    cached,
                    ..
                } => {
                    self.prompt_tokens = *prompt;
                    self.completion_tokens = *completion;
                    self.cached_tokens = *cached;
                }
            }
        }
        out
    }

    fn finish(&mut self) -> Vec<u8> {
        let mut out = Vec::new();
        self.ensure_started(&mut out);
        self.close_block(&mut out);

        let has_tools = !self.tools.is_empty();
        let stop_reason = match self.finish_reason.as_deref() {
            Some("length") => "max_tokens",
            Some("tool_calls") => "tool_use",
            _ if has_tools => "tool_use",
            _ => "end_turn",
        };

        emit(
            &mut out,
            "message_delta",
            json!({"type": "message_delta",
            "delta": {"stop_reason": stop_reason, "stop_sequence": Value::Null},
            "usage": {
                // Anthropic 的 input_tokens 不含缓存命中部分，单独报 cache_read。
                "input_tokens": self.prompt_tokens.saturating_sub(self.cached_tokens),
                "output_tokens": self.completion_tokens,
                "cache_read_input_tokens": self.cached_tokens,
            }}),
        );
        emit(&mut out, "message_stop", json!({"type": "message_stop"}));
        out
    }
}

fn call_id_of(call: &ToolCall) -> String {
    if !call.id.is_empty() {
        return call.id.clone();
    }
    format!("toolu_{}", call.name)
}

fn emit(out: &mut Vec<u8>, event: &str, payload: Value) {
    out.extend_from_slice(format!("event: {event}\n").as_bytes());
    out.extend_from_slice(format!("data: {payload}\n\n").as_bytes());
}

/// 非流式：Chat completion JSON → Anthropic message 对象。
pub(crate) fn json_response(chat: &[u8], model: &str, message_id: &str) -> Vec<u8> {
    let value: Value = serde_json::from_slice(chat).unwrap_or_else(|_| json!({}));
    let message = value
        .pointer("/choices/0/message")
        .cloned()
        .unwrap_or_else(|| json!({}));

    let mut content = Vec::new();
    let text = message
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !text.is_empty() {
        content.push(json!({"type": "text", "text": text}));
    }
    let mut has_tools = false;
    if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
        for call in calls {
            has_tools = true;
            content.push(json!({
                "type": "tool_use",
                "id": call.get("id").and_then(Value::as_str).unwrap_or("toolu_1"),
                "name": call.pointer("/function/name").and_then(Value::as_str).unwrap_or(""),
                "input": call.pointer("/function/arguments")
                    .and_then(Value::as_str)
                    .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
                    .unwrap_or_else(|| json!({})),
            }));
        }
    }

    let usage = value.get("usage").cloned().unwrap_or_else(|| json!({}));
    let prompt = usage
        .get("prompt_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let completion = usage
        .get("completion_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let cached = usage
        .pointer("/prompt_tokens_details/cached_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);

    let body = json!({
        "id": message_id,
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": if has_tools { "tool_use" } else { "end_turn" },
        "stop_sequence": Value::Null,
        "usage": {
            "input_tokens": prompt.saturating_sub(cached),
            "output_tokens": completion,
            "cache_read_input_tokens": cached,
        }
    });
    serde_json::to_vec(&body).unwrap_or_else(|_| b"{}".to_vec())
}

/// `POST /count_tokens`：上游没有对应能力，按"3 字节 ≈ 1 token"给一个估算。
///
/// 明确标 `estimated`：Claude Code 只用它做上下文管理，不用于计费。
pub(crate) fn count_tokens(raw: &[u8]) -> Vec<u8> {
    let tokens = super::usage::estimate_tokens(raw.len() as u64);
    serde_json::to_vec(&json!({"input_tokens": tokens})).unwrap_or_else(|_| b"{}".to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::code_proxy::translate::tests::chunk;
    use crate::code_proxy::translate::ChatParser;

    #[test]
    fn system_tools_and_tool_results_are_mapped() {
        let request = json!({
            "model": "m",
            "max_tokens": 512,
            "system": [{"type": "text", "text": "你是编码 agent"}],
            "messages": [
                {"role": "user", "content": "列目录"},
                {"role": "assistant", "content": [
                    {"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "ls"}}
                ]},
                {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_1",
                     "content": [{"type": "text", "text": "a.txt"}]},
                    {"type": "text", "text": "继续"}
                ]}
            ],
            "tools": [{"name": "Bash", "description": "跑命令",
                       "input_schema": {"type": "object", "properties": {"command": {"type": "string"}}}}],
            "tool_choice": {"type": "any"},
            "stream": true
        });
        let chat: Value =
            serde_json::from_slice(&to_chat(request.to_string().as_bytes()).unwrap()).unwrap();
        let messages = chat["messages"].as_array().unwrap();
        assert_eq!(messages[0]["role"], "system");
        assert_eq!(messages[1]["content"], "列目录");
        assert_eq!(messages[2]["tool_calls"][0]["function"]["name"], "Bash");
        assert_eq!(messages[3]["role"], "tool");
        assert_eq!(messages[3]["tool_call_id"], "toolu_1");
        assert_eq!(messages[4]["content"], "继续");
        assert_eq!(chat["tools"][0]["function"]["parameters"]["type"], "object");
        assert_eq!(chat["tool_choice"], "required");
        assert_eq!(chat["max_tokens"], 512);
        assert_eq!(chat["stream_options"]["include_usage"], true);
    }

    #[test]
    fn text_stream_has_the_anthropic_skeleton() {
        let mut parser = ChatParser::default();
        let mut renderer = StreamRenderer::new("m", "msg_1");
        let mut out = Vec::new();
        out.extend(renderer.push(&parser.feed(chunk(json!({"content": "好"})).as_bytes())));
        out.extend(
            renderer.push(
                &parser.feed(
                    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\
             \"usage\":{\"prompt_tokens\":8,\"completion_tokens\":2,\
             \"prompt_tokens_details\":{\"cached_tokens\":3}}}\n\n"
                        .as_bytes(),
                ),
            ),
        );
        out.extend(renderer.finish());
        let text = String::from_utf8_lossy(&out);
        for event in [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ] {
            assert!(text.contains(event), "缺事件 {event}：\n{text}");
        }
        assert!(text.contains("\"stop_reason\":\"end_turn\""), "{text}");
        assert!(text.contains("\"cache_read_input_tokens\":3"), "{text}");
        assert!(
            text.contains("\"input_tokens\":5"),
            "缓存命中要从输入里扣掉：{text}"
        );
    }

    #[test]
    fn tool_stream_uses_input_json_delta_and_tool_use_stop() {
        let mut parser = ChatParser::default();
        let mut renderer = StreamRenderer::new("m", "msg_1");
        let mut out = Vec::new();
        out.extend(
            renderer.push(
                &parser.feed(
                    chunk(
                        json!({"tool_calls": [{"index": 0, "id": "call_1", "type": "function",
                        "function": {"name": "Bash", "arguments": "{\"command\":"}}]}),
                    )
                    .as_bytes(),
                ),
            ),
        );
        out.extend(
            renderer.push(
                &parser.feed(
                    chunk(json!({"tool_calls": [{"index": 0,
                        "function": {"arguments": "\"ls\"}"}}]}))
                    .as_bytes(),
                ),
            ),
        );
        out.extend(renderer.finish());
        let text = String::from_utf8_lossy(&out);
        assert!(text.contains("\"type\":\"tool_use\""), "{text}");
        assert!(text.contains("input_json_delta"), "{text}");
        assert!(text.contains("\"stop_reason\":\"tool_use\""), "{text}");
        assert!(text.contains("\"id\":\"call_1\""), "{text}");
    }

    #[test]
    fn non_stream_response_maps_tool_inputs() {
        let chat = json!({
            "choices": [{"message": {"role": "assistant", "content": "好的",
                "tool_calls": [{"id": "c1", "type": "function",
                                "function": {"name": "Bash", "arguments": "{\"command\":\"ls\"}"}}]}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 3}
        });
        let out = json_response(chat.to_string().as_bytes(), "m", "msg_1");
        let value: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(value["stop_reason"], "tool_use");
        assert_eq!(value["content"][1]["input"]["command"], "ls");
        assert_eq!(value["usage"]["input_tokens"], 10);
    }
}
