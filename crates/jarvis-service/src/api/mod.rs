//! 对外 `/api/*` 路由。
//!
//! M2 加"身份门"（配对与登录），M3 加业务主干（会话、任务、审批、产物、技能）。
//! 除配对与登录外，所有端点都必须携带 `Authorization: Bearer <token>`。

pub mod artifacts;
pub mod attachments;
pub mod browser;
pub mod code;
pub mod conversations;
pub mod entities;
pub mod error;
pub mod file_writes;
pub mod fs;
pub mod git;
pub mod grants;
pub mod local_tool;
pub mod media;
pub mod memories;
pub mod models;
pub mod plugins;
pub mod recordings;
pub mod skills;
pub mod ssh;
pub mod tasks;
pub mod themes;
pub mod projects;

use axum::extract::{DefaultBodyLimit, FromRequest, Path, Request, State};
use axum::http::header::AUTHORIZATION;
use axum::http::StatusCode;
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Extension, Json, Router};
use protocol::{
    ChallengeRequest, ChallengeResponse, DeviceInfo, ErrorCode, PairConfirmRequest, PairPending,
    PairRequest, PairResult, PairStatus, SessionResponse, VerifyRequest,
};
use serde::de::DeserializeOwned;

use self::error::ApiRejection;
use crate::auth::{self, AuthDevice};
use crate::pairing;
use crate::shutdown::shutdown_signal;
use crate::state::AppState;

