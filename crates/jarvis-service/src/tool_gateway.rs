//! 对话工具网关。
//!
//! 对话只允许**只读**工具，当前是 `web.fetch` 与 `weather.current`。真正执行在
//! `jarvis-worker`：域名白名单、超时、体积上限只有一套实现。service 不复制这套逻辑，
//! 只负责把调用转发过去、把结果或失败归一成 [`ToolError`]。
//!
//! worker 未连接、超时、断线都必须**立即失败**——对话宁可写"未核实"，也不能挂住。

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use crate::clock::now_ms;
use crate::worker::WorkerHandle;

/// 一条可引用的来源。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub url: String,
    /// 采集时间（Unix 毫秒）。由执行工具的一侧记录，不由模型填写。
    pub fetched_at: i64,
    /// 来源类型：网页 / 记忆 / 本地文档，客户端据此分支渲染。
    pub kind: protocol::SourceKind,
    /// 记忆来源才有：`memories.id`，客户端据此跳详情。
    pub memory_id: Option<String>,
}

impl Source {
    /// 网页来源：工具网关产出的来源全部是这一类。
    pub fn web(url: impl Into<String>, fetched_at: i64) -> Self {
        Self {
            url: url.into(),
            fetched_at,
            kind: protocol::SourceKind::Web,
            memory_id: None,
        }
    }

    /// 记忆来源：`url` 用稳定标识 `memory://{id}`，不是可点击的 http 地址。
    pub fn memory(memory_id: impl Into<String>, fetched_at: i64) -> Self {
        let id = memory_id.into();
        Self {
            url: format!("memory://{id}"),
            fetched_at,
            kind: protocol::SourceKind::Memory,
            memory_id: Some(id),
        }
    }

    /// 本地文件来源（`read_file` / `search_content`）。
    ///
    /// `path` 用**项目相对路径**而不是绝对路径：绝对路径会把用户名与目录结构
    /// 写进会话记录，而相对路径在来源卡片上也更容易读。`url` 仍按 `file://`
    /// 约定拼，客户端据此识别为本地文档、不当作外链打开。
    pub fn doc(path: impl Into<String>, fetched_at: i64) -> Self {
        let path = path.into();
        Self {
            url: format!("file://{path}"),
            fetched_at,
            kind: protocol::SourceKind::Doc,
            memory_id: None,
        }
    }
}

/// 工具返回的结果。
#[derive(Debug, Clone)]
pub struct ToolOutcome {
    pub summary: String,
    /// 可引用的来源。**搜索类工具没有来源**：候选页并没有被读过，
    /// 把结果页地址写成来源等于伪造采集时间，客户端会渲染出一张点开无意义的卡片。
    pub source: Option<Source>,
    pub size: i64,
}

#[derive(Debug, Clone, thiserror::Error)]
pub enum ToolError {
    #[error("工具不可用：{0}")]
    Unavailable(String),
    #[error("工具被拒绝：{0}")]
    Denied(String),
    #[error("工具执行失败：{0}")]
    Failed(String),
}

impl ToolError {
    /// 回填给模型的失败说明（模型据此写“未核实”）。
    pub fn reason(&self) -> String {
        self.to_string()
    }
}

pub type ToolFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub trait ToolGateway: std::fmt::Debug + Send + Sync {
    /// 按"工具名 + 参数"调用只读工具。实现方负责超时与错误归一。
    fn call(
        &self,
        tool: &str,
        args: serde_json::Value,
    ) -> ToolFuture<'_, Result<ToolOutcome, ToolError>>;

    /// 读一个 URL：`web.fetch` 的便捷入口。
    ///
    /// 保留它作为默认方法，是为了让"只想说清读哪个地址"的调用方不必拼 JSON；
    /// 请求本身仍然走 [`ToolGateway::call`]，不会出现两套执行路径。
    fn fetch(&self, url: String) -> ToolFuture<'_, Result<ToolOutcome, ToolError>> {
        Box::pin(async move {
            self.call("web.fetch", serde_json::json!({ "url": url }))
                .await
        })
    }
}

/// 走 `jarvis-worker` 的网关。
#[derive(Debug, Clone)]
pub struct WorkerToolGateway {
    handle: WorkerHandle,
    timeout: Duration,
}

impl WorkerToolGateway {
    pub fn new(handle: WorkerHandle, timeout: Duration) -> Self {
        Self { handle, timeout }
    }
}

impl ToolGateway for WorkerToolGateway {
    fn call(
        &self,
        tool: &str,
        args: serde_json::Value,
    ) -> ToolFuture<'_, Result<ToolOutcome, ToolError>> {
        // 工具名转 owned：返回的 future 只跟随 `&self` 的生命周期，
        // 否则调用方传临时字符串时签名无法满足 `'_`。
        let tool = tool.to_string();
        Box::pin(async move {
            let reply = self
                .handle
                .call_tool(&tool, args, self.timeout)
                .await
                .map_err(|reason| {
                    if reason.contains("拒绝") {
                        ToolError::Denied(reason)
                    } else {
                        ToolError::Unavailable(reason)
                    }
                })?;

            if !reply.ok {
                let reason = reply.error.unwrap_or_else(|| "工具执行失败".to_string());
                // worker 侧的拒绝（未配置白名单、域名不在白名单）语义上是“被拒绝”，
                // 与网络故障区分开，便于日志排查。
                return Err(if reason.contains("拒绝") || reason.contains("未配置") {
                    ToolError::Denied(reason)
                } else {
                    ToolError::Failed(reason)
                });
            }

            // 来源是可选的：搜索没有读过的页面，就不该有来源卡片。
            // 采集时间只在真的读了页面时才有意义，缺失时用本地时钟兜底。
            let source = reply
                .source_url
                .map(|url| Source::web(url, reply.fetched_at.unwrap_or_else(now_ms)));

            Ok(ToolOutcome {
                summary: reply.summary,
                source,
                size: reply.size,
            })
        })
    }
}

/// worker 未启用时的网关：一律失败，让回答明确写“未核实”。
#[derive(Debug, Default)]
pub struct DisabledToolGateway;

impl ToolGateway for DisabledToolGateway {
    fn call(
        &self,
        _tool: &str,
        _args: serde_json::Value,
    ) -> ToolFuture<'_, Result<ToolOutcome, ToolError>> {
        Box::pin(async { Err(ToolError::Unavailable("执行进程未启用".to_string())) })
    }
}
