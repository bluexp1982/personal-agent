//! 管理面（`/admin/*`）。
//!
//! 传输方式按既定决策：
//! - macOS / Linux：unix domain socket，权限 0600，文件权限即鉴权；
//! - Windows：回退到回环 TCP + 令牌（named pipe 的实现留到 v1.2 与 `jarvis-tui` 一起做）。
//!
//! 管理面永不监听对外地址，也不承载业务数据。M2 增加配对审批与设备管理——
//! 这两件事必须"人在机器旁"才能做，所以只能走管理面。

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use protocol::{HealthResponse, PairResult};
use serde::Serialize;

use crate::api::error::ApiRejection;
use crate::auth;
use crate::pairing;
use crate::shutdown::shutdown_signal;
use crate::state::AppState;

/// 管理面路由。与 `/api/*` 共享同一个 `AppState`。
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/admin/health", get(health))
        .route("/admin/identity", get(identity))
        .route("/admin/worker", get(worker_status))
        .route("/admin/code", get(code_status))
        .route("/admin/pair/start", post(pair_start))
        .route("/admin/pair/pending", get(pair_pending))
        .route("/admin/pair/{id}/approve", post(pair_approve))
        .route("/admin/pair/{id}/reject", post(pair_reject))
        .route("/admin/devices", get(devices))
        // 路径用 revoke-all 而不是 `/admin/devices/revoke`：后者会和 `{id}` 段撞语义，
        // 也不该只差一个词就变成"全选"这种破坏性操作。
        .route("/admin/devices/revoke-all", post(revoke_all_devices))
        .route("/admin/devices/{id}/revoke", post(revoke_device))
        .with_state(state)
}

#[derive(Debug, Serialize)]
struct IdentityView {
    pubkey: String,
    fingerprint: String,
    /// 自签 TLS 证书指纹。明文 HTTP 模式下为空。
    tls_fingerprint: Option<String>,
}

#[derive(Debug, Serialize)]
struct PairStartView {
    request_id: String,
    /// 明文配对码，只在这一次响应里出现；调用方打印后即丢弃。
    code: String,
    expires_at: i64,
    /// 客户端首次连接时要核对的证书指纹；明文模式下为空。
    tls_fingerprint: Option<String>,
}

#[derive(Debug, Serialize)]
struct PendingView {
    request_id: String,
    device_name: Option<String>,
    platform: Option<String>,
    status: String,
    created_at: i64,
    expires_at: i64,
}

#[derive(Debug, Serialize)]
struct DeviceView {
    id: String,
    name: String,
    platform: String,
    approved_by: Option<String>,
    paired_at: i64,
    last_seen_at: Option<i64>,
    revoked_at: Option<i64>,
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse::ok())
}

#[derive(Debug, Serialize)]
struct WorkerStatusView {
    phase: &'static str,
    pid: Option<u32>,
    last_heartbeat_ms: Option<i64>,
    restarts: u32,
    last_error: Option<String>,
    skills: Vec<String>,
    /// worker 自报的活跃任务（心跳里带上来的）。
    active_tasks: Vec<String>,
}

async fn worker_status(State(state): State<AppState>) -> Json<WorkerStatusView> {
    let view = state.worker.view();
    Json(WorkerStatusView {
        phase: view.phase,
        pid: view.pid,
        last_heartbeat_ms: view.last_heartbeat_ms,
        restarts: view.restarts,
        last_error: view.last_error,
        skills: view.skills,
        active_tasks: view.active_tasks,
    })
}

/// 编码能力的现状：配置、代理地址、活跃任务与内存里的用量。
///
/// 明细（每次调用）在审计表 `code.model_call` 里；这里只回答"现在有没有在跑、花了多少"。
#[derive(Debug, Serialize)]
struct CodeStatusView {
    enabled: bool,
    provider: String,
    model: String,
    /// 代理实际监听地址（仅回环），未启用时为空。
    proxy: Option<String>,
    /// 上游是否已配置密钥。false 表示编码任务会直接 `code_unavailable`。
    has_upstream: bool,
    active_tokens: usize,
    active_tasks: Vec<String>,
    worktrees: String,
    allow_roots: usize,
    usage: Vec<CodeUsageView>,
}

