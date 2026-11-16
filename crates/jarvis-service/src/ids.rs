//! 对象标识生成。
//!
//! 统一形如 `<prefix>_<26 字符 base32>`：带前缀便于日志与审计里区分对象类型，
//! 128 bit 随机保证同一前缀内不碰撞（无需查库）。

use crate::identity::B32;

/// 带前缀的随机 id。
pub fn new_id(prefix: &str) -> String {
    let bytes: [u8; 16] = rand::random();
    format!("{prefix}_{}", base32::encode(B32, &bytes).to_lowercase())
}

/// 只用于测试断言：id 是否带预期前缀。
pub fn has_prefix(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix)
        .and_then(|rest| rest.strip_prefix('_'))
        .is_some_and(|rest| rest.len() == 26)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_prefixed_and_unique() {
        let first = new_id("conv");
        let second = new_id("conv");

        assert!(has_prefix(&first, "conv"));
        assert_ne!(first, second);
    }

    #[test]
    fn rejects_wrong_prefix() {
        let id = new_id("task");
        assert!(!has_prefix(&id, "conv"));
    }
}
