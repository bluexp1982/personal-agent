//! Codex（实测 codex-cli 0.164.0）。
//!
//! 与另两家的差异（都有实测依据）：
//! - **只讲 Responses API**：0.164.0 移除了 `wire_api = "chat"`，配置里写 chat 会直接
//!   拒绝启动。所以模型请求必须经代理的 `/responses` 路由（由 service 侧做
//!   Responses→Chat 映射），base_url 要写全 `{proxy}/internal/code/v1`；
//! - 配置全部落在 `CODEX_HOME`：`config.toml` 写在 `{config_dir}/codex/`，
//!   用户自己的 `~/.codex` 完全隔离，工作树里不出现任何配置；
//! - 无头执行是 `codex exec`（不是 `-p`），结构化输出是 `--json`（JSONL）；
//! - 工具名是新的统一执行工具 `exec_command` / `write_stdin`，**不是** `shell`；
//! - 钩子机制存在（`hooks/hooks.json` + `PreToolUse`），但需要持久化 trust
//!   （`--dangerously-bypass-hook-trust` 是逃生门），本阶段不启用，
//!   因此 `tool_approval` 只能判 `Unsupported`，审批落在合并前那一张卡。

use std::path::{Path, PathBuf};

use super::{CliEvent, CodingProvider, RunRequest};
// 只有单测的 `request()` 需要构造 hook 字段，生产路径不碰它。
#[cfg(test)]
use super::HookSpec;

pub(super) const ID: &str = "codex";

/// 令牌环境变量：`config.toml` 里用 `env_key` 引用它，文件里没有明文。
const TOKEN_ENV: &str = "PERSONAL_AGENT_CODE_TOKEN";

#[derive(Debug, Default)]
pub(crate) struct Codex;

impl CodingProvider for Codex {
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
        let home = Self::codex_home(req);
        std::fs::create_dir_all(&home)?;
        let path = home.join("config.toml");
        std::fs::write(&path, self.config_text(req))?;
        Ok(path)
    }

    fn command(&self, exe: &Path, req: &RunRequest) -> tokio::process::Command {
        let mut command = tokio::process::Command::new(exe);
        command
            .current_dir(&req.worktree)
            // `--json` 是逐行 JSONL；不加它 codex 会打印人类可读的彩色输出。
            .arg("exec")
            .arg("--json")
            // 工作树是我们自己建的，`--skip-git-repo-check` 只为容忍空仓库。
            .arg("--skip-git-repo-check")
            // 不落会话文件：每次任务一棵工作树，历史留在我们的 run_log 里。
            .arg("--ephemeral")
            .arg("--color")
            .arg("never")
            .arg("-C")
            .arg(&req.worktree)
            .arg(&req.prompt);
        command
    }

    fn parse(&self, line: &str) -> Option<CliEvent> {
        let value: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
        let kind = value.get("type")?.as_str()?;
        match kind {
            "thread.started" => Some(CliEvent::Started {
                session_id: value
                    .get("thread_id")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_string),
            }),
            // `turn.started` / `turn.completed` 的正文在 item 与 usage 里；
            // 这里只取用量，其余交给下一次调用。
            "turn.completed" => {
                let usage = value.get("usage")?;
                Some(CliEvent::Usage {
                    prompt_tokens: usage
                        .get("input_tokens")
                        .and_then(serde_json::Value::as_u64),
                    completion_tokens: usage
                        .get("output_tokens")
                        .and_then(serde_json::Value::as_u64),
                })
            }
            "turn.failed" => Some(CliEvent::Failed {
                message: value
                    .pointer("/error/message")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("codex 报告本回合失败")
                    .chars()
                    .take(500)
                    .collect(),
            }),
            "error" => Some(CliEvent::Failed {
                message: value
                    .get("message")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("codex 报错")
                    .chars()
                    .take(500)
                    .collect(),
            }),
            "item.started" | "item.completed" => {
                self.parse_item(value.get("item")?, kind == "item.started")
            }
            _ => None,
        }
    }

    fn hook_env(&self, req: &RunRequest) -> std::io::Result<Vec<(String, String)>> {
        Ok(vec![
            (
                "CODEX_HOME".to_string(),
                Self::codex_home(req).display().to_string(),
            ),
            (TOKEN_ENV.to_string(), req.token.clone()),
        ])
    }
}

impl Codex {
    /// `CODEX_HOME` 指向 `config_dir` 下的子目录：工作树里一个文件都不留。
    fn codex_home(req: &RunRequest) -> PathBuf {
        req.config_dir.join("codex")
    }

