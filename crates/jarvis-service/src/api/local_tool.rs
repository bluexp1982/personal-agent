//! `LocalToolCall` 的服务端处理：技能让 service 读一个项目文件。
//!
//! 这不是对外端点，而是 worker 经 IPC 发来的请求。之所以绕回来：
//! 路径准入（项目根、软链接不越界、密钥类文件拦截）只实现在这一侧，
//! worker 既不查库、也不知道任务属于哪个目录。
//!
//! 三条必须守住的边界：
//!
//! 1. `tool` 只能在 [`LOCAL_TOOL_WHITELIST`] 里——worker 不能点名任意工具；
//! 2. `task_id` 必须是还在跑的任务，否则就是拿别人的任务 id 越权读文件；
//! 3. 项目根必须存在且可访问，越界与敏感文件的拒绝由 `path_guard` 给出。

use protocol::{IpcMessage, LOCAL_TOOL_WHITELIST};
use sqlx::SqlitePool;

use crate::local_tools::{self, path_guard::ProjectRoot};
use crate::state::AppState;

/// 处理一次请求并回传结果。
///
/// 永远回一条 `LocalToolResult`：worker 在等着它，不回就等于把任务挂到超时。
pub(crate) async fn handle(
    state: &AppState,
    call_id: String,
    task_id: String,
    tool: String,
    args: serde_json::Value,
) {
    let (ok, content, error) = execute(state, &task_id, &tool, &args).await;

    let sent = state
        .worker
        .send(IpcMessage::LocalToolResult {
            call_id: call_id.clone(),
            ok,
            content,
            error,
        })
        .await;

    if !sent {
        tracing::warn!(%call_id, "回传本地工具结果失败：worker 已断开");
    }
}

async fn execute(
    state: &AppState,
    task_id: &str,
    tool: &str,
    args: &serde_json::Value,
) -> (bool, String, Option<String>) {
    if !LOCAL_TOOL_WHITELIST.contains(&tool) {
        return (
            false,
            String::new(),
            Some(format!("工具 {tool} 不在技能可用的只读工具里")),
        );
    }

    let Some(root_path) = active_task_project(&state.pool, task_id).await else {
        return (
            false,
            String::new(),
            Some(
                "这个任务没有可用的项目（无归属直聊、任务已结束或项目已删除），读不到文件"
                    .to_string(),
            ),
        );
    };

    let root = match ProjectRoot::new(&root_path) {
        Ok(root) => root,
        Err(err) => return (false, String::new(), Some(err.to_string())),
    };

    let Some(outcome) = local_tools::call_one(root, tool, &args.to_string()).await else {
        return (false, String::new(), Some(format!("未知工具 {tool}")));
    };

    if outcome.ok {
        (true, outcome.content, None)
    } else {
        // 失败也把可读原因带回 content：worker 会把它原样写进「未获取 + 原因」，
        // 用户看到的是"为什么没读到"，而不是一句干巴巴的失败。
        (false, String::new(), Some(outcome.content))
    }
}

/// 查任务所属项目的目录。
///
/// 只认**还在跑**的任务：任务结束后 worker 若还在发请求，那是越权。
async fn active_task_project(pool: &SqlitePool, task_id: &str) -> Option<String> {
    let row = sqlx::query_as::<_, (String,)>(
        "SELECT w.path FROM tasks t \
         JOIN conversations c ON c.id = t.conversation_id \
         JOIN projects w ON w.id = c.project_id \
         WHERE t.id = ? AND t.deleted_at IS NULL \
           AND t.state IN ('queued', 'running', 'needs_input', 'needs_approval')",
    )
    .bind(task_id)
    .fetch_optional(pool)
    .await
    .ok()
    .flatten();

    row.map(|(path,)| path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whitelist_rejects_write_and_unknown_tools() {
        for tool in ["write_file", "shell", "preview_url", ""] {
            assert!(
                !LOCAL_TOOL_WHITELIST.contains(&tool),
                "{tool} 不该在技能可用的工具里"
            );
        }
        for tool in ["read_file", "list_dir", "search_file", "search_content"] {
            assert!(LOCAL_TOOL_WHITELIST.contains(&tool), "{tool} 应可用");
        }
    }
}
