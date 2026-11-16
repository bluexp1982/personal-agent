//! `/api/memories*` 的行为：鉴权、证据必填、分页、软删、状态快照、总开关。

mod common;

use axum::http::StatusCode;
use serde_json::{json, Value};
use jarvis_service::config::Config;

use common::{body_json, setup_with, TestContext};

async fn memory_enabled() -> TestContext {
    setup_with(|config: &mut Config| {
        config.memory.enabled = true;
    })
    .await
}

fn create_body(content: &str) -> Value {
    json!({
        "kind": "preference",
        "content": content,
        "evidence_quote": content,
    })
}

async fn create_memory(ctx: &TestContext, token: &str, content: &str) -> Value {
    let response = ctx
        .post_json("/api/memories", token, &create_body(content))
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "写入记忆失败");
    body_json(response).await
}

#[tokio::test]
async fn requires_auth() {
    let ctx = memory_enabled().await;
    let response = ctx.get_json("/api/memories", "not-a-token").await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn disabled_service_returns_memory_unavailable() {
    // 默认配置就是关的：升级后不该有任何记忆行为。
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("mem-off").await;

    let response = ctx
        .post_json("/api/memories", &token, &create_body("回答先给结论"))
        .await;
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = body_json(response).await;
    assert_eq!(body["code"], "memory_unavailable");
    assert_eq!(body["retryable"], false);

    // 读路径不报错：状态接口返回 enabled=false，摘要为空。
    let response = ctx.get_json("/api/memories/state", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let state = body_json(response).await;
    assert_eq!(state["enabled"], false);
    assert_eq!(state["counts"]["active"], 0);
}

#[tokio::test]
async fn explicit_write_requires_evidence() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-evidence").await;

    let response = ctx
        .post_json(
            "/api/memories",
            &token,
            &json!({ "kind": "preference", "content": "回答先给结论" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = body_json(response).await;
    assert_eq!(body["code"], "invalid_request");
    assert!(
        body["hint"].as_str().unwrap_or("").contains("原话"),
        "提示要说清缺的是哪一句原话"
    );
}

#[tokio::test]
async fn create_then_detail_and_delete() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-crud").await;

    let created = create_memory(&ctx, &token, "回答先给结论再给依据").await;
    let memory = &created["memory"];
    let id = memory["id"].as_str().expect("缺 id").to_string();
    assert_eq!(memory["status"], "active");
    assert_eq!(memory["source"], "explicit");
    assert_eq!(memory["pinned"], false);

    // 证据必须能点开看到原话。
    let evidence = created["evidence"].as_array().expect("缺 evidence");
    assert_eq!(evidence.len(), 1);
    assert_eq!(evidence[0]["quote"], "回答先给结论再给依据");
    assert_eq!(evidence[0]["source_kind"], "explicit");

    let response = ctx.get_json(&format!("/api/memories/{id}"), &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(body_json(response).await["memory"]["id"], id.as_str());

    let response = ctx.delete(&format!("/api/memories/{id}"), &token).await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 删除立即对读路径生效，重复删也是 204。
    let response = ctx.get_json(&format!("/api/memories/{id}"), &token).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let response = ctx.delete(&format!("/api/memories/{id}"), &token).await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let response = ctx.get_json("/api/memories/state", &token).await;
    let state = body_json(response).await;
    assert_eq!(state["counts"]["active"], 0);
}

#[tokio::test]
async fn duplicate_write_merges_evidence() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-dedupe").await;

    let first = create_memory(&ctx, &token, "每周三下午有空").await;
    let second = create_memory(&ctx, &token, "每周三下午有空").await;

    assert_eq!(
        first["memory"]["id"], second["memory"]["id"],
        "同内容应合并"
    );
    assert_eq!(
        second["evidence"].as_array().expect("缺 evidence").len(),
        2,
        "合并时应追加证据"
    );
}

#[tokio::test]
async fn list_paginates_by_cursor() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-page").await;

    for index in 0..5 {
        create_memory(&ctx, &token, &format!("第 {index} 条记忆")).await;
        tokio::time::sleep(std::time::Duration::from_millis(2)).await;
    }

    let response = ctx.get_json("/api/memories?limit=2", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let page = body_json(response).await;
    assert_eq!(page["items"].as_array().expect("缺 items").len(), 2);
    let cursor = page["next_cursor"]
        .as_str()
        .expect("还有下一页")
        .to_string();

    let response = ctx
        .get_json(&format!("/api/memories?limit=2&cursor={cursor}"), &token)
        .await;
    let second = body_json(response).await;
    let first_ids: Vec<&str> = page["items"]
        .as_array()
        .expect("缺 items")
        .iter()
        .filter_map(|item| item["id"].as_str())
        .collect();
    for item in second["items"].as_array().expect("缺 items") {
        assert!(!first_ids.contains(&item["id"].as_str().unwrap_or("")));
    }
}

#[tokio::test]
async fn list_searches_chinese_two_char_query() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-search").await;

    create_memory(&ctx, &token, "报销走飞书审批").await;
    create_memory(&ctx, &token, "每周五晚上去游泳").await;

    // 两字查询是 P0 定的关键场景：unicode61 直索在中文下命中 0。
    let response = ctx
        .get_json("/api/memories?q=%E6%8A%A5%E9%94%80", &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let page = body_json(response).await;
    let items = page["items"].as_array().expect("缺 items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["content"], "报销走飞书审批");
}

#[tokio::test]
async fn update_pins_and_marks_corrected() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-update").await;

    let created = create_memory(&ctx, &token, "用 Jenkinss").await;
    let id = created["memory"]["id"].as_str().expect("缺 id").to_string();

    let response = ctx
        .patch_json(
            &format!("/api/memories/{id}"),
            &token,
            &json!({ "content": "用 GitHub Actions", "pinned": true }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let detail = body_json(response).await;
    assert_eq!(detail["memory"]["content"], "用 GitHub Actions");
    assert_eq!(detail["memory"]["pinned"], true);
    assert_eq!(detail["memory"]["source"], "user_corrected");
}

#[tokio::test]
async fn update_rejects_delete_via_patch() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-patch-status").await;

    let created = create_memory(&ctx, &token, "不吃香菜").await;
    let id = created["memory"]["id"].as_str().expect("缺 id").to_string();

    let response = ctx
        .patch_json(
            &format!("/api/memories/{id}"),
            &token,
            &json!({ "status": "deleted" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn state_exposes_quota_and_digest_size() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-state").await;

    create_memory(&ctx, &token, "回答先给结论再给依据").await;

    let response = ctx.get_json("/api/memories/state", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let state = body_json(response).await;

    assert_eq!(state["enabled"], true);
    assert_eq!(state["counts"]["active"], 1);
    assert!(state["digest"]["chars"].as_u64().unwrap_or(0) > 0);
    assert_eq!(state["digest"]["memory_items"], 1);
    assert_eq!(state["extract"]["daily_limit"], 50);
    assert_eq!(state["extract"]["used_today"], 0);
    assert_eq!(state["heartbeat"]["enabled"], false);
}

#[tokio::test]
async fn invalid_enum_is_rejected() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-enum").await;

    let response = ctx.get_json("/api/memories?kind=unknown", &token).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let response = ctx.get_json("/api/memories?status=all", &token).await;
    assert_eq!(response.status(), StatusCode::OK, "status=all 表示不过滤");
}

#[tokio::test]
async fn delete_conversation_marks_evidence_stale() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-stale").await;
    let project_id = ctx.work_project("mem-stale").await;

    let response = ctx
        .post_json(
            "/api/conversations",
            &token,
            &json!({ "project_id": project_id, "title": "会话" }),
        )
        .await;
    let conversation_id = body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();

    // 造一条消息，并让记忆的证据指向它（抽取链路里证据的 source_id 就是消息 id）。
    let now = jarvis_service::clock::now_ms();
    sqlx::query(
        "INSERT INTO messages (id, conversation_id, role, content_json, created_at) \
         VALUES ('msg_1', ?, 'user', '\"我一般周三有空\"', ?)",
    )
    .bind(&conversation_id)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入消息失败");

    let memory = create_memory(&ctx, &token, "每周三下午有空").await;
    let memory_id = memory["memory"]["id"].as_str().expect("缺少记忆 id");
    sqlx::query("UPDATE memory_evidence SET source_kind = 'message', source_id = 'msg_1' WHERE memory_id = ?")
        .bind(memory_id)
        .execute(&ctx.state.pool)
        .await
        .expect("改写证据来源失败");

    let response = ctx
        .delete(&format!("/api/conversations/{conversation_id}"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let response = ctx
        .get_json(&format!("/api/memories/{memory_id}"), &token)
        .await;
    let detail = body_json(response).await;
    assert_eq!(
        detail["memory"]["status"], "stale",
        "源消息没了，依赖它的记忆应转已失效"
    );
}

#[tokio::test]
async fn digest_setting_toggle_takes_effect() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-digest-switch").await;
    create_memory(&ctx, &token, "回答先给结论再给依据").await;

    // 默认开着：摘要有内容。
    let state = body_json(ctx.get_json("/api/memories/state", &token).await).await;
    assert!(
        state["digest"]["chars"].as_i64().unwrap_or(0) > 0,
        "默认应当注入摘要，实际 {state}"
    );

    // 关掉之后必须**立刻**不再注入。这一条是这个开关唯一的用户价值：
    // 只写库不生效的话，用户点了会以为没反应。
    let response = ctx
        .patch_json(
            "/api/memories/settings",
            &token,
            &json!({ "digest_enabled": false }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let state = body_json(ctx.get_json("/api/memories/state", &token).await).await;
    assert_eq!(
        state["digest"]["chars"], 0,
        "关掉摘要后不该再注入，实际 {state}"
    );

    // 改回 true 立即恢复。
    ctx.patch_json(
        "/api/memories/settings",
        &token,
        &json!({ "digest_enabled": true }),
    )
    .await;
    let state = body_json(ctx.get_json("/api/memories/state", &token).await).await;
    assert!(
        state["digest"]["chars"].as_i64().unwrap_or(0) > 0,
        "重新打开后应恢复注入，实际 {state}"
    );
}

/// 造一条归档记忆：走正常写入再直接把状态改成 archived（归并/取代路径没有
/// 对外入口，测试里直写库是最短的造数方式）。返回记忆 id。
async fn create_archived(ctx: &TestContext, token: &str, kind: &str, content: &str) -> String {
    let response = ctx
        .post_json(
            "/api/memories",
            token,
            &json!({ "kind": kind, "content": content, "evidence_quote": content }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "写入记忆失败");
    let id = body_json(response).await["memory"]["id"]
        .as_str()
        .expect("缺 id")
        .to_string();
    sqlx::query("UPDATE memories SET status = 'archived' WHERE id = ?")
        .bind(&id)
        .execute(&ctx.state.pool)
        .await
        .expect("改状态失败");
    id
}

#[tokio::test]
async fn purge_archived_clears_all_kinds_and_is_idempotent() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-purge-all").await;

    let archived_a = create_archived(&ctx, &token, "profile", "老家在嘉兴").await;
    let archived_b = create_archived(&ctx, &token, "preference", "讨厌香菜").await;
    // 一条生效记忆：清空归档绝不能碰它。
    let active = create_memory(&ctx, &token, "回答先给结论").await;
    let active_id = active["memory"]["id"].as_str().expect("缺 id").to_string();

    let response = ctx
        .post_json("/api/memories/archived/purge", &token, &json!({}))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(body_json(response).await["purged"], 2);

    // 归档列表空了、计数归零，生效那条还在。
    let page = body_json(ctx.get_json("/api/memories?status=archived", &token).await).await;
    assert_eq!(page["items"].as_array().expect("缺 items").len(), 0);
    let state = body_json(ctx.get_json("/api/memories/state", &token).await).await;
    assert_eq!(state["counts"]["archived"], 0);
    assert_eq!(state["counts"]["active"], 1);

    for id in [&archived_a, &archived_b] {
        let response = ctx.get_json(&format!("/api/memories/{id}"), &token).await;
        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "已清除的归档不该再能读到"
        );
    }
    let response = ctx
        .get_json(&format!("/api/memories/{active_id}"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    // 幂等：再清一次返回 0，不报错。
    let response = ctx
        .post_json("/api/memories/archived/purge", &token, &json!({}))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(body_json(response).await["purged"], 0);
}

#[tokio::test]
async fn purge_archived_can_narrow_by_kind() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("mem-purge-kind").await;

    create_archived(&ctx, &token, "profile", "老家在嘉兴").await;
    create_archived(&ctx, &token, "preference", "讨厌香菜").await;
    create_archived(&ctx, &token, "preference", "不吃辣").await;

    let response = ctx
        .post_json(
            "/api/memories/archived/purge",
            &token,
            &json!({ "kind": "preference" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(body_json(response).await["purged"], 2);

    // 画像类的归档原样保留。
    let page = body_json(ctx.get_json("/api/memories?status=archived", &token).await).await;
    let items = page["items"].as_array().expect("缺 items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["kind"], "profile");
}
