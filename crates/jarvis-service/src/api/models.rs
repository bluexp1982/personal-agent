//! 模型配置的增删改查与生效切换。
//!
//! 设计要点：
//! - **配置与密钥分开写**：`config.json` 只存配置名/地址/模型ID/模型名，密钥落
//!   `model-secrets.json`（0600）。任何响应都不回显密钥，只给来源与末四位；
//! - **先落盘再生效**：写盘失败就当没改过，避免"这次能用、重启就没了"；
//! - **删除当前项自动回落默认档**：不给用户留下"当前配置指向一条不存在的记录"
//!   的状态；
//! - **测试连接不返回 4xx**：连通性探测失败是"结论"而不是"请求错了"，
//!   用 200 + `ok:false` 让客户端能把原因、状态码与耗时一起显示出来。

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use protocol::ErrorCode;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::api::error::ApiRejection;
use crate::api::ApiJson;
use crate::audit::{self, AuditEntry};
use crate::auth::AuthDevice;
use crate::config::{LlmConfig, ModelProfile, DEFAULT_PROFILE_ID};
use crate::llm::LlmClient;
use crate::model_profiles::{self, ProfileView};
use crate::state::AppState;

// ---------------------------------------------------------------------------
// 请求体
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateModelRequest {
    pub name: String,
    pub base_url: String,
    /// 发给上游的模型 ID。
    pub model: String,
    /// 人可读的模型名，可留空。
    #[serde(default)]
    pub model_name: Option<String>,
    /// 路径前缀。缺省 `/v1`：新增的配置基本都是标准 OpenAI 兼容网关。
    #[serde(default)]
    pub api_path: Option<String>,
    #[serde(default)]
    pub api_key: Option<String>,
    /// 想从哪个环境变量读密钥。可选，留空就只认客户端写入的密钥。
    #[serde(default)]
    pub api_key_env: Option<String>,
    #[serde(default)]
    pub vision: Option<bool>,
    /// 上游认不认 `reasoning_effort`。缺省为假：第三方网关多数不认。
    #[serde(default)]
    pub reasoning: Option<bool>,
    /// 模型最大上下文窗口（tokens）。缺省 128K，只影响输入栏占比的分母。
    #[serde(default)]
    pub context_window: Option<u32>,
    #[serde(default)]
    pub enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateModelRequest {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    /// 人可读的模型名。显式传空串即清空（界面回退模型ID）。
    #[serde(default)]
    pub model_name: Option<String>,
    #[serde(default)]
    pub api_path: Option<String>,
    /// 空串或缺省表示"不改动已有密钥"。
    #[serde(default)]
    pub api_key: Option<String>,
    /// 显式清空密钥。
    #[serde(default)]
    pub clear_api_key: Option<bool>,
    #[serde(default)]
    pub api_key_env: Option<String>,
    #[serde(default)]
    pub vision: Option<bool>,
    #[serde(default)]
    pub reasoning: Option<bool>,
    /// 上下文窗口；缺省表示"不改动"，给值则按区间校验后覆盖。
    #[serde(default)]
    pub context_window: Option<u32>,
    #[serde(default)]
    pub enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct TestModelRequest {
    /// 已保存配置的 id。给了它就可以只测不存。
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub api_path: Option<String>,
    /// 表单里刚填、还没保存的密钥。为空时复用已保存的那把。
    #[serde(default)]
    pub api_key: Option<String>,
    /// 表单里刚勾的「支持推理等级」。为空时沿用已存配置。
    #[serde(default)]
    pub reasoning: Option<bool>,
}

// ---------------------------------------------------------------------------
// 列表
// ---------------------------------------------------------------------------

pub async fn list(State(state): State<AppState>) -> Json<Value> {
    let views = state.models.views();
    Json(json!({
        "active_id": state.models.active_id(),
        "persisted": state.config.source_path().is_some(),
        "models": views,
    }))
}

// ---------------------------------------------------------------------------
// 新建
// ---------------------------------------------------------------------------

pub async fn create(
    State(state): State<AppState>,
    axum::Extension(device): axum::Extension<AuthDevice>,
    ApiJson(request): ApiJson<CreateModelRequest>,
) -> Result<(StatusCode, Json<Value>), ApiRejection> {
    let api_path = request
        .api_path
        .clone()
        .unwrap_or_else(|| "/v1".to_string());
    let fields = model_profiles::validate_fields(
        &request.name,
        request.model_name.as_deref().unwrap_or_default(),
        &request.base_url,
        &request.model,
        &api_path,
    )
    .map_err(invalid)?;
    let context_window = request
        .context_window
        .map(model_profiles::validate_context_window)
        .transpose()
        .map_err(invalid)?
        .unwrap_or(crate::config::DEFAULT_CONTEXT_WINDOW);

    let mut llm = state.models.llm();
    let id = unique_id(&llm);
    let display_name = fields.name.clone();
    let profile = ModelProfile {
        id: id.clone(),
        name: fields.name,
        enabled: request.enabled.unwrap_or(true),
        base_url: fields.base_url,
        api_path: fields.api_path,
        model: fields.model,
        model_name: fields.model_name,
        api_key_env: request
            .api_key_env
            .clone()
            .unwrap_or_default()
            .trim()
            .to_string(),
        vision: request.vision.unwrap_or(false),
        reasoning: request.reasoning.unwrap_or(false),
        context_window,
        ..ModelProfile::default()
    };
    llm.profiles.push(profile);

    let key = request
        .api_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let persisted = persist_with_key(&state, &llm, &id, key, None)?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "model", "model.created", "ok")
            .target(&id)
            .detail(json!({
                "name": display_name,
                // 地址只记 host，不记可能带 token 的完整 URL。
                "model": request.model.trim(),
                "base_url": host_of(&request.base_url),
            })),
    )
    .await;

    let view = view_of(&state, &id);
    Ok((
        StatusCode::CREATED,
        Json(json!({ "model": view, "persisted": persisted })),
    ))
}

