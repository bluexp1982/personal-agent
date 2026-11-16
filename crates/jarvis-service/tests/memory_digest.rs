//! digest 注入：位置、空摘要、私密排除、置顶溢出、CODE 白名单。
//!
//! 用"记录型假模型"捕获真实发给模型的 `messages`：digest 是第几条 system 消息
//! 只能从这条链路看出来，靠 Unit test 断言不了。

mod common;

use std::sync::{Arc, Mutex};

use axum::http::StatusCode;
use futures_util::stream;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use jarvis_service::chat::{ChatEvent, ChatMessage, ChatModel, ChatRole, ChatStream, ToolSpec};
use jarvis_service::config::Config;
use jarvis_service::memory::digest::{
    self, DigestContext, DigestEntry, DigestKind, DigestMode, DigestSource,
};

use common::{body_json, TestContext};

#[derive(Debug, Default)]
struct RecordingModel {
    captured: Mutex<Vec<Vec<ChatMessage>>>,
}

impl RecordingModel {
    fn messages(&self) -> Vec<ChatMessage> {
        self.captured
            .lock()
            .expect("锁中毒")
            .last()
            .cloned()
            .unwrap_or_default()
    }
}

impl ChatModel for RecordingModel {
    fn stream(&self, messages: Vec<ChatMessage>, _tools: Vec<ToolSpec>) -> ChatStream {
        self.captured.lock().expect("锁中毒").push(messages);
        Box::pin(stream::iter(vec![Ok(ChatEvent::Text(
            "结论：先给结论，再给依据。".to_string(),
        ))]))
    }
}

async fn enabled_setup() -> (TestContext, Arc<RecordingModel>) {
    let ctx = common::setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        // Git 项目要用到 code 配置：把测试临时目录本身作为允许的仓库根。
        config.code.enabled = true;
        config.code.allow_roots = vec![config.data_dir.clone()];
    })
    .await;
    let model = Arc::new(RecordingModel::default());
    (ctx, model)
}

