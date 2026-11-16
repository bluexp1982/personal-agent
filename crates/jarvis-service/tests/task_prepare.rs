//! `POST /api/tasks/prepare` 的集成测试。
//!
//! 重点不是"模型解析得准不准"（那是 `task_prepare` 的单测），而是三件事：
//! 没有模型时**只带原文不猜字段**、跑不了的技能被挡在门外、审计不落用户原话。

mod common;

use axum::http::StatusCode;
use common::{body_json, setup};
use protocol::skill::{FetchSource, FetchTool, SkillFetch};
use protocol::{SkillManifest, BUILTIN_SOURCE};

fn site_brief() -> SkillManifest {
    SkillManifest {
        name: "site-brief".to_string(),
        version: "1.0.0".to_string(),
        risk_level: "read".to_string(),
        triggers: vec!["网页".to_string()],
        required_tools: vec!["web.fetch".to_string()],
        outputs: vec!["report".to_string()],
        stop_before: None,
        steps: vec!["读取".to_string(), "归纳".to_string()],
        source: BUILTIN_SOURCE.to_string(),
        plugin_id: None,
        fetch: Some(SkillFetch {
            step: "读取".to_string(),
            from: FetchSource::Url,
            tool: FetchTool::WebFetch,
        }),
    }
}

fn code_task() -> SkillManifest {
    SkillManifest {
        name: "code-task".to_string(),
        version: "1.0.0".to_string(),
        risk_level: "irreversible_write".to_string(),
        triggers: vec!["改代码".to_string()],
        required_tools: vec!["code.exec".to_string()],
        outputs: vec!["diff".to_string()],
        stop_before: None,
        steps: vec!["执行编码".to_string()],
        source: BUILTIN_SOURCE.to_string(),
        plugin_id: None,
        fetch: None,
    }
}

fn install_skills(ctx: &common::TestContext, manifests: Vec<SkillManifest>) {
    let mut registry = ctx
        .state
        .skills
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.extend(manifests);
}

/// 测试环境不配模型，走的正是"没有模型"这条路：
/// 只把原文放进 `text`，一个字段都不猜，并把缺口报出来。
#[tokio::test]
async fn without_model_only_the_raw_text_is_kept() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("prepare-fallback").await;
    install_skills(&ctx, vec![site_brief()]);

    let response = ctx
        .post_json(
            "/api/tasks/prepare",
            &token,
            &serde_json::json!({
                "conversation_id": "conv_1",
                "skill": "site-brief",
                "text": "  读取 https://example.com/a  ",
            }),
        )
        .await;

    assert_eq!(response.status(), StatusCode::OK);
    let body = body_json(response).await;

    assert_eq!(body["source"], "fallback");
    assert_eq!(
        body["input"]["text"], "读取 https://example.com/a",
        "原话要保留且 trim"
    );
    assert!(
        body["input"].get("url").is_none(),
        "兜底不许抽 URL: {}",
        body["input"]
    );
    assert_eq!(body["missing"][0], "url", "缺口要报出来，界面才能提示");
}

/// 编码任务需要仓库、执行方式与审批档，通用解析给不出：直接拒，让它走任务页。
#[tokio::test]
async fn coding_task_is_rejected_with_a_readable_reason() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("prepare-code").await;
    install_skills(&ctx, vec![code_task()]);

    let response = ctx
        .post_json(
            "/api/tasks/prepare",
            &token,
            &serde_json::json!({
                "conversation_id": "conv_1",
                "skill": "code-task",
                "text": "修一下登录过期",
            }),
        )
        .await;

    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = body_json(response).await;
    assert_eq!(body["code"], "skill_unknown");
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("任务页"),
        "要告诉用户去哪儿派: {body}"
    );
}

#[tokio::test]
async fn unknown_skill_is_rejected() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("prepare-unknown").await;

    let response = ctx
        .post_json(
            "/api/tasks/prepare",
            &token,
            &serde_json::json!({
                "conversation_id": "conv_1",
                "skill": "no-such-skill",
                "text": "随便说点什么",
            }),
        )
        .await;

    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert_eq!(body_json(response).await["code"], "skill_unknown");
}

/// 停用的插件技能不该还能从会话里派任务。
#[tokio::test]
async fn plugin_skill_must_be_enabled_and_runnable() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("prepare-plugin").await;

    let mut manifest = site_brief();
    manifest.name = "weekly-digest".to_string();
    manifest.source = "third_party".to_string();
    manifest.plugin_id = Some("com.example.weekly".to_string());
    install_skills(&ctx, vec![manifest]);

    let response = ctx
        .post_json(
            "/api/tasks/prepare",
            &token,
            &serde_json::json!({
                "conversation_id": "conv_1",
                "skill": "weekly-digest",
                "text": "整理一下这周的记录",
            }),
        )
        .await;

    // 库里没有这个插件的启用记录，按"不可运行"处理。
    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert_eq!(body_json(response).await["code"], "skill_unknown");
}

/// 审计只记形态，不记用户原话——那句话可能含个人信息。
#[tokio::test]
async fn audit_does_not_store_the_user_text() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("prepare-audit").await;
    install_skills(&ctx, vec![site_brief()]);

    let response = ctx
        .post_json(
            "/api/tasks/prepare",
            &token,
            &serde_json::json!({
                "conversation_id": "conv_1",
                "skill": "site-brief",
                "text": "读取 https://secret.example.com/private",
            }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let row: Option<(String,)> = sqlx::query_as(
        "SELECT detail_json FROM audit_log WHERE action = 'task.prepare' ORDER BY id DESC LIMIT 1",
    )
    .fetch_optional(&ctx.state.pool)
    .await
    .expect("查审计失败");

    let detail = row.expect("应写入一条 task.prepare 审计").0;
    assert!(detail.contains("site-brief"), "{detail}");
    assert!(
        !detail.contains("secret.example.com"),
        "审计不该落用户原话: {detail}"
    );
}

/// 装完插件、worker 还没重载时，`prepare` 也要认得这个技能。
///
/// 这是真实窗口：设置页装完立刻去 `@` 里派任务，若只认 worker 上报的清单，
/// 用户会得到"技能不可用"——而它明明刚刚才装好。库里的归一化清单是装包时
/// 的结论，比 registry 更早可用。
#[tokio::test]
async fn plugin_skill_is_usable_before_worker_reload() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("prepare-fresh-plugin").await;

    // 播种已把 trip-plan 装进库；清空 registry 模拟"worker 还没重载"。
    {
        let mut registry = ctx
            .state
            .skills
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.clear();
    }

    let response = ctx
        .post_json(
            "/api/tasks/prepare",
            &token,
            &serde_json::json!({
                "conversation_id": "conv_1",
                "skill": "trip-plan",
                "text": "下周三去上海",
            }),
        )
        .await;

    assert_eq!(
        response.status(),
        StatusCode::OK,
        "库里已装的技能不该因为 worker 还没重载就报不可用"
    );
}