// ---------------------------------------------------------------------------
// 更新
// ---------------------------------------------------------------------------

pub async fn update(
    State(state): State<AppState>,
    axum::Extension(device): axum::Extension<AuthDevice>,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<UpdateModelRequest>,
) -> Result<Json<Value>, ApiRejection> {
    let mut llm = state.models.llm();
    let index = match profile_index(&mut llm, &id) {
        Some(index) => index,
        None => return Err(not_found(&id)),
    };

    let current = if id == DEFAULT_PROFILE_ID {
        llm.builtin_profile()
    } else {
        llm.profiles[index].clone()
    };

    let name = request.name.clone().unwrap_or(current.name.clone());
    let model_name = request
        .model_name
        .clone()
        .unwrap_or(current.model_name.clone());
    let base_url = request.base_url.clone().unwrap_or(current.base_url.clone());
    let model = request.model.clone().unwrap_or(current.model.clone());
    let api_path = request.api_path.clone().unwrap_or(current.api_path.clone());
    let fields = model_profiles::validate_fields(&name, &model_name, &base_url, &model, &api_path)
        .map_err(invalid)?;
    let context_window = match request.context_window {
        Some(value) => model_profiles::validate_context_window(value).map_err(invalid)?,
        None => current.context_window,
    };

    let updated = ModelProfile {
        id: current.id.clone(),
        name: fields.name,
        enabled: request.enabled.unwrap_or(current.enabled),
        base_url: fields.base_url,
        api_path: fields.api_path,
        model: fields.model,
        model_name: fields.model_name,
        api_key_env: request
            .api_key_env
            .clone()
            .unwrap_or(current.api_key_env)
            .trim()
            .to_string(),
        vision: request.vision.unwrap_or(current.vision),
        reasoning: request.reasoning.unwrap_or(current.reasoning),
        context_window,
        timeout_ms: current.timeout_ms,
        stream_idle_timeout_ms: current.stream_idle_timeout_ms,
    };

    if id == DEFAULT_PROFILE_ID {
        // 默认档散落在 `llm` 主节的字段上，没有独立的 profiles 条目可改。
        llm.enabled = updated.enabled;
        llm.base_url = updated.base_url;
        llm.api_path = updated.api_path;
        llm.model = updated.model;
        llm.model_name = updated.model_name;
        llm.api_key_env = updated.api_key_env;
        llm.vision = updated.vision;
        llm.reasoning = updated.reasoning;
        llm.context_window = updated.context_window;
    } else {
        llm.profiles[index] = updated;
    }

    let previous = state.models.secrets().get(&id);
    let key = if request.clear_api_key.unwrap_or(false) {
        Some("")
    } else {
        request
            .api_key
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
    };
    let persisted = persist_with_key(&state, &llm, &id, key, previous.as_deref())?;

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "model", "model.updated", "ok")
            .target(&id)
            .detail(json!({ "cleared_key": request.clear_api_key.unwrap_or(false) })),
    )
    .await;

    Ok(Json(
        json!({ "model": view_of(&state, &id), "persisted": persisted }),
    ))
}

// ---------------------------------------------------------------------------
// 删除
// ---------------------------------------------------------------------------

