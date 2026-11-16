//! 流式事件模型。
//!
//! SSE（v1）与 DataChannel（v1.1）共用同一份事件定义：传输不同，语义相同。
//! 判别字段固定为 `type`，取值 snake_case。

use serde::{Deserialize, Serialize};

use crate::conversation::{
    FileWrite, MediaAsset, MessageSource, MessageStep, TaskSuggestion, TokenUsage,
};
use crate::task::TaskState;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StreamEvent {
    /// 回答的一个分片。
    MessageDelta { message_id: String, text: String },
    /// 回答完成。收到它时消息已经落库，可立即查询。
    ///
    /// `sources` 随事件一起给，客户端不必再拉一次消息就能渲染来源卡片；
    /// 空列表时该字段整个省略，旧客户端解析不受影响。
    MessageCompleted {
        message_id: String,
        finish_reason: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        sources: Vec<MessageSource>,
        /// 与 `Message.task_suggestions` 同源：实时渲染与历史回看共用一份数据。
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        task_suggestions: Vec<TaskSuggestion>,
        /// 与 `Message.file_writes` 同源：本轮生成 / 待确认的文件。
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        file_writes: Vec<FileWrite>,
        /// 与 `Message.steps` 同源：本轮的执行过程，按发生顺序。
        ///
        /// 流式期间客户端已经靠 `tool_activity` 累积了一份临时列表；
        /// 这里给的是权威版本（含失败原因与最终耗时），收尾时以它为准。
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        steps: Vec<MessageStep>,
        /// 与 `Message.media` 同源：本轮生成的图片 / 视频元信息。
        ///
        /// 只给元信息，正文由客户端按 `id` 另取，避免把几 MB 的产物塞进事件流。
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        media: Vec<MediaAsset>,
        /// 本轮耗时（毫秒）：实时消息与历史消息要显示同一个数，
        /// 所以这里给的就是落库的那一份。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        elapsed_ms: Option<i64>,
        /// 本轮 token 用量；没开模型时为 `None`。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        usage: Option<TokenUsage>,
        /// 与回答同轮的会话提示（目前用于显式「记住」的结果）。
        ///
        /// 它已经作为一条 `system` 消息落库，这里只是让本次会话立刻显示，
        /// 不必等用户重进会话拉历史。缺省时旧客户端行为不变。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        notice: Option<String>,
    },
    /// 任务状态变化（客户端订阅任务时使用）。
    TaskUpdated { task_id: String, state: TaskState },
    /// 请客户端打开一个页面（`preview_url` 工具产生）。
    ///
    /// 只在**对话流**里出现：服务端不打开浏览器，它只是替模型把"想看这一页"
    /// 转成 UI 动作。客户端据此决定开右栏标签还是交给系统浏览器。
    ///
    /// `title` 只是标签标题的候选值，缺省时客户端按 URL 推导；空串不序列化，
    /// 旧客户端读到未知 `type` 会忽略，行为与没有这个事件一致。
    OpenUrl {
        url: String,
        /// 地址栏要显示的**逻辑地址**（项目名 + 相对路径、运行目标名等）。
        ///
        /// 预览站给的 `url` 里有随机端口与访问令牌，只用于加载；
        /// 缺省时客户端按 `url` 自己推导显示值，旧客户端忽略该字段行为不变。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        display: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    /// 覆盖已有文件前的确认卡。
    ///
    /// 只在**对话流**里出现：待写内容已经在服务端落库，客户端点"覆盖"由独立端点
    /// 完成写入，不需要模型再参与一轮。`expires_at` 到了之后请求自动作废，
    /// 客户端据此把卡片置灰而不是让用户点一个已经没有意义的按钮。
    FileWriteRequest {
        id: String,
        path: String,
        scope: String,
        existing_bytes: i64,
        new_bytes: i64,
        expires_at: i64,
    },
    /// 一次工具执行的进度。
    ///
    /// 模型调工具时服务端在做实事（读文件、查网页、写文件），而这段时间**没有任何
    /// 正文分片**——界面只能干转圈，用户看到的是一个省略号。这个事件让界面能说
    /// "正在读取 calculator2.html"。
    ///
    /// 同一个 `id` 会出现两次（开始与结束），客户端按 id 覆盖同一条状态，
    /// 不要追加多行——否则一次读四段文件就会刷出四行流水。
    ToolActivity {
        id: String,
        tool: String,
        /// 面向用户的动作描述，服务端已经拼好（`正在读取 calculator2.html`）。
        /// 客户端不需要认识工具名，也就不必跟着服务端加新工具而改文案。
        label: String,
        /// `running` / `ok` / `failed`。
        phase: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        elapsed_ms: Option<i64>,
    },
    /// 生成过程中出错。流会随后结束，不保证有 completed。
    Error { code: String, hint: String },
}

impl StreamEvent {
    /// 序列化为 SSE 的 data 行内容。
    pub fn to_json(&self) -> String {
        // 事件模型是自有的、字段固定的枚举，序列化不会失败。
        serde_json::to_string(self).unwrap_or_else(|_| {
            r#"{"type":"error","code":"internal_error","hint":"事件序列化失败"}"#.to_string()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discriminator_is_type() {
        let event = StreamEvent::MessageDelta {
            message_id: "msg_1".to_string(),
            text: "你好".to_string(),
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");

        assert_eq!(value["type"], "message_delta");
        assert_eq!(value["text"], "你好");
    }

    #[test]
    fn completed_omits_empty_suggestions() {
        let event = StreamEvent::MessageCompleted {
            message_id: "msg_1".to_string(),
            finish_reason: "stop".to_string(),
            sources: Vec::new(),
            task_suggestions: Vec::new(),
            file_writes: Vec::new(),
            steps: Vec::new(),
            media: Vec::new(),
            elapsed_ms: None,
            usage: None,
            notice: None,
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");
        assert!(value.get("task_suggestions").is_none());
        assert!(value.get("elapsed_ms").is_none());
        assert!(value.get("usage").is_none());
    }

    #[test]
    fn completed_carries_suggestions() {
        let event = StreamEvent::MessageCompleted {
            message_id: "msg_1".to_string(),
            finish_reason: "stop".to_string(),
            sources: Vec::new(),
            task_suggestions: vec![TaskSuggestion {
                skill: "trip-plan".to_string(),
                reason: "你说下周三去上海".to_string(),
                input: serde_json::json!({ "city": "上海" }),
            }],
            file_writes: Vec::new(),
            steps: Vec::new(),
            media: Vec::new(),
            elapsed_ms: None,
            usage: None,
            notice: None,
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");
        assert_eq!(value["task_suggestions"][0]["skill"], "trip-plan");
        assert_eq!(value["task_suggestions"][0]["input"]["city"], "上海");
    }

    #[test]
    fn completed_carries_metrics() {
        // 实时事件与历史消息共用同一份耗时与用量，客户端不必二次拉取。
        let event = StreamEvent::MessageCompleted {
            message_id: "msg_1".to_string(),
            finish_reason: "stop".to_string(),
            sources: Vec::new(),
            task_suggestions: Vec::new(),
            file_writes: Vec::new(),
            steps: Vec::new(),
            media: Vec::new(),
            elapsed_ms: Some(118_000),
            usage: Some(TokenUsage {
                prompt_tokens: 1200,
                completion_tokens: 320,
                tokens_estimated: false,
                context_tokens: 980,
            }),
            notice: Some("已记住：我儿子叫小姚".to_string()),
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");

        assert_eq!(value["notice"], "已记住：我儿子叫小姚");
        assert_eq!(value["elapsed_ms"], 118_000);
        assert_eq!(value["usage"]["prompt_tokens"], 1200);
        assert_eq!(value["usage"]["completion_tokens"], 320);
        assert_eq!(value["usage"]["tokens_estimated"], false);
        assert_eq!(value["usage"]["context_tokens"], 980);
    }

    #[test]
    fn file_write_request_round_trips() {
        let event = StreamEvent::FileWriteRequest {
            id: "fw_1".to_string(),
            path: "index.html".to_string(),
            scope: "draft".to_string(),
            existing_bytes: 100,
            new_bytes: 200,
            expires_at: 1_700_000_600_000,
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");
        assert_eq!(value["type"], "file_write_request");
        assert_eq!(value["path"], "index.html");
        assert_eq!(value["new_bytes"], 200);
    }

    #[test]
    fn task_updated_carries_state() {
        let event = StreamEvent::TaskUpdated {
            task_id: "task_1".to_string(),
            state: TaskState::NeedsApproval,
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");

        assert_eq!(value["type"], "task_updated");
        assert_eq!(value["state"], "needs_approval");
    }

    #[test]
    fn open_url_omits_empty_title() {
        let event = StreamEvent::OpenUrl {
            url: "https://example.com".to_string(),
            display: None,
            title: None,
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");

        assert_eq!(value["type"], "open_url");
        assert_eq!(value["url"], "https://example.com");
        assert!(value.get("title").is_none(), "空标题不应上线缆: {value}");
        assert!(
            value.get("display").is_none(),
            "空展示地址不应上线缆: {value}"
        );
    }

    #[test]
    fn open_url_carries_title_and_display() {
        let event = StreamEvent::OpenUrl {
            url: "http://127.0.0.1:9999/f/token/p1/report.html".to_string(),
            display: Some("hello-demo/report.html".to_string()),
            title: Some("本地预览".to_string()),
        };
        let value: serde_json::Value =
            serde_json::from_str(&event.to_json()).expect("反序列化失败");

        assert_eq!(value["type"], "open_url");
        assert_eq!(value["title"], "本地预览");
        assert_eq!(
            value["display"], "hello-demo/report.html",
            "地址栏显示的是逻辑地址，不是带令牌的真实地址"
        );
    }
}
