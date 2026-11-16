//! 会话与消息载荷。字段与 `api-spec/openapi.yaml` 一致。
//!
//! 时间统一 Unix 毫秒；分页一律 cursor（`updated_at` + `id`）。

use serde::{Deserialize, Serialize};

use crate::cursor::Cursor;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationMode {
    /// 纯文本。
    Text,
    /// 分段语音（v1.1）。
    Staged,
    /// 全双工（v1.1）。
    Realtime,
}

impl ConversationMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Staged => "staged",
            Self::Realtime => "realtime",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "text" => Some(Self::Text),
            "staged" => Some(Self::Staged),
            "realtime" => Some(Self::Realtime),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Conversation {
    pub id: String,
    /// 所属项目。**空串表示无归属直聊**：这类会话不挂项目，
    /// 走基础系统提示与全局记忆，也不提供编码技能与任务落点。
    pub project_id: String,
    pub title: String,
    pub mode: ConversationMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    pub archived: bool,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationCreate {
    /// 归属项目。省略或空串 = 无归属直聊（不挂项目）；给出时必须命中活动项目，
    /// 因为项目决定模式边界（例如能不能派编码任务）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<ConversationMode>,
}

/// 重命名会话。本期只允许改标题：归属项目与模式一经创建不可变。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationUpdate {
    pub title: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    User,
    Assistant,
    Tool,
    System,
}

impl MessageRole {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::Tool => "tool",
            Self::System => "system",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "user" => Some(Self::User),
            "assistant" => Some(Self::Assistant),
            "tool" => Some(Self::Tool),
            "system" => Some(Self::System),
            _ => None,
        }
    }
}

/// 来源类型。
///
/// **发版硬约束**：老数据里没有这个键，因此 `MessageSource.kind` 必须带
/// `#[serde(default)]` 且默认 `Web`。漏了它，升级后库里所有历史来源卡片会
/// 因为整批解析失败而一起消失（读取路径解析失败时 `unwrap_or_default()`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    /// 网页查证。历史来源全部属于这一类。
    #[default]
    Web,
    /// 记忆注入或召回命中。
    Memory,
    /// 本地文档：`read_file` / `search_content` 读到的文件。
    ///
    /// `url` 用稳定标识 `file://{绝对路径}`，与记忆来源的 `memory://` 同一套思路：
    /// 它不是可点击的公网地址，客户端据此画"本地文件"卡片而不是外链。
    Doc,
}

/// 回答里引用的一条来源。
///
/// 与 `content_json` 里存的形状一致；服务端从库里解析后原样下发，
/// 客户端据此渲染来源卡片，不再从正文里猜 URL。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageSource {
    /// 网页来源是 URL；记忆来源用稳定标识 `memory://{id}`。
    pub url: String,
    /// 采集时间（Unix 毫秒）。
    pub fetched_at: i64,
    /// 来源类型。缺省是网页——老数据没有这个键。
    #[serde(default)]
    pub kind: SourceKind,
    /// 记忆来源才有：客户端据此跳记忆详情。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_id: Option<String>,
}

/// 回答附带的"要不要我办"建议。
///
/// 只是**提议**，不代表任何动作已发生：客户端点一下才调用 `POST /api/tasks`，
/// 服务端不会因为模型提了建议就自动建任务。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskSuggestion {
    pub skill: String,
    /// 面向用户的一句话理由，服务端截断到 80 字。
    pub reason: String,
    /// 预填的任务参数，用户点击后原样作为 `TaskCreateRequest.input`。
    #[serde(default, skip_serializing_if = "serde_json::Value::is_null")]
    pub input: serde_json::Value,
}