    /// 逐行解析 `item.*` 事件。
    ///
    /// `started` 为真表示"这条工具调用刚开始"，只报 `ToolUse`；
    /// 完成时再报 `ToolResult`。两条都带同一段命令，便于 `run_log` 对账。
    fn parse_item(&self, item: &serde_json::Value, started: bool) -> Option<CliEvent> {
        let kind = item.get("type").and_then(serde_json::Value::as_str)?;
        match kind {
            "agent_message" => {
                if started {
                    return None;
                }
                let text = item
                    .get("text")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                (!text.is_empty()).then(|| CliEvent::Text {
                    text: text.chars().take(2_000).collect(),
                })
            }
            // Codex 把"跑命令"表达成一个统一工具，名字与参数都与 codebuddy 不同：
            // 摘要取 `command`，风险规则按 `Bash` 的语义判（cmd 里有 shell 命令）。
            "command_execution" => {
                let command = item
                    .get("command")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                if started {
                    return Some(CliEvent::ToolUse {
                        name: "Bash".to_string(),
                        detail: command.to_string(),
                        input: Some(serde_json::json!({ "command": command })),
                        call_id: item
                            .get("id")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string),
                    });
                }
                let ok = item
                    .get("exit_code")
                    .and_then(serde_json::Value::as_i64)
                    .is_some_and(|code| code == 0);
                Some(CliEvent::ToolResult {
                    ok,
                    summary: super::shared::clamp(command, 200),
                })
            }
            "file_change" => {
                let path = item
                    .pointer("/changes/0/path")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                if started {
                    return Some(CliEvent::ToolUse {
                        name: "ApplyPatch".to_string(),
                        detail: path.to_string(),
                        input: Some(serde_json::json!({ "path": path })),
                        call_id: item
                            .get("id")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string),
                    });
                }
                Some(CliEvent::ToolResult {
                    ok: true,
                    summary: format!("已修改 {path}"),
                })
            }
            "mcp_tool_call" => {
                let name = item
                    .get("tool")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("mcp");
                if started {
                    return Some(CliEvent::ToolUse {
                        name: format!("mcp__{name}"),
                        detail: name.to_string(),
                        input: item.get("arguments").cloned(),
                        call_id: item
                            .get("id")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string),
                    });
                }
                let ok = item
                    .get("status")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|status| status == "completed");
                Some(CliEvent::ToolResult {
                    ok,
                    summary: format!("MCP {name}"),
                })
            }
            // Codex 把"模型元数据缺失"这类警告也做成 error item：它不是任务失败，
            // 只记一条通知，让 run_log 里能看到。
            "error" => {
                if started {
                    return None;
                }
                let message = item
                    .get("message")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("codex 报告了一条错误");
                Some(CliEvent::Notification {
                    code: "cli_error".to_string(),
                    message: message.chars().take(200).collect(),
                })
            }
            // 未知 item（reasoning / todo 列表 / 未来新增）只记一条通知：
            // Codex 升级后多一个类型是常态，不该让整条任务失败。
            _ => {
                if started {
                    return None;
                }
                Some(CliEvent::Notification {
                    code: "unknown_item".to_string(),
                    message: kind.chars().take(120).collect(),
                })
            }
        }
    }

    /// `config.toml` 的内容。
    ///
    /// 三个关键点（任何一条写错都会让任务"莫名失败"）：
    /// 1. `wire_api` 只能是 `responses`——chat 已被移除；
    /// 2. `base_url` 要写到 `/internal/code/v1`，codex 自己拼 `/responses`；
    /// 3. `env_key` 指向一次性令牌，文件里不出现真 key。
    fn config_text(&self, req: &RunRequest) -> String {
        let base = format!("{}/internal/code/v1", req.proxy_url.trim_end_matches('/'));
        format!(
            "# 由 personal-agent 生成：每个任务一份，落在 CODEX_HOME 下。\n\
             model = {model:?}\n\
             model_provider = \"personal-agent\"\n\
             approval_policy = \"never\"\n\
             sandbox_mode = \"workspace-write\"\n\
             project_doc_max_bytes = 0\n\
             \n\
             [model_providers.personal-agent]\n\
             name = \"personal-agent\"\n\
             base_url = {base:?}\n\
             env_key = \"{token_env}\"\n\
             wire_api = \"responses\"\n",
            model = req.model,
            base = base,
            token_env = TOKEN_ENV,
        )
    }
}

