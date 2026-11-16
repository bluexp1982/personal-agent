//! 技能包管理：安装、列表、启停、卸载。
//!
//! 安装走二进制 body（`application/zip`）而不是 multipart：客户端已有
//! `postBytes`（录音分段用的就是它），少一层边界解析，也少一个"表单字段名拼错"
//! 的失败面。
//!
//! 所有会改变技能清单的操作最后都要 `request_reload()`：worker 只在启动时
//! 加载技能，不重载就永远看不到新装的东西。有任务在跑时它只标记「待生效」。

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Extension;
use axum::Json;
use protocol::{PluginPage, PluginStateUpdate};

use super::error::ApiRejection;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::plugin::{install, store, PluginError};
use crate::state::AppState;

/// 插件列表。`pending_reload` 让客户端能说清"装了但要等任务结束才生效"。
pub async fn list(State(state): State<AppState>) -> Result<Json<PluginPage>, ApiRejection> {
    let pending = state.worker.is_reload_pending();
    let page = store::list(&state.pool, pending).await.map_err(reject)?;
    Ok(Json(page))
}

/// 安装一个 zip 技能包。
///
/// 顺序刻意固定：解包校验 → 落库 → 请求重载 → 写审计。
/// 落库失败时把已经落盘的目录删掉——"文件在、库里没有"的孤儿目录既占空间，
/// 又会让下次安装因为 `rename` 目标已存在而报一个看不懂的错。
pub async fn install_package(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    body: Bytes,
) -> Result<(StatusCode, Json<PluginPage>), ApiRejection> {
    let plugins_root = state.config.plugins_dir();
    install::ensure_plugins_root(&plugins_root).map_err(reject)?;

    let reserved = store::reserved(&state.pool).await.map_err(reject)?;
    let installed = install::install(&body, &plugins_root, &reserved).map_err(reject)?;

    if let Err(err) = store::save(&state.pool, &installed).await {
        let _ = install::remove_plugin_dir(
            &plugins_root,
            &installed.manifest.id,
            &installed.manifest.version,
        );
        return Err(reject(err));
    }

    state.worker.request_reload().await;

    audit::record(
        &state.pool,
        &AuditEntry::new(
            &installed.manifest.id,
            &device.device_id,
            "plugin.install",
            "ok",
        )
        .target(&installed.manifest.id)
        .detail(serde_json::json!({
            "version": installed.manifest.version,
            // 只记数量与 id，不记包内容与技能正文。
            "skills": installed.skills.len(),
            "checksum": installed.checksum,
        })),
    )
    .await;

    let pending = state.worker.is_reload_pending();
    let page = store::list(&state.pool, pending).await.map_err(reject)?;
    Ok((StatusCode::CREATED, Json(page)))
}

/// 启用或停用插件。停用后其技能立即从候选里消失。
pub async fn set_state(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
    Json(update): Json<PluginStateUpdate>,
) -> Result<Json<PluginPage>, ApiRejection> {
    store::set_enabled(&state.pool, &id, update.enabled)
        .await
        .map_err(reject)?;

    state.worker.request_reload().await;

    let action = if update.enabled {
        "plugin.enable"
    } else {
        "plugin.disable"
    };
    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, action, "ok").target(&id),
    )
    .await;

    let pending = state.worker.is_reload_pending();
    let page = store::list(&state.pool, pending).await.map_err(reject)?;
    Ok(Json(page))
}

/// 卸载插件：先删文件、再删记录。
///
/// 顺序不能反：反过来的话，删文件失败会留下一条指向空目录的记录，
/// 用户在界面上还会看到这个插件，但它的技能一个都加载不出来。
pub async fn delete(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    let (version, _dir) = store::load_location(&state.pool, &id)
        .await
        .map_err(reject)?;

    let plugins_root = state.config.plugins_dir();
    // 目录可能已经被手工删掉：文件不存在不算失败，记录仍要清掉。
    install::remove_plugin_dir(&plugins_root, &id, &version).map_err(reject)?;

    store::delete(&state.pool, &id).await.map_err(reject)?;

    state.worker.request_reload().await;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "plugin.remove", "ok")
            .target(&id)
            .detail(serde_json::json!({ "version": version })),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

fn reject(error: PluginError) -> ApiRejection {
    ApiRejection::new(error.code(), error.to_string(), error.hint())
}
