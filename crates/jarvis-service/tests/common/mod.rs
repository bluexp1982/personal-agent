//! 集成测试公用脚手架。
//!
//! 每个测试用独立的 `tempfile` 目录，避免并发写同一个 SQLite 文件。
//! 直接构造 `AppState` 并对 Router 调 `oneshot`，不起真实端口。

#![allow(dead_code, unreachable_pub)]

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::response::Response;
use http_body_util::BodyExt;
use std::sync::Arc;

use jarvis_service::config::Config;
use jarvis_service::identity::Identity;
use jarvis_service::identity::B32;
use jarvis_service::state::AppState;
use jarvis_service::{db, pairing};
use tower::ServiceExt;

#[derive(Debug)]
pub struct TestContext {
    pub state: AppState,
    pub dir: tempfile::TempDir,
}

impl TestContext {
    /// 客户端身份密钥放在测试目录里，与服务端身份分开。
    pub fn client_identity(&self, tag: &str) -> Identity {
        let path = self.dir.path().join(format!("client-{tag}.key"));
        Identity::load_or_create(&path).expect("创建客户端身份失败")
    }

    /// 建（或复用）一个 普通项目，返回 id。
    ///
    /// 会话必须挂在项目下，测试里几乎每个用例都要先有一个；同一个 `tag`
    /// 复用同一个项目，避免同一个测试建两个会话时撞上"目录已被占用"。
    pub async fn work_project(&self, tag: &str) -> String {
        let existing =
            jarvis_service::project::list(&self.state.pool, Some(protocol::ProjectMode::Work))
                .await
                .expect("列出项目失败");
        if let Some(project) = existing.into_iter().find(|project| project.name == tag) {
            return project.id;
        }

        let path = self.dir.path().join(format!("ws-{tag}"));
        std::fs::create_dir_all(&path).expect("创建项目目录失败");
        jarvis_service::project::create(
            &self.state.pool,
            &self.state.config,
            &protocol::ProjectCreate {
                name: Some(tag.to_string()),
                mode: protocol::ProjectMode::Work,
                path: path.to_string_lossy().to_string(),
                init_git: false,
            },
        )
        .await
        .expect("创建项目失败")
        .id
    }

    pub async fn start_pairing(&self) -> (String, String) {
        pairing::start(&self.state.pool)
            .await
            .expect("生成配对码失败")
    }

    /// 走完整个配对流程并返回 device_id，供鉴权测试复用。
    pub async fn pair_device(&self, client: &Identity, name: &str) -> String {
        let (request_id, code) = self.start_pairing().await;

        let payload = serde_json::json!({
            "code": code,
            "device_name": name,
            "platform": "test",
            "client_pubkey": client.public_key_b32(),
        });
        let router = jarvis_service::api::router(self.state.clone());
        let response = router
            .oneshot(json_post("/api/pair/request", &payload))
            .await
            .expect("提交配对码失败");
        assert_eq!(response.status(), StatusCode::ACCEPTED);

        self.approve_pairing(&request_id).await;

        let router = jarvis_service::api::router(self.state.clone());
        let response = router
            .oneshot(get(&format!("/api/pair/requests/{request_id}")))
            .await
            .expect("查询票据失败");
        let body = body_json(response).await;
        body["device_id"]
            .as_str()
            .expect("批准后应返回 device_id")
            .to_string()
    }

    /// 配对并登录，返回 `(device_id, token)`。
    pub async fn pair_and_login(&self, tag: &str) -> (String, String) {
        let client = self.client_identity(tag);
        let device_id = self.pair_device(&client, tag).await;
        let token = self.login(&device_id, &client).await;
        (device_id, token)
    }

    /// challenge → 签名 → 换令牌。
    pub async fn login(&self, device_id: &str, client: &Identity) -> String {
        let payload = serde_json::json!({ "device_id": device_id });
        let response = self.call(json_post("/api/auth/challenge", &payload)).await;
        assert_eq!(response.status(), StatusCode::OK, "获取挑战失败");

        let body = body_json(response).await;
        let challenge = body["challenge"]
            .as_str()
            .expect("缺少 challenge")
            .to_string();

        // 签名对象是挑战串解码后的原始字节。
        let message = base32::decode(B32, &challenge).expect("挑战不是 base32");
        let signature = base32::encode(B32, &client.sign(&message));

        let payload = serde_json::json!({
            "device_id": device_id,
            "challenge": challenge,
            "signature": signature,
        });
        let response = self.call(json_post("/api/auth/verify", &payload)).await;
        assert_eq!(response.status(), StatusCode::OK, "登录失败");

        let body = body_json(response).await;
        body["token"].as_str().expect("缺少 token").to_string()
    }

    /// 对 `/api/*` 发一次请求。
    /// 接一个真的预览站（绑回环随机端口）到 `state` 上。
    ///
    /// 文件预览端点需要 `state.web_preview` 才能把相对路径换成可加载地址；
    /// 生产里由 `app::run` 装配，测试里得自己起一个。
    pub async fn start_preview(&mut self) -> Arc<jarvis_service::web_preview::WebPreview> {
        let preview = jarvis_service::web_preview::WebPreview::start(
            self.state.pool.clone(),
            self.state.config.clone(),
        )
        .await
        .expect("预览站启动失败");
        self.state.web_preview = Some(preview.clone());
        preview
    }

    pub async fn call(&self, request: Request<Body>) -> Response {
        jarvis_service::api::router(self.state.clone())
            .oneshot(request)
            .await
            .expect("请求失败")
    }

