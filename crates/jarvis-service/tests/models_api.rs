//! 模型配置接口的集成测试。
//!
//! 覆盖的是"配错一次就会让人以为功能坏了"的那几条线：
//! - 密钥永不出现在响应里（只给来源与末四位）；
//! - 删除当前生效项会回落到默认档，不留悬空引用；
//! - 切换之后运行期真的换了（`active_model` 立刻反映）；
//! - 测试连接能区分"密钥错"和"地址错"，而不是一律报"失败"。

mod common;

use axum::http::StatusCode;
use axum::routing::post;
use axum::Router;
use common::{body_json, setup, TestContext};

/// 假上游：`Bearer bad` 回 401，模型名 `nope` 回 404（带 model 字样），其余成功。
fn upstream_router() -> Router {
    Router::new().route(
        "/v1/chat/completions",
        post(
            |headers: axum::http::HeaderMap, body: axum::body::Bytes| async move {
                let authorized = headers
                    .get("authorization")
                    .and_then(|value| value.to_str().ok())
                    .map(|value| value == "Bearer sk-good")
                    .unwrap_or(false);
                if !authorized {
                    return (
                        StatusCode::UNAUTHORIZED,
                        [("content-type", "application/json")],
                        r#"{"error":{"message":"invalid api key"}}"#.to_string(),
                    );
                }

                let model = serde_json::from_slice::<serde_json::Value>(&body)
                    .ok()
                    .and_then(|value| {
                        value
                            .get("model")
                            .and_then(|m| m.as_str())
                            .map(str::to_string)
                    })
                    .unwrap_or_default();
                if model == "nope" {
                    return (
                        StatusCode::NOT_FOUND,
                        [("content-type", "application/json")],
                        r#"{"error":{"message":"model not found"}}"#.to_string(),
                    );
                }

                (
                    StatusCode::OK,
                    [("content-type", "application/json")],
                    r#"{"choices":[{"message":{"content":"pong"}}]}"#.to_string(),
                )
            },
        ),
    )
}

/// 起一个真端口，返回 base_url。
async fn start_upstream() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定假上游失败");
    let addr = listener.local_addr().expect("取端口失败");
    tokio::spawn(async move {
        axum::serve(listener, upstream_router()).await.ok();
    });
    format!("http://{addr}")
}

/// 建一条配置，返回它的 id。
async fn create_profile(ctx: &TestContext, token: &str, base_url: &str, model: &str) -> String {
    let response = ctx
        .post_json(
            "/api/models",
            token,
            &serde_json::json!({
                "name": "测试配置",
                "base_url": base_url,
                "api_path": "/v1",
                "model": model,
                "api_key": "sk-good",
            }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "新建配置应当成功");
    let body = body_json(response).await;
    body["model"]["id"]
        .as_str()
        .expect("应返回新配置的 id")
        .to_string()
}

#[tokio::test]
async fn legacy_deployment_lists_only_the_builtin_profile() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-list").await;

    let response = ctx.get_json("/api/models", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = body_json(response).await;

    assert_eq!(body["active_id"], "default");
    let models = body["models"].as_array().expect("应返回列表");
    assert_eq!(models.len(), 1, "老部署只有默认档");
    assert_eq!(models[0]["id"], "default");
    assert_eq!(models[0]["builtin"], true);
    assert_eq!(models[0]["active"], true);
    assert_eq!(
        models[0]["model_name"], "",
        "老配置没有 model_name：按空串返回，界面回退模型ID"
    );
    assert_eq!(
        models[0]["context_window"], 1_000_000u64,
        "默认档是 deepseek-v4.1-flash，上下文窗口按 1M 下发"
    );
}

#[tokio::test]
async fn context_window_round_trips_and_rejects_out_of_range() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-context").await;

    // 新增配置不填时给保守的 128K，客户端拿它算占比不会一路爆表。
    let id = create_profile(&ctx, &token, "https://api.example.com", "deepseek-chat").await;
    let list = body_json(ctx.get_json("/api/models", &token).await).await;
    let created = list["models"]
        .as_array()
        .expect("应返回列表")
        .iter()
        .find(|item| item["id"] == id.as_str())
        .expect("新建的配置应出现在列表里")
        .clone();
    assert_eq!(created["context_window"], 128_000u64);

    // 改成实际窗口后视图要跟着变。
    let updated = body_json(
        ctx.patch_json(
            &format!("/api/models/{id}"),
            &token,
            &serde_json::json!({ "context_window": 200_000 }),
        )
        .await,
    )
    .await;
    assert_eq!(updated["model"]["context_window"], 200_000u64);

    // 太小（手滑少写几个 0）与太大都要挡住。
    for bad in [0u64, 999u64, 100_000_001u64] {
        let response = ctx
            .patch_json(
                &format!("/api/models/{id}"),
                &token,
                &serde_json::json!({ "context_window": bad }),
            )
            .await;
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "context_window={bad} 应当被拒绝"
        );
    }
}

