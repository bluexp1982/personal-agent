//! `/api/grants*`：执行授权的列表与撤销。
//!
//! 授权只能由"用户在工具审批卡上勾了记住"创建，**没有创建端点**：
//! 让客户端能直接建授权，等于让界面绕过审批。

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use serde::Deserialize;

use protocol::{GrantPage, GrantScope};

use crate::api::error::ApiRejection;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::clock::now_ms;
use crate::grants::{self, GrantError, GrantFilter};
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub scope: Option<String>,
    pub scope_id: Option<String>,
    pub tool: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<GrantPage>, ApiRejection> {
    let filter = GrantFilter {
        scope: match query.scope.as_deref() {
            None | Some("") | Some("all") => None,
            Some(raw) => Some(
                GrantScope::parse(raw)
                    .ok_or_else(|| GrantError::Invalid(format!("未知的授权作用域：{raw}")))?,
            ),
        },
        scope_id: query.scope_id.filter(|value| !value.is_empty()),
        tool: query.tool.filter(|value| !value.is_empty()),
    };

    let page = grants::list(
        &state.pool,
        &filter,
        query.cursor.as_deref(),
        query.limit.unwrap_or(20),
        now_ms(),
    )
    .await?;

    Ok(Json(page))
}

pub async fn revoke(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    grants::revoke(&state.pool, &id, now_ms()).await?;

    audit::record(
        &state.pool,
        &AuditEntry::new(
            &device.device_id,
            "approval",
            "approval.grant_revoked",
            "ok",
        )
        .target(&id)
        .detail(serde_json::json!({ "grant_id": id })),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}