/// 组装 `/api/*` 路由。公开端点与受保护端点在这里显式分流。
pub fn router(state: AppState) -> Router {
    let public = Router::new()
        .route("/api/pair/request", post(submit_pairing))
        .route("/api/pair/requests/{id}", get(pairing_status))
        .route("/api/auth/challenge", post(challenge))
        .route("/api/auth/verify", post(verify));

    let protected = Router::new()
        .route("/api/auth/me", get(me))
        // 信任传递：已配对设备代批新设备
        .route("/api/pair/confirm", post(confirm_pairing))
        // 项目：会话与任务的归属，绑定服务端真实目录
        .route(
            "/api/projects",
            get(projects::list).post(projects::create),
        )
        // 静态段写在前面：`/preflight` 不能被 `/{id}` 抢走
        .route("/api/projects/preflight", get(projects::preflight))
        .route(
            "/api/projects/{id}",
            get(projects::detail)
                .patch(projects::rename)
                .delete(projects::delete),
        )
        // 目录浏览：给客户端选项目目录用，边界由服务端配置决定
        .route("/api/fs/dirs", get(fs::dirs))
        // 项目文件树：边界是该项目自己的目录，与上面的选择器分开
        .route("/api/projects/{id}/files", get(fs::list_project_files))
        .route("/api/projects/{id}/file", get(fs::read_project_file))
        // 原始字节：供客户端内置的图片 / PDF 查看器使用。文本仍走上面的 /file。
        .route("/api/projects/{id}/raw", get(fs::read_project_raw))
        // 网页预览：把项目里的 html 换成预览站的地址（含随机端口与令牌），
        // 客户端据此在浏览器面板里打开，不自己拼端口。
        .route("/api/projects/{id}/preview", get(fs::preview_target))
        // Git 面板：审查与本地提交。远程操作（fetch/pull/push）不在本轮，
        // 也就不需要任何凭据；命令全部在服务端跑，客户端只传仓库内相对路径。
        .route("/api/projects/{id}/git/status", get(git::status))
        .route("/api/projects/{id}/git/diff", get(git::diff))
        .route("/api/projects/{id}/git/stage", post(git::stage))
        .route("/api/projects/{id}/git/unstage", post(git::unstage))
        .route("/api/projects/{id}/git/discard", post(git::discard))
        .route("/api/projects/{id}/git/commit", post(git::commit))
        .route("/api/projects/{id}/git/commits", get(git::history))
        // 会话与消息：L1/L2 由这条链路直接回答，不建任务
        .route(
            "/api/conversations",
            get(conversations::list).post(conversations::create),
        )
        .route(
            "/api/conversations/{id}",
            get(conversations::detail)
                .patch(conversations::rename)
                .delete(conversations::delete),
        )
        .route(
            "/api/conversations/{id}/messages",
            get(conversations::list_messages).post(conversations::send_message),
        )
        // 停止本轮生成：与"断开连接"分开，断开会被当成"没人要了"而丢弃半截回答
        .route("/api/conversations/{id}/stop", post(conversations::stop))
        // 上下文压缩：手动重算一次（202 受理）、关掉这个会话的压缩。
        .route(
            "/api/conversations/{id}/compaction",
            post(conversations::compact).delete(conversations::uncompact),
        )
        // 覆盖已有文件的确认：待写内容已在服务端落库，这里只记决定并执行。
        .route(
            "/api/conversations/{id}/file-writes/{request_id}",
            post(file_writes::decide),
        )
        // 会话文件预览：项目与草稿两种落点共用一个入口，客户端不必判断归属。
        .route(
            "/api/conversations/{id}/file-preview",
            get(file_writes::file_preview),
        )
        // 草案文件字节：只给「另存为」用。草案里的 md / png / mp4 在此之前
        // 没有任何读取通道（`file-preview` 只换 html 的地址）。
        .route(
            "/api/conversations/{id}/draft-file",
            get(file_writes::draft_file),
        )
        // 任务：L3 显式触发，携带幂等键
        .route("/api/tasks", get(tasks::list).post(tasks::create))
        // 静态段写在 `/{id}` 之前：否则 `prepare` 会被当成一个任务 id 吃掉。
        .route("/api/tasks/prepare", post(tasks::prepare))
        .route("/api/tasks/{id}", get(tasks::detail).delete(tasks::delete))
        .route("/api/tasks/{id}/cancel", post(tasks::cancel))
        .route("/api/tasks/{id}/approve", post(tasks::approve))
        .route("/api/tasks/{id}/retry", post(tasks::retry))
        // 现场清理：只删数据目录里的隔离克隆，不动用户仓库
        .route(
            "/api/tasks/{id}/worktree",
            axum::routing::delete(tasks::clean_worktree),
        )
        // 记忆：显式增删改查 + 状态快照 + digest 快照。
        // 静态段（/state、/digest）写在 `/{id}` 之前，与项目那组同一约定。
        .route("/api/memories", get(memories::list).post(memories::create))
        .route("/api/memories/state", get(memories::state))
        // 候选、反馈、批量遗忘、导出：静态段都写在 `/{id}` 之前。
        .route("/api/memories/candidates/decide", post(memories::decide))
        .route(
            "/api/memories/batches/{batch_id}/revoke",
            post(memories::revoke_batch),
        )
        .route("/api/memories/forget", post(memories::forget))
        // 清空归档：静态段写在 `/{id}` 之前。
        .route(
            "/api/memories/archived/purge",
            post(memories::purge_archived),
        )
        // 手动整理：与心跳夜间分支共用同一份实现，静态段写在 `/{id}` 之前。
        .route("/api/memories/organize", post(memories::organize))
        .route(
            "/api/memories/settings",
            axum::routing::patch(memories::settings),
        )
        .route(
            "/api/memories/export/preview",
            post(memories::export_preview),
        )
        .route("/api/memories/export/apply", post(memories::export_apply))
        .route("/api/memories/{id}/feedback", post(memories::feedback))
        // 实体页：列表、详情、改名、合并、拆分。
        .route("/api/grants", get(grants::list))
        .route("/api/grants/{id}", axum::routing::delete(grants::revoke))
        .route("/api/entities", get(entities::list))
        .route("/api/entities/merge", post(entities::merge))
        .route(
            "/api/entities/{id}",
            get(entities::detail).patch(entities::update),
        )
        .route("/api/entities/{id}/split", post(entities::split))
        .route("/api/memories/digest", get(memories::digest_list))
        .route("/api/memories/digest/{id}", get(memories::digest_detail))
        .route(
            "/api/memories/{id}",
            get(memories::detail)
                .patch(memories::update)
                .delete(memories::delete),
        )
        .route("/api/artifacts/{id}", get(artifacts::get))
        .route("/api/artifacts/{id}/content", get(artifacts::content))
        // 会话里生成的图片 / 视频：只按 id 取，路径永远由服务端记录决定。
        .route("/api/media/{id}/content", get(media::content))
        // 视频封面：生成时抽的第一帧。没有就 404，客户端回退到占位块。
        .route("/api/media/{id}/poster", get(media::poster))
        // 另存到项目：文件已在服务端产物库里，复制由服务端做，客户端只给文件名。
        .route("/api/media/{id}/save", post(media::save))
        .route("/api/skills", get(skills::list))
        // 模型配置：客户端在这里维护多份第三方模型并挑一份生效。
        // 静态段（`/test`）写在 `/{id}` 之前，与项目、记忆那几组同一约定。
        .route("/api/models", get(models::list).post(models::create))
        .route("/api/models/test", post(models::test))
        .route(
            "/api/models/{id}",
            axum::routing::patch(models::update).delete(models::delete),
        )
        .route("/api/models/{id}/activate", post(models::activate))
        // 编码执行层的静态能力：客户端按它决定"能不能显示工具级审批"等入口。
        .route("/api/code/providers", get(code::providers))
        // SSH 隧道：`/api/ssh` 升级为 WebSocket 后纯字节透传到本机 sshd；
        // `/api/ssh/info` 让客户端在输密码前先知道"能不能连"。
        .route("/api/ssh", get(ssh::tunnel))
        .route("/api/ssh/info", get(ssh::info))
        // 浏览器隧道：`/api/browser/tunnel` 升级后纯字节透传到本机回环端口；
        // `/api/browser/info` 让客户端在输入端口前就知道白名单与并发上限。
        .route("/api/browser/tunnel", get(browser::tunnel))
        .route("/api/browser/info", get(browser::info))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_device,
        ));

    // 录音分段是二进制上传，必须单独放宽请求体上限；其余端点保持默认，
    // 避免一个 `/api/conversations` 的 JSON 请求也能塞进几十 MB。
    //
    // 多留 1MB：axum 的 body limit 拒绝会返回纯文本 413，客户端解析不出
    // 统一错误码；留一点余量让 handler 自己判断并返回 `payload_too_large`。
    let segment_limit = state
        .config
        .recording
        .max_segment_bytes
        .max(1)
        .saturating_add(1024 * 1024);
    let recordings = recordings::router()
        .layer(DefaultBodyLimit::max(
            usize::try_from(segment_limit).unwrap_or(32 * 1024 * 1024),
        ))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_device,
        ));

    // 技能包安装是二进制上传，必须单独放宽请求体上限；其余端点维持默认，
    // 避免一个普通 JSON 请求也能塞进几十 MB。
    //
    // 多留 1MB：axum 的 body limit 拒绝会返回纯文本 413，客户端解析不出统一错误码；
    // 留一点余量让 handler 自己判断并返回 `plugin_invalid` + 可读原因。
    let plugins = Router::new()
        .route(
            "/api/plugins",
            get(plugins::list).post(plugins::install_package),
        )
        .route(
            "/api/plugins/{id}",
            axum::routing::patch(plugins::set_state).delete(plugins::delete),
        )
        .layer(DefaultBodyLimit::max(
            crate::plugin::MAX_ARCHIVE_BYTES.saturating_add(1024 * 1024),
        ))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_device,
        ));

    // 主题包安装同样是二进制上传，必须单独放宽请求体上限；其余端点维持默认。
    //
    // 多留 1MB：axum 的 body limit 拒绝会返回纯文本 413，客户端解析不出统一错误码；
    // 留一点余量让 handler 自己判断并返回 `theme_invalid` + 可读原因。
    let themes = Router::new()
        .route(
            "/api/themes",
            get(themes::list).post(themes::install_package),
        )
        .route("/api/themes/{id}", axum::routing::delete(themes::delete))
        .layer(DefaultBodyLimit::max(
            crate::theme::MAX_ARCHIVE_BYTES.saturating_add(1024 * 1024),
        ))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_device,
        ));

    // 输入框附件同样是二进制上传，必须单独放宽请求体上限；其余端点维持默认。
    //
    // 多留 1MB：axum 的 body limit 拒绝会返回纯文本 413，客户端解析不出统一错误码；
    // 留一点余量让 handler 自己判断并返回 `payload_too_large` + 可读原因。
    let attachment_limit = state
        .config
        .attachment
        .max_bytes
        .max(1)
        .saturating_add(1024 * 1024);
    let attachments = Router::new()
        .route("/api/attachments", post(attachments::upload))
        .route(
            "/api/attachments/{id}/content",
            get(attachments::content),
        )
        .route(
            "/api/attachments/{id}",
            axum::routing::delete(attachments::delete),
        )
        .layer(DefaultBodyLimit::max(
            usize::try_from(attachment_limit).unwrap_or(32 * 1024 * 1024),
        ))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_device,
        ));

    Router::new()
        .merge(public)
        .merge(protected)
        .merge(recordings)
        .merge(plugins)
        .merge(themes)
        .merge(attachments)
        .with_state(state)
}