#[derive(Debug, Serialize)]
struct CodeUsageView {
    task_id: String,
    calls: u64,
    prompt_tokens: u64,
    completion_tokens: u64,
    tokens_estimated: bool,
}

async fn code_status(State(state): State<AppState>) -> Json<CodeStatusView> {
    let view = state.code_proxy.as_ref().map(|proxy| proxy.view());

    Json(CodeStatusView {
        enabled: state.config.code.enabled,
        provider: state.config.code.provider.clone(),
        model: state.config.code_upstream_model().to_string(),
        proxy: view.as_ref().map(|view| view.addr.clone()),
        has_upstream: view.as_ref().map(|view| view.has_upstream).unwrap_or(false),
        active_tokens: view.as_ref().map(|view| view.active_tokens()).unwrap_or(0),
        active_tasks: view
            .as_ref()
            .map(|view| view.active_tasks.clone())
            .unwrap_or_default(),
        worktrees: state.config.code_worktree_dir().display().to_string(),
        allow_roots: state.config.code.allow_roots.len(),
        usage: view
            .map(|view| {
                view.usage
                    .into_iter()
                    .map(|(task_id, totals)| CodeUsageView {
                        task_id,
                        calls: totals.calls,
                        prompt_tokens: totals.prompt_tokens,
                        completion_tokens: totals.completion_tokens,
                        tokens_estimated: totals.estimated,
                    })
                    .collect()
            })
            .unwrap_or_default(),
    })
}

async fn identity(State(state): State<AppState>) -> Json<IdentityView> {
    Json(IdentityView {
        pubkey: state.identity.public_key_b32(),
        fingerprint: state.identity.fingerprint(),
        tls_fingerprint: state.tls.as_ref().map(|tls| tls.fingerprint().to_string()),
    })
}

async fn pair_start(State(state): State<AppState>) -> Result<Json<PairStartView>, ApiRejection> {
    let (request_id, code) = pairing::start(&state.pool).await?;
    let expires_at = crate::clock::now_ms() + pairing::CODE_TTL_MS;

    // 只记 request_id：配对码不落日志。
    tracing::info!(request_id = %request_id, "已生成配对码，等待客户端提交");

    Ok(Json(PairStartView {
        request_id,
        code,
        expires_at,
        tls_fingerprint: state.tls.as_ref().map(|tls| tls.fingerprint().to_string()),
    }))
}

async fn pair_pending(
    State(state): State<AppState>,
) -> Result<Json<Vec<PendingView>>, ApiRejection> {
    let pending = pairing::pending(&state.pool).await?;

    Ok(Json(
        pending
            .into_iter()
            .map(|item| PendingView {
                request_id: item.id,
                device_name: item.device_name,
                platform: item.platform,
                status: item.status,
                created_at: item.created_at,
                expires_at: item.expires_at,
            })
            .collect(),
    ))
}

/// 本机确认。`approved_by` 记为 `local`，与"已配对设备代批"区分开。
async fn pair_approve(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<PairResult>, ApiRejection> {
    let approved = pairing::approve(&state.pool, &id, "local").await?;

    tracing::info!(request_id = %id, device_id = %approved.device_id, "本机确认配对");
    Ok(Json(PairResult {
        accepted: true,
        reason: "approved locally".to_string(),
        device_id: Some(approved.device_id),
        server_pubkey: Some(state.identity.public_key_b32()),
        server_fingerprint: Some(state.identity.fingerprint()),
    }))
}

async fn pair_reject(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<PairResult>, ApiRejection> {
    pairing::reject(&state.pool, &id).await?;

    tracing::info!(request_id = %id, "本机拒绝配对");
    Ok(Json(PairResult {
        accepted: false,
        reason: "rejected locally".to_string(),
        device_id: None,
        server_pubkey: None,
        server_fingerprint: None,
    }))
}

async fn devices(State(state): State<AppState>) -> Result<Json<Vec<DeviceView>>, ApiRejection> {
    let rows = sqlx::query_as::<
        _,
        (
            String,
            String,
            String,
            Option<String>,
            i64,
            Option<i64>,
            Option<i64>,
        ),
    >(
        "SELECT id, name, platform, approved_by, paired_at, last_seen_at, revoked_at \
         FROM devices ORDER BY paired_at DESC",
    )
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(
        rows.into_iter()
            .map(|row| DeviceView {
                id: row.0,
                name: row.1,
                platform: row.2,
                approved_by: row.3,
                paired_at: row.4,
                last_seen_at: row.5,
                revoked_at: row.6,
            })
            .collect(),
    ))
}

async fn revoke_device(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    auth::revoke_device(&state.pool, &id).await?;

    tracing::info!(device_id = %id, "设备已吊销");
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Serialize)]
struct RevokeAllView {
    revoked: u64,
}