#[tokio::test]
async fn created_profile_never_echoes_the_key() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-key").await;

    let id = create_profile(&ctx, &token, "https://api.example.com", "deepseek-chat").await;

    let response = ctx.get_json("/api/models", &token).await;
    let raw = response.into_body();
    let bytes = axum::body::to_bytes(raw, usize::MAX)
        .await
        .expect("读取响应体失败");
    let text = String::from_utf8_lossy(&bytes).to_string();

    assert!(
        !text.contains("sk-good"),
        "完整密钥绝不能出现在响应里：{text}"
    );
    assert!(text.contains("…good"), "只给末四位提示：{text}");

    let body: serde_json::Value = serde_json::from_str(&text).expect("响应不是合法 JSON");
    let created = body["models"]
        .as_array()
        .expect("应返回列表")
        .iter()
        .find(|item| item["id"] == id.as_str())
        .expect("新建的配置应出现在列表里");
    assert_eq!(created["api_key_source"], "secrets");
    assert_eq!(created["available"], true, "填了密钥就该可用");
}

#[tokio::test]
async fn activating_a_profile_switches_the_runtime_model() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-activate").await;
    let id = create_profile(&ctx, &token, "https://api.example.com", "deepseek-chat").await;

    let response = ctx
        .post_json(
            &format!("/api/models/{id}/activate"),
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK, "设为当前应当成功");
    let body = body_json(response).await;
    assert_eq!(body["active_id"], id.as_str());
    assert_eq!(body["available"], true, "有密钥且地址非空，应当可用");

    let active = ctx.state.active_model();
    assert_eq!(active.id, id);
    assert_eq!(active.model, "deepseek-chat");
    assert!(
        active.available(),
        "切换之后运行期必须真的拿得到客户端：{:?}",
        active.reason
    );
    assert!(ctx.state.chat_model().is_some());
    assert!(ctx.state.completion_model().is_some());
}

#[tokio::test]
async fn deleting_the_active_profile_falls_back_to_default() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-delete").await;
    let id = create_profile(&ctx, &token, "https://api.example.com", "m").await;

    ctx.post_json(
        &format!("/api/models/{id}/activate"),
        &token,
        &serde_json::json!({}),
    )
    .await;

    let response = ctx.delete(&format!("/api/models/{id}"), &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = body_json(response).await;
    assert_eq!(
        body["active_id"], "default",
        "删掉当前项必须回落默认档，不能留悬空 active"
    );
    assert_eq!(ctx.state.active_model().id, "default");

    let list = body_json(ctx.get_json("/api/models", &token).await).await;
    assert_eq!(
        list["models"].as_array().expect("应返回列表").len(),
        1,
        "删完之后只剩默认档"
    );
}

#[tokio::test]
async fn builtin_profile_cannot_be_deleted() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-builtin").await;

    let response = ctx.delete("/api/models/default", &token).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = body_json(response).await;
    assert_eq!(body["code"], "invalid_request");
    assert!(
        body["hint"]
            .as_str()
            .unwrap_or_default()
            .contains("不能删除"),
        "提示要说清为什么删不掉：{body}"
    );
}

#[tokio::test]
async fn unknown_profile_is_not_found() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-404").await;

    let response = ctx
        .post_json(
            "/api/models/model_missing/activate",
            &token,
            &serde_json::json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert_eq!(body_json(response).await["code"], "not_found");
}

