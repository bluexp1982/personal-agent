//! 任务与审批的集成测试。
//!
//! 覆盖：批准 → 成功、拒绝 → 取消并保留现场、超时 → 失败、幂等键、重复审批、审计可追溯。

mod common;

use axum::http::StatusCode;

async fn create_conversation(ctx: &common::TestContext, token: &str) -> String {
    let project_id = ctx.work_project("tasks").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "任务会话", "project_id": project_id }),
        )
        .await;
    let body = common::body_json(response).await;
    body["id"].as_str().expect("缺少会话 id").to_string()
}

async fn create_task(
    ctx: &common::TestContext,
    token: &str,
    conversation_id: &str,
    key: &str,
) -> (StatusCode, serde_json::Value) {
    let response = ctx
        .post_json(
            "/api/tasks",
            token,
            &serde_json::json!({
                "conversation_id": conversation_id,
                "type": "skill:trip-plan",
                "skill": "trip-plan",
                "idempotency_key": key,
            }),
        )
        .await;
    let status = response.status();
    (status, common::body_json(response).await)
}

async fn get_task(ctx: &common::TestContext, token: &str, id: &str) -> serde_json::Value {
    let response = ctx
        .call(common::authed_get(&format!("/api/tasks/{id}"), token))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    common::body_json(response).await
}

/// 轮询到指定状态。实现放在 `common`，全仓共用一套上限与步长，
/// 避免每个测试文件各写一份、各自猜一个够用的超时。
async fn wait_for_state(
    ctx: &common::TestContext,
    token: &str,
    id: &str,
    expected: &str,
) -> serde_json::Value {
    common::wait_for_state(ctx, token, id, expected).await
}

async fn decide(
    ctx: &common::TestContext,
    token: &str,
    task_id: &str,
    approval_id: &str,
    decision: &str,
) -> axum::response::Response {
    ctx.post_json(
        &format!("/api/tasks/{task_id}/approve"),
        token,
        &serde_json::json!({ "approval_id": approval_id, "decision": decision }),
    )
    .await
}

#[tokio::test]
async fn approval_leads_to_success() {
    let ctx = common::setup().await;
    let (device_id, token) = ctx.pair_and_login("approve").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let (status, task) = create_task(&ctx, &token, &conversation_id, "key-ok").await;
    assert_eq!(status, StatusCode::CREATED, "首次创建应当 201");

    let task_id = task["id"].as_str().expect("缺少 task id").to_string();
    let waiting = wait_for_state(&ctx, &token, &task_id, "needs_approval").await;

    let approval_id = waiting["pending_approval"]["id"]
        .as_str()
        .expect("应有待批审批")
        .to_string();
    assert_eq!(waiting["pending_approval"]["action"], "submit_form");
    assert!(waiting["plan"]
        .as_array()
        .is_some_and(|plan| plan.len() == 3));

    let response = decide(&ctx, &token, &task_id, &approval_id, "approve").await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    // 审批响应里任务状态应已变为 running
    let body = common::body_json(response).await;
    assert_eq!(body["state"], "running");

    let done = wait_for_state(&ctx, &token, &task_id, "succeeded").await;
    assert!(
        done["artifacts"]
            .as_array()
            .is_some_and(|items| !items.is_empty()),
        "成功任务应有产物"
    );
    assert!(done["finished_at"].as_i64().unwrap_or_default() > 0);

    // 审计可按 trace_id（= task_id）串起来
    let records = jarvis_service::audit::list_by_trace(&ctx.state.pool, &task_id)
        .await
        .expect("读取审计失败");
    let actions: Vec<&str> = records
        .iter()
        .map(|record| record.action.as_str())
        .collect();

    assert!(actions.contains(&"task.created"));
    assert!(actions.contains(&"approval.decided"));
    assert!(
        actions
            .iter()
            .filter(|action| **action == "task.state_changed")
            .count()
            >= 3,
        "应记录多次状态转移，实际 {actions:?}"
    );
    assert_eq!(records[0].actor, device_id);
}

#[tokio::test]
async fn rejection_cancels_and_keeps_scene() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("reject").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let (_, task) = create_task(&ctx, &token, &conversation_id, "key-reject").await;
    let task_id = task["id"].as_str().expect("缺少 task id").to_string();

    let waiting = wait_for_state(&ctx, &token, &task_id, "needs_approval").await;
    let approval_id = waiting["pending_approval"]["id"]
        .as_str()
        .expect("缺少审批 id")
        .to_string();

    let response = decide(&ctx, &token, &task_id, &approval_id, "reject").await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    let canceled = wait_for_state(&ctx, &token, &task_id, "canceled").await;
    assert!(
        canceled["plan"]
            .as_array()
            .is_some_and(|plan| plan.len() == 3),
        "取消后应保留计划现场"
    );
    assert!(canceled.get("pending_approval").is_none(), "不应再有待批项");
}

