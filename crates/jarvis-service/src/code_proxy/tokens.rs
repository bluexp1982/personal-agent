//! 编码任务的一次性代理令牌。
//!
//! 为什么不是"把真 key 给 worker"：真 key 一旦进了子进程环境，就再也收不回来，
//! 也没法按任务撤销。这里发的令牌：
//!
//! - **只对本地代理有效**：拿去直连上游没有任何用处；
//! - **绑定任务**：网关据此计账、限模型、写审计；
//! - **有 TTL**：任务超时后自动失效，不依赖"任务一定走到终态"这种假设；
//! - **只在内存**：进程重启即全部失效，而那时任务本就该 `needs_retry`。

use std::collections::HashMap;

use rand::RngCore;

/// 一枚令牌对应的授权范围。
#[derive(Debug, Clone)]
pub(crate) struct TaskToken {
    pub(crate) task_id: String,
    /// Unix 毫秒。
    pub(crate) expires_at: i64,
}

#[derive(Debug, Default)]
pub(crate) struct TokenStore {
    tokens: HashMap<String, TaskToken>,
}

impl TokenStore {
    /// 给任务发一枚令牌。`ttl_ms` 与任务超时对齐。
    pub(crate) fn mint(&mut self, task_id: &str, ttl_ms: i64) -> String {
        let token = random_token();
        self.tokens.insert(
            token.clone(),
            TaskToken {
                task_id: task_id.to_string(),
                expires_at: crate::clock::now_ms() + ttl_ms.max(1_000),
            },
        );
        token
    }

    /// 解析令牌。顺手清掉已过期的条目，避免内存随任务数无限增长。
    pub(crate) fn resolve(&mut self, token: &str) -> Option<TaskToken> {
        let now = crate::clock::now_ms();
        self.tokens.retain(|_, entry| entry.expires_at > now);
        self.tokens.get(token).cloned()
    }

    /// 任务进入终态后立刻吊销，不等 TTL。
    pub(crate) fn revoke_task(&mut self, task_id: &str) {
        self.tokens.retain(|_, entry| entry.task_id != task_id);
    }

    /// 当前仍有效的任务 id，管理面展示用。
    pub(crate) fn active_tasks(&mut self) -> Vec<String> {
        let now = crate::clock::now_ms();
        self.tokens.retain(|_, entry| entry.expires_at > now);
        self.tokens
            .values()
            .map(|entry| entry.task_id.clone())
            .collect()
    }
}

/// 32 字节随机令牌，十六进制表示。
fn random_token() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minted_token_resolves_to_its_task() {
        let mut store = TokenStore::default();
        let token = store.mint("task_1", 60_000);

        let entry = store.resolve(&token).expect("应能解析");
        assert_eq!(entry.task_id, "task_1");
        assert_ne!(token.len(), 0);
    }

    #[test]
    fn tokens_are_unique_and_long_enough() {
        let mut store = TokenStore::default();
        let a = store.mint("task_1", 60_000);
        let b = store.mint("task_2", 60_000);
        assert_ne!(a, b);
        assert_eq!(a.len(), 64, "32 字节应为 64 个十六进制字符");
    }

    #[test]
    fn expired_token_is_rejected() {
        let mut store = TokenStore::default();
        // TTL 有 1 秒下限，这里直接把过期时间改成过去，避免 sleep。
        let token = store.mint("task_1", 60_000);
        store.tokens.get_mut(&token).expect("应存在").expires_at = crate::clock::now_ms() - 1;

        assert!(store.resolve(&token).is_none());
        assert!(store.active_tasks().is_empty(), "过期条目应被清理");
    }

    #[test]
    fn revoke_removes_every_token_of_the_task() {
        let mut store = TokenStore::default();
        let a = store.mint("task_1", 60_000);
        let b = store.mint("task_1", 60_000);
        let c = store.mint("task_2", 60_000);

        store.revoke_task("task_1");

        assert!(store.resolve(&a).is_none());
        assert!(store.resolve(&b).is_none());
        assert!(store.resolve(&c).is_some(), "别的任务不受影响");
    }

    #[test]
    fn unknown_token_is_rejected() {
        let mut store = TokenStore::default();
        assert!(store.resolve("not-a-token").is_none());
    }
}
