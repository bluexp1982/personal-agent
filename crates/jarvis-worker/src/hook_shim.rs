//! `jarvis-worker hook-shim`：编码 CLI 的 `PreToolUse` 钩子客户端。
//!
//! 为什么是 worker 的隐藏子命令而不是一个 Node/Python 脚本：
//! - 随 worker 二进制一起分发，不引入额外运行时；
//! - 不受用户本机 Node 环境影响；
//! - 与决策端点用同一份代码连 socket，协议不会两边漂移。
//!
//! 输出契约（codebuddy v2.177.1）：
//! `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|deny",
//!   "permissionDecisionReason":"..."}}`，退出码恒为 0。
//!
//! **所有失败路径都是 deny**：连不上端点、超时、返回格式不认识，一律不放行。
//! 退出码保持 0 是刻意的：非 0 会被 CLI 当成"钩子崩了"而继续按自己的权限策略走。

use std::io::{Read, Write};
use std::path::Path;
use std::time::Duration;

use serde_json::{json, Value};

/// 与决策端点一致：115 秒。超过它就当没有人看。
const TIMEOUT: Duration = Duration::from_secs(115);

/// 执行一次钩子调用，返回进程退出码（恒为 0）。
pub(crate) fn run(socket: &Path) -> i32 {
    let mut raw = String::new();
    if let Err(err) = std::io::stdin().read_to_string(&mut raw) {
        tracing::warn!(%err, "读取钩子 stdin 失败");
    }

    let decision = match build_request(&raw) {
        Some(request) => query(socket, &request),
        None => Err("钩子输入不是合法 JSON".to_string()),
    };

    let payload = match decision {
        Ok(value) => {
            let approved = value
                .get("approved")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let reason = value
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            render(approved, &reason)
        }
        Err(reason) => render(false, &reason),
    };

    let mut stdout = std::io::stdout();
    if let Err(err) = writeln!(stdout, "{payload}") {
        tracing::warn!(%err, "输出钩子结论失败");
    }
    let _ = stdout.flush();
    0
}

/// 把 CLI 给的输入压成端点认识的形状。
fn build_request(raw: &str) -> Option<Value> {
    let value: Value = serde_json::from_str(raw).ok()?;
    Some(json!({
        "tool": value.get("tool_name").and_then(Value::as_str).unwrap_or("unknown"),
        "input": value.get("tool_input").cloned().unwrap_or_else(|| json!({})),
    }))
}

/// 发给本机端点，读回一行结论。
fn query(socket: &Path, request: &Value) -> Result<Value, String> {
    let mut stream = std::os::unix::net::UnixStream::connect(socket)
        .map_err(|err| format!("决策端点不可用（{}）：{err}", socket.display()))?;
    let _ = stream.set_read_timeout(Some(TIMEOUT));
    let _ = stream.set_write_timeout(Some(TIMEOUT));

    let line = format!("{request}\n");
    stream
        .write_all(line.as_bytes())
        .map_err(|err| format!("发送决策请求失败：{err}"))?;

    let mut reader = std::io::BufReader::new(stream);
    let mut response = String::new();
    std::io::BufRead::read_line(&mut reader, &mut response)
        .map_err(|err| format!("等待决策超时或被中断：{err}"))?;

    serde_json::from_str(response.trim()).map_err(|err| format!("决策响应格式无效：{err}"))
}

fn render(approved: bool, reason: &str) -> Value {
    let mut output = json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": if approved { "allow" } else { "deny" },
        }
    });
    if !approved && !reason.is_empty() {
        output["hookSpecificOutput"]["permissionDecisionReason"] = json!(reason);
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_is_built_from_cli_payload() {
        let raw = r#"{"hook_event_name":"PreToolUse","tool_name":"Bash",
            "tool_input":{"command":"rm -rf build"}}"#;
        let request = build_request(raw).expect("应能解析");
        assert_eq!(request["tool"], "Bash");
        assert_eq!(request["input"]["command"], "rm -rf build");
    }

    #[test]
    fn broken_input_is_none() {
        assert!(build_request("not json").is_none());
    }

    #[test]
    fn allow_output_has_no_reason() {
        let value = render(true, "");
        assert_eq!(value["hookSpecificOutput"]["permissionDecision"], "allow");
        assert!(value["hookSpecificOutput"]
            .get("permissionDecisionReason")
            .is_none());
    }

    #[test]
    fn deny_output_carries_reason() {
        let value = render(false, "太危险");
        assert_eq!(value["hookSpecificOutput"]["permissionDecision"], "deny");
        assert_eq!(
            value["hookSpecificOutput"]["permissionDecisionReason"],
            "太危险"
        );
    }

    #[test]
    fn missing_socket_is_denied_not_allowed() {
        let err = query(Path::new("/tmp/pa-does-not-exist.sock"), &json!({}))
            .expect_err("连不上必须报错");
        assert!(err.contains("决策端点不可用"), "{err}");
    }
}
