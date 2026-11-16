//! Claude Code（实测 2.1.310）。
//!
//! 实测结论（2026-10-29，用真实 2.1.310 二进制验证）：
//! - `--output-format stream-json` 在 `-p` 下**必须**同时给 `--verbose`，否则直接报错退出；
//! - `ANTHROPIC_BASE_URL` 要写到 `{proxy}/internal/code`：CLI 自己拼 `/v1/messages`
//!   （实测路径是 `/internal/code/v1/messages?beta=true`，我们的路由能匹配，query 忽略）；
//! - 鉴权用 `ANTHROPIC_AUTH_TOKEN`（实测走 `Authorization: Bearer`），**不要**设
//!   `ANTHROPIC_API_KEY`：它会走 x-api-key，还会先去官方端点校验；
//! - 用户级 `~/.claude/settings.json` 里的 `env` 会**覆盖**进程环境变量（实测被它带到
//!   了别的网关），所以必须 `--setting-sources project`，只认我们用 `--settings` 给的那份；
//! - `PreToolUse` 钩子与 CodeBuddy 同源同形；`--permission-mode default` 下钩子
//!   `allow` 是工具能执行的唯一通道（实测文件真的被创建，`permission_decision.source=hook`）；
//! - `--mcp-config` 必须是 `{"mcpServers":{}}`，给 `{}` 会直接报配置非法。
//!
//! 与 CodeBuddy 的实现差异只有三处：命令参数、环境变量、事件结构（见 `parse`）。

use std::path::{Path, PathBuf};

use super::{CliEvent, CodingProvider, RunRequest};

pub(super) const ID: &str = "claude";

/// 令牌环境变量：Claude 从这里读 bearer，不落任何文件。
const TOKEN_ENV: &str = "ANTHROPIC_AUTH_TOKEN";
/// 工具面：与 CodeBuddy 保持同一份白名单。`--allowedTools` 不足以保证放行，
/// 真正的门禁在钩子上；这里只是别把用不到的工具塞给模型。
const TOOLS: &str = "Bash,Read,Write,Edit,Glob,Grep";

#[derive(Debug, Default)]
pub(crate) struct Claude;

impl CodingProvider for Claude {
    fn id(&self) -> &'static str {
        ID
    }

    fn resolve(&self, bin: Option<&Path>) -> Option<PathBuf> {
        match bin {
            Some(path) => path.is_file().then(|| path.to_path_buf()),
            None => super::shared::which(ID),
        }
    }

    fn write_config(&self, req: &RunRequest) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(&req.config_dir)?;
        let path = req.config_dir.join("claude-settings.json");
        // 钩子配置与 CodeBuddy 共用同一份生成器：两家是同一个钩子契约。
        let document = super::shared::hook_settings(req.hook.as_ref());
        std::fs::write(&path, serde_json::to_vec_pretty(&document)?)?;
        Ok(path)
    }

    fn command(&self, exe: &Path, req: &RunRequest) -> tokio::process::Command {
        let settings = req.config_dir.join("claude-settings.json");
        let mut command = tokio::process::Command::new(exe);
        command
            .current_dir(&req.worktree)
            // 继承来的 `ANTHROPIC_API_KEY` 会让 CLI 走 x-api-key 并先去官方端点校验；
            // 我们的令牌只从 `ANTHROPIC_AUTH_TOKEN` 走。
            .env_remove("ANTHROPIC_API_KEY")
            .arg("-p")
            .arg(&req.prompt)
            .arg("--output-format")
            .arg("stream-json")
            // 实测：`-p` + `stream-json` 不给 --verbose 会直接报错退出。
            .arg("--verbose")
            .arg("--model")
            .arg(&req.model)
            .arg("--settings")
            .arg(&settings)
            // 只读我们给的 settings：用户级 settings 的 `env` 会覆盖进程环境变量。
            .arg("--setting-sources")
            .arg("project")
            // 屏蔽 MCP：那些工具不过我们的钩子，属于必须关掉的盲区。
            .arg("--strict-mcp-config")
            .arg("--mcp-config")
            .arg(r#"{"mcpServers":{}}"#)
            .arg("--tools")
            .arg(TOOLS)
            // 不用 acceptEdits / bypass：工具放行必须来自钩子。
            .arg("--permission-mode")
            .arg("default");
        command
    }

    fn parse(&self, line: &str) -> Option<CliEvent> {
        let value: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
        match value.get("type")?.as_str()? {
            "system" => match value.get("subtype").and_then(serde_json::Value::as_str) {
                Some("init") => Some(CliEvent::Started {
                    session_id: value
                        .get("session_id")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_string),
                }),
                // `thinking_tokens` / `status` / `api_retry` 这些是进度噪声：
                // `--verbose` 下会刷几十行，进事件环只会把真正的动作挤掉。
                _ => None,
            },
            "assistant" => self.parse_assistant(value.get("message")?),
            "user" => self.parse_user(value.get("message")?),
            "result" => {
                if value
                    .get("is_error")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false)
                {
                    let message = value
                        .get("result")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("Claude Code 报告执行失败");
                    return Some(CliEvent::Failed {
                        message: message.chars().take(500).collect(),
                    });
                }
                let usage = value.get("usage")?;
                Some(CliEvent::Usage {
                    prompt_tokens: token_field(usage, "input_tokens").map(|input| {
                        input
                            + token_field(usage, "cache_read_input_tokens").unwrap_or(0)
                            + token_field(usage, "cache_creation_input_tokens").unwrap_or(0)
                    }),
                    completion_tokens: token_field(usage, "output_tokens"),
                })
            }
            _ => None,
        }
    }

    fn injects_hook(&self) -> bool {
        // `write_config` 写的就是 `PreToolUse`：每次调用都会先问 worker。
        true
    }

    fn hook_env(&self, req: &RunRequest) -> std::io::Result<Vec<(String, String)>> {
        let base = format!("{}/internal/code", req.proxy_url.trim_end_matches('/'));
        // 所有模型档位都指向本任务选中的那个模型：Claude 会按用途分别取
        // haiku / sonnet / opus，任何一个没覆盖都会用一个不在白名单里的名字去请求。
        Ok(vec![
            ("ANTHROPIC_BASE_URL".to_string(), base),
            (TOKEN_ENV.to_string(), req.token.clone()),
            ("ANTHROPIC_MODEL".to_string(), req.model.clone()),
            ("ANTHROPIC_SMALL_FAST_MODEL".to_string(), req.model.clone()),
            (
                "ANTHROPIC_DEFAULT_HAIKU_MODEL".to_string(),
                req.model.clone(),
            ),
            (
                "ANTHROPIC_DEFAULT_SONNET_MODEL".to_string(),
                req.model.clone(),
            ),
            (
                "ANTHROPIC_DEFAULT_OPUS_MODEL".to_string(),
                req.model.clone(),
            ),
            // 非必要流量（遥测、更新检查）在任务里没有意义，还会污染审计。
            (
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".to_string(),
                "1".to_string(),
            ),
        ])
    }
}