pub async fn delete(
    State(state): State<AppState>,
    axum::Extension(device): axum::Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiRejection> {
    if id == DEFAULT_PROFILE_ID {
        return Err(ApiRejection::new(
            ErrorCode::InvalidRequest,
            "cannot delete builtin profile",
            "默认配置来自配置文件主节，不能删除；可以直接编辑它，或把别的配置设为当前",
        ));
    }

    let mut llm = state.models.llm();
    let Some(index) = profile_index(&mut llm, &id) else {
        return Err(not_found(&id));
    };
    llm.profiles.remove(index);

    // 删的是当前生效项 → 回落到默认档，否则 active 会指向一条不存在的记录。
    let was_active = llm.active_id() == id;
    if was_active {
        llm.active = String::new();
    }

    let persisted = persist(&state, &llm)?;
    // 配置已落盘，密钥文件是残留的话下次新建同 id 会撞上一把旧 Key。
    if let Err(err) = state.models.secrets().remove(&id) {
        tracing::warn!(%err, profile_id = %id, "删除模型配置后清理密钥失败");
    }
    state.apply_llm(llm);

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "model", "model.deleted", "ok")
            .target(&id)
            .detail(json!({ "was_active": was_active })),
    )
    .await;

    Ok(Json(json!({
        "deleted": id,
        "active_id": state.models.active_id(),
        "persisted": persisted,
    })))
}

// ---------------------------------------------------------------------------
// 设为当前
// ---------------------------------------------------------------------------

pub async fn activate(
    State(state): State<AppState>,
    axum::Extension(device): axum::Extension<AuthDevice>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiRejection> {
    let mut llm = state.models.llm();
    if profile_index(&mut llm, &id).is_none() {
        return Err(not_found(&id));
    }

    // 默认档用空串表示：这样即使以后 id 命名规则变了，老配置文件也不会失效。
    llm.active = if id == DEFAULT_PROFILE_ID {
        String::new()
    } else {
        id.clone()
    };
    let persisted = persist(&state, &llm)?;
    let active = state.apply_llm(llm);

    audit::record(
        &state.pool,
        &AuditEntry::new(&device.device_id, "model", "model.activated", "ok")
            .target(&id)
            .detail(json!({
                "model": active.model,
                "available": active.available(),
                "reason": active.reason,
            })),
    )
    .await;

    Ok(Json(json!({
        "active_id": active.id,
        "model": view_of(&state, &id),
        "persisted": persisted,
        "available": active.available(),
        "reason": active.reason,
    })))
}

// ---------------------------------------------------------------------------
// 测试连接
// ---------------------------------------------------------------------------

pub async fn test(
    State(state): State<AppState>,
    ApiJson(request): ApiJson<TestModelRequest>,
) -> Json<Value> {
    // 已保存配置打底，表单里现填的字段逐个覆盖：用户改了一半就来点测试，
    // 测的应当是他眼前看到的这一份，而不是磁盘上的旧值。
    let stored = request
        .id
        .as_deref()
        .filter(|id| !id.is_empty())
        .and_then(|id| {
            state
                .models
                .profiles()
                .into_iter()
                .find(|profile| profile.id == id)
        });

    let base_url = request
        .base_url
        .clone()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| stored.as_ref().map(|profile| profile.base_url.clone()))
        .unwrap_or_default();
    let model = request
        .model
        .clone()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| stored.as_ref().map(|profile| profile.model.clone()))
        .unwrap_or_default();
    let api_path = request
        .api_path
        .clone()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| stored.as_ref().map(|profile| profile.api_path.clone()))
        .unwrap_or_else(|| "/v1".to_string());

    // 模型名不参与请求构造，探测时不必传；这里只看地址、模型ID与路径前缀。
    if let Err(reason) = model_profiles::validate_fields("测试", "", &base_url, &model, &api_path)
    {
        return Json(json!({
            "ok": false,
            "error_code": "invalid_request",
            "message": reason,
            "hint": "补齐网关地址与模型ID后再测试",
        }));
    }

    // 探测要按"用户眼前的这份表单"发请求：勾了「支持推理等级」才会带上
    // `reasoning_effort: none`，否则测的是另一套请求形状。
    let reasoning = request
        .reasoning
        .or_else(|| stored.as_ref().map(|profile| profile.reasoning))
        .unwrap_or(false);
    let profile = ModelProfile {
        id: stored
            .as_ref()
            .map(|profile| profile.id.clone())
            .unwrap_or_else(|| "probe".to_string()),
        name: "测试".to_string(),
        base_url,
        api_path,
        model,
        reasoning,
        ..ModelProfile::default()
    };

    let provided = request
        .api_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let key = match provided {
        Some(key) => Some(key),
        None => model_profiles::resolve_key(&profile, state.models.secrets()).key,
    };
    let Some(key) = key else {
        return Json(json!({
            "ok": false,
            "error_code": "no_key",
            "message": "没有可用的密钥",
            "hint": "填一把 API Key 再测试；已经保存过的配置留空即可复用",
        }));
    };

    let client = LlmClient::from_profile(&profile, key);
    match client.probe().await {
        Ok(latency_ms) => Json(json!({
            "ok": true,
            "latency_ms": latency_ms,
            "endpoint": client.endpoint(),
            "message": format!("连接正常，往返 {latency_ms} ms"),
        })),
        Err(failure) => Json(json!({
            "ok": false,
            "error_code": failure.code,
            "status": failure.status,
            "endpoint": client.endpoint(),
            "message": failure.message,
            "hint": failure.hint,
        })),
    }
}