/// 一次回答的 token 用量。
///
/// `tokens_estimated` 区分真实值与估算值：网关没回 `usage` 时服务端按字符估算，
/// 客户端据此决定数字前面要不要加"约"，而不是把估算值当账单展示。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenUsage {
    #[serde(default)]
    pub prompt_tokens: u32,
    #[serde(default)]
    pub completion_tokens: u32,
    #[serde(default)]
    pub tokens_estimated: bool,
    /// 本轮**最后一次**模型调用的输入 token 数，即"当前上下文长度"。
    ///
    /// 与 [`Self::prompt_tokens`] 口径不同：后者是整轮（含工具调用后的续轮）
    /// 的累加值，多步时会把前几次的输入重复算进去；这里只留最后一次，
    /// 客户端拿它除以模型上下文窗口才是"现在占了多少"。
    #[serde(default)]
    pub context_tokens: u32,
}

impl TokenUsage {
    pub fn total(&self) -> u32 {
        self.prompt_tokens.saturating_add(self.completion_tokens)
    }

    /// 两项都为 0 等于"没统计到"：不必下发，也不该在界面上占一行。
    ///
    /// 只看 prompt / completion：`context_tokens` 是它们的派生值，
    /// 单独有值而总量为 0 只可能是构造错了，不该因此造出一条假用量。
    pub fn is_empty(&self) -> bool {
        self.prompt_tokens == 0 && self.completion_tokens == 0
    }
}

/// 回答正常写完。
pub const FINISH_STOP: &str = "stop";

/// 生成中途出错（模型失败、保存失败）。
pub const FINISH_ERROR: &str = "error";

/// 用户点了停止：半截回答照样落库，但界面不能显示"已完成"。
///
/// 与"客户端断开连接"不是一回事——那种情况服务端丢弃半截回答、什么都不写，
/// 所以这里不会出现对应取值。
pub const FINISH_STOPPED: &str = "stopped";

/// 会话里生成的一个文件。
///
/// 新建成功时直接是 `written`；要覆盖已有文件时先落一条 `pending`，
/// 用户决策后变成 `written` / `rejected` / `expired`。
///
/// 实时事件（`StreamEvent::MessageCompleted`）与历史回看共用这一份结构：
/// 两张卡片如果各定义一遍字段，状态文案迟早会不一致。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileWrite {
    /// 待确认请求 id。新建直写时也有一条记录，方便客户端统一按 id 去重。
    pub request_id: String,
    /// 根内相对路径（项目相对或草稿相对），绝不带绝对路径。
    pub path: String,
    /// `project`（会话绑定项目）或 `draft`（无项目会话的草稿目录）。
    pub scope: String,
    /// `written` / `pending` / `rejected` / `expired` / `failed` / `superseded`。
    pub status: String,
    /// 本次要写入的字节数。
    pub bytes: i64,
    /// 被覆盖文件的字节数；新建时为 0。
    #[serde(default)]
    pub existing_bytes: i64,
    /// 覆盖前备份的绝对路径。用户要还原时直接拿它。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup_path: Option<String>,
    /// 待确认请求的过期时刻（Unix 毫秒）。已决策时为 `None`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    pub created_at: i64,
}

/// 覆盖决策请求体。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileWriteDecision {
    pub approve: bool,
}

/// 会话里生成的一张图片或一段视频。
///
/// 只放元信息：正文按 `id` 走 `/api/media/{id}/content` 取。
/// 一张图 2–3MB、一段视频 5–10MB，塞进消息正文会让每次拉历史都把整个产物读一遍。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaAsset {
    /// 产物 id。客户端按它下载正文，也按它去重。
    pub id: String,
    /// `image` / `video`。
    pub kind: String,
    pub mime: String,
    pub bytes: i64,
    /// 生成模型，例如 `qwen-image-3.0` / `wan3.0-video-prime`。
    pub model: String,
    /// 用户原始的提示词，卡片上作为说明展示。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub prompt: String,
    /// 图片像素宽高；视频不解析 mp4，保持为空。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    /// 视频时长（毫秒）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u32>,
    /// 视频分辨率档位，例如 `480P`；图片为空。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    pub created_at: i64,
}

