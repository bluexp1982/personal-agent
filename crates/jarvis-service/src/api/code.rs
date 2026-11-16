//! 编码执行层的能力清单（只读）。
//!
//! 客户端只信任 service：它不该自己猜"这个 CLI 能不能工具级审批"，也不该
//! 按 provider 名字写死按钮文案。这里把三件事一次说清：
//! - `available`：现在真的能跑吗（未被显式禁用 + 可执行文件存在）。客户端用它
//!   填"执行方式"下拉，所以这一位必须与路由的可用性口径同源；
//! - `capabilities`：静态能力（来自 `protocol` 的唯一注册表）；
//! - `routing`：默认会怎么选（档位映射到哪个模型）。
//!
//! 放在 `/api/code/providers` 而不是塞进任务详情：能力是"服务端装了什么"，
//! 与某一个任务无关，客户端启动时拉一次就够。

use axum::extract::State;
use axum::Json;
use serde_json::{json, Value};

use crate::code::{available_providers, provider_available};
use crate::state::AppState;

pub async fn providers(State(state): State<AppState>) -> Json<Value> {
    let config = &state.config;
    let available = available_providers(config);

    let mut list = Vec::new();
    for id in protocol::SUPPORTED_CODE_PROVIDERS {
        let capabilities = protocol::provider_capabilities(id);
        let tool_approval = capabilities
            .map(|caps| match caps.tool_approval {
                protocol::ApprovalSupport::Native => "native",
                protocol::ApprovalSupport::Degraded => "degraded",
                protocol::ApprovalSupport::Unsupported => "unsupported",
            })
            .unwrap_or("unsupported");

        list.push(json!({
            "id": id,
            // 未登记也按启用处理：这一位现在只表示"没被显式关掉"。
            "enabled": config.code_provider_enabled(id),
            "available": provider_available(config, id),
            "bin": config.code_provider_bin(id).map(|path| path.to_string_lossy().into_owned()),
            "capabilities": {
                "tool_approval": tool_approval,
                "append_message": capabilities.map(|caps| caps.append_message).unwrap_or(false),
                "switch_model": capabilities.map(|caps| caps.switch_model).unwrap_or(false),
                "stream_events": capabilities.map(|caps| caps.stream_events).unwrap_or(false),
            },
        }));
    }

    Json(json!({
        "default_provider": config.code.provider,
        "available": available,
        "providers": list,
        "routing": {
            "preferred": config.code.routing.preferred,
            "fallback": config.code.routing.fallback,
            "tiers": {
                "fast": config.code_tier_model("fast"),
                "strong": config.code_tier_model("strong"),
            },
        },
    }))
}