// ---------------------------------------------------------------------------
// 内部
// ---------------------------------------------------------------------------

fn invalid(message: String) -> ApiRejection {
    ApiRejection::new(ErrorCode::InvalidRequest, message.clone(), message)
}

fn not_found(id: &str) -> ApiRejection {
    ApiRejection::new(
        ErrorCode::NotFound,
        format!("model profile {id} not found"),
        "这条模型配置不存在，可能已被删除；刷新列表后重试",
    )
}

/// 找到一条配置在 `llm.profiles` 里的下标。默认档返回 `Some(0)` 占位。
fn profile_index(llm: &mut LlmConfig, id: &str) -> Option<usize> {
    if id == DEFAULT_PROFILE_ID {
        // 默认档永远存在：用 0 当占位，调用方按 id 再判一次是不是默认档。
        return Some(0);
    }
    llm.profiles.iter().position(|profile| profile.id == id)
}

fn unique_id(llm: &LlmConfig) -> String {
    loop {
        let id = model_profiles::new_profile_id();
        if !llm.profiles.iter().any(|profile| profile.id == id) {
            return id;
        }
    }
}

/// 只记主机名：完整 URL 可能自带查询参数里的令牌。
fn host_of(raw: &str) -> String {
    raw.trim()
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(raw)
        .split('/')
        .next()
        .unwrap_or_default()
        .to_string()
}

fn view_of(state: &AppState, id: &str) -> Option<ProfileView> {
    state.models.views().into_iter().find(|view| view.id == id)
}

/// 落盘 `llm` 节。返回是否真的写进了文件。
fn persist(state: &AppState, llm: &LlmConfig) -> Result<bool, ApiRejection> {
    state.config.save_llm_section(llm).map_err(|err| {
        tracing::error!(%err, "写回模型配置失败");
        ApiRejection::new(
            ErrorCode::InternalError,
            format!("写入配置文件失败: {err}"),
            "服务端写配置文件失败，本次修改没有生效；检查配置文件与数据目录的权限",
        )
    })
}

/// 落盘配置并处理密钥写入，两步要么都成功、要么回滚密钥。
///
/// `key`：`Some("")` 表示清空，`Some(v)` 表示写入，`None` 表示不动。
fn persist_with_key(
    state: &AppState,
    llm: &LlmConfig,
    id: &str,
    key: Option<&str>,
    previous: Option<&str>,
) -> Result<bool, ApiRejection> {
    // 先落盘配置：它是最可能失败的一步（只读目录、磁盘满），失败时密钥还没动。
    let persisted = persist(state, llm)?;

    let Some(key) = key else {
        state.apply_llm(llm.clone());
        return Ok(persisted);
    };

    let secrets = state.models.secrets();
    let result = if key.is_empty() {
        secrets.remove(id)
    } else {
        secrets.set(id, key)
    };

    if let Err(err) = result {
        tracing::error!(%err, profile_id = %id, "写入模型密钥失败");
        // 配置已经落盘：尽最大努力恢复密钥，让"配置写的"与"密钥能用的"一致。
        match previous {
            Some(old) => {
                let _ = secrets.set(id, old);
            }
            None => {
                let _ = secrets.remove(id);
            }
        }
        return Err(ApiRejection::new(
            ErrorCode::InternalError,
            format!("写入密钥文件失败: {err}"),
            "密钥没能保存，模型配置已保存但会显示「缺少密钥」；检查数据目录权限后重试",
        ));
    }

    state.apply_llm(llm.clone());
    Ok(persisted)
}