/// 启动对外 API 监听。绑定地址来自配置（默认 `127.0.0.1:8787`，与客户端默认一致）。
pub async fn serve(state: AppState, router: Router) -> std::io::Result<()> {
    let bind = state.config.api_bind.clone();
    let listener = match tokio::net::TcpListener::bind(&bind).await {
        Ok(listener) => listener,
        // 端口被占是开发期最常见的失败：默认值固定之后，装过一次服务再起前台实例就会撞。
        // 原始 "Address already in use" 不会告诉人该怎么办，这里补一句可执行的提示。
        Err(err) if err.kind() == std::io::ErrorKind::AddrInUse => {
            return Err(std::io::Error::new(
                err.kind(),
                format!(
                    "端口 {bind} 已被占用（可能已有一个服务在跑）。\
                     换端口：配置里写 \"api_bind\": \"127.0.0.1:<端口>\"，\
                     或先停掉旧实例（`jarvis-service status` / `jarvis-service uninstall`）"
                ),
            ));
        }
        Err(err) => return Err(err),
    };
    let addr = listener.local_addr()?;
    let port_path = state.config.api_port_path();

    if let Err(err) = std::fs::write(&port_path, addr.port().to_string()) {
        tracing::warn!(path = %port_path.display(), %err, "写入 api.port 失败，客户端无法自动发现端口");
    }

    // 非回环绑定意味着"别人连得上"：这条必须显式说出来，否则用户不会意识到端口已开放。
    if !state.config.is_loopback_bind() {
        tracing::warn!(
            %addr,
            "监听非本机地址，局域网内其他设备可访问；请确认只有自己的网络能到这里"
        );
    }

    // 隧道是长连接：收到退出信号后先通知它们主动收尾，再由 axum 排空。
    // 否则 Ctrl-C 要等到对端自己断开，或者干等 TLS 路径的 10 秒强杀。
    let notice = state.shutdown.clone();
    let shutdown = async move {
        shutdown_signal().await;
        notice.notify();
    };

    match state.tls.clone() {
        Some(tls) => {
            tracing::info!(%addr, fingerprint = %tls.fingerprint(), "对外 API 监听（自签 TLS）");
            serve_tls(listener, router, tls, shutdown).await?;
        }
        None => {
            tracing::info!(%addr, "对外 API 监听（明文 HTTP）");
            axum::serve(listener, router)
                .with_graceful_shutdown(shutdown)
                .await?;
        }
    }

    let _ = std::fs::remove_file(&port_path);
    tracing::info!("对外 API 已关闭，api.port 已清理");
    Ok(())
}

