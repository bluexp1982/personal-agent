//! 主题包管理：安装、列表、删除。
//!
//! 与技能包一样走二进制 body（`application/zip`）而不是 multipart：客户端已有
//! `postBytes`，少一层边界解析，也少一个"表单字段名拼错"的失败面。
//!
//! 与技能包不同的是**不需要 `request_reload()`**：换肤完全在客户端完成，
//! 执行进程不参与，所以也没有 `pending_reload` 这个字段。

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Extension;
use axum::Json;
use protocol::ThemePage;

use super::error::ApiRejection;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::state::AppState;
use crate::theme::{install, store, ThemeError};

/// 主题包列表。
pub async fn list(State(state): State<AppState>) -> Result<Json<ThemePage>, ApiRejection> {
    let page = store::list(&state.pool).await.map_err(reject)?;
    Ok(Json(page))
}

/// 安装一个 zip 主题包。同 id 即覆盖安装。
///
/// 顺序与技能包一致：解包校验 → 落库（失败回滚目录）→ 审计 → 返回最新列表。
/// 返回最新列表而不是只返回新装的那个，客户端可以直接替换整份状态，
/// 不必自己合并。
pub async fn install_package(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    body: Bytes,
) -> Result<(StatusCode, Json<ThemePage>), ApiRejection> {
    let themes_root = state.config.themes_dir();
    install::ensure_themes_root(&themes_root).map_err(reject)?;

    let installed = install::install(&body, &themes_root).map_err(reject)?;

    if let Err(err) = store::save(&state.pool, &installed).await {
        // 落库失败就把已经落盘的目录删掉：孤儿目录既占空间，又会让下次
        // 覆盖安装撞上"目标已存在"而报一个看不懂的错。
        let _ = install::remove_theme_dir(&themes_root, &installed.manifest.id);
        return Err(reject(err));
    }

    audit::record(
        &state.pool,
        &AuditEntry::new(
            &installed.manifest.id,
            &device.device_id,
            "theme.install",
            "ok",
        )
        .target(&installed.manifest.id)
        .detail(serde_json::json!({
            "version": installed.manifest.version,
            "brightness": installed.manifest.brightness.as_str(),
            // 只记版本与校验和，不记具体色值：审计里不需要一份配色表。
            "checksum": installed.checksum,
        })),
    )
    .await;

    let page = store::list(&state.pool).await.map_err(reject)?;
    Ok((StatusCode::CREATED, Json(page)))
}

/// 删除主题包：先删文件、再删记录。
///
/// 顺序不能反：反过来的话，删文件失败会留下一条指向空目录的记录，
/// 用户在界面上还会看到这个主题，点上去却是空壳。
pub async fn delete(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<Json<ThemePage>, ApiRejection> {
    let manifest = store::load_manifest(&state.pool, &id)
        .await
        .map_err(reject)?;

    let themes_root = state.config.themes_dir();
    install::remove_theme_dir(&themes_root, &id).map_err(reject)?;
    store::delete(&state.pool, &id).await.map_err(reject)?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&id, &device.device_id, "theme.remove", "ok")
            .target(&id)
            .detail(serde_json::json!({ "version": manifest.version })),
    )
    .await;

    let page = store::list(&state.pool).await.map_err(reject)?;
    Ok(Json(page))
}

fn reject(error: ThemeError) -> ApiRejection {
    ApiRejection::new(error.code(), error.to_string(), error.hint())
}