#[tokio::test]
async fn approval_timeout_fails_task() {
    // 把审批有效期压到 300ms，避免测试等待 10 分钟
    let ctx = common::setup_with(|config| {
        config.approval_ttl_ms = 300;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("timeout").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let (_, task) = create_task(&ctx, &token, &conversation_id, "key-timeout").await;
    let task_id = task["id"].as_str().expect("缺少 task id").to_string();

    let waiting = wait_for_state(&ctx, &token, &task_id, "needs_approval").await;
    let expires_at = waiting["pending_approval"]["expires_at"]
        .as_i64()
        .expect("应有过期时间");

    // 直接以"刚过有效期"的时刻跑一轮扫描：判定是纯时间比较，
    // 不需要真的 sleep 过 300ms，也不怕并行跑测试时的时间抖动。
    jarvis_service::ticker::run_once_at(&ctx.state, expires_at + 1)
        .await
        .expect("扫描失败");

    let body = get_task(&ctx, &token, &task_id).await;
    assert_eq!(body["state"], "failed");
    assert_eq!(body["error"]["code"], "approval_expired");
}

#[tokio::test]
async fn idempotency_key_returns_same_task() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("idem").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let (first_status, first) = create_task(&ctx, &token, &conversation_id, "same-key").await;
    let (second_status, second) = create_task(&ctx, &token, &conversation_id, "same-key").await;

    assert_eq!(first_status, StatusCode::CREATED);
    assert_eq!(second_status, StatusCode::OK, "幂等命中应返回 200");
    assert_eq!(first["id"], second["id"]);
}

#[tokio::test]
async fn task_list_can_filter_by_conversation() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("conv-filter").await;
    let first_conversation = create_conversation(&ctx, &token).await;
    let second_conversation = create_conversation(&ctx, &token).await;

    let (_, first) = create_task(&ctx, &token, &first_conversation, "conv-a-key").await;
    let (_, second) = create_task(&ctx, &token, &second_conversation, "conv-b-key").await;

    let response = ctx
        .call(common::authed_get(
            &format!("/api/tasks?conversation_id={first_conversation}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let page = common::body_json(response).await;
    let items = page["items"].as_array().expect("缺少 items");
    assert_eq!(items.len(), 1, "只应返回该会话的任务");
    assert_eq!(items[0]["id"], first["id"]);
    assert_eq!(
        items[0]["idempotency_key"], "conv-a-key",
        "列表要带幂等键：建议卡靠它把任务对回去"
    );

    // 详情同样要带：重进会话时先拉历史、再拉任务，两处都得能对上。
    let detail = get_task(&ctx, &token, first["id"].as_str().expect("缺少 task id")).await;
    assert_eq!(detail["idempotency_key"], "conv-a-key");
    assert_eq!(detail["conversation_id"], first_conversation);
    assert_ne!(first["id"], second["id"]);
}

#[tokio::test]
async fn duplicate_decision_is_a_conflict() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("dup").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let (_, task) = create_task(&ctx, &token, &conversation_id, "key-dup").await;
    let task_id = task["id"].as_str().expect("缺少 task id").to_string();

    let waiting = wait_for_state(&ctx, &token, &task_id, "needs_approval").await;
    let approval_id = waiting["pending_approval"]["id"]
        .as_str()
        .expect("缺少审批 id")
        .to_string();

    let first = decide(&ctx, &token, &task_id, &approval_id, "approve").await;
    assert_eq!(first.status(), StatusCode::ACCEPTED);

    let second = decide(&ctx, &token, &task_id, &approval_id, "approve").await;
    assert_eq!(second.status(), StatusCode::CONFLICT);
    let body = common::body_json(second).await;
    assert_eq!(body["code"], "conflict");
}

#[tokio::test]
async fn cancel_prevents_further_execution() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("cancel").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    let (_, task) = create_task(&ctx, &token, &conversation_id, "key-cancel").await;
    let task_id = task["id"].as_str().expect("缺少 task id").to_string();

    wait_for_state(&ctx, &token, &task_id, "needs_approval").await;

    let response = ctx
        .call(common::authed_json_post(
            &format!("/api/tasks/{task_id}/cancel"),
            &token,
            &serde_json::json!({}),
        ))
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    assert_eq!(body["state"], "canceled");

    // 已取消的任务不能再审批
    let second = decide(&ctx, &token, &task_id, "apr_missing", "approve").await;
    assert_eq!(second.status(), StatusCode::NOT_FOUND);
}

/// 无归属直聊可以派普通技能任务。
///
/// 空态页「随时开聊」建的就是无归属会话，`@技能` 是它的主路径之一：
/// 没有项目只是拿不到文件读取与代码执行的边界，不该把整条派任务堵死。
#[tokio::test]
async fn unassigned_conversation_can_host_a_skill_task() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("unassigned-task").await;

    let created = ctx
        .post_json("/api/conversations", &token, &serde_json::json!({}))
        .await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let conversation_id = common::body_json(created).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();

    let (status, body) = create_task(&ctx, &token, &conversation_id, "key-unassigned").await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "无归属会话应能派技能任务：{body}"
    );
    assert_eq!(body["conversation_id"], conversation_id.as_str());

    // 清理：任务会起执行器，测试结束前取消，避免占住并发位。
    let task_id = body["id"].as_str().expect("缺少 task id").to_string();
    let _ = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/cancel"),
            &token,
            &serde_json::json!({}),
        )
        .await;
}

/// 编码任务在无归属会话里仍然被拒：它必须有项目边界。
///
/// 拒绝要发生在建任务之前，并给出可执行的下一步（去项目里新建会话），
/// 而不是让 CLI 先跑起来再报一个含糊的错误。
#[tokio::test]
async fn coding_task_in_unassigned_conversation_needs_a_project() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("unassigned-code").await;

    let created = ctx
        .post_json("/api/conversations", &token, &serde_json::json!({}))
        .await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let conversation_id = common::body_json(created).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string();

    let response = ctx
        .post_json(
            "/api/tasks",
            &token,
            &serde_json::json!({
                "conversation_id": conversation_id,
                "type": "skill:code-task",
                "skill": "code-task",
                "input": { "instruction": "修一个空指针" },
                "idempotency_key": "key-unassigned-code",
            }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = common::body_json(response).await;
    let hint = body["hint"].as_str().unwrap_or_default();
    assert!(
        hint.contains("项目"),
        "提示要指向可执行的下一步：{hint}"
    );
}