impl Claude {
    fn parse_assistant(&self, message: &serde_json::Value) -> Option<CliEvent> {
        let content = message.get("content")?.as_array()?;
        // 一次 assistant 消息里可能有多个块；这里只取第一块能表达的东西，
        // 其余块会在后续事件里再出现（Claude 每轮至少一条 assistant 行）。
        for block in content {
            match block.get("type").and_then(serde_json::Value::as_str) {
                Some("text") => {
                    let text = block
                        .get("text")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    if !text.trim().is_empty() {
                        return Some(CliEvent::Text {
                            text: text.chars().take(2_000).collect(),
                        });
                    }
                }
                Some("tool_use") => {
                    let name = block
                        .get("name")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("unknown")
                        .to_string();
                    let input = block.get("input").cloned();
                    return Some(CliEvent::ToolUse {
                        detail: tool_detail(&name, input.as_ref()),
                        name,
                        input,
                        call_id: block
                            .get("id")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string),
                    });
                }
                _ => {}
            }
        }
        None
    }

    fn parse_user(&self, message: &serde_json::Value) -> Option<CliEvent> {
        let content = message.get("content")?.as_array()?;
        for block in content {
            if block.get("type").and_then(serde_json::Value::as_str) != Some("tool_result") {
                continue;
            }
            let ok = !block
                .get("is_error")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            let summary = match block.get("content") {
                Some(serde_json::Value::String(text)) => super::shared::clamp(text, 200),
                Some(serde_json::Value::Array(parts)) => super::shared::clamp(
                    &parts
                        .iter()
                        .filter_map(|part| part.get("text").and_then(serde_json::Value::as_str))
                        .collect::<Vec<_>>()
                        .join(" "),
                    200,
                ),
                _ => String::new(),
            };
            return Some(CliEvent::ToolResult { ok, summary });
        }
        None
    }
}

/// 一行摘要：优先取命令 / 路径，其次才是工具名。
fn tool_detail(name: &str, input: Option<&serde_json::Value>) -> String {
    let Some(input) = input else {
        return name.to_string();
    };
    for key in ["command", "file_path", "path", "pattern"] {
        if let Some(value) = input.get(key).and_then(serde_json::Value::as_str) {
            if !value.is_empty() {
                return super::shared::clamp(value, 200);
            }
        }
    }
    name.to_string()
}

fn token_field(usage: &serde_json::Value, key: &str) -> Option<u64> {
    usage.get(key).and_then(serde_json::Value::as_u64)
}