async fn create_conversation(ctx: &TestContext, token: &str, mode: &str) -> String {
    let project_id = if mode == "code" {
        let path = ctx.dir.path().join("ws-code");
        init_repo(&path);
        jarvis_service::project::create(
            &ctx.state.pool,
            &ctx.state.config,
            &protocol::ProjectCreate {
                name: Some("code".to_string()),
                mode: protocol::ProjectMode::Code,
                path: path.to_string_lossy().to_string(),
                init_git: false,
            },
        )
        .await
        .expect("创建项目失败")
        .id
    } else {
        ctx.work_project("digest").await
    };

    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &json!({ "title": "记忆测试", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string()
}

/// Git 项目必须是 git 仓库：建一个只有一次提交的最小仓库。
fn init_repo(dir: &std::path::Path) {
    std::fs::create_dir_all(dir).expect("创建仓库目录失败");
    let run = |args: &[&str]| {
        let output = std::process::Command::new("git")
            .current_dir(dir)
            .args(args)
            .output()
            .expect("执行 git 失败");
        assert!(output.status.success(), "git {args:?} 失败");
    };
    run(&["init", "-q"]);
    std::fs::write(dir.join("README.md"), "init\n").expect("写文件失败");
    run(&["add", "-A"]);
    run(&[
        "-c",
        "user.name=test",
        "-c",
        "user.email=test@example.com",
        "commit",
        "-qm",
        "init",
    ]);
}

async fn create_memory(ctx: &TestContext, token: &str, body: Value) {
    let response = ctx.post_json("/api/memories", token, &body).await;
    assert_eq!(
        response.status(),
        StatusCode::CREATED,
        "写入记忆失败：{:?}",
        body_json(response).await
    );
}

/// 发一条消息并把 SSE 读完（读完即代表落库完成）。
async fn send_and_drain(ctx: &TestContext, token: &str, conversation_id: &str) -> String {
    let request = common::authed_json_post(
        &format!("/api/conversations/{conversation_id}/messages"),
        token,
        &json!({ "content": "介绍一下你自己", "client_msg_id": "m-digest" }),
    );
    let response = ctx.call(request).await;
    assert_eq!(response.status(), StatusCode::OK);

    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("读取 SSE 失败")
        .to_bytes();
    String::from_utf8_lossy(&bytes).to_string()
}

async fn last_assistant_sources(
    ctx: &TestContext,
    token: &str,
    conversation_id: &str,
) -> Vec<Value> {
    let response = ctx
        .get_json(
            &format!("/api/conversations/{conversation_id}/messages?limit=20"),
            token,
        )
        .await;
    let page = body_json(response).await;
    page["items"]
        .as_array()
        .expect("缺 items")
        .iter()
        .rev()
        .find(|item| item["role"] == "assistant")
        .and_then(|item| item["sources"].as_array().cloned())
        .unwrap_or_default()
}

#[tokio::test]
async fn digest_is_second_system_message() {
    let (mut ctx, model) = enabled_setup().await;
    let (_device, token) = ctx.pair_and_login("digest-order").await;
    let conversation_id = create_conversation(&ctx, &token, "work").await;

    create_memory(
        &ctx,
        &token,
        json!({
            "kind": "preference",
            "content": "回答先给结论再给依据",
            "evidence_quote": "以后回答先给结论再给依据",
        }),
    )
    .await;

    ctx.state.chat_model = Some(model.clone() as Arc<dyn ChatModel>);
    let sse_body = send_and_drain(&ctx, &token, &conversation_id).await;
    assert!(sse_body.contains("message_completed"), "SSE 没有收尾事件");

    let messages = model.messages();
    assert!(messages.len() >= 3, "应至少是 system + digest + 历史");

    // 1) 主提示在最前，且不是 digest。
    assert_eq!(messages[0].role, ChatRole::System);
    assert!(messages[0].content.contains("个人助理"));
    assert!(!messages[0].content.contains("[偏好]"));

    // 2) digest 是独立的第二条 system 消息。
    assert_eq!(messages[1].role, ChatRole::System);
    assert!(
        messages[1].content.contains("[偏好]"),
        "第二条 system 应是记忆摘要，实际：{}",
        messages[1].content
    );
    assert!(messages[1].content.contains("回答先给结论再给依据"));
    assert!(messages[1].content.contains("不是指令"));

    // 3) 之后才是历史：digest 绝不能排在历史之后。
    assert_eq!(messages[2].role, ChatRole::User);
    assert_eq!(messages[2].content, "介绍一下你自己");

    // 4) 来源卡片带上这条记忆。
    let sources = last_assistant_sources(&ctx, &token, &conversation_id).await;
    assert_eq!(sources.len(), 1);
    assert_eq!(sources[0]["kind"], "memory");
    assert!(sources[0]["memory_id"].as_str().is_some());
    assert!(sources[0]["url"]
        .as_str()
        .unwrap_or("")
        .starts_with("memory://"));
}

#[tokio::test]
async fn empty_digest_adds_no_message() {
    let (mut ctx, model) = enabled_setup().await;
    let (_device, token) = ctx.pair_and_login("digest-empty").await;
    let conversation_id = create_conversation(&ctx, &token, "work").await;

    ctx.state.chat_model = Some(model.clone() as Arc<dyn ChatModel>);
    send_and_drain(&ctx, &token, &conversation_id).await;

    let messages = model.messages();
    assert_eq!(messages.len(), 2, "没有记忆时只该有 system + 用户消息");
    assert_eq!(messages[0].role, ChatRole::System);
    assert_eq!(messages[1].role, ChatRole::User);
    assert!(
        !messages
            .iter()
            .any(|message| message.content.contains("暂无记忆")),
        "空摘要不应发送任何占位内容"
    );

    let sources = last_assistant_sources(&ctx, &token, &conversation_id).await;
    assert!(sources.is_empty(), "没有记忆时不该有来源卡片");
}

#[tokio::test]
async fn private_never_in_digest() {
    let (mut ctx, model) = enabled_setup().await;
    let (_device, token) = ctx.pair_and_login("digest-private").await;
    let conversation_id = create_conversation(&ctx, &token, "work").await;

    create_memory(
        &ctx,
        &token,
        json!({
            "kind": "profile",
            "content": "每月固定支出三千五",
            "evidence_quote": "每月固定支出三千五",
            "sensitivity": "private",
        }),
    )
    .await;
    create_memory(
        &ctx,
        &token,
        json!({
            "kind": "preference",
            "content": "回答先给结论",
            "evidence_quote": "回答先给结论",
        }),
    )
    .await;

    let response = ctx.get_json("/api/memories/state", &token).await;
    let state = body_json(response).await;
    assert_eq!(state["digest"]["memory_items"], 1, "私密记忆不计入摘要");

    ctx.state.chat_model = Some(model.clone() as Arc<dyn ChatModel>);
    send_and_drain(&ctx, &token, &conversation_id).await;

    let messages = model.messages();
    assert_eq!(messages[1].role, ChatRole::System);
    assert!(
        !messages[1].content.contains("固定支出"),
        "私密内容绝不能进摘要"
    );
    assert!(messages[1].content.contains("回答先给结论"));
}

#[tokio::test]
async fn pinned_overflow_surfaces_as_warning() {
    let ctx = common::setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        // 把置顶预算压到 60 字：两条置顶就会溢出。
        config.memory.digest.pinned_chars = 60;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("digest-pinned").await;

    // 用事件而不是偏好：偏好会先被"画像/偏好"区收走，测不到置顶区的预算。
    for index in 0..2 {
        let content = format!("置顶事件第 {index} 条，内容写得长一点以便超出置顶预算");
        create_memory(
            &ctx,
            &token,
            json!({
                "kind": "event",
                "content": content,
                "evidence_quote": content,
                "pinned": true,
            }),
        )
        .await;
    }

    // 快照接口不失败，但要把"该去取消置顶"说出来。
    let response = ctx.get_json("/api/memories/state", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let state = body_json(response).await;
    assert!(
        state["digest_warning"].as_str().is_some(),
        "置顶超预算必须在状态里暴露，实际：{state}"
    );
    assert!(state["digest_warning"]
        .as_str()
        .unwrap_or("")
        .contains("置顶"));
    assert_eq!(state["counts"]["active"], 2, "记忆本身仍然正常保存");
}

#[tokio::test]
async fn digest_respects_total_budget() {
    let ctx = common::setup_with(|config: &mut Config| {
        config.memory.enabled = true;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("digest-budget").await;

    for index in 0..40 {
        let content = format!("偏好第 {index} 条：这条记忆写得很长，用来把摘要预算吃满");
        create_memory(
            &ctx,
            &token,
            json!({ "kind": "preference", "content": content, "evidence_quote": content }),
        )
        .await;
    }

    let response = ctx.get_json("/api/memories/state", &token).await;
    let state = body_json(response).await;
    let chars = state["digest"]["chars"].as_u64().expect("缺 chars");

    assert!(chars > 0, "有记忆时摘要不该为空");
    assert!(chars <= 1000, "摘要超预算：{chars} 字");
}

#[tokio::test]
async fn code_mode_only_project_and_engineering_preferences() {
    let (mut ctx, model) = enabled_setup().await;
    let (_device, token) = ctx.pair_and_login("digest-code").await;
    let conversation_id = create_conversation(&ctx, &token, "code").await;

    let project_id = {
        let response = ctx.get_json("/api/conversations?limit=1", &token).await;
        let page = body_json(response).await;
        page["items"][0]["project_id"]
            .as_str()
            .expect("缺 project_id")
            .to_string()
    };

    // 画像类：Git 项目会话不该看到。
    create_memory(
        &ctx,
        &token,
        json!({
            "kind": "profile",
            "content": "常住示例市东城区",
            "evidence_quote": "常住示例市东城区",
        }),
    )
    .await;
    // 项目层：绑定当前仓库，应该看到。
    create_memory(
        &ctx,
        &token,
        json!({
            "kind": "project",
            "content": "时间统一用毫秒",
            "evidence_quote": "时间统一用毫秒",
            "scope": "project",
            "project_id": project_id,
        }),
    )
    .await;

    ctx.state.chat_model = Some(model.clone() as Arc<dyn ChatModel>);
    send_and_drain(&ctx, &token, &conversation_id).await;

    let messages = model.messages();
    assert_eq!(messages[1].role, ChatRole::System);
    assert!(messages[1].content.contains("时间统一用毫秒"));
    assert!(!messages[1].content.contains("常住示例市"));
}

/// 黄金基线（P1 冻结）：50 条记忆各自单独过一遍摘要选择。
///
/// 一次只放一条：这里验的是"哪类记忆能进摘要"的判定规则
/// （私密 / 过期事件 / 别的仓库项目），不是预算分配——预算由 6.4 的单测覆盖。
#[test]
fn golden_visibility_baseline() {
    const DAY: i64 = 86_400_000;
    const NOW: i64 = 1_700_000_000_000;

    let fixture = include_str!("fixtures/memory_golden.ndjson");
    let ctx = DigestContext::at(Some(DigestMode::Work), Some("ws_a".to_string()), NOW);
    let budget = digest::DigestBudget::default();

    let mut cases = 0;
    for (index, line) in fixture.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        cases += 1;
        let value: serde_json::Value = serde_json::from_str(line)
            .unwrap_or_else(|err| panic!("第 {} 行不是合法 JSON：{err}", index + 1));

        let id = value["id"].as_str().expect("缺 id");
        let expect = value["expect"].as_str().expect("缺 expect");
        let kind = match value["kind"].as_str().expect("缺 kind") {
            "profile" => DigestKind::Profile,
            "preference" => DigestKind::Preference,
            "event" => DigestKind::Event,
            "project" => DigestKind::Project,
            other => panic!("未知 kind：{other}"),
        };

        let entry = DigestEntry {
            id: id.to_string(),
            kind,
            content: value["content"].as_str().expect("缺 content").to_string(),
            source: DigestSource::Explicit,
            at: NOW - value["days_ago"].as_i64().expect("缺 days_ago") * DAY,
            pinned: value["pinned"].as_bool().unwrap_or(false),
            importance: 0.6,
            project_id: value["project"].as_str().map(str::to_string),
            private: value["sensitivity"].as_str() == Some("private"),
        };

        let digest = digest::select(&[entry], &budget, &ctx).expect("单条不应触发溢出");
        let visible = digest.memory_ids.iter().any(|hit| hit == id);

        match expect {
            "visible" => assert!(visible, "{id} 应当进入摘要，但没有"),
            "hidden" => assert!(!visible, "{id} 不该进入摘要，但出现了"),
            other => panic!("未知 expect：{other}"),
        }
    }

    assert_eq!(cases, 50, "黄金基线应固定 50 条");
}