#[tokio::test]
async fn update_without_key_keeps_the_saved_one() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-update").await;
    let id = create_profile(&ctx, &token, "https://api.example.com", "old-model").await;

    let response = ctx
        .patch_json(
            &format!("/api/models/{id}"),
            &token,
            &serde_json::json!({ "name": "改名了", "model": "new-model" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = body_json(response).await;
    assert_eq!(body["model"]["name"], "改名了");
    assert_eq!(body["model"]["model"], "new-model");
    assert_eq!(
        body["model"]["api_key_source"], "secrets",
        "不传 api_key 时不能把已有密钥丢掉"
    );
}

#[tokio::test]
async fn model_name_is_stored_apart_from_the_model_id() {
    let ctx = common::setup_with(|config| {
        config.source_path = Some(config.data_dir.join("config.json"));
    })
    .await;
    let (_, token) = ctx.pair_and_login("models-name").await;

    let response = ctx
        .post_json(
            "/api/models",
            &token,
            &serde_json::json!({
                "name": "DeepSeek",
                "model_name": "DeepSeek V3.2 Flash",
                "base_url": "https://api.example.com",
                "api_path": "/v1",
                "model": "deepseek-flash",
                "api_key": "sk-good",
            }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = body_json(response).await;
    assert_eq!(body["model"]["name"], "DeepSeek", "配置名保持原义");
    assert_eq!(body["model"]["model_name"], "DeepSeek V3.2 Flash");
    assert_eq!(
        body["model"]["model"], "deepseek-flash",
        "模型名与模型ID是两个字段，不能互相覆盖"
    );
    let id = body["model"]["id"]
        .as_str()
        .expect("应返回新配置的 id")
        .to_string();

    // 落盘：重启后两个字段都要还在。
    let path = ctx
        .state
        .config
        .source_path()
        .expect("应记录来源文件")
        .to_path_buf();
    let raw = std::fs::read_to_string(&path).expect("配置文件应已写入");
    let parsed: serde_json::Value = serde_json::from_str(&raw).expect("写回的不是合法 JSON");
    let stored = parsed["llm"]["profiles"]
        .as_array()
        .expect("llm.profiles 应被写入")
        .iter()
        .find(|item| item["id"] == id.as_str())
        .expect("新建的配置必须落盘");
    assert_eq!(stored["model_name"], "DeepSeek V3.2 Flash");
    assert_eq!(stored["model"], "deepseek-flash");

    // 只改模型名时模型ID原样保留。
    let body = body_json(
        ctx.patch_json(
            &format!("/api/models/{id}"),
            &token,
            &serde_json::json!({ "model_name": "换了个名字" }),
        )
        .await,
    )
    .await;
    assert_eq!(body["model"]["model_name"], "换了个名字");
    assert_eq!(body["model"]["model"], "deepseek-flash");

    // 显式传空串即清空，界面回退模型ID。
    let body = body_json(
        ctx.patch_json(
            &format!("/api/models/{id}"),
            &token,
            &serde_json::json!({ "model_name": "" }),
        )
        .await,
    )
    .await;
    assert_eq!(body["model"]["model_name"], "", "空串表示清空");
}

#[tokio::test]
async fn invalid_base_url_is_rejected_with_a_readable_hint() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-invalid").await;

    let response = ctx
        .post_json(
            "/api/models",
            token.as_str(),
            &serde_json::json!({
                "name": "x",
                "base_url": "api.example.com/v1",
                "model": "m",
                "api_key": "sk-good",
            }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = body_json(response).await;
    assert!(
        body["hint"].as_str().unwrap_or_default().contains("http"),
        "要说清地址该怎么填：{body}"
    );
}

#[tokio::test]
async fn test_connection_reports_success_and_failure_reasons() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-probe").await;
    let base = start_upstream().await;

    let ok = body_json(
        ctx.post_json(
            "/api/models/test",
            &token,
            &serde_json::json!({
                "base_url": base,
                "api_path": "/v1",
                "model": "deepseek-chat",
                "api_key": "sk-good",
            }),
        )
        .await,
    )
    .await;
    assert_eq!(ok["ok"], true, "假上游应答正常时应当成功：{ok}");
    assert!(ok["latency_ms"].is_number(), "成功要给往返耗时：{ok}");

    let bad_key = body_json(
        ctx.post_json(
            "/api/models/test",
            &token,
            &serde_json::json!({
                "base_url": base,
                "api_path": "/v1",
                "model": "deepseek-chat",
                "api_key": "sk-wrong",
            }),
        )
        .await,
    )
    .await;
    assert_eq!(bad_key["ok"], false);
    assert_eq!(
        bad_key["error_code"], "auth_failed",
        "401 要归因到密钥：{bad_key}"
    );
    assert_eq!(bad_key["status"], 401);

    let no_model = body_json(
        ctx.post_json(
            "/api/models/test",
            &token,
            &serde_json::json!({
                "base_url": base,
                "api_path": "/v1",
                "model": "nope",
                "api_key": "sk-good",
            }),
        )
        .await,
    )
    .await;
    assert_eq!(no_model["ok"], false);
    assert_eq!(
        no_model["error_code"], "model_not_found",
        "404 且响应提到 model 时要归因到模型名：{no_model}"
    );
}

#[tokio::test]
async fn probe_reuses_the_saved_key_when_none_is_typed() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-probe-saved").await;
    let base = start_upstream().await;
    let id = create_profile(&ctx, &token, &base, "deepseek-chat").await;

    let body = body_json(
        ctx.post_json(
            "/api/models/test",
            &token,
            &serde_json::json!({ "id": id, "model": "deepseek-chat" }),
        )
        .await,
    )
    .await;

    assert_eq!(body["ok"], true, "只给 id 时就该复用已保存的密钥：{body}");
}

#[tokio::test]
async fn profiles_are_persisted_to_the_config_file() {
    // 让配置有来源文件：客户端改完之后重启服务不能丢。
    let ctx = common::setup_with(|config| {
        config.source_path = Some(config.data_dir.join("config.json"));
    })
    .await;
    let (_, token) = ctx.pair_and_login("models-persist").await;
    let id = create_profile(&ctx, &token, "https://api.example.com", "persisted-model").await;

    let path = ctx
        .state
        .config
        .source_path()
        .expect("应记录来源文件")
        .to_path_buf();
    let raw = std::fs::read_to_string(&path).expect("配置文件应已写入");
    let parsed: serde_json::Value = serde_json::from_str(&raw).expect("写回的不是合法 JSON");

    let profiles = parsed["llm"]["profiles"]
        .as_array()
        .expect("llm.profiles 应被写入");
    assert!(
        profiles.iter().any(|item| item["id"] == id.as_str()),
        "新建的配置必须落盘，否则重启就没了：{parsed}"
    );
    assert!(!raw.contains("sk-good"), "配置文件里绝不能出现密钥：{raw}");
}

#[tokio::test]
async fn reasoning_capability_round_trips_through_the_api() {
    let ctx = setup().await;
    let (_, token) = ctx.pair_and_login("models-reasoning").await;

    // 默认档来自配置文件主节：实测支持该参数，所以默认是 true。
    let body = body_json(ctx.get_json("/api/models", &token).await).await;
    assert_eq!(
        body["models"][0]["reasoning"], true,
        "默认档必须默认声明支持推理等级，否则输入栏那一行永远出不来"
    );

    // 新增的第三方配置默认不声明：多数网关不认这个字段。
    let created = body_json(
        ctx.post_json(
            "/api/models",
            &token,
            &serde_json::json!({
                "name": "第三方",
                "base_url": "https://api.example.com",
                "api_path": "/v1",
                "model": "m",
                "api_key": "sk-good",
            }),
        )
        .await,
    )
    .await;
    let id = created["model"]["id"].as_str().expect("应有 id").to_string();
    assert_eq!(created["model"]["reasoning"], false);

    // 勾上之后视图与配置都要跟着变。
    let updated = body_json(
        ctx.patch_json(
            &format!("/api/models/{id}"),
            &token,
            &serde_json::json!({ "reasoning": true }),
        )
        .await,
    )
    .await;
    assert_eq!(updated["model"]["reasoning"], true);

    let installed = ctx
        .state
        .models
        .profiles()
        .into_iter()
        .find(|profile| profile.id == id);
    assert_eq!(
        installed.map(|profile| profile.reasoning),
        Some(true),
        "能力位必须进运行期快照，payload 守门读的是它"
    );
}
