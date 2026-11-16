//! 分页游标。
//!
//! 分页一律用 cursor（`updated_at` 与 `id` 复合），不用 offset：
//! 任务与会话的状态会变化，offset 分页必然出现重复项或漏项。

use serde::{Deserialize, Serialize};

/// 复合游标。`updated_at` 为毫秒时间戳，`id` 为同一时间戳内的稳定排序键。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cursor {
    pub updated_at: i64,
    pub id: String,
}

/// 编码分隔符。`id` 内允许出现该字符，解码时只按首个分隔符切分。
const SEP: char = '.';

impl Cursor {
    pub fn new(updated_at: i64, id: impl Into<String>) -> Self {
        Self {
            updated_at,
            id: id.into(),
        }
    }

    /// 编码为不透明字符串，直接放进 `?cursor=`。
    pub fn encode(&self) -> String {
        format!("{}{}{}", self.updated_at, SEP, self.id)
    }

    /// 解码失败返回 `None`，调用方应转换为 `invalid_request` 错误，
    /// 不要静默回退到第一页——那会让客户端无限循环。
    pub fn decode(raw: &str) -> Option<Self> {
        let (ts, id) = raw.split_once(SEP)?;
        if id.is_empty() {
            return None;
        }
        let updated_at = ts.parse::<i64>().ok()?;
        Some(Self {
            updated_at,
            id: id.to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let cursor = Cursor::new(1_700_000_000_000, "conv_01");
        assert_eq!(Cursor::decode(&cursor.encode()), Some(cursor));
    }

    #[test]
    fn id_may_contain_separator() {
        let cursor = Cursor::new(42, "conv.01.2");
        let encoded = cursor.encode();
        assert_eq!(encoded, "42.conv.01.2");
        assert_eq!(Cursor::decode(&encoded), Some(cursor));
    }

    #[test]
    fn rejects_malformed_input() {
        assert_eq!(Cursor::decode(""), None);
        assert_eq!(Cursor::decode("no-separator"), None);
        assert_eq!(Cursor::decode("not-a-number.conv_01"), None);
        assert_eq!(Cursor::decode("42."), None);
    }
}
