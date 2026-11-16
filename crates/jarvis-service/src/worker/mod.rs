//! 与 `jarvis-worker` 的跨进程集成。
//!
//! 分工：
//! - [`supervisor`]：拉起进程、监听本地套接字、心跳与重启；只负责"活着且连上"。
//! - [`events`]：把 worker 上报的事件应用成任务状态、审批、产物与审计。
//! - [`executor`]：实现 [`crate::runner::TaskExecutor`]，向 worker 下发命令。
//! - [`model_bridge`]：代替 worker 调模型，把预算、密钥与用量审计收敛在服务端。
//!
//! 状态权威始终在服务端：worker 只发事件，不写数据库。

pub mod events;
pub mod executor;
pub mod model_bridge;
pub mod supervisor;

pub use executor::WorkerExecutor;
pub use model_bridge::ModelBridge;
pub use supervisor::{spawn, WorkerHandle, WorkerPhase, WorkerView};