    /// 带令牌的 JSON POST。
    pub async fn post_json(&self, uri: &str, token: &str, payload: &serde_json::Value) -> Response {
        self.call(authed_json_post(uri, token, payload)).await
    }

    /// 带令牌的 JSON PATCH。
    pub async fn patch_json(
        &self,
        uri: &str,
        token: &str,
        payload: &serde_json::Value,
    ) -> Response {
        self.call(authed_json_patch(uri, token, payload)).await
    }

    /// 带令牌的 DELETE。
    pub async fn delete(&self, uri: &str, token: &str) -> Response {
        self.call(authed_delete(uri, token)).await
    }

    /// 带令牌的 GET。
    pub async fn get_json(&self, uri: &str, token: &str) -> Response {
        self.call(authed_get(uri, token)).await
    }

    pub async fn approve_pairing(&self, request_id: &str) {
        // 走管理面而不是直接调 pairing::approve，顺带覆盖审批端点。
        let router = jarvis_service::admin::router(self.state.clone());
        let request = Request::post(format!("/admin/pair/{request_id}/approve"))
            .body(Body::empty())
            .expect("构造请求失败");
        let response = router.oneshot(request).await.expect("管理面调用失败");
        assert_eq!(response.status(), StatusCode::OK, "本机批准应当成功");
    }
}

pub async fn setup() -> TestContext {
    setup_with(|_| {}).await
}

/// 等待上限（毫秒）。并行跑整套测试时调度延迟会被放大，默认量级留足。
///
/// 用环境变量覆盖而不是写死：定位偶发失败时可以临时调大，不必改代码。
pub fn wait_limit_ms() -> u64 {
    std::env::var("AGENT_TEST_WAIT_MS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(15_000)
}

/// 轮询任务直到进入期望状态，超时即 panic。
///
/// 轮询而不是 sleep 固定时长：快的情况几毫秒就返回，慢的情况也不会因为
/// "刚好差一点"误判——误判会把真正的缺陷盖住，比慢 10 秒更难查。
pub async fn wait_for_state(
    ctx: &TestContext,
    token: &str,
    id: &str,
    expected: &str,
) -> serde_json::Value {
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(wait_limit_ms());
    let mut last = serde_json::Value::Null;

    while std::time::Instant::now() < deadline {
        let response = ctx
            .call(authed_get(&format!("/api/tasks/{id}"), token))
            .await;
        if response.status() == StatusCode::OK {
            last = body_json(response).await;
            if last["state"] == expected {
                return last;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }

    panic!(
        "任务未在 {}ms 内进入 {expected}，最后一次状态：{last}",
        wait_limit_ms()
    );
}

/// 允许单个测试覆盖配置（例如把审批有效期压到几百毫秒）。
pub async fn setup_with(configure: impl FnOnce(&mut Config)) -> TestContext {
    let dir = tempfile::tempdir().expect("创建临时目录失败");

    let mut config = Config {
        data_dir: dir.path().to_path_buf(),
        api_bind: "127.0.0.1:0".to_string(),
        ..Config::default()
    };
    configure(&mut config);

    let pool = db::connect(&config.db_path())
        .await
        .expect("打开数据库失败");
    db::migrate(&pool).await.expect("迁移失败");

    // 与 `app::run` 保持同一初始化序列：示例技能（trip-plan / bill-explain）
    // 现在由播种装成外部插件，不会自动出现。集成测试大量把 trip-plan 当作
    // "那个可派的技能"的样本，漏了这一步会整片失败。
    jarvis_service::plugin::seed::ensure(&pool, &config.plugins_dir())
        .await
        .expect("安装示例技能失败");

    let identity = Identity::load_or_create(&config.identity_path()).expect("创建服务端身份失败");

    TestContext {
        state: AppState::new(pool, identity, config),
        dir,
    }
}

/// 读取响应体并解析为 JSON。
pub async fn body_json(response: Response) -> serde_json::Value {
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("读取响应体失败")
        .to_bytes();
    serde_json::from_slice(&bytes).expect("响应不是合法 JSON")
}

/// 构造 JSON POST 请求。
pub fn json_post(uri: &str, payload: &serde_json::Value) -> Request<Body> {
    Request::post(uri)
        .header("content-type", "application/json")
        .body(Body::from(payload.to_string()))
        .expect("构造请求失败")
}

/// 构造带 Bearer 令牌的 JSON POST 请求。
pub fn authed_json_post(uri: &str, token: &str, payload: &serde_json::Value) -> Request<Body> {
    Request::post(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(payload.to_string()))
        .expect("构造请求失败")
}

/// 构造带 Bearer 令牌的 JSON PATCH 请求。
pub fn authed_json_patch(uri: &str, token: &str, payload: &serde_json::Value) -> Request<Body> {
    Request::patch(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(payload.to_string()))
        .expect("构造请求失败")
}

/// 构造带 Bearer 令牌的 DELETE 请求。
pub fn authed_delete(uri: &str, token: &str) -> Request<Body> {
    Request::delete(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .expect("构造请求失败")
}

/// 构造带 Bearer 令牌的 GET 请求。
pub fn authed_get(uri: &str, token: &str) -> Request<Body> {
    Request::get(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .expect("构造请求失败")
}

pub fn get(uri: &str) -> Request<Body> {
    Request::get(uri).body(Body::empty()).expect("构造请求失败")
}
