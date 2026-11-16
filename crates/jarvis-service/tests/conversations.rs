//! 会话与消息的集成测试。
//!
//! 覆盖：SSE 流、消息落库、cursor 翻页、`client_msg_id` 去重、未认证拒绝。

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;

async fn create_conversation(ctx: &common::TestContext, token: &str) -> String {
    let project_id = ctx.work_project("chat").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "测试会话", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

async fn send(
    ctx: &common::TestContext,
    token: &str,
    id: &str,
    payload: serde_json::Value,
) -> String {
    let response = ctx
        .post_json(
            &format!("/api/conversations/{id}/messages"),
            token,
            &payload,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK, "发送消息应当返回 SSE 流");

    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();
    assert!(
        content_type.starts_with("text/event-stream"),
        "内容类型应为 SSE，实际为 {content_type}"
    );

    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("读取 SSE 失败")
        .to_bytes();
    String::from_utf8_lossy(&bytes).into_owned()
}

#[tokio::test]
async fn message_streams_and_persists() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("chat").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let stream = send(
        &ctx,
        &token,
        &conversation_id,
        serde_json::json!({ "content": "帮我看下天气", "client_msg_id": "c-1" }),
    )
    .await;

    assert!(stream.contains("message_delta"), "应有分片事件: {stream}");
    assert!(
        stream.contains("message_completed"),
        "应有完成事件: {stream}"
    );
    // 完成事件带耗时：会话页的状态行要能直接显示"用时 X 分 Y 秒"。
    assert!(
        stream.contains("\"elapsed_ms\""),
        "完成事件应带耗时: {stream}"
    );

    // 历史里应有用户与助理两条，倒序返回
    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}/messages"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    let items = body["items"].as_array().expect("缺少 items");

    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["role"], "assistant");
    assert_eq!(items[1]["role"], "user");
    assert!(items[0]["content"]
        .as_str()
        .expect("助理消息应有内容")
        .contains("帮我看下天气"));
}

#[tokio::test]
async fn duplicate_client_message_id_is_ignored() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("dedupe").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let payload = serde_json::json!({ "content": "重复提交", "client_msg_id": "same-id" });
    send(&ctx, &token, &conversation_id, payload.clone()).await;
    send(&ctx, &token, &conversation_id, payload).await;

    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}/messages?limit=50"),
            &token,
        ))
        .await;
    let body = common::body_json(response).await;
    let items = body["items"].as_array().expect("缺少 items");

    let user_messages: Vec<_> = items.iter().filter(|item| item["role"] == "user").collect();
    assert_eq!(
        user_messages.len(),
        1,
        "同一个 client_msg_id 不应产生两条用户消息"
    );
}

#[tokio::test]
async fn messages_paginate_with_cursor() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("paging").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    for index in 0..3 {
        send(
            &ctx,
            &token,
            &conversation_id,
            serde_json::json!({ "content": format!("第 {index} 条") }),
        )
        .await;
    }

    let first = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}/messages?limit=2"),
            &token,
        ))
        .await;
    let first = common::body_json(first).await;
    let first_items = first["items"].as_array().expect("缺少 items");
    assert_eq!(first_items.len(), 2);

    let cursor = first["next_cursor"]
        .as_str()
        .expect("应有下一页游标")
        .to_string();

    let second = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}/messages?limit=2&cursor={cursor}"),
            &token,
        ))
        .await;
    let second = common::body_json(second).await;
    let second_items = second["items"].as_array().expect("缺少 items");

    assert!(!second_items.is_empty());
    for item in second_items {
        assert!(
            first_items.iter().all(|known| known["id"] != item["id"]),
            "两页之间不应重复"
        );
    }
}

#[tokio::test]
async fn conversations_require_auth() {
    let ctx = common::setup().await;

    let response = ctx
        .call(
            Request::get("/api/conversations")
                .body(Body::empty())
                .expect("构造请求失败"),
        )
        .await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "unauthenticated");
}

#[tokio::test]
async fn unknown_conversation_returns_not_found() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("notfound").await;

    let response = ctx
        .call(common::authed_get(
            "/api/conversations/conv_missing",
            &token,
        ))
        .await;

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "not_found");
}

