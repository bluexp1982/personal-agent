//! 版本常量。客户端与服务端在握手时交换这些值，用于兼容性判断。

/// 二进制版本，取自 Cargo.toml。
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// 对外 HTTP 契约版本（`api-spec/openapi.yaml` 的 `/api/*` 前缀）。
pub const API_VERSION: &str = "v1";

/// service 与 worker 之间的内部 IPC 契约版本。
///
/// 与 `ipc::IPC_VERSION`（线缆信封版本）同步进位：新增 `model_call` /
/// `model_result` 属破坏性变更，混跑旧 worker 会因未知 `type` 整行解析失败。
pub const IPC_CONTRACT_VERSION: &str = "internal/v3";