/// 供单测构造一个最小的 `RunRequest`。
#[cfg(test)]
pub(super) fn request(model: &str, dir: &Path) -> RunRequest {
    RunRequest {
        model: model.to_string(),
        worktree: dir.join("wt"),
        config_dir: dir.join("conf"),
        proxy_url: "http://127.0.0.1:51234".to_string(),
        token: "secret-token".to_string(),
        prompt: "改一个 bug".to_string(),
        hook: None::<HookSpec>,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../fixtures/codex.ndjson");

    fn events() -> Vec<CliEvent> {
        let provider = Codex;
        FIXTURE
            .lines()
            .filter(|line| !line.trim().is_empty())
            .filter_map(|line| provider.parse(line))
            .collect()
    }

    #[test]
    fn parses_every_line_of_the_recorded_fixture() {
        // 夹具是用真实二进制录下来的（含一次真实的
        // exec_command 工具调用）；解析器必须能吃掉全部行。
        let events = events();
        assert!(!events.is_empty(), "夹具不应解析出空事件");

        assert!(matches!(
            &events[0],
            CliEvent::Started { session_id: Some(id) } if !id.is_empty()
        ));
        assert!(
            events.iter().any(|event| matches!(
                event,
                CliEvent::ToolUse { name, .. } if name == "Bash"
            )),
            "command_execution 应映射成 Bash 工具调用：{events:?}"
        );
        assert!(
            events
                .iter()
                .any(|event| matches!(event, CliEvent::ToolResult { ok: true, .. })),
            "命令成功应映射成 ToolResult{{ok:true}}：{events:?}"
        );
        assert!(
            events.iter().any(|event| matches!(
                event,
                CliEvent::Usage {
                    prompt_tokens: Some(_),
                    ..
                }
            )),
            "turn.completed 应带用量：{events:?}"
        );
    }

    #[test]
    fn unknown_items_are_reported_once_not_fatal() {
        let provider = Codex;
        assert!(provider
            .parse(r#"{"type":"item.completed","item":{"id":"i","type":"reasoning","text":"想"}}"#)
            .is_some_and(|event| matches!(event, CliEvent::Notification { .. })));
        assert!(provider.parse("not json").is_none());
        assert!(provider.parse(r#"{"type":"brand_new"}"#).is_none());
    }

    #[test]
    fn failed_turn_carries_the_message() {
        let provider = Codex;
        let event = provider
            .parse(r#"{"type":"turn.failed","error":{"message":"stream disconnected"}}"#)
            .expect("应识别失败");
        assert!(matches!(event, CliEvent::Failed { message } if message.contains("stream")));
    }

    #[test]
    fn config_points_at_the_proxy_with_responses_wire_api() {
        let dir = super::super::shared::test_support::tempdir();
        let req = request("deepseek-v4.1-flash", &dir);
        let text = Codex.config_text(&req);

        assert!(text.contains("wire_api = \"responses\""), "{text}");
        assert!(
            text.contains("base_url = \"http://127.0.0.1:51234/internal/code/v1\""),
            "codex 自己拼 /responses，base_url 必须写到 /internal/code/v1：{text}"
        );
        assert!(
            text.contains("env_key = \"PERSONAL_AGENT_CODE_TOKEN\""),
            "{text}"
        );
        assert!(
            !text.contains("secret-token"),
            "令牌不能落进配置文件：{text}"
        );
        assert!(
            text.contains("sandbox_mode = \"workspace-write\""),
            "{text}"
        );
        assert!(!text.contains("dangerously"), "不能绕过沙箱：{text}");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn config_lands_in_codex_home_not_the_worktree() {
        let dir = super::super::shared::test_support::tempdir();
        let req = request("m", &dir);
        let path = Codex.write_config(&req).expect("写配置失败");

        assert_eq!(path, dir.join("conf").join("codex").join("config.toml"));
        assert!(!path.starts_with(&req.worktree), "配置不能落在工作树里");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn command_keeps_the_headless_flags() {
        let dir = super::super::shared::test_support::tempdir();
        let req = request("m", &dir);
        let mut command = Codex.command(Path::new("/usr/local/bin/codex"), &req);
        let args: Vec<String> = command
            .as_std_mut()
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();

        assert_eq!(args[0], "exec");
        assert!(args.contains(&"--json".to_string()));
        assert!(args.contains(&"--skip-git-repo-check".to_string()));
        assert!(args.contains(&"--ephemeral".to_string()));
        assert!(
            !args.iter().any(|arg| arg.contains("dangerously")),
            "不允许绕过沙箱：{args:?}"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn environment_isolates_codex_home_and_passes_only_the_task_token() {
        let dir = super::super::shared::test_support::tempdir();
        let req = request("m", &dir);
        let pairs = Codex.hook_env(&req).expect("环境变量应可构造");
        let map: std::collections::HashMap<_, _> = pairs.into_iter().collect();

        assert_eq!(
            map.get("CODEX_HOME").map(String::as_str),
            Some(dir.join("conf").join("codex").to_string_lossy().as_ref())
        );
        assert_eq!(
            map.get("PERSONAL_AGENT_CODE_TOKEN").map(String::as_str),
            Some("secret-token")
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