#[tokio::test]
async fn renames_conversation_without_touching_updated_at() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("rename").await;
    let project_id = ctx.work_project("rename").await;

    let created = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "title": "旧名字", "project_id": project_id }),
        )
        .await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let created = common::body_json(created).await;
    let id = created["id"].as_str().expect("缺少会话 id").to_string();
    let updated_at = created["updated_at"].clone();

    // 让时间戳有机会变化：若改名顺手刷新了 updated_at，下面这条断言就会失败。
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;

    let response = ctx
        .patch_json(
            &format!("/api/conversations/{id}"),
            &token,
            &serde_json::json!({ "title": "  周报草稿  " }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let renamed = common::body_json(response).await;
    assert_eq!(renamed["title"], "周报草稿", "标题应 trim 后保存");
    assert_eq!(
        renamed["updated_at"], updated_at,
        "改名不该刷新 updated_at，否则会话会跳到列表最前"
    );

    // 真的落库了：重新读详情仍是新标题，其余字段不受影响。
    let detail = ctx
        .get_json(&format!("/api/conversations/{id}"), &token)
        .await;
    assert_eq!(detail.status(), StatusCode::OK);
    let detail = common::body_json(detail).await;
    assert_eq!(detail["title"], "周报草稿");
    assert_eq!(detail["project_id"], project_id.as_str());

    // 空标题与超长标题都是 400：这是用户手输的值，不该静默截断或改成占位。
    let empty = ctx
        .patch_json(
            &format!("/api/conversations/{id}"),
            &token,
            &serde_json::json!({ "title": "   " }),
        )
        .await;
    assert_eq!(empty.status(), StatusCode::BAD_REQUEST);

    let too_long = "字".repeat(40);
    let long = ctx
        .patch_json(
            &format!("/api/conversations/{id}"),
            &token,
            &serde_json::json!({ "title": too_long }),
        )
        .await;
    assert_eq!(long.status(), StatusCode::BAD_REQUEST);

    // 未知 id 404，而不是悄悄什么都不做。
    let missing = ctx
        .patch_json(
            "/api/conversations/conv_missing",
            &token,
            &serde_json::json!({ "title": "无所谓" }),
        )
        .await;
    assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    assert_eq!(common::body_json(missing).await["code"], "not_found");
}

/// 侧栏连点「新建会话」不该堆出一串「新会话」：同一项目里空白会话只留一条。
#[tokio::test]
async fn reuses_blank_conversation_in_same_project() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("reuse").await;
    let project_id = ctx.work_project("reuse").await;

    let first = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "project_id": project_id }),
        )
        .await;
    assert_eq!(first.status(), StatusCode::CREATED, "第一次应当真的新建");
    let first = common::body_json(first).await;
    assert_eq!(first["title"], "新会话", "没给标题时是占位标题");

    // 错开时间戳：复用会刷新 updated_at，用它确认命中的是同一条。
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;

    let second = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "project_id": project_id }),
        )
        .await;
    assert_eq!(second.status(), StatusCode::OK, "第二次应当复用而不是新建");
    let second = common::body_json(second).await;
    assert_eq!(second["id"], first["id"], "应当跳回同一条会话");
    assert_ne!(
        second["updated_at"], first["updated_at"],
        "复用要刷新 updated_at，好让这条会话回到列表顶部"
    );

    // 复用的范围是项目：另一个项目里没有空白会话，照样要新建。
    let other_project = ctx.work_project("reuse-other").await;
    let other = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "project_id": other_project }),
        )
        .await;
    assert_eq!(other.status(), StatusCode::CREATED, "跨项目不该复用");
    let other = common::body_json(other).await;
    assert_ne!(other["id"], first["id"]);

    // 库里确实只有两条会话：复用没有偷偷插一条新的。
    let list = ctx.get_json("/api/conversations?limit=50", &token).await;
    assert_eq!(list.status(), StatusCode::OK);
    let list = common::body_json(list).await;
    assert_eq!(
        list["items"].as_array().expect("缺少 items").len(),
        2,
        "同一项目不该堆出两条「新会话」"
    );
}

