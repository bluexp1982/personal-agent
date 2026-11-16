//! SSE 事件编码。
//!
//! 事件模型来自 `protocol::StreamEvent`，与 v1.1 的 DataChannel 共用：
//! 换传输不换语义，客户端只需要一套解析逻辑。

use axum::response::sse::Event;
use protocol::{
    FileWrite, MediaAsset, MessageSource, MessageStep, StreamEvent, TaskSuggestion, TokenUsage,
};

/// 把统一事件包装成 SSE 的 `data:` 行。
pub fn to_sse(event: &StreamEvent) -> Event {
    Event::default().data(event.to_json())
}

/// 完成事件要带给客户端的全部内容。
///
/// 收成结构体而不是长参数列表：每加一类卡片（文件、媒体……）都改一次签名，
/// 调用方与测试就得跟着挪位置，还容易把两个 `&[]` 传反。
#[derive(Debug, Default)]
pub struct CompletedPayload<'a> {
    pub message_id: &'a str,
    pub finish_reason: &'a str,
    pub sources: &'a [MessageSource],
    pub suggestions: &'a [TaskSuggestion],
    pub file_writes: &'a [FileWrite],
    pub media: &'a [MediaAsset],
    pub steps: &'a [MessageStep],
    pub elapsed_ms: Option<i64>,
    pub usage: Option<TokenUsage>,
    pub notice: Option<String>,
}

/// 完成事件同样走 SSE，但客户端可据此判定"消息已落库"。
///
/// 来源、建议、产物与用量随事件一起带出：客户端拿到完成事件即可渲染卡片，
/// 不必再拉一次历史；它们都与落库值同源，避免"实时看到一个样、刷新又变一个样"。
///
/// `steps` 是权威的执行过程：流式期间客户端靠自己累积的那份是"进行中"的
/// 近似值（耗时可能还没有），收尾时以这里为准。
pub fn completed(payload: CompletedPayload<'_>) -> StreamEvent {
    StreamEvent::MessageCompleted {
        message_id: payload.message_id.to_string(),
        finish_reason: payload.finish_reason.to_string(),
        sources: payload.sources.to_vec(),
        task_suggestions: payload.suggestions.to_vec(),
        file_writes: payload.file_writes.to_vec(),
        media: payload.media.to_vec(),
        steps: payload.steps.to_vec(),
        elapsed_ms: payload.elapsed_ms,
        usage: payload.usage,
        notice: payload.notice,
    }
}

/// 工具执行进度事件。
///
/// 工具执行期间没有正文分片，界面只能干转圈；这条事件让客户端能显示
/// "正在读取 calculator2.html"。文案由服务端拼好，客户端不必认识工具名。
pub fn activity(activity: &crate::chat::Activity) -> StreamEvent {
    StreamEvent::ToolActivity {
        id: activity.call_id.clone(),
        tool: activity.tool.clone(),
        label: activity.label.clone(),
        phase: activity.phase.as_str().to_string(),
        elapsed_ms: activity.elapsed_ms,
    }
}

/// 覆盖确认卡事件。
///
/// 没有 `expires_at` 的请求（理论上不会出现）退化成"立即过期"，
/// 客户端会把按钮置灰——宁可点不动，也不要让人点完才发现已经作废。
pub fn file_write_request(write: &FileWrite) -> StreamEvent {
    StreamEvent::FileWriteRequest {
        id: write.request_id.clone(),
        path: write.path.clone(),
        scope: write.scope.clone(),
        existing_bytes: write.existing_bytes,
        new_bytes: write.bytes,
        expires_at: write.expires_at.unwrap_or(0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completion_event_has_stable_finish_reason() {
        let event = completed(CompletedPayload {
            message_id: "msg_1",
            finish_reason: "stop",
            sources: &[MessageSource {
                url: "https://example.com".to_string(),
                fetched_at: 1_700_000_000_000,
                kind: protocol::SourceKind::Web,
                memory_id: None,
            }],
            suggestions: &[TaskSuggestion {
                skill: "trip-plan".to_string(),
                reason: "你提到下周三去上海".to_string(),
                input: serde_json::json!({ "city": "上海" }),
            }],
            file_writes: &[],
            media: &[],
            steps: &[MessageStep {
                tool: "read_file".to_string(),
                label: "已读取 a.html".to_string(),
                target: "file:a.html:1-20".to_string(),
                ok: true,
                elapsed_ms: 3,
                error: None,
            }],
            elapsed_ms: Some(118_000),
            usage: Some(TokenUsage {
                prompt_tokens: 1200,
                completion_tokens: 320,
                tokens_estimated: false,
                context_tokens: 980,
            }),
            notice: None,
        });
        match event {
            StreamEvent::MessageCompleted {
                message_id,
                finish_reason,
                sources,
                task_suggestions,
                file_writes,
                media,
                steps,
                elapsed_ms,
                usage,
                notice,
            } => {
                assert_eq!(message_id, "msg_1");
                assert_eq!(finish_reason, "stop");
                assert_eq!(sources.len(), 1);
                assert_eq!(sources[0].url, "https://example.com");
                assert_eq!(task_suggestions.len(), 1);
                assert_eq!(task_suggestions[0].skill, "trip-plan");
                assert!(file_writes.is_empty());
                assert!(media.is_empty());
                assert_eq!(steps.len(), 1);
                assert_eq!(steps[0].label, "已读取 a.html");
                assert_eq!(elapsed_ms, Some(118_000));
                assert_eq!(usage.map(|usage| usage.total()), Some(1520));
                assert!(notice.is_none());
            }
            other => panic!("期望完成事件，得到 {other:?}"),
        }
    }

    #[test]
    fn empty_sources_are_omitted_from_json() {
        let event = completed(CompletedPayload {
            message_id: "msg_1",
            finish_reason: "stop",
            ..CompletedPayload::default()
        });
        let json = event.to_json();
        assert!(!json.contains("sources"), "空来源不应出现在事件里：{json}");
        assert!(
            !json.contains("task_suggestions"),
            "空建议不应出现在事件里：{json}"
        );
        assert!(
            !json.contains("file_writes"),
            "空写入不应出现在事件里：{json}"
        );
        assert!(!json.contains("usage"), "没有用量时不该出现该键：{json}");
        assert!(!json.contains("notice"), "没有提示时不该出现该键：{json}");
    }
}
