//! OpenAI **Responses API** → OpenAI **Chat Completions** 的转换（Codex 用）。
//!
//! 为什么需要它：`codex-cli 0.164.0` 已移除 `wire_api = "chat"`，只会发
//! `POST {base}/responses`。本项目的模型出口只有 `/chat/completions` 一条，
//! 所以在这一层做**字段映射**，而不是让 Codex 绕过代理。
//!
//! 明确不做的：`reasoning` / `include: ["reasoning.encrypted_content"]` /
//! `store` / `prompt_cache_key` 这些 Responses 专有语义一律丢弃（记一次 warn）——
//! 我们的网关没有推理态与跨轮存储，伪造只会让模型行为更怪。前缀缓存仍由
//! 网关按请求体自动命中，不需要 `prompt_cache_key`。

use serde_json::{json, Value};

use super::translate::{ChatDelta, Renderer, ToolCall};
// 只有单测的 `render_all()` 需要解析上游片断。
#[cfg(test)]
use super::translate::ChatParser;

/// Responses 请求 → Chat 请求体。
pub(crate) fn to_chat(raw: &[u8]) -> Result<Vec<u8>, String> {
    let request: Value =
        serde_json::from_slice(raw).map_err(|err| format!("请求体不是合法 JSON：{err}"))?;
    let model = request
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if model.is_empty() {
        return Err("Responses 请求缺少 model".to_string());
    }

    let mut messages: Vec<Value> = Vec::new();
    if let Some(instructions) = request.get("instructions").and_then(Value::as_str) {
        if !instructions.trim().is_empty() {
            messages.push(json!({"role": "system", "content": instructions}));
        }
    }

    let mut dropped = 0usize;
    if let Some(items) = request.get("input").and_then(Value::as_array) {
        for item in items {
            match item
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("message")
            {
                "message" => {
                    let role = item.get("role").and_then(Value::as_str).unwrap_or("user");
                    let text = content_text(item.get("content"));
                    // Codex 把系统提示写成 developer 消息：换成 system，
                    // 否则模型会把"你是编码 agent"当成用户说的话。
                    let role = match role {
                        "developer" | "system" => "system",
                        "assistant" => "assistant",
                        _ => "user",
                    };
                    if text.is_empty() && role != "assistant" {
                        continue;
                    }
                    messages.push(json!({"role": role, "content": text}));
                }
                "function_call" => {
                    let call_id = item.get("call_id").and_then(Value::as_str).unwrap_or("");
                    let name = item.get("name").and_then(Value::as_str).unwrap_or("");
                    let arguments = item
                        .get("arguments")
                        .and_then(Value::as_str)
                        .unwrap_or("{}");
                    if call_id.is_empty() || name.is_empty() {
                        dropped += 1;
                        continue;
                    }
                    // 连续的工具调用要落进同一条 assistant 消息的 `tool_calls` 里，
                    // 拆成多条会让上游以为模型连着说了几句。
                    let reuse = messages
                        .last_mut()
                        .filter(|message| message.get("tool_calls").is_some());
                    match reuse {
                        Some(message) => {
                            if let Some(calls) =
                                message.get_mut("tool_calls").and_then(Value::as_array_mut)
                            {
                                calls.push(tool_call(call_id, name, arguments));
                            }
                        }
                        None => messages.push(json!({
                            "role": "assistant",
                            "content": Value::Null,
                            "tool_calls": [tool_call(call_id, name, arguments)]
                        })),
                    }
                }
                "function_call_output" => {
                    let call_id = item.get("call_id").and_then(Value::as_str).unwrap_or("");
                    if call_id.is_empty() {
                        dropped += 1;
                        continue;
                    }
                    messages.push(json!({
                        "role": "tool",
                        "tool_call_id": call_id,
                        "content": output_text(item.get("output"))
                    }));
                }
                _ => dropped += 1,
            }
        }
    }

    let mut tools: Vec<Value> = Vec::new();
    if let Some(list) = request.get("tools").and_then(Value::as_array) {
        for tool in list {
            match tool.get("type").and_then(Value::as_str) {
                Some("function") => {
                    let name = tool.get("name").and_then(Value::as_str).unwrap_or("");
                    if name.is_empty() {
                        continue;
                    }
                    let parameters = tool
                        .get("parameters")
                        .cloned()
                        .unwrap_or_else(|| json!({"type": "object", "properties": {}}));
                    tools.push(json!({
                        "type": "function",
                        "function": {
                            "name": name,
                            "description": tool.get("description").cloned().unwrap_or(Value::Null),
                            "parameters": parameters,
                        }
                    }));
                }
                // `web_search` / `namespace` 这类 Responses 专有工具在 chat 协议里
                // 没有对应物；不静默塞一个假的，直接计数后丢弃。
                _ => dropped += 1,
            }
        }
    }

    if dropped > 0 {
        // 一条 warn 就够：正文里每轮都会出现，刷屏没有额外信息。
        tracing::debug!(
            dropped,
            "Responses 请求里有无法映射到 chat 协议的字段，已丢弃"
        );
    }

    let mut body = json!({
        "model": model,
        "messages": messages,
        "stream": request.get("stream").and_then(Value::as_bool).unwrap_or(false),
    });
    if !tools.is_empty() {
        body["tools"] = Value::Array(tools);
        body["tool_choice"] = request
            .get("tool_choice")
            .cloned()
            .unwrap_or_else(|| json!("auto"));
    }
    for key in ["temperature", "top_p", "max_output_tokens"] {
        if let Some(value) = request.get(key) {
            let target = if key == "max_output_tokens" {
                "max_tokens"
            } else {
                key
            };
            body[target] = value.clone();
        }
    }
    if body["stream"].as_bool().unwrap_or(false) {
        body["stream_options"] = json!({"include_usage": true});
    }

    serde_json::to_vec(&body).map_err(|err| format!("构造 chat 请求失败：{err}"))
}

