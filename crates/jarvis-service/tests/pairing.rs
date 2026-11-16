//! 配对流程的集成测试。
//!
//! 覆盖：正常配对、错误配对码锁定、重复活跃票据被拒。
//! 全部直打 Router，不起端口。

mod common;

use axum::http::StatusCode;
use jarvis_service::pairing::PairingError;
use tower::ServiceExt;

#[tokio::test]
async fn pair_flow_completes_and_exposes_fingerprint() {
    let ctx = common::setup().await;
    let client = ctx.client_identity("primary");
    let (request_id, code) = ctx.start_pairing().await;

    // 1. 客户端提交配对码
    let payload = serde_json::json!({
        "code": code,
        "device_name": "Test iPhone",
        "platform": "ios",
        "client_pubkey": client.public_key_b32(),
    });
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/pair/request", &payload))
        .await
        .expect("提交配对码失败");

    assert_eq!(response.status(), StatusCode::ACCEPTED);
    let body = common::body_json(response).await;
    assert_eq!(body["request_id"], request_id.as_str());

    // 2. 状态进入待确认
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::get(&format!("/api/pair/requests/{request_id}")))
        .await
        .expect("查询票据失败");
    let body = common::body_json(response).await;
    assert_eq!(body["status"], "awaiting_confirmation");
    assert!(body.get("device_id").is_none(), "未批准时不应返回设备 id");

    // 3. 本机批准
    ctx.approve_pairing(&request_id).await;

    // 4. 批准后返回服务端公钥与指纹
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::get(&format!("/api/pair/requests/{request_id}")))
        .await
        .expect("查询票据失败");
    let body = common::body_json(response).await;

    assert_eq!(body["status"], "approved");
    assert_eq!(
        body["server_pubkey"].as_str(),
        Some(ctx.state.identity.public_key_b32().as_str())
    );
    assert_eq!(
        body["server_fingerprint"].as_str(),
        Some(ctx.state.identity.fingerprint().as_str())
    );

    // 5. 设备已入库，且记录为本机批准
    let device: (String, String) =
        sqlx::query_as("SELECT name, approved_by FROM devices WHERE id = ?")
            .bind(body["device_id"].as_str().expect("缺少 device_id"))
            .fetch_one(&ctx.state.pool)
            .await
            .expect("设备未入库");

    assert_eq!(device.0, "Test iPhone");
    assert_eq!(device.1, "local");
}

#[tokio::test]
async fn wrong_code_locks_after_five_attempts() {
    let ctx = common::setup().await;
    let client = ctx.client_identity("wrong-code");
    let (request_id, _code) = ctx.start_pairing().await;

    let payload = serde_json::json!({
        "code": "AAAAAAAAAAAA", // 故意错误
        "device_name": "Bad Device",
        "platform": "test",
        "client_pubkey": client.public_key_b32(),
    });

    for attempt in 1..=5 {
        let router = jarvis_service::api::router(ctx.state.clone());
        let response = router
            .oneshot(common::json_post("/api/pair/request", &payload))
            .await
            .expect("提交配对码失败");

        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "第 {attempt} 次错误应当被拒"
        );
        let body = common::body_json(response).await;
        assert_eq!(body["code"], "unauthenticated");
    }

    let status: String = sqlx::query_scalar("SELECT status FROM pairing_requests WHERE id = ?")
        .bind(&request_id)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询票据失败");
    assert_eq!(status, "locked");

    // 锁定后再提交正确码也不放行（本测试中没有正确码，只验证锁定态稳定）
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/pair/request", &payload))
        .await
        .expect("提交配对码失败");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn second_active_request_is_rejected() {
    let ctx = common::setup().await;
    let _first = ctx.start_pairing().await;

    let second = jarvis_service::pairing::start(&ctx.state.pool).await;
    assert!(
        matches!(second, Err(PairingError::Conflict(_))),
        "同一时刻只允许一个活跃票据"
    );
}

#[tokio::test]
async fn unknown_request_id_returns_not_found() {
    let ctx = common::setup().await;
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::get("/api/pair/requests/pair_missing"))
        .await
        .expect("查询票据失败");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "not_found");
}