/// 把一枚会话产物另存进项目目录的结果。
///
/// 只回项目内相对路径（`artifacts/xxx.png`）与字节数：客户端要提示"存到哪儿了"，
/// 但不需要、也不该知道服务端的绝对路径。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaSaveResult {
    /// 项目内相对路径，`/` 分隔。
    pub path: String,
    /// 落盘字节数。
    pub bytes: i64,
}

/// 用户随消息上传的一枚附件（输入框里的那枚 chip）。
///
/// 与 [`MediaAsset`] 方向相反：那个是模型生成给用户看的，这个是用户交给模型的。
/// 同样只放元信息：正文按 `id` 走 `/api/attachments/{id}/content` 取，
/// 一张 2MB 的截图塞进消息行会让每次拉历史都把整份字节读一遍。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    /// 服务端生成的附件 id。客户端上传后拿到它，发送时按 id 引用。
    pub id: String,
    /// 原始文件名，只用于展示；服务端不落绝对路径。
    pub name: String,
    /// `image` / `file`。客户端据此决定画缩略图还是文档图标。
    pub kind: String,
    pub mime: String,
    pub bytes: i64,
    /// 图片像素宽高；非图片或客户端没给时为空。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}

impl Attachment {
    /// 是不是图片。`kind` 是唯一判据，客户端与服务端都只看它。
    pub fn is_image(&self) -> bool {
        self.kind == "image"
    }
}

/// 一次工具执行，给界面的"执行过程"列表用。
///
/// `label` 由服务端拼好（复用 `activity_label`），客户端不认识工具名——
/// 否则每加一个工具都要同步改前端文案。
///
/// 没有 `kind` 字段：当前只记录工具调用，思考过程（`reasoning_content`）
/// 在 `llm.rs` 里就被丢弃了，没有数据源。将来真要展示思考，加一个带默认值的
/// `kind` 即可，旧数据缺省为工具。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageStep {
    pub tool: String,
    /// 面向用户的一句话，例如 `已写入 calculator2.html`。
    pub label: String,
    /// 审计用的对象标识（`file:a.html:1-20`、URL）。客户端只用于 tooltip。
    #[serde(default)]
    pub target: String,
    pub ok: bool,
    #[serde(default)]
    pub elapsed_ms: i64,
    /// 失败原因（服务端已截断）。成功时省略。
    ///
    /// 放在这里而不是只回填给模型：用户看到的"这次没做成"必须能点开看到为什么，
    /// 否则额度用尽与上游报错在界面上长得一模一样。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub conversation_id: String,
    pub role: MessageRole,
    pub content: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sources: Vec<MessageSource>,
    /// 建议用户派发的任务；为空时整个字段省略（旧数据解析为空列表）。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub task_suggestions: Vec<TaskSuggestion>,
    /// 本轮生成的文件（含待确认状态）；为空时整个字段省略。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub file_writes: Vec<FileWrite>,
    /// 本轮的执行过程（按发生顺序）；没有调用工具时整个字段省略。
    ///
    /// 落库的意义是"回看"：只在流里推一次的话，刷新之后这段过程就没了。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<MessageStep>,
    /// 本轮生成的图片 / 视频；为空时整个字段省略。
    ///
    /// 与 `file_writes` 同一套语义：实时事件与历史回看共用一份结构。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub media: Vec<MediaAsset>,
    /// 用户在输入框里附上的文件 / 图片；为空时整个字段省略。
    ///
    /// 与 `media` 同一套做法：元信息随消息落库，正文另走附件端点。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<Attachment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_id: Option<String>,
    pub created_at: i64,
    /// 从收到提问到答案落库的耗时（毫秒）。历史旧行没有这一项，为 `None`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elapsed_ms: Option<i64>,
    /// 这一轮回答的 token 用量；没开模型或网关没给时为 `None`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<TokenUsage>,
    /// 回答的终态：`stop` / `error` / `stopped`。
    ///
    /// 历史行与被中断前的旧数据都没有这一列，`None` 按"已完成"处理，
    /// 所以字段可以整段省略，旧客户端解析不受影响。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finish_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationDetail {
    #[serde(flatten)]
    pub conversation: Conversation,
    pub recent_messages: Vec<Message>,
    /// 这个会话的上下文压缩状态；从未压缩过时整段省略，旧客户端解析不受影响。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compaction: Option<Compaction>,
}