fn tool_call(call_id: &str, name: &str, arguments: &str) -> Value {
    json!({
        "id": call_id,
        "type": "function",
        "function": { "name": name, "arguments": arguments }
    })
}

fn content_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(parts)) => parts
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

fn output_text(output: Option<&Value>) -> String {
    match output {
        Some(Value::String(text)) => text.clone(),
        Some(other) => other.to_string(),
        None => String::new(),
    }
}

/// Chat SSE → Responses SSE。
pub(crate) struct StreamRenderer {
    model: String,
    response_id: String,
    created_at: i64,
    started: bool,
    text: String,
    text_open: bool,
    tools: Vec<(u32, ToolCall)>,
    finish_reason: Option<String>,
    prompt_tokens: u64,
    completion_tokens: u64,
    cached_tokens: u64,
}

impl StreamRenderer {
    pub(crate) fn new(model: &str, response_id: &str, created_at: i64) -> Self {
        Self {
            model: model.to_string(),
            response_id: response_id.to_string(),
            created_at,
            started: false,
            text: String::new(),
            text_open: false,
            tools: Vec::new(),
            finish_reason: None,
            prompt_tokens: 0,
            completion_tokens: 0,
            cached_tokens: 0,
        }
    }

    fn response_object(&self, status: &str, output: Value) -> Value {
        let mut response = json!({
            "id": self.response_id,
            "object": "response",
            "created_at": self.created_at,
            "model": self.model,
            "status": status,
            "output": output,
        });
        if status == "completed" {
            response["usage"] = json!({
                "input_tokens": self.prompt_tokens,
                "input_tokens_details": { "cached_tokens": self.cached_tokens },
                "output_tokens": self.completion_tokens,
                "total_tokens": self.prompt_tokens + self.completion_tokens,
            });
        }
        response
    }

    fn ensure_started(&mut self, out: &mut Vec<u8>) {
        if self.started {
            return;
        }
        self.started = true;
        emit(
            out,
            "response.created",
            json!({"type": "response.created", "response": self.response_object("in_progress", json!([]))}),
        );
        emit(
            out,
            "response.in_progress",
            json!({"type": "response.in_progress", "response": self.response_object("in_progress", json!([]))}),
        );
    }

    fn open_text(&mut self, out: &mut Vec<u8>) {
        if self.text_open {
            return;
        }
        self.text_open = true;
        emit(
            out,
            "response.output_item.added",
            json!({
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {"id": format!("{}_msg", self.response_id), "type": "message",
                         "status": "in_progress", "role": "assistant", "content": []}
            }),
        );
        emit(
            out,
            "response.content_part.added",
            json!({
                "type": "response.content_part.added",
                "item_id": format!("{}_msg", self.response_id),
                "output_index": 0,
                "content_index": 0,
                "part": {"type": "output_text", "text": ""}
            }),
        );
    }

    fn tool_item_id(&self, index: u32) -> String {
        format!("{}_fc{index}", self.response_id)
    }

    fn close(&mut self, out: &mut Vec<u8>) {
        if self.text_open {
            emit(
                out,
                "response.output_text.done",
                json!({
                    "type": "response.output_text.done",
                    "item_id": format!("{}_msg", self.response_id),
                    "output_index": 0,
                    "content_index": 0,
                    "text": self.text,
                }),
            );
            emit(
                out,
                "response.content_part.done",
                json!({
                    "type": "response.content_part.done",
                    "item_id": format!("{}_msg", self.response_id),
                    "output_index": 0,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": self.text},
                }),
            );
            emit(
                out,
                "response.output_item.done",
                json!({
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": {"id": format!("{}_msg", self.response_id), "type": "message",
                             "status": "completed", "role": "assistant",
                             "content": [{"type": "output_text", "text": self.text}]}
                }),
            );
        }