/// TLS 版 accept 循环。
///
/// 不用 `axum::serve`：它只接受明文 `TcpListener`。这里复用管理面已验证的
/// `hyper_util` 组合（`server::conn::auto` + `TokioIo`），保持"一个 accept 循环、
/// 两种传输"的实现风格一致。
async fn serve_tls(
    listener: tokio::net::TcpListener,
    router: Router,
    tls: std::sync::Arc<crate::tls::TlsIdentity>,
    shutdown: impl std::future::Future<Output = ()>,
) -> std::io::Result<()> {
    use hyper_util::rt::{TokioExecutor, TokioIo};
    use hyper_util::service::TowerToHyperService;

    let acceptor = tls
        .acceptor()
        .map_err(|err| std::io::Error::other(format!("构建 TLS 配置失败: {err}")))?;

    tokio::pin!(shutdown);

    let mut connections = tokio::task::JoinSet::new();

    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => {
                let (stream, peer) = match accepted {
                    Ok(pair) => pair,
                    Err(err) => {
                        // 单次 accept 失败（如瞬时 fd 耗尽）不该让整个服务停下。
                        tracing::warn!(%err, "接受连接失败，继续监听");
                        continue;
                    }
                };
                let acceptor = acceptor.clone();
                let router = router.clone();
                connections.spawn(async move {
                    // 扫描器与配置错误的客户端会频繁换握手错误：只记 debug，不刷屏。
                    let stream = match acceptor.accept(stream).await {
                        Ok(stream) => stream,
                        Err(err) => {
                            tracing::debug!(%peer, %err, "TLS 握手失败");
                            return;
                        }
                    };

                    let service = TowerToHyperService::new(router);
                    let connection =
                        hyper_util::server::conn::auto::Builder::new(TokioExecutor::new())
                            .serve_connection_with_upgrades(TokioIo::new(stream), service)
                            .await;
                    if let Err(err) = connection {
                        tracing::debug!(%peer, %err, "连接结束");
                    }
                });
            }
            // 及时回收已结束的连接，避免 JoinSet 随连接数无界增长。
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }

    // 停止 accept 后给在途请求收尾。SSE 是长连接，不设上限会让卸载服务卡住，
    // 因此 10 秒后强制关闭：客户端本来就要重连，卡住退出更难排查。
    let drain = async { while connections.join_next().await.is_some() {} };
    if tokio::time::timeout(std::time::Duration::from_secs(10), drain)
        .await
        .is_err()
    {
        connections.abort_all();
        tracing::warn!("TLS 连接排空超时（10 秒），强制关闭");
    }

    Ok(())
}

