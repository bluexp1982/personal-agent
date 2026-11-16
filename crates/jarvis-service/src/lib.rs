//! `jarvis-service` 内部实现。
//!
//! 拆成 lib + bin 的原因：集成测试（`tests/` 目录）只能引用 lib crate。
//! 配对、鉴权、任务与审批都需要真实启动服务来测，靠"起进程 + 发请求"既慢又难断言
//! 中间状态，因此把实现放在 lib 里、`main.rs` 只保留 CLI 与 daemon 生命周期。
//!
//! 这里不导出任何"给其他 crate 用"的 API——它是二进制的一部分，
//! 跨模块共享的类型一律走 `protocol` crate。

pub mod admin;
pub mod api;
pub mod app;
pub mod approval;
pub mod archive;
pub mod artifact_store;
pub mod attachment;
pub mod audit;
pub mod auth;
pub mod chat;
pub mod clock;
pub mod code;
pub mod code_proxy;
pub mod compaction;
pub mod config;
pub mod conversation;
pub mod db;
pub mod fs_browse;
pub mod git;
pub mod grants;
pub mod heartbeat;
pub mod identity;
pub mod ids;
pub mod llm;
pub mod local_tools;
pub mod logging;
pub mod media;
pub mod memory;
pub mod model;
pub mod model_hub;
pub mod model_profiles;
pub mod model_secrets;
pub mod pairing;
pub mod plugin;
pub mod recording;
pub mod responder;
pub mod runner;
pub mod service_ctl;
pub mod shutdown;
pub mod sse;
pub mod state;
pub mod task;
pub mod task_prepare;
pub mod theme;
pub mod ticker;
pub mod title;
pub mod tls;
pub mod tool_gateway;
pub mod tool_proxy;
pub mod web_preview;
pub mod worker;
pub mod project;
pub mod project_files;
pub mod worktree;
pub mod write_store;

#[cfg(unix)]
pub mod cli;