/// 单测用的最小 `RunRequest`。
#[cfg(test)]
fn request(dir: &Path) -> RunRequest {
    RunRequest {
        model: "deepseek-v4.1-flash".to_string(),
        worktree: dir.join("wt"),
        config_dir: dir.join("conf"),
        proxy_url: "http://127.0.0.1:51234".to_string(),
        token: "secret-token".to_string(),
        prompt: "改一个 bug".to_string(),
        hook: Some(super::HookSpec {
            socket: dir.join("task.sock"),
            shim: PathBuf::from("/usr/local/bin/jarvis-worker"),
            timeout_secs: 115,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../fixtures/claude.ndjson");

    fn events() -> Vec<CliEvent> {
        let provider = Claude;
        FIXTURE
            .lines()
            .filter(|line| !line.trim().is_empty())
            .filter_map(|line| provider.parse(line))
            .collect()
    }

    #[test]
    fn parses_every_line_of_the_recorded_fixture() {
        // 夹具是用真实 2.1.310 录的（含一次 Bash 调用）。
        let events = events();
        assert!(
            matches!(&events[0], CliEvent::Started { session_id: Some(id) } if !id.is_empty()),
            "{events:?}"
        );
        assert!(
            events.iter().any(|event| matches!(
                event,
                CliEvent::ToolUse { name, .. } if name == "Bash"
            )),
            "tool_use 应映射成工具调用：{events:?}"
        );
        assert!(
            events
                .iter()
                .any(|event| matches!(event, CliEvent::ToolResult { ok: true, .. })),
            "{events:?}"
        );
        assert!(
            events.iter().any(|event| matches!(
                event,
                CliEvent::Usage { prompt_tokens: Some(total), .. } if *total >= 300
            )),
            "用量要把缓存命中算进输入：{events:?}"
        );
    }

    #[test]
    fn noise_system_events_are_dropped() {
        let provider = Claude;
        for line in [
            r#"{"type":"system","subtype":"thinking_tokens","estimated_tokens":5}"#,
            r#"{"type":"system","subtype":"status","status":"requesting"}"#,
            r#"{"type":"system","subtype":"api_retry","attempt":2}"#,
        ] {
            assert!(provider.parse(line).is_none(), "{line}");
        }
        assert!(provider.parse("not json").is_none());
        assert!(provider.parse(r#"{"type":"brand_new"}"#).is_none());
    }

    #[test]
    fn failed_result_carries_the_message() {
        let provider = Claude;
        let event = provider
            .parse(r#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"超出轮数"}"#)
            .expect("应识别失败");
        assert!(matches!(event, CliEvent::Failed { message } if message.contains("轮数")));
    }

    #[test]
    fn settings_file_carries_the_hook_and_stays_out_of_the_worktree() {
        let dir = super::super::shared::test_support::tempdir();
        let req = request(&dir);
        let path = Claude.write_config(&req).expect("写配置失败");
        assert_eq!(path, dir.join("conf").join("claude-settings.json"));
        assert!(!path.starts_with(&req.worktree));

        let text = std::fs::read_to_string(&path).expect("读配置失败");
        assert!(text.contains("PreToolUse"), "{text}");
        assert!(text.contains("hook-shim"), "{text}");
        assert!(text.contains("\"matcher\": \"*\""), "{text}");
        assert!(!text.contains("secret-token"), "令牌不能落盘：{text}");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn command_keeps_the_safety_flags() {
        let dir = super::super::shared::test_support::tempdir();
        let req = request(&dir);
        let mut command = Claude.command(Path::new("/usr/local/bin/claude"), &req);
        let args: Vec<String> = command
            .as_std_mut()
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();

        assert!(args.contains(&"--verbose".to_string()), "{args:?}");
        assert!(args.contains(&"--setting-sources".to_string()), "{args:?}");
        assert!(args.contains(&"project".to_string()), "{args:?}");
        assert!(
            args.contains(&"--strict-mcp-config".to_string()),
            "{args:?}"
        );
        assert!(
            args.iter().any(|arg| arg.contains("mcpServers")),
            "{args:?}"
        );
        assert!(
            args.contains(&"default".to_string()),
            "不能默认放行：{args:?}"
        );
        assert!(
            !args.iter().any(|arg| arg.contains("dangerously")),
            "{args:?}"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn environment_points_every_model_tier_at_the_task_model() {
        let dir = super::super::shared::test_support::tempdir();
        let req = request(&dir);
        let map: std::collections::HashMap<_, _> = Claude
            .hook_env(&req)
            .expect("环境变量应可构造")
            .into_iter()
            .collect();

        assert_eq!(
            map.get("ANTHROPIC_BASE_URL").map(String::as_str),
            Some("http://127.0.0.1:51234/internal/code"),
            "CLI 自己拼 /v1/messages"
        );
        assert_eq!(
            map.get("ANTHROPIC_AUTH_TOKEN").map(String::as_str),
            Some("secret-token")
        );
        for key in [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
        ] {
            assert_eq!(
                map.get(key).map(String::as_str),
                Some("deepseek-v4.1-flash"),
                "{key} 必须指向本次档位"
            );
        }
        assert!(
            !map.contains_key("ANTHROPIC_API_KEY"),
            "设了 API_KEY 会走 x-api-key 并先校验官方端点"
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