/// JSON 提取器：把 axum 的提取失败也转成统一错误体，避免客户端遇到两种错误格式。
#[derive(Debug)]
pub struct ApiJson<T>(pub T);

impl<S, T> FromRequest<S> for ApiJson<T>
where
    T: DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = ApiRejection;

    async fn from_request(request: Request, state: &S) -> Result<Self, Self::Rejection> {
        let Json(value) = Json::<T>::from_request(request, state)
            .await
            .map_err(|err| {
                ApiRejection::new(
                    ErrorCode::InvalidRequest,
                    err.body_text(),
                    "请求参数格式不正确",
                )
            })?;
        Ok(Self(value))
    }
}

async fn submit_pairing(
    State(state): State<AppState>,
    ApiJson(request): ApiJson<PairRequest>,
) -> Result<(StatusCode, Json<PairPending>), ApiRejection> {
    let (request_id, expires_at) = pairing::submit(
        &state.pool,
        &request.code,
        &request.device_name,
        &request.platform,
        &request.client_pubkey,
    )
    .await?;

    Ok((
        StatusCode::ACCEPTED,
        Json(PairPending {
            request_id,
            expires_at,
        }),
    ))
}

async fn pairing_status(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<PairStatus>, ApiRejection> {
    let status = pairing::status(&state.pool, &id).await?;
    let approved = status.status == "approved";

    Ok(Json(PairStatus {
        request_id: status.id,
        status: status.status,
        device_id: status.device_id,
        server_pubkey: approved.then(|| state.identity.public_key_b32()),
        server_fingerprint: approved.then(|| state.identity.fingerprint()),
    }))
}

async fn confirm_pairing(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(request): ApiJson<PairConfirmRequest>,
) -> Result<Json<PairResult>, ApiRejection> {
    if !request.approve {
        pairing::reject(&state.pool, &request.request_id).await?;
        return Ok(Json(PairResult {
            accepted: false,
            reason: "rejected by paired device".to_string(),
            device_id: None,
            server_pubkey: None,
            server_fingerprint: None,
        }));
    }

    let approved = pairing::approve(&state.pool, &request.request_id, &device.device_id).await?;

    Ok(Json(PairResult {
        accepted: true,
        reason: format!("approved by {}", device.device_id),
        device_id: Some(approved.device_id),
        server_pubkey: Some(state.identity.public_key_b32()),
        server_fingerprint: Some(state.identity.fingerprint()),
    }))
}

async fn challenge(
    State(state): State<AppState>,
    ApiJson(request): ApiJson<ChallengeRequest>,
) -> Result<Json<ChallengeResponse>, ApiRejection> {
    let (challenge, expires_at) = auth::issue_challenge(
        &state.pool,
        &state.challenges,
        &state.limiter,
        &request.device_id,
    )
    .await?;

    Ok(Json(ChallengeResponse {
        challenge,
        expires_at,
    }))
}

async fn verify(
    State(state): State<AppState>,
    ApiJson(request): ApiJson<VerifyRequest>,
) -> Result<Json<SessionResponse>, ApiRejection> {
    let (token, expires_at) = auth::verify_and_issue(
        &state.pool,
        &state.challenges,
        &request.device_id,
        &request.challenge,
        &request.signature,
    )
    .await?;

    Ok(Json(SessionResponse { token, expires_at }))
}

async fn me(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
) -> Result<Json<DeviceInfo>, ApiRejection> {
    let row = sqlx::query_as::<_, (String, String, i64)>(
        "SELECT name, platform, paired_at FROM devices WHERE id = ?",
    )
    .bind(&device.device_id)
    .fetch_optional(&state.pool)
    .await?;

    let (name, platform, paired_at) = row.ok_or_else(|| {
        ApiRejection::new(
            ErrorCode::Unauthenticated,
            "device disappeared",
            "设备未授权，请重新配对",
        )
    })?;

    Ok(Json(DeviceInfo {
        device_id: device.device_id,
        name,
        platform,
        paired_at,
    }))
}

/// 令牌校验中间件。成功后把 `AuthDevice` 放进请求扩展，供 handler 读取。
async fn require_device(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    mut request: Request,
    next: Next,
) -> Response {
    let token = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));

    let Some(token) = token else {
        return ApiRejection::new(
            ErrorCode::Unauthenticated,
            "missing bearer token",
            "设备未授权，请重新配对",
        )
        .into_response();
    };

    match auth::authenticate(&state.pool, token).await {
        Ok(device) => {
            request.extensions_mut().insert(device);
            next.run(request).await
        }
        Err(err) => ApiRejection::from(err).into_response(),
    }
}