/// 吊销全部设备。危险操作，只由 CLI（`pair --reset --yes`）在确认后调用。
async fn revoke_all_devices(
    State(state): State<AppState>,
) -> Result<Json<RevokeAllView>, ApiRejection> {
    let revoked = auth::revoke_all_devices(&state.pool).await?;

    // 只记数量：设备名与令牌都不进日志。
    tracing::info!(revoked, "全部设备已吊销");
    Ok(Json(RevokeAllView { revoked }))
}

/// 启动管理面并阻塞到收到退出信号。
pub async fn serve(config: &crate::config::Config, router: Router) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        serve_unix(config, router).await
    }

    #[cfg(windows)]
    {
        serve_loopback(config, router).await
    }
}

#[cfg(unix)]
async fn serve_unix(config: &crate::config::Config, router: Router) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    use hyper_util::rt::{TokioExecutor, TokioIo};
    use hyper_util::service::TowerToHyperService;

    let path = config.admin_socket_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // 上次异常退出可能留下 socket 文件，先清掉。
    let _ = std::fs::remove_file(&path);

    let listener = tokio::net::UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;

    tracing::info!(socket = %path.display(), "管理面监听（本地套接字，0600）");

    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                let router = router.clone();
                tokio::spawn(async move {
                    let service = TowerToHyperService::new(router);
                    let connection = hyper_util::server::conn::auto::Builder::new(TokioExecutor::new())
                        .serve_connection_with_upgrades(TokioIo::new(stream), service)
                        .await;
                    if let Err(err) = connection {
                        // 管理面是单机运维通道，连接级错误只记 debug，不打扰主流程。
                        tracing::debug!(%err, "管理面连接结束");
                    }
                });
            }
        }
    }

    let _ = std::fs::remove_file(&path);
    tracing::info!("管理面已关闭，socket 已清理");
    Ok(())
}

#[cfg(windows)]
async fn serve_loopback(config: &crate::config::Config, router: Router) -> std::io::Result<()> {
    use axum::extract::Request;
    use axum::http::{HeaderMap, StatusCode as HttpStatus};
    use axum::middleware::{self, Next};
    use axum::response::Response;

    let token = load_or_create_token(&config.admin_token_path())?;
    let expected = token.clone();

    let app = router.layer(middleware::from_fn(
        move |headers: HeaderMap, request: Request, next: Next| {
            let expected = expected.clone();
            async move {
                let provided = headers
                    .get("authorization")
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| value.strip_prefix("Bearer "));

                match provided {
                    Some(value) if constant_time_eq(value.as_bytes(), expected.as_bytes()) => {
                        Ok::<Response, HttpStatus>(next.run(request).await)
                    }
                    _ => Err(HttpStatus::UNAUTHORIZED),
                }
            }
        },
    ));

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", config.port)).await?;
    let addr = listener.local_addr()?;
    std::fs::write(
        config.data_dir.join("admin.port"),
        addr.port().to_string().as_bytes(),
    )?;
    tracing::info!(%addr, token = %config.admin_token_path().display(), "管理面监听（回环 TCP + 令牌）");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

#[cfg(windows)]
fn load_or_create_token(path: &std::path::Path) -> std::io::Result<String> {
    if let Ok(existing) = std::fs::read_to_string(path) {
        let trimmed = existing.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let bytes: [u8; 32] = rand::random();
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    std::fs::write(path, &token)?;
    Ok(token)
}

#[cfg(windows)]
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}