        let mut output = Vec::new();
        if self.text_open {
            output.push(json!({
                "id": format!("{}_msg", self.response_id),
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": self.text}]
            }));
        }
        let tools = self.tools.clone();
        for (position, (index, call)) in tools.iter().enumerate() {
            let output_index = if self.text_open {
                position + 1
            } else {
                position
            };
            let item = json!({
                "id": self.tool_item_id(*index),
                "type": "function_call",
                "status": "completed",
                "name": call.name,
                "arguments": call.arguments,
                "call_id": call_id_of(call),
            });
            emit(
                out,
                "response.output_item.done",
                json!({"type": "response.output_item.done",
                       "output_index": output_index, "item": item}),
            );
            output.push(item);
        }

        let status = if self.finish_reason.as_deref() == Some("length") {
            "incomplete"
        } else {
            "completed"
        };
        emit(
            out,
            "response.completed",
            json!({"type": "response.completed",
                   "response": self.response_object(status, Value::Array(output))}),
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
                    self.text.push_str(text);
                    emit(
                        &mut out,
                        "response.output_text.delta",
                        json!({
                            "type": "response.output_text.delta",
                            "item_id": format!("{}_msg", self.response_id),
                            "output_index": 0,
                            "content_index": 0,
                            "delta": text,
                        }),
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
                    let output_index = if self.text_open {
                        position + 1
                    } else {
                        position
                    };
                    if opened {
                        let (index, call) = &self.tools[position];
                        emit(
                            &mut out,
                            "response.output_item.added",
                            json!({
                                "type": "response.output_item.added",
                                "output_index": output_index,
                                "item": {"id": self.tool_item_id(*index), "type": "function_call",
                                         "status": "in_progress", "name": call.name,
                                         "arguments": "", "call_id": call_id_of(call)}
                            }),
                        );
                    }
                    if let ChatDelta::ToolArgs { args, .. } = delta {
                        let (index, _) = &self.tools[position];
                        emit(
                            &mut out,
                            "response.function_call_arguments.delta",
                            json!({
                                "type": "response.function_call_arguments.delta",
                                "item_id": self.tool_item_id(*index),
                                "output_index": output_index,
                                "delta": args,
                            }),
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
        self.close(&mut out);
        out
    }
}

/// 上游可能不给 `id`；Codex 用它把结果配回调用，缺了会报错，所以补一个稳定值。
fn call_id_of(call: &ToolCall) -> String {
    if !call.id.is_empty() {
        return call.id.clone();
    }
    format!("call_{}", call.name)
}

fn emit(out: &mut Vec<u8>, event: &str, payload: Value) {
    out.extend_from_slice(format!("event: {event}\n").as_bytes());
    out.extend_from_slice(format!("data: {payload}\n\n").as_bytes());
}

/// 非流式：Chat 的 completion JSON → Responses 的 response 对象。
pub(crate) fn json_response(
    chat: &[u8],
    model: &str,
    response_id: &str,
    created_at: i64,
) -> Vec<u8> {
    let value: Value = serde_json::from_slice(chat).unwrap_or_else(|_| json!({}));
    let message = value
        .pointer("/choices/0/message")
        .cloned()
        .unwrap_or_else(|| json!({}));

    let mut output = Vec::new();
    let text = message
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !text.is_empty() {
        output.push(json!({
            "id": format!("{response_id}_msg"),
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text}]
        }));
    }
    if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
        for (index, call) in calls.iter().enumerate() {
            output.push(json!({
                "id": format!("{response_id}_fc{index}"),
                "type": "function_call",
                "status": "completed",
                "name": call.pointer("/function/name").and_then(Value::as_str).unwrap_or(""),
                "arguments": call.pointer("/function/arguments").and_then(Value::as_str).unwrap_or("{}"),
                "call_id": call.get("id").and_then(Value::as_str).unwrap_or(""),
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
        "id": response_id,
        "object": "response",
        "created_at": created_at,
        "model": model,
        "status": "completed",
        "output": output,
        "usage": {
            "input_tokens": prompt,
            "input_tokens_details": {"cached_tokens": cached},
            "output_tokens": completion,
            "total_tokens": prompt + completion,
        }
    });
    serde_json::to_vec(&body).unwrap_or_else(|_| b"{}".to_vec())
}

/// 把上游的 SSE 文本渲染成 Responses 的完整事件流（测试与离线校验用）。
#[cfg(test)]
fn render_all(chunks: &[&str], model: &str) -> String {
    let mut parser = ChatParser::default();
    let mut renderer = StreamRenderer::new(model, "resp_test", 1);
    let mut out = Vec::new();
    for chunk in chunks {
        out.extend(renderer.push(&parser.feed(chunk.as_bytes())));
    }
    out.extend(renderer.finish());
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::code_proxy::translate::tests::chunk;

    #[test]
    fn developer_messages_become_system_and_tool_items_round_trip() {
        let request = json!({
            "model": "m",
            "stream": true,
            "input": [
                {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "你是编码 agent"}]},
                {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "列目录"}]},
                {"type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"ls\"}", "call_id": "c1"},
                {"type": "function_call_output", "call_id": "c1", "output": "a.txt"}
            ],
            "tools": [{"type": "function", "name": "exec_command", "parameters": {"type": "object"}}],
            "reasoning": {"summary": "auto"},
            "store": false
        });
        let chat: Value =
            serde_json::from_slice(&to_chat(request.to_string().as_bytes()).unwrap()).unwrap();
        let messages = chat.get("messages").and_then(Value::as_array).unwrap();
        assert_eq!(messages[0]["role"], "system");
        assert_eq!(messages[0]["content"], "你是编码 agent");
        assert_eq!(messages[1]["role"], "user");
        assert_eq!(messages[2]["role"], "assistant");
        assert_eq!(
            messages[2]["tool_calls"][0]["function"]["name"],
            "exec_command"
        );
        assert_eq!(messages[3]["role"], "tool");
        assert_eq!(messages[3]["tool_call_id"], "c1");
        assert_eq!(chat["tools"][0]["function"]["name"], "exec_command");
        assert_eq!(chat["stream_options"]["include_usage"], true);
    }

    #[test]
    fn consecutive_calls_share_one_assistant_message() {
        let request = json!({
            "model": "m",
            "input": [
                {"type": "function_call", "name": "a", "arguments": "{}", "call_id": "c1"},
                {"type": "function_call", "name": "b", "arguments": "{}", "call_id": "c2"}
            ]
        });
        let chat: Value =
            serde_json::from_slice(&to_chat(request.to_string().as_bytes()).unwrap()).unwrap();
        let messages = chat.get("messages").and_then(Value::as_array).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0]["tool_calls"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn text_stream_emits_the_events_codex_expects() {
        let out = render_all(
            &[
                &chunk(json!({"role": "assistant", "content": "完成"})),
                "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\
                 \"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}\n\n",
            ],
            "deepseek",
        );
        for event in [
            "response.created",
            "response.output_item.added",
            "response.output_text.delta",
            "response.output_text.done",
            "response.output_item.done",
            "response.completed",
        ] {
            assert!(out.contains(event), "缺事件 {event}：\n{out}");
        }
        assert!(out.contains("\"input_tokens\":10"), "{out}");
        assert!(out.contains("\"status\":\"completed\""), "{out}");
    }

    #[test]
    fn tool_calls_become_function_call_items_with_call_id() {
        let out = render_all(
            &[&chunk(json!({"tool_calls": [{
                "index": 0, "id": "call_abc", "type": "function",
                "function": {"name": "exec_command", "arguments": "{\"cmd\":\"ls\"}"}
            }]}))],
            "deepseek",
        );
        assert!(
            out.contains("response.function_call_arguments.delta"),
            "{out}"
        );
        assert!(out.contains("\"call_id\":\"call_abc\""), "{out}");
        assert!(out.contains("\"name\":\"exec_command\""), "{out}");
        assert!(out.contains("response.completed"), "{out}");
    }

    #[test]
    fn missing_tool_id_gets_a_stable_call_id() {
        let out = render_all(
            &[&chunk(json!({"tool_calls": [{
                "index": 0, "type": "function",
                "function": {"name": "exec_command", "arguments": "{}"}
            }]}))],
            "deepseek",
        );
        assert!(out.contains("\"call_id\":\"call_exec_command\""), "{out}");
    }

    #[test]
    fn non_stream_response_is_a_response_object() {
        let chat = json!({
            "choices": [{"message": {"role": "assistant", "content": "好",
                          "tool_calls": [{"id": "c1", "type": "function",
                                          "function": {"name": "exec_command", "arguments": "{}"}}]}}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2,
                      "prompt_tokens_details": {"cached_tokens": 1}}
        });
        let out = json_response(chat.to_string().as_bytes(), "m", "resp_1", 7);
        let value: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(value["object"], "response");
        assert_eq!(value["output"].as_array().unwrap().len(), 2);
        assert_eq!(value["usage"]["input_tokens_details"]["cached_tokens"], 1);
    }
}
