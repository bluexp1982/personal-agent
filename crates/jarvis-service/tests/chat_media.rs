//! 对话内媒体生成的集成测试。
//!
//! 用假模型 + 假媒体后端打真实 Router，验证四件事：
//! 1. 未配置媒体时工具对模型不可见；
//! 2. 生成成功 → `message_completed.media` 与历史消息都带卡片，正文可下载；
//! 3. 上游失败 → 没有卡片、失败原因可读、对话继续；
//! 4. 单轮次数上限生效，第二次调用被拒而不是继续花钱。

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use futures_util::stream;
use jarvis_service::artifact_store::ArtifactStore;
use jarvis_service::chat::{ChatEvent, ChatMessage, ChatModel, ChatStream, ChatToolCall, ToolSpec};
use jarvis_service::media::{MediaArtifact, MediaBackend, MediaError, MediaRequest};

/// 一张足够"像图片"的最小字节：只用于验证落盘与下载，不参与解码。
const PNG_BYTES: [u8; 16] = [
    0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, b'I', b'H', b'D', b'R',
];

#[derive(Debug)]
struct ScriptedModel {
    rounds: Mutex<Vec<Vec<ChatEvent>>>,
    /// 最近一次被问到的工具名，用于断言"工具是否对模型可见"。
    seen_tools: Mutex<Vec<String>>,
}

impl ScriptedModel {
    fn new(rounds: Vec<Vec<ChatEvent>>) -> Self {
        Self {
            rounds: Mutex::new(rounds),
            seen_tools: Mutex::new(Vec::new()),
        }
    }

    fn seen_tools(&self) -> Vec<String> {
        self.seen_tools.lock().expect("锁中毒").clone()
    }
}

impl ChatModel for ScriptedModel {
    fn stream(&self, _messages: Vec<ChatMessage>, tools: Vec<ToolSpec>) -> ChatStream {
        *self.seen_tools.lock().expect("锁中毒") =
            tools.iter().map(|spec| spec.name.clone()).collect();
        let next = self
            .rounds
            .lock()
            .expect("锁中毒")
            .pop()
            .unwrap_or_else(|| vec![ChatEvent::Text("（无脚本）".to_string())]);
        Box::pin(stream::iter(next.into_iter().map(Ok)))
    }
}

/// 假的媒体后端：不联网、不花钱，只按脚本成功或失败。
#[derive(Debug)]
struct FakeMedia {
    image: bool,
    video: bool,
    /// `Some(原因)` 时模拟上游失败。
    fail: Option<String>,
    calls: AtomicUsize,
    /// 每次出图收到的 `size`：`None` 表示"走配置默认"。
    image_sizes: Mutex<Vec<Option<String>>>,
}

impl FakeMedia {
    fn ok() -> Self {
        Self {
            image: true,
            video: true,
            fail: None,
            calls: AtomicUsize::new(0),
            image_sizes: Mutex::new(Vec::new()),
        }
    }

    fn failing(reason: &str) -> Self {
        Self {
            image: true,
            video: true,
            fail: Some(reason.to_string()),
            calls: AtomicUsize::new(0),
            image_sizes: Mutex::new(Vec::new()),
        }
    }

    fn image_sizes(&self) -> Vec<Option<String>> {
        self.image_sizes.lock().expect("锁中毒").clone()
    }
}

impl FakeMedia {
    async fn build(
        &self,
        mime: &'static str,
        bytes: &[u8],
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(reason) = &self.fail {
            return Err(MediaError::Upstream(reason.clone()));
        }
        let id = jarvis_service::ids::new_id("img");
        let (relative, size) = store
            .save_bytes(task_id, &id, Some(mime), bytes)
            .await
            .map_err(|err| MediaError::Store(err.to_string()))?;
        Ok(MediaArtifact {
            absolute_path: store.root().join(&relative).to_string_lossy().to_string(),
            relative_path: relative,
            mime,
            bytes: size as u64,
            elapsed_ms: 5,
            width: Some(8),
            height: Some(8),
            duration_ms: None,
            upstream_task_id: None,
        })
    }
}