/// 一次成功压缩在客户端眼里的样子。
///
/// 它**只描述模型看到的那份上下文**，不改变消息流：原文一条不删，
/// 客户端只是据此在 `anchor_message_id` 处插一条"更早 N 条已整理"的横条。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Compaction {
    /// `ready`：摘要可用；`pending`：正在跑，界面上显示进行中。
    ///
    /// 用字符串而不是枚举，是为了让将来的状态不必升级契约；
    /// 客户端只认这两个值，其余按"未知"渲染。
    pub status: String,
    /// 摘要正文。`pending` 或旧记录没有正文时省略。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// 压缩边界：第一条**没被折叠**的消息 id。
    ///
    /// 这是**位置锚点**，不是区间端点：客户端插横条全靠它，
    /// 不要把它当某个消息区间的开始去算长度。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor_message_id: Option<String>,
    /// 被折叠的消息条数。
    #[serde(default)]
    pub source_messages: u32,
    /// 生成摘要用的模型。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// 摘要生成时间（毫秒时间戳）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<i64>,
    /// 这次整理调用花掉的 token；网关没给时为估算值，看 `tokens_estimated`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<CompactionTokens>,
    /// 这次整理调用的耗时（毫秒）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elapsed_ms: Option<i64>,
    /// 最近一次失败，可能发生在这条成功记录之前。
    ///
    /// 与 `summary` 相互独立：上一次失败、这一次成功时两者同时存在，
    /// 客户端在抽屉里多显示一行小字，而不是把成功摘要画成错误态。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_failure: Option<CompactionFailure>,
}

/// 一次整理调用的用量。
///
/// 与 [`TokenUsage`] 分开：那个是"一轮回答"的口径（`prompt_tokens` 含工具续轮累加），
/// 而这个只是一次非流式补全，输入就是提示本身，两者混用会让数字对不上。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompactionTokens {
    #[serde(default)]
    pub prompt_tokens: u32,
    #[serde(default)]
    pub completion_tokens: u32,
    /// 网关没回 `usage`、按字符估算时为 `true`，界面用"约"表述。
    #[serde(default)]
    pub tokens_estimated: bool,
}

impl CompactionTokens {
    pub fn total(&self) -> u32 {
        self.prompt_tokens.saturating_add(self.completion_tokens)
    }

    /// 两项都为 0 等于"没统计到"：不下发，也不在界面上占一行。
    pub fn is_empty(&self) -> bool {
        self.prompt_tokens == 0 && self.completion_tokens == 0
    }
}

