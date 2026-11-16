//! 跨 provider 复用的解析小工具与测试辅助。
//!
//! 放在这里而不是各文件里复制一份：`clamp` / `shell_quote` 一旦两份实现漂移，
//! 摘要长度与钩子转义就会出现"某一家 CLI 才有的怪问题"。

use std::path::Path;

use serde_json::json;

use super::HookSpec;

/// 把多行文本压成一行，超长截断并以 `…` 结尾。
pub(super) fn clamp(text: &str, max_chars: usize) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= max_chars {
        compact
    } else {
        compact.chars().take(max_chars).collect::<String>() + "…"
    }
}

/// 命令行参数的 shell 转义：钩子命令由 CLI 交给用户 shell 执行。
pub(super) fn shell_quote(path: &Path) -> String {
    let raw = path.to_string_lossy();
    if !raw.contains(|c: char| c.is_whitespace() || c == '\'' || c == '"') {
        return raw.into_owned();
    }
    format!("'{}'", raw.replace('\'', "'\\''"))
}

/// 在 PATH 里找一个可执行文件。不引入 `which` crate：只需要这一处。
pub(super) fn which(name: &str) -> Option<std::path::PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Claude 系 CLI 共用的 `PreToolUse` 钩子配置文档（CodeBuddy / Claude Code）。
///
/// `matcher` 用 `*`：只挂 `Bash|Write|Edit` 会留下盲区（MCP 与其它写工具
/// 同样能改文件）。`timeout` 是秒，取"审批 TTL 减 5"，保证钩子先放弃。
pub(super) fn hook_settings(hook: Option<&HookSpec>) -> serde_json::Value {
    match hook {
        Some(hook) => json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "*",
                    "hooks": [{
                        "type": "command",
                        "command": format!(
                            "{} hook-shim --socket {}",
                            shell_quote(&hook.shim),
                            shell_quote(&hook.socket)
                        ),
                        "timeout": hook.timeout_secs
                    }]
                }]
            }
        }),
        None => json!({ "hooks": {} }),
    }
}

#[cfg(test)]
pub(super) mod test_support {
    use std::path::PathBuf;

    /// 一个可写的临时目录。
    ///
    /// 不引 `tempfile`：worker 的 dev-dependency 里没有它，这里只要一个可写目录。
    pub(in crate::code::provider) fn tempdir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "pa-provider-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        dir
    }
}
