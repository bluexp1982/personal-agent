//! 登录与鉴权的集成测试。
//!
//! 覆盖：正常登录、挑战重放被拒、错误签名被拒、缺令牌 401、吊销即时生效。

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use jarvis_service::identity::{Identity, B32};
use tower::ServiceExt;

/// 完整登录，返回会话令牌。
async fn login(ctx: &common::TestContext, device_id: &str, client: &Identity) -> String {
    let payload = serde_json::json!({ "device_id": device_id });
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/challenge", &payload))
        .await
        .expect("获取挑战失败");
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    let challenge = body["challenge"]
        .as_str()
        .expect("缺少 challenge")
        .to_string();

    // 签名对象是挑战串解码后的原始字节，不是字符串本身。
    let message = base32::decode(B32, &challenge).expect("挑战不是 base32");
    let signature = base32::encode(B32, &client.sign(&message));

    let payload = serde_json::json!({
        "device_id": device_id,
        "challenge": challenge,
        "signature": signature,
    });
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/verify", &payload))
        .await
        .expect("提交签名失败");
    assert_eq!(response.status(), StatusCode::OK);

    let body = common::body_json(response).await;
    body["token"].as_str().expect("缺少 token").to_string()
}

#[tokio::test]
async fn login_succeeds_and_returns_device_info() {
    let ctx = common::setup().await;
    let client = ctx.client_identity("me");
    let device_id = ctx.pair_device(&client, "My Mac").await;

    let token = login(&ctx, &device_id, &client).await;

    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::authed_get("/api/auth/me", &token))
        .await
        .expect("查询设备信息失败");

    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["device_id"], device_id.as_str());
    assert_eq!(body["name"], "My Mac");
    assert!(body["paired_at"].as_i64().unwrap_or_default() > 0);
}

#[tokio::test]
async fn challenge_cannot_be_replayed() {
    let ctx = common::setup().await;
    let client = ctx.client_identity("replay");
    let device_id = ctx.pair_device(&client, "Replay Device").await;

    // 取一次挑战并签名
    let payload = serde_json::json!({ "device_id": device_id });
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/challenge", &payload))
        .await
        .expect("获取挑战失败");
    let body = common::body_json(response).await;
    let challenge = body["challenge"]
        .as_str()
        .expect("缺少 challenge")
        .to_string();

    let message = base32::decode(B32, &challenge).expect("挑战不是 base32");
    let signature = base32::encode(B32, &client.sign(&message));
    let payload = serde_json::json!({
        "device_id": device_id,
        "challenge": challenge,
        "signature": signature,
    });

    // 第一次成功
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/verify", &payload))
        .await
        .expect("提交签名失败");
    assert_eq!(response.status(), StatusCode::OK);

    // 同一挑战第二次必须被拒
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/verify", &payload))
        .await
        .expect("提交签名失败");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    let body = common::body_json(response).await;
    assert_eq!(body["code"], "unauthenticated");
    assert_eq!(body["retryable"], false);
}

#[tokio::test]
async fn bad_signature_is_rejected() {
    let ctx = common::setup().await;
    let client = ctx.client_identity("bad-sig");
    let device_id = ctx.pair_device(&client, "Bad Sig").await;

    let payload = serde_json::json!({ "device_id": device_id });
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/challenge", &payload))
        .await
        .expect("获取挑战失败");
    let body = common::body_json(response).await;
    let challenge = body["challenge"].as_str().expect("缺少 challenge");

    // 用另一个身份签名：公钥对不上
    let impostor = ctx.client_identity("impostor");
    let message = base32::decode(B32, challenge).expect("挑战不是 base32");
    let signature = base32::encode(B32, &impostor.sign(&message));

    let payload = serde_json::json!({
        "device_id": device_id,
        "challenge": challenge,
        "signature": signature,
    });
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/verify", &payload))
        .await
        .expect("提交签名失败");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn protected_route_requires_bearer_token() {
    let ctx = common::setup().await;
    let router = jarvis_service::api::router(ctx.state.clone());

    let response = router
        .oneshot(
            Request::get("/api/auth/me")
                .body(Body::empty())
                .expect("构造请求失败"),
        )
        .await
        .expect("请求失败");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body = common::body_json(response).await;
    assert_eq!(body["code"], "unauthenticated");
    assert!(body["hint"].as_str().is_some(), "错误体必须带 hint");
}

#[tokio::test]
async fn revocation_takes_effect_immediately() {
    let ctx = common::setup().await;
    let client = ctx.client_identity("revoke");
    let device_id = ctx.pair_device(&client, "To Be Revoked").await;
    let token = login(&ctx, &device_id, &client).await;

    // 吊销前可用
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::authed_get("/api/auth/me", &token))
        .await
        .expect("查询设备信息失败");
    assert_eq!(response.status(), StatusCode::OK);

    // 管理面吊销
    let router = jarvis_service::admin::router(ctx.state.clone());
    let response = router
        .oneshot(
            Request::post(format!("/admin/devices/{device_id}/revoke"))
                .body(Body::empty())
                .expect("构造请求失败"),
        )
        .await
        .expect("吊销失败");
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 旧令牌立刻失效
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::authed_get("/api/auth/me", &token))
        .await
        .expect("查询设备信息失败");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    // 吊销后也无法再取挑战
    let payload = serde_json::json!({ "device_id": device_id });
    let router = jarvis_service::api::router(ctx.state.clone());
    let response = router
        .oneshot(common::json_post("/api/auth/challenge", &payload))
        .await
        .expect("获取挑战失败");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn revoke_all_takes_effect_immediately_and_is_idempotent() {
    let ctx = common::setup().await;
    let first = ctx.client_identity("reset-1");
    let second = ctx.client_identity("reset-2");
    let first_id = ctx.pair_device(&first, "Reset One").await;
    let second_id = ctx.pair_device(&second, "Reset Two").await;
    let first_token = login(&ctx, &first_id, &first).await;
    let second_token = login(&ctx, &second_id, &second).await;

    let router = jarvis_service::admin::router(ctx.state.clone());
    let response = router
        .oneshot(
            Request::post("/admin/devices/revoke-all")
                .body(Body::empty())
                .expect("构造请求失败"),
        )
        .await
        .expect("全部吊销失败");
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["revoked"], 2);

    // 两台设备的令牌同时失效，不会出现"吊销了一台、另一台还能用"。
    for token in [&first_token, &second_token] {
        let router = jarvis_service::api::router(ctx.state.clone());
        let response = router
            .oneshot(common::authed_get("/api/auth/me", token))
            .await
            .expect("查询设备信息失败");
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    // 幂等：已经没有活跃设备，再调一次返回 0 而不是报错。
    let router = jarvis_service::admin::router(ctx.state.clone());
    let response = router
        .oneshot(
            Request::post("/admin/devices/revoke-all")
                .body(Body::empty())
                .expect("构造请求失败"),
        )
        .await
        .expect("重复吊销失败");
    assert_eq!(response.status(), StatusCode::OK);
    let body = common::body_json(response).await;
    assert_eq!(body["revoked"], 0);
}