#[async_trait::async_trait]
impl MediaBackend for FakeMedia {
    fn image_enabled(&self) -> bool {
        self.image
    }

    fn video_enabled(&self) -> bool {
        self.video
    }

    async fn image(
        &self,
        request: MediaRequest<'_>,
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError> {
        self.image_sizes
            .lock()
            .expect("锁中毒")
            .push(request.size.map(str::to_string));
        self.build("image/png", &PNG_BYTES, store, task_id).await
    }

    async fn video(
        &self,
        _request: MediaRequest<'_>,
        store: &ArtifactStore,
        task_id: &str,
    ) -> Result<MediaArtifact, MediaError> {
        self.build("video/mp4", b"\x00\x00\x00\x18ftypisom", store, task_id)
            .await
    }
}

fn image_call(id: &str, prompt: &str) -> ChatToolCall {
    ChatToolCall {
        id: id.to_string(),
        name: "generate_image".to_string(),
        arguments: serde_json::json!({ "prompt": prompt }).to_string(),
    }
}

/// 模型"自作主张"带上尺寸的调用：用来验证配置不会被模型盖掉。
fn image_call_with_size(id: &str, prompt: &str, size: &str) -> ChatToolCall {
    ChatToolCall {
        id: id.to_string(),
        name: "generate_image".to_string(),
        arguments: serde_json::json!({ "prompt": prompt, "size": size }).to_string(),
    }
}

async fn create_conversation(ctx: &common::TestContext, token: &str, tag: &str) -> String {
    let project_id = ctx.work_project(tag).await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "媒体测试", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::CREATED);
    common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string()
}

/// 发一条消息，返回完整 SSE 正文。
async fn send_message(
    state: &jarvis_service::state::AppState,
    token: &str,
    conversation_id: &str,
    content: &str,
) -> String {
    let router = jarvis_service::api::router(state.clone());
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        token,
        &serde_json::json!({ "content": content, "client_msg_id": "m-media-1" }),
    );
    let response = tower::ServiceExt::oneshot(router, request)
        .await
        .expect("请求失败");
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 22)
        .await
        .expect("读取 SSE 失败");
    String::from_utf8(bytes.to_vec()).expect("SSE 不是 UTF-8")
}

fn completed_event(body: &str) -> serde_json::Value {
    body.lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter_map(|payload| serde_json::from_str::<serde_json::Value>(payload).ok())
        .find(|event| event["type"] == "message_completed")
        .expect("SSE 应包含完成事件")
}

#[tokio::test]
async fn media_tools_are_hidden_until_enabled() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-media-hidden").await;
    let conversation_id = create_conversation(&ctx, &token, "media-hidden").await;

    let model = Arc::new(ScriptedModel::new(vec![vec![ChatEvent::Text(
        "没有生成能力。".to_string(),
    )]]));
    let mut state = ctx.state.clone();
    state.media = None;
    state.chat_model = Some(model.clone());

    send_message(&state, &token, &conversation_id, "画一只猫").await;

    let seen = model.seen_tools();
    assert!(
        !seen.iter().any(|name| name == "generate_image"),
        "未启用时不该把生成工具给模型：{seen:?}"
    );
}

