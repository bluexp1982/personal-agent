//! 日志初始化。
//!
//! 环境变量 `PERSONAL_AGENT_LOG` 覆盖默认级别（默认 `info`）。
//! 生产环境下所有日志走 stderr，由系统服务管理器收集。

use tracing_subscriber::{fmt, prelude::*, EnvFilter};

/// 初始化全局 subscriber。重复调用会 panic，因此只在 `main` 里调一次。
pub fn init() {
    let filter =
        EnvFilter::try_from_env("PERSONAL_AGENT_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().with_target(true))
        .init();
}
