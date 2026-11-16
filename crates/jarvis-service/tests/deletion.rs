//! 逻辑删除的集成测试。
//!
//! 四条规则：
//! 1. 删除只写 `deleted_at`：接口视图里消失（404 / 列表不含），库里的行与从属数据全部保留；
//! 2. 删会话会**级联软删**它名下已结束的任务，只挡未结束的任务（409）；已软删的任务不挡路；
//! 3. 未结束的任务拒绝（409）；已结束的任务可删，磁盘文件保留，产物端点随任务一起 404；
//! 4. 删除会释放任务的幂等键，同一个键可以重新创建任务。

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;

fn authed_delete(uri: &str, token: &str) -> Request<Body> {
    Request::delete(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .expect("构造请求失败")
}

async fn create_conversation(ctx: &common::TestContext, token: &str) -> String {
    let project_id = ctx.work_project("deletion").await;
    let response = ctx
        .post_json(
            "/api/conversations",
            token,
            &serde_json::json!({ "title": "待删除会话", "project_id": project_id }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    common::body_json(response).await["id"]
        .as_str()
        .expect("缺少会话 id")
        .to_string()
}

async fn create_task_with_key(
    ctx: &common::TestContext,
    token: &str,
    conversation_id: &str,
    key: &str,
) -> (StatusCode, String) {
    let response = ctx
        .post_json(
            "/api/tasks",
            token,
            &serde_json::json!({
                "conversation_id": conversation_id,
                "type": "skill:trip-plan",
                "skill": "trip-plan",
                "input": { "submit": false },
                "idempotency_key": key,
            }),
        )
        .await;
    let status = response.status();
    let body = common::body_json(response).await;
    let id = body["id"].as_str().unwrap_or_default().to_string();
    (status, id)
}

async fn create_task(ctx: &common::TestContext, token: &str, conversation_id: &str) -> String {
    let key = format!("del-{}", unique());
    let (status, id) = create_task_with_key(ctx, token, conversation_id, &key).await;
    assert_eq!(status, StatusCode::CREATED);
    id
}

/// 不引 uuid：只需要在单次测试内唯一。
fn unique() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default()
}

async fn cancel_task(ctx: &common::TestContext, token: &str, task_id: &str) {
    let response = ctx
        .post_json(
            &format!("/api/tasks/{task_id}/cancel"),
            token,
            &serde_json::json!({}),
        )
        .await;
    assert!(
        response.status() == StatusCode::OK || response.status() == StatusCode::CONFLICT,
        "取消应成功或任务已自行结束，实际 {}",
        response.status()
    );
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

/// 直接插一条指定状态的任务。
///
/// 不用 `POST /api/tasks`：那会真的拉起执行器，状态随时可能被改写，
/// 「哪些状态挡住删除」这张表就没法断言了。
async fn insert_task(ctx: &common::TestContext, conversation_id: &str, state: &str) -> String {
    let id = format!("task_{}", unique());
    let now = now_ms();
    sqlx::query(
        "INSERT INTO tasks (id, conversation_id, type, skill, state, created_at, updated_at) \
         VALUES (?, ?, 'skill:trip-plan', 'trip-plan', ?, ?, ?)",
    )
    .bind(&id)
    .bind(conversation_id)
    .bind(state)
    .bind(now)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入任务失败");
    id
}

/// 会话下还剩多少条"未删除"的任务。
async fn live_tasks(ctx: &common::TestContext, conversation_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM tasks WHERE conversation_id = ? AND deleted_at IS NULL",
    )
    .bind(conversation_id)
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查询任务数失败")
}

async fn task_state(ctx: &common::TestContext, task_id: &str) -> Option<String> {
    sqlx::query_scalar("SELECT state FROM tasks WHERE id = ?")
        .bind(task_id)
        .fetch_optional(&ctx.state.pool)
        .await
        .expect("查询任务状态失败")
}

#[tokio::test]
async fn conversation_is_soft_deleted_with_messages_kept() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-conversation").await;
    let conversation_id = create_conversation(&ctx, &token).await;

    // 先发一条消息，确认删除后消息仍留在库里（只是接口看不到）。
    let response = ctx
        .post_json(
            &format!("/api/conversations/{conversation_id}/messages"),
            &token,
            &serde_json::json!({ "content": "这条消息应留在库里" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let _ = response.into_body().collect().await;

    let response = ctx
        .call(authed_delete(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 接口视图：详情 404，列表不含。
    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND, "会话应已不可见");

    let response = ctx
        .call(common::authed_get("/api/conversations?limit=50", &token))
        .await;
    let body = common::body_json(response).await;
    let items = body["items"].as_array().expect("缺少 items");
    assert!(
        !items
            .iter()
            .any(|item| item["id"] == conversation_id.as_str()),
        "列表里不应再有已删除的会话"
    );

    // 存储层：行还在，deleted_at 有值，消息一条没少。
    let deleted_at: Option<i64> =
        sqlx::query_scalar("SELECT deleted_at FROM conversations WHERE id = ?")
            .bind(&conversation_id)
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询会话失败");
    assert!(deleted_at.is_some(), "会话应被标记删除而不是物理删除");

    let messages: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM messages WHERE conversation_id = ?")
            .bind(&conversation_id)
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询消息失败");
    assert_eq!(messages, 2, "消息应随会话保留在库里");

    let audits: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM audit_log WHERE action = 'conversation.deleted'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询审计失败");
    assert_eq!(audits, 1, "删除应留下一条审计");
}

#[tokio::test]
async fn conversation_delete_cascades_finished_tasks() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-conversation-cascade").await;
    let conversation_id = create_conversation(&ctx, &token).await;
    let first = create_task(&ctx, &token, &conversation_id).await;
    let second = create_task(&ctx, &token, &conversation_id).await;
    cancel_task(&ctx, &token, &first).await;
    cancel_task(&ctx, &token, &second).await;

    let response = ctx
        .call(authed_delete(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    // 断言里带上响应体：并发下偶发 500 时，能直接看到 internal_error 而不是只有状态码。
    let status = response.status();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("读取响应体失败")
        .to_bytes();
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "body={}",
        String::from_utf8_lossy(&bytes)
    );

    // 接口视图：会话与两条任务都不可见。
    for uri in [
        format!("/api/conversations/{conversation_id}"),
        format!("/api/tasks/{first}"),
        format!("/api/tasks/{second}"),
    ] {
        let response = ctx.call(common::authed_get(&uri, &token)).await;
        assert_eq!(response.status(), StatusCode::NOT_FOUND, "{uri} 应已不可见");
    }

    let response = ctx
        .call(common::authed_get("/api/tasks?limit=50", &token))
        .await;
    let body = common::body_json(response).await;
    let items = body["items"].as_array().expect("缺少 items");
    assert!(
        !items
            .iter()
            .any(|item| item["id"] == first.as_str() || item["id"] == second.as_str()),
        "任务列表里不该再有被级联删除的任务"
    );

    // 存储层：任务行保留，deleted_at 有值，幂等键必须释放。
    let remaining: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM tasks WHERE conversation_id = ? AND deleted_at IS NULL",
    )
    .bind(&conversation_id)
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查询任务失败");
    assert_eq!(remaining, 0, "两条任务都应被标记删除");

    for id in [&first, &second] {
        let key: Option<String> =
            sqlx::query_scalar("SELECT idempotency_key FROM tasks WHERE id = ?")
                .bind(id)
                .fetch_one(&ctx.state.pool)
                .await
                .expect("查询幂等键失败");
        assert!(
            key.is_none(),
            "级联删除必须释放幂等键，否则同键永远建不出任务"
        );
    }

    // 审计：级联条数要能事后核对。
    let detail: Option<String> = sqlx::query_scalar(
        "SELECT detail_json FROM audit_log WHERE action = 'conversation.deleted' \
         ORDER BY id DESC LIMIT 1",
    )
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查询审计失败");
    assert!(
        detail.unwrap_or_default().contains("\"cascaded_tasks\":2"),
        "审计应记录级联删除的任务条数"
    );
}

#[tokio::test]
async fn conversation_delete_rejects_unfinished_tasks() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-conversation-unfinished").await;
    let conversation_id = create_conversation(&ctx, &token).await;
    let task_id = create_task(&ctx, &token, &conversation_id).await;

    let response = ctx
        .call(authed_delete(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "conflict");
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("未结束"),
        "hint 要指出是未结束的任务挡住了删除：{body}"
    );

    // 事务回滚干净：会话与任务都还在，谁也没被标记删除。
    let response = ctx
        .call(common::authed_get(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "被拒绝时应回滚，会话仍在"
    );
    let response = ctx
        .call(common::authed_get(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "被拒绝时应回滚，任务仍在"
    );
    assert_eq!(live_tasks(&ctx, &conversation_id).await, 1);

    // 已软删的任务不该继续挡路。
    cancel_task(&ctx, &token, &task_id).await;
    let response = ctx
        .call(authed_delete(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let response = ctx
        .call(authed_delete(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn only_unfinished_states_block_conversation_deletion() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-conversation-states").await;

    // 四个未结束状态：一律拒绝，且原样保留。
    for state in ["queued", "running", "needs_input", "needs_approval"] {
        let conversation_id = create_conversation(&ctx, &token).await;
        let task_id = insert_task(&ctx, &conversation_id, state).await;

        let response = ctx
            .call(authed_delete(
                &format!("/api/conversations/{conversation_id}"),
                &token,
            ))
            .await;
        assert_eq!(
            response.status(),
            StatusCode::CONFLICT,
            "{state} 属未结束，不该允许删会话"
        );
        assert_eq!(
            common::body_json(response).await["code"],
            "conflict",
            "{state}"
        );
        assert_eq!(
            live_tasks(&ctx, &conversation_id).await,
            1,
            "{state}: 被拒绝时任务应原样保留"
        );
        assert_eq!(
            task_state(&ctx, &task_id).await.as_deref(),
            Some(state),
            "{state}: 被拒绝时任务状态不该被改写"
        );
    }

    // 三个终态：允许删除，任务随会话一起消失。
    for state in ["succeeded", "failed", "canceled"] {
        let conversation_id = create_conversation(&ctx, &token).await;
        let task_id = insert_task(&ctx, &conversation_id, state).await;

        let response = ctx
            .call(authed_delete(
                &format!("/api/conversations/{conversation_id}"),
                &token,
            ))
            .await;
        assert_eq!(
            response.status(),
            StatusCode::NO_CONTENT,
            "{state} 属终态，应允许删会话"
        );
        assert_eq!(
            live_tasks(&ctx, &conversation_id).await,
            0,
            "{state}: 任务应被级联删除"
        );
        assert_eq!(
            task_state(&ctx, &task_id).await.as_deref(),
            Some(state),
            "{state}: 级联删除只写标记，不动状态"
        );
    }
}

#[tokio::test]
async fn cascade_releases_idempotency_key() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-conversation-key").await;
    let conversation_id = create_conversation(&ctx, &token).await;
    let key = format!("cascade-{}", unique());

    let (status, task_id) = create_task_with_key(&ctx, &token, &conversation_id, &key).await;
    assert_eq!(status, StatusCode::CREATED);
    cancel_task(&ctx, &token, &task_id).await;

    let response = ctx
        .call(authed_delete(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 级联删除也必须让出幂等键：唯一索引不区分是否已删。
    let another = create_conversation(&ctx, &token).await;
    let (status, new_id) = create_task_with_key(&ctx, &token, &another, &key).await;
    assert_eq!(status, StatusCode::CREATED, "同一个幂等键应可重新使用");
    assert_ne!(new_id, task_id, "应当是新建任务，而不是命中已删除的那条");
}

#[tokio::test]
async fn unfinished_task_is_rejected() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-running-task").await;
    let conversation_id = create_conversation(&ctx, &token).await;
    let task_id = create_task(&ctx, &token, &conversation_id).await;

    // 模拟执行器可能已经在跑；queued / running 都属于"未结束"，都应被拒。
    let response = ctx
        .call(authed_delete(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "conflict");

    let response = ctx
        .call(common::authed_get(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(response.status(), StatusCode::OK, "被拒绝的任务应仍然存在");
}

#[tokio::test]
async fn finished_task_is_soft_deleted_but_rows_and_files_stay() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-finished-task").await;
    let conversation_id = create_conversation(&ctx, &token).await;
    let task_id = create_task(&ctx, &token, &conversation_id).await;
    cancel_task(&ctx, &token, &task_id).await;

    // 造一条步骤与一条产物：删除任务后记录都还在，只是接口看不到。
    sqlx::query(
        "INSERT INTO task_steps (id, task_id, seq, name, state) VALUES (?, ?, 999, '手工步骤', 'done')",
    )
    .bind(format!("step_{task_id}"))
    .bind(&task_id)
    .execute(&ctx.state.pool)
    .await
    .expect("插入步骤记录失败");

    let artifacts_dir = ctx.state.config.artifacts_dir().join(&task_id);
    std::fs::create_dir_all(&artifacts_dir).expect("创建产物目录失败");
    let file = artifacts_dir.join("keep.txt");
    std::fs::write(&file, b"keep me").expect("写产物文件失败");

    let artifact_id = format!("art_{task_id}");
    sqlx::query(
        "INSERT INTO artifacts (id, task_id, kind, path, size, mime, created_at) \
         VALUES (?, ?, 'run_log', ?, ?, 'text/plain', ?)",
    )
    .bind(&artifact_id)
    .bind(&task_id)
    .bind(format!("{task_id}/keep.txt"))
    .bind(8_i64)
    .bind(1_i64)
    .execute(&ctx.state.pool)
    .await
    .expect("插入产物记录失败");

    let response = ctx
        .call(authed_delete(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let response = ctx
        .call(common::authed_get(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    // 存储层：任务、步骤、产物记录都还在，只是 deleted_at 非空。
    let deleted_at: Option<i64> = sqlx::query_scalar("SELECT deleted_at FROM tasks WHERE id = ?")
        .bind(&task_id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询任务失败");
    assert!(deleted_at.is_some(), "任务应被标记删除而不是物理删除");

    let steps: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM task_steps WHERE task_id = ?")
        .bind(&task_id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询步骤失败");
    assert!(steps > 0, "步骤记录应随任务保留");

    let artifacts: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM artifacts WHERE task_id = ?")
        .bind(&task_id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询产物失败");
    assert_eq!(artifacts, 1, "产物记录应随任务保留");

    assert!(file.exists(), "磁盘上的产物文件按约定保留");

    // 产物端点跟随任务一起不可见：不能绕开任务直接拿已删任务的文件。
    let response = ctx
        .call(common::authed_get(
            &format!("/api/artifacts/{artifact_id}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn deleting_task_releases_idempotency_key() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-idempotency").await;
    let conversation_id = create_conversation(&ctx, &token).await;
    let key = format!("reuse-{}", unique());

    let (status, task_id) = create_task_with_key(&ctx, &token, &conversation_id, &key).await;
    assert_eq!(status, StatusCode::CREATED);

    cancel_task(&ctx, &token, &task_id).await;
    let response = ctx
        .call(authed_delete(&format!("/api/tasks/{task_id}"), &token))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 唯一索引不区分是否已删：软删除必须把键让出来，否则同名任务永远建不出来。
    let (status, new_id) = create_task_with_key(&ctx, &token, &conversation_id, &key).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_ne!(new_id, task_id, "应当是新建任务，而不是命中已删除的那条");
}

#[tokio::test]
async fn deleting_twice_or_unknown_ids_returns_not_found() {
    let ctx = common::setup().await;
    let (_, token) = ctx.pair_and_login("delete-missing").await;

    for uri in ["/api/conversations/conv_missing", "/api/tasks/task_missing"] {
        let response = ctx.call(authed_delete(uri, &token)).await;
        assert_eq!(response.status(), StatusCode::NOT_FOUND, "{uri}");
    }

    // 重复删除同一会话：第二次按"已不存在"处理。
    let conversation_id = create_conversation(&ctx, &token).await;
    let first = ctx
        .call(authed_delete(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(first.status(), StatusCode::NO_CONTENT);

    let second = ctx
        .call(authed_delete(
            &format!("/api/conversations/{conversation_id}"),
            &token,
        ))
        .await;
    assert_eq!(second.status(), StatusCode::NOT_FOUND);
}