#[tokio::test]
async fn image_card_is_returned_and_downloadable() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-media-ok").await;
    let conversation_id = create_conversation(&ctx, &token, "media-ok").await;

    let backend = Arc::new(FakeMedia::ok());
    let model = Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("画好了，是一只橘猫。".to_string())],
        vec![ChatEvent::ToolCalls(vec![image_call(
            "call_img_1",
            "一只橘猫坐在窗台上",
        )])],
    ]));
    let mut state = ctx.state.clone();
    state.media = Some(backend.clone());
    state.chat_model = Some(model.clone());

    let body = send_message(&state, &token, &conversation_id, "画一只橘猫").await;

    assert!(
        model.seen_tools().iter().any(|name| name == "generate_image"),
        "启用后工具应对模型可见：{:?}",
        model.seen_tools()
    );
    assert!(body.contains("正在生成图片"), "应有生成中进度：{body}");
    assert_eq!(backend.calls.load(Ordering::SeqCst), 1);

    let completed = completed_event(&body);
    let media = completed["media"]
        .as_array()
        .unwrap_or_else(|| panic!("完成事件应带媒体：{completed}"));
    assert_eq!(media.len(), 1, "{completed}");
    assert_eq!(media[0]["kind"], "image");
    assert_eq!(media[0]["mime"], "image/png");
    let media_id = media[0]["id"].as_str().expect("缺少媒体 id").to_string();

    // 历史消息同样带卡片：刷新后不丢。
    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}/messages"),
            &token,
        ))
        .await;
    let page = common::body_json(response).await;
    let assistant = page["items"]
        .as_array()
        .expect("消息列表应为数组")
        .iter()
        .find(|item| item["role"] == "assistant")
        .expect("应有 assistant 消息")
        .clone();
    assert_eq!(assistant["media"][0]["id"], media_id.as_str());

    // 正文按 id 下载，内容与 mime 都来自记录。
    let response = ctx
        .call(common::authed_get(
            &format!("/api/media/{media_id}/content"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    assert_eq!(
        response.headers()["content-type"],
        "image/png",
        "Content-Type 应取自记录里的 mime"
    );
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("读取媒体失败");
    assert_eq!(bytes.to_vec(), PNG_BYTES);
}

#[tokio::test]
async fn model_supplied_size_is_ignored_when_user_did_not_ask_for_one() {
    let ctx = common::setup_with(|config| {
        config.media.image.size = "1024*1024".to_string();
    })
    .await;
    let (_, token) = ctx.pair_and_login("chat-media-size-model").await;
    let conversation_id = create_conversation(&ctx, &token, "media-size-model").await;

    let backend = Arc::new(FakeMedia::ok());
    let model = Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("画好了。".to_string())],
        // 模型按旧习惯自己填了 1328*1328——这正是配置被盖掉的原因。
        vec![ChatEvent::ToolCalls(vec![image_call_with_size(
            "call_img_size",
            "一只橘猫",
            "1328*1328",
        )])],
    ]));
    let mut state = ctx.state.clone();
    state.media = Some(backend.clone());
    state.chat_model = Some(model);

    let body = send_message(&state, &token, &conversation_id, "画一只橘猫").await;

    assert!(body.contains("正在生成图片"), "应有生成中进度：{body}");
    assert_eq!(
        backend.image_sizes(),
        vec![None],
        "用户没点名尺寸时必须走配置默认值，模型传的 size 不该生效"
    );
}

#[tokio::test]
async fn user_named_size_wins_over_config() {
    let ctx = common::setup_with(|config| {
        config.media.image.size = "1328*1328".to_string();
    })
    .await;
    let (_, token) = ctx.pair_and_login("chat-media-size-user").await;
    let conversation_id = create_conversation(&ctx, &token, "media-size-user").await;

    let backend = Arc::new(FakeMedia::ok());
    let model = Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("画好了。".to_string())],
        vec![ChatEvent::ToolCalls(vec![image_call(
            "call_img_user_size",
            "一只橘猫",
        )])],
    ]));
    let mut state = ctx.state.clone();
    state.media = Some(backend.clone());
    state.chat_model = Some(model);

    send_message(&state, &token, &conversation_id, "画一张 1024x1024 的橘猫").await;

    assert_eq!(
        backend.image_sizes(),
        vec![Some("1024*1024".to_string())],
        "用户原话里点名的尺寸应压过配置默认值"
    );
}

#[tokio::test]
async fn upstream_failure_is_readable_and_drops_the_card() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-media-fail").await;
    let conversation_id = create_conversation(&ctx, &token, "media-fail").await;

    let backend = Arc::new(FakeMedia::failing(
        "code=InvalidParameter；message=prompt too long；request_id=req-9",
    ));
    let model = Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("这次没生成出来。".to_string())],
        vec![ChatEvent::ToolCalls(vec![image_call(
            "call_img_fail",
            "一只橘猫",
        )])],
    ]));
    let mut state = ctx.state.clone();
    state.media = Some(backend);
    state.chat_model = Some(model);

    let body = send_message(&state, &token, &conversation_id, "画一只橘猫").await;

    assert!(body.contains("生成图片失败"), "失败原因要可读：{body}");
    assert!(body.contains("request_id=req-9"), "要带上游线索：{body}");
    let completed = completed_event(&body);
    assert!(
        completed.get("media").is_none(),
        "失败不应留下卡片：{completed}"
    );
}

