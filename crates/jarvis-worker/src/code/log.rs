//! 运行日志的环形缓冲与进度节流。
//!
//! 编码 CLI 的输出量不可控：一次任务几万行很正常。这里做两件事：
//! - **存尾部而不是全部**：产物 `run_log` 只需要"最后发生了什么"；
//! - **节流上报**：进度事件按时间或条数触发，避免每行一条 IPC。

use std::collections::VecDeque;

/// 单行超过这个长度就截断：日志里出现巨型 JSON 时不该把整个产物挤掉。
const MAX_LINE_CHARS: usize = 2_000;

/// 行数与字节双上限：任何一个先到就淘汰最旧的行。
///
/// 只用行数会因为单行很长而爆内存，只用字节会让"行数很多但都很短"的日志失去上下文。
#[derive(Debug)]
pub(crate) struct LineRing {
    max_lines: usize,
    max_bytes: usize,
    lines: VecDeque<String>,
    bytes: usize,
}

impl LineRing {
    pub(crate) fn new(max_lines: usize, max_bytes: usize) -> Self {
        Self {
            max_lines,
            max_bytes,
            lines: VecDeque::new(),
            bytes: 0,
        }
    }

    pub(crate) fn push(&mut self, line: &str) {
        let line = clamp(line, MAX_LINE_CHARS);
        if line.trim().is_empty() {
            return;
        }

        // +1 是换行符：tail() 拼回去时它会真实存在，不算进来就会超预算。
        self.bytes += line.len() + 1;
        self.lines.push_back(line);

        while self.lines.len() > self.max_lines || self.bytes > self.max_bytes {
            let Some(dropped) = self.lines.pop_front() else {
                break;
            };
            self.bytes = self.bytes.saturating_sub(dropped.len() + 1);
        }
    }

    /// 尾部若干行，按时间正序。
    pub(crate) fn tail(&self) -> String {
        self.lines.iter().cloned().collect::<Vec<_>>().join("\n")
    }

    pub(crate) fn len(&self) -> usize {
        self.lines.len()
    }
}

fn clamp(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    text.chars().take(max_chars).collect::<String>() + "…"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_oldest_lines_beyond_line_cap() {
        let mut ring = LineRing::new(3, 10_000);
        for index in 0..5 {
            ring.push(&format!("line{index}"));
        }
        assert_eq!(ring.len(), 3);
        assert_eq!(ring.tail(), "line2\nline3\nline4");
    }

    #[test]
    fn drops_oldest_lines_beyond_byte_cap() {
        // 5 字节一行 + 换行 = 6，上限 10 只能容纳一行。
        let mut ring = LineRing::new(100, 10);
        ring.push("12345");
        ring.push("67890");
        ring.push("abcde");
        assert!(ring.tail().len() <= 10, "字节上限未生效: {}", ring.tail());
        assert_eq!(ring.tail(), "abcde", "应只保留最新一行");
    }

    #[test]
    fn giant_line_is_clamped() {
        let mut ring = LineRing::new(4, 1_000_000);
        ring.push(&"啊".repeat(MAX_LINE_CHARS * 2));
        assert_eq!(ring.len(), 1);
        assert!(ring.tail().chars().count() <= MAX_LINE_CHARS + 1);
    }

    #[test]
    fn blank_lines_are_ignored() {
        let mut ring = LineRing::new(4, 1_000);
        ring.push("   ");
        ring.push("");
        assert!(ring.tail().trim().is_empty());
        assert_eq!(ring.len(), 0);
    }

    #[test]
    fn tail_preserves_order() {
        let mut ring = LineRing::new(10, 10_000);
        ring.push("first");
        ring.push("second");
        assert_eq!(ring.tail(), "first\nsecond");
    }
}