/// 显式起名仍是新建：脚本、导入这类调用期望拿到自己的那条会话。
#[tokio::test]
async fn explicit_title_still_creates_new_conversation() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("explicit").await;
    let project_id = ctx.work_project("explicit").await;

    let blank = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "project_id": project_id }),
        )
        .await;
    assert_eq!(blank.status(), StatusCode::CREATED);
    let blank = common::body_json(blank).await;

    let named = ctx
        .post_json(
            "/api/conversations",
            &token,
            &serde_json::json!({ "project_id": project_id, "title": "周报草稿" }),
        )
        .await;
    assert_eq!(named.status(), StatusCode::CREATED, "给了标题就该新建");
    let named = common::body_json(named).await;
    assert_eq!(named["title"], "周报草稿");
    assert_ne!(named["id"], blank["id"], "不该并到已有的空白会话上");
}

/// 无归属直聊：不挂项目也能建会话、能正常对话，并能被 `?unassigned=true` 单独列出。
#[tokio::test]
async fn unassigned_conversation_can_chat_and_is_listed_separately() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("unassigned").await;

    let created = ctx
        .post_json("/api/conversations", &token, &serde_json::json!({}))
        .await;
    assert_eq!(
        created.status(),
        StatusCode::CREATED,
        "不带项目也应当能建会话"
    );
    let created = common::body_json(created).await;
    assert_eq!(created["project_id"], "", "无归属会话用空串表达");
    let id = created["id"].as_str().expect("缺少会话 id").to_string();

    // 无归属会话照样能对话：系统提示与记忆走全局兜底，不需要项目。
    let stream = send(
        &ctx,
        &token,
        &id,
        serde_json::json!({ "content": "在吗", "client_msg_id": "u-1" }),
    )
    .await;
    assert!(
        stream.contains("message_completed"),
        "无归属会话也要能正常回答: {stream}"
    );

    // 只看无归属：只返回它一条。
    let unassigned = ctx
        .get_json("/api/conversations?unassigned=true&limit=50", &token)
        .await;
    assert_eq!(unassigned.status(), StatusCode::OK);
    let unassigned = common::body_json(unassigned).await;
    let items = unassigned["items"].as_array().expect("缺少 items");
    assert_eq!(items.len(), 1, "「对话」分组只该有无归属会话");
    assert_eq!(items[0]["id"], id);

    // 按项目过滤时看不到它：空串在 `project_id` 语义里是"不筛选"，
    // 所以「只看无归属」必须靠独立参数，这里正是那条边界。
    let project_id = ctx.work_project("unassigned-ws").await;
    let scoped = ctx
        .get_json(
            &format!("/api/conversations?project_id={project_id}&limit=50"),
            &token,
        )
        .await;
    assert_eq!(scoped.status(), StatusCode::OK);
    let scoped = common::body_json(scoped).await;
    assert!(
        scoped["items"].as_array().expect("缺少 items").is_empty(),
        "按项目查不该带出无归属会话"
    );
}

/// 无归属直聊也复用空白会话：它没有项目分组可在侧栏收拢，堆起来更难找。
#[tokio::test]
async fn reuses_blank_unassigned_conversation() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("reuse-unassigned").await;

    let first = ctx
        .post_json("/api/conversations", &token, &serde_json::json!({}))
        .await;
    assert_eq!(first.status(), StatusCode::CREATED, "第一次应当真的新建");
    let first = common::body_json(first).await;

    // 错开时间戳：复用会刷新 updated_at，用它确认命中的是同一条。
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;

    let second = ctx
        .post_json("/api/conversations", &token, &serde_json::json!({}))
        .await;
    assert_eq!(second.status(), StatusCode::OK, "第二次应当复用而不是新建");
    let second = common::body_json(second).await;
    assert_eq!(second["id"], first["id"], "应当跳回同一条会话");
    assert_eq!(second["project_id"], "", "复用出来的仍是无归属会话");
}