#[tokio::test]
async fn second_generation_in_one_turn_is_refused() {
    let ctx = common::setup_with(|config| {
        config.tool.max_media_calls_per_turn = 1;
    })
    .await;
    let (_, token) = ctx.pair_and_login("chat-media-quota").await;
    let conversation_id = create_conversation(&ctx, &token, "media-quota").await;

    let backend = Arc::new(FakeMedia::ok());
    let model = Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("只画了一张。".to_string())],
        vec![ChatEvent::ToolCalls(vec![
            image_call("call_img_a", "第一张"),
            image_call("call_img_b", "第二张"),
        ])],
    ]));
    let mut state = ctx.state.clone();
    state.media = Some(backend.clone());
    state.chat_model = Some(model);

    let body = send_message(&state, &token, &conversation_id, "画两张猫").await;

    assert_eq!(
        backend.calls.load(Ordering::SeqCst),
        1,
        "额度只有一次，第二次不该真的调用后端"
    );
    assert!(
        body.contains("生成次数已经用完"),
        "第二次调用应得到可读拒绝：{body}"
    );
    let completed = completed_event(&body);
    assert_eq!(
        completed["media"].as_array().map(Vec::len),
        Some(1),
        "只应有一张卡片：{completed}"
    );
}

/// 真链路冒烟：假模型 + **真** `MediaGenerator`。
///
/// 验证的是"工具 → 百炼 → 落盘 → 记录 → 下载端点"这一整条，不花对话模型的钱，
/// 但会真出一次图。默认不跑：
///
/// ```bash
/// cargo test -p jarvis-service --test chat_media -- --ignored --nocapture real_image_tool
/// ```
#[tokio::test]
#[ignore = "联网冒烟，需 BAILIAN_API_KEY（会产生真实费用）"]
#[allow(clippy::print_stdout)] // 手动跑时要看到产物路径
async fn real_image_tool_smoke() {
    let ctx = common::setup_with(|config| {
        config.media.image.enabled = true;
    })
    .await;
    assert!(
        ctx.state.media.is_some(),
        "需要环境变量 BAILIAN_API_KEY（否则媒体后端不会被装配）"
    );

    let (_, token) = ctx.pair_and_login("chat-media-real").await;
    let conversation_id = create_conversation(&ctx, &token, "media-real").await;

    let model = Arc::new(ScriptedModel::new(vec![
        vec![ChatEvent::Text("画好了。".to_string())],
        vec![ChatEvent::ToolCalls(vec![image_call(
            "call_real_img",
            "一只坐在窗台上的橘猫，水彩风格，暖光",
        )])],
    ]));
    let mut state = ctx.state.clone();
    state.chat_model = Some(model);

    let body = send_message(&state, &token, &conversation_id, "画一只橘猫").await;
    let completed = completed_event(&body);
    let media = completed["media"]
        .as_array()
        .unwrap_or_else(|| panic!("完成事件应带媒体：{completed}"));
    assert_eq!(media.len(), 1, "{completed}");
    let media_id = media[0]["id"].as_str().expect("缺少媒体 id").to_string();
    println!("媒体 id：{media_id}，{} 字节", media[0]["bytes"]);

    let response = ctx
        .call(common::authed_get(
            &format!("/api/media/{media_id}/content"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 25)
        .await
        .expect("读取媒体失败");
    assert!(bytes.len() > 1024, "产物过小：{} 字节", bytes.len());
    assert_eq!(
        &bytes[..8],
        &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A],
        "下载到的不是 PNG"
    );
    println!("下载校验通过：{} 字节", bytes.len());
}

#[tokio::test]
async fn unknown_media_id_is_404() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("chat-media-404").await;

    let response = ctx
        .call(common::authed_get("/api/media/img_missing/content", &token))
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::NOT_FOUND);
}
