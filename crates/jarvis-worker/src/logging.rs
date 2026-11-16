//! 日志初始化。
//!
//! 与 `jarvis-service` 保持同一套规则：环境变量 `PERSONAL_AGENT_LOG` 控制级别，
//! 默认 `info`，结构化日志走 stderr。
//!
//! 两个进程各自初始化，不抽成公共 crate：可观测性属于各二进制的运行期配置，
//! 未来 worker 可能改用不同输出（如写入文件供 supervisor 采集）。

use tracing_subscriber::{fmt, prelude::*, EnvFilter};

pub(crate) fn init() {
    let filter =
        EnvFilter::try_from_env("PERSONAL_AGENT_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().with_target(true))
        .init();
}