/// 一次失败的整理尝试。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompactionFailure {
    /// 面向用户的一句话原因（上游报错 / 摘要为空 / 超时 / 达到输出上限）。
    pub error: String,
    /// 失败时间（毫秒时间戳）。
    pub at: i64,
    /// 当时用的模型；可能是空（模型没配起来就失败了）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SendMessageRequest {
    pub content: String,
    /// 客户端生成的幂等键。重复提交同一条消息时带上同一个值。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_msg_id: Option<String>,
    /// 已上传附件的 id 列表，按用户在输入框里的顺序。
    ///
    /// 只传 id，不传元信息：文件名、类型、字节数都以服务端登记的那份为准，
    /// 客户端也伪造不出"我这有个 2GB 的图片"。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<String>,
    /// 本轮期望的推理等级：`none` / `low` / `high` / `max`。
    ///
    /// 只作用于这一轮对话，不落库——重开会话由客户端回默认档。`None` 表示
    /// "不指定"，行为与加这个字段之前完全一致；服务端还会再做一次白名单收敛，
    /// 因为上游对非法值是直接 400。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationPage {
    pub items: Vec<Conversation>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessagePage {
    pub items: Vec<Message>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

impl ConversationPage {
    pub fn from_items(items: Vec<Conversation>, cursor: Option<Cursor>) -> Self {
        Self {
            items,
            next_cursor: cursor.map(|cursor| cursor.encode()),
        }
    }
}

impl MessagePage {
    pub fn from_items(items: Vec<Message>, cursor: Option<Cursor>) -> Self {
        Self {
            items,
            next_cursor: cursor.map(|cursor| cursor.encode()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_detail_flattens_conversation() {
        let detail = ConversationDetail {
            conversation: Conversation {
                id: "conv_1".to_string(),
                project_id: "ws_1".to_string(),
                title: "测试".to_string(),
                mode: ConversationMode::Text,
                device_id: None,
                archived: false,
                created_at: 1,
                updated_at: 2,
            },
            recent_messages: Vec::new(),
            compaction: None,
        };
        let value = serde_json::to_value(&detail).expect("序列化失败");
        assert_eq!(value["id"], "conv_1");
        assert_eq!(value["project_id"], "ws_1");
        assert_eq!(value["mode"], "text");
        // 没有压缩时整段省略：旧客户端解析不受影响。
        assert!(value.get("compaction").is_none());
        assert!(value["recent_messages"].is_array());
    }

    #[test]
    fn page_omits_cursor_when_last_page() {
        let page = MessagePage::from_items(Vec::new(), None);
        let value = serde_json::to_value(&page).expect("序列化失败");
        assert!(value.get("next_cursor").is_none());
    }

    #[test]
    fn message_without_suggestions_still_parses() {
        // 旧数据没有 task_suggestions，解析必须给空列表而不是报错。
        let raw = r#"{
            "id": "msg_1",
            "conversation_id": "conv_1",
            "role": "assistant",
            "content": "你好",
            "created_at": 1
        }"#;
        let message: Message = serde_json::from_str(raw).expect("解析失败");
        assert!(message.task_suggestions.is_empty());
        assert!(message.sources.is_empty());

        let value = serde_json::to_value(&message).expect("序列化失败");
        assert!(value.get("task_suggestions").is_none(), "空列表应整个省略");
    }

    #[test]
    fn legacy_sources_still_parse() {
        // 升级前的库里只有 url + fetched_at。缺 kind 必须默认成 web，
        // 否则整批解析失败会让历史来源卡片一起消失。
        let raw = r#"{"url":"https://example.com","fetched_at":1700000000000}"#;
        let source: MessageSource = serde_json::from_str(raw).expect("旧来源必须能解析");
        assert_eq!(source.url, "https://example.com");
        assert_eq!(source.kind, SourceKind::Web);
        assert_eq!(source.memory_id, None);
    }

    #[test]
    fn memory_source_round_trips() {
        let source = MessageSource {
            url: "memory://mem_1".to_string(),
            fetched_at: 1_700_000_000_000,
            kind: SourceKind::Memory,
            memory_id: Some("mem_1".to_string()),
        };
        let raw = serde_json::to_string(&source).expect("序列化失败");
        let parsed: MessageSource = serde_json::from_str(&raw).expect("解析失败");

        assert_eq!(parsed, source);
        assert!(raw.contains("\"kind\":\"memory\""));
        assert!(raw.contains("\"memory_id\":\"mem_1\""));
    }

    #[test]
    fn unknown_source_kind_is_rejected_not_silently_wrong() {
        // 未知 kind 解析失败由上层兜底；这里锁定"不会静默变成 web 之外的东西"。
        let raw = r#"{"url":"x","fetched_at":1,"kind":"hologram"}"#;
        assert!(serde_json::from_str::<MessageSource>(raw).is_err());
    }

    #[test]
    fn web_source_omits_memory_id() {
        let source = MessageSource {
            url: "https://example.com".to_string(),
            fetched_at: 1,
            kind: SourceKind::Web,
            memory_id: None,
        };
        let value = serde_json::to_value(&source).expect("序列化失败");
        assert!(
            value.get("memory_id").is_none(),
            "网页来源不应带 memory_id 键"
        );
        assert_eq!(value["kind"], "web");
    }

    #[test]
    fn message_carries_task_suggestions() {
        let message = Message {
            id: "msg_1".to_string(),
            conversation_id: "conv_1".to_string(),
            role: MessageRole::Assistant,
            content: "要不要我直接排一下？".to_string(),
            sources: Vec::new(),
            task_suggestions: vec![TaskSuggestion {
                skill: "trip-plan".to_string(),
                reason: "你提到下周三去上海".to_string(),
                input: serde_json::json!({ "city": "上海" }),
            }],
            file_writes: Vec::new(),
            steps: Vec::new(),
            media: Vec::new(),
            attachments: Vec::new(),
            task_id: None,
            created_at: 1,
            elapsed_ms: None,
            usage: None,
            finish_reason: None,
        };
        let value = serde_json::to_value(&message).expect("序列化失败");
        assert_eq!(value["task_suggestions"][0]["skill"], "trip-plan");
        assert_eq!(value["task_suggestions"][0]["input"]["city"], "上海");
    }

    #[test]
    fn message_metrics_are_optional() {
        // 旧行没有耗时与用量：序列化不出现这两个键，解析也不报错。
        let raw = r#"{
            "id": "msg_1",
            "conversation_id": "conv_1",
            "role": "assistant",
            "content": "你好",
            "created_at": 1
        }"#;
        let message: Message = serde_json::from_str(raw).expect("解析失败");
        assert!(message.elapsed_ms.is_none());
        assert!(message.usage.is_none());

        let value = serde_json::to_value(&message).expect("序列化失败");
        assert!(value.get("elapsed_ms").is_none());
        assert!(value.get("usage").is_none());
    }

    #[test]
    fn token_usage_totals_both_directions() {
        let usage = TokenUsage {
            prompt_tokens: 900,
            completion_tokens: 120,
            tokens_estimated: false,
            context_tokens: 760,
        };
        assert_eq!(usage.total(), 1020);
        assert!(!usage.is_empty());
        // 上下文长度是独立口径，不参与"这条回答花了多少"的求和。
        assert_eq!(usage.context_tokens, 760);
        assert!(TokenUsage::default().is_empty());
    }

    #[test]
    fn send_message_without_reasoning_still_parses() {
        // 老客户端不会发这个字段：缺省即"不指定"，解析不能失败。
        let legacy: SendMessageRequest =
            serde_json::from_str(r#"{"content":"你好"}"#).expect("旧请求体应能解析");
        assert_eq!(legacy.content, "你好");
        assert_eq!(legacy.reasoning_effort, None);

        // 新字段为 None 时也不该出现在请求体里：抓包时要能一眼看出"这次没选档位"。
        let value = serde_json::to_value(&legacy).expect("序列化失败");
        assert!(value.get("reasoning_effort").is_none());
    }

    #[test]
    fn send_message_carries_reasoning_effort() {
        let request: SendMessageRequest =
            serde_json::from_str(r#"{"content":"你好","reasoning_effort":"max"}"#)
                .expect("应能解析档位");
        assert_eq!(request.reasoning_effort.as_deref(), Some("max"));
    }

    #[test]
    fn mode_roundtrip() {
        for mode in [
            ConversationMode::Text,
            ConversationMode::Staged,
            ConversationMode::Realtime,
        ] {
            assert_eq!(ConversationMode::parse(mode.as_str()), Some(mode));
        }
        assert_eq!(ConversationMode::parse("nope"), None);
    }
}
