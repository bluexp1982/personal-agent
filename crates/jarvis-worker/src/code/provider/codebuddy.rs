//! codebuddy 适配（实测 v2.177.1）。
//!
//! 与初稿差异最大的三处（都是实测推翻的）：
//! - 模型配置只能写进工作树并在跑完删除（`CODEBUDDY_PROJECT_CONFIG_DIR` 不重定向）；
//! - `--model` 必须带 `custom-local:` 前缀，否则撞上内置 id 会走官方端点；
//! - 钩子 `matcher` 要用 `*`，只挂 `Bash|Write|Edit` 会留下 MCP 盲区。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::json;

use super::shared::{clamp, hook_settings, which};
use super::{CliEvent, CodingProvider, RunRequest};

/// codebuddy（实测 v2.177.1）。
#[derive(Debug, Default)]
pub(crate) struct Codebuddy {
    /// 未知事件类型只警告一次：CLI 升级后事件变多是常态，
    /// 但同一类型刷满整份日志就没有信息量了。
    seen_unknown: Mutex<HashSet<String>>,
}

/// codebuddy 的项目级配置目录名。只能落在工作树里（实测：env 覆盖不生效）。
const CB_PROJECT_DIR: &str = ".codebuddy";
/// 钩子配置文件名（放在 `config_dir`，通过 `--settings` 注入，不进工作树）。
const CB_SETTINGS_FILE: &str = "codebuddy-settings.json";
/// 仓库自带 `models.json` 时的备份名（同样落在工作树外）。
const CB_MODELS_BACKUP: &str = "codebuddy-models.json.bak";
/// 允许模型看到的工具集。**窄**是刻意的：MCP、子代理、后台任务都不在这个名单里。
const CB_TOOLS: &str = "Read,Write,Edit,Bash,Glob,Grep";
/// 自定义模型的强制前缀：不加它，模型名撞上内置 id 时会走官方端点。
const CB_CUSTOM_PREFIX: &str = "custom-local:";
/// 令牌环境变量名：`models.json` 里只放引用，不写明文。
const TOKEN_ENV: &str = "PERSONAL_AGENT_CODE_TOKEN";

impl CodingProvider for Codebuddy {
    fn id(&self) -> &'static str {
        "codebuddy"
    }

    fn resolve(&self, bin: Option<&Path>) -> Option<PathBuf> {
        if let Some(bin) = bin {
            return bin.exists().then(|| bin.to_path_buf());
        }
        // 官方安装器同时提供 `codebuddy` 与短名 `cbc`。
        which("codebuddy").or_else(|| which("cbc"))
    }

    fn write_config(&self, req: &RunRequest) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(&req.config_dir)?;

        // 1) 模型配置必须落在 `<worktree>/.codebuddy/models.json`：
        //    v2.177.1 只认这个位置（`CODEBUDDY_PROJECT_CONFIG_DIR` 不生效，实测）。
        let project_dir = req.worktree.join(CB_PROJECT_DIR);
        std::fs::create_dir_all(&project_dir)?;
        let models_path = project_dir.join("models.json");
        // 仓库自己可能就带 `.codebuddy/models.json`（团队共享的模型配置）。
        // 先备份到工作树外，跑完再还原——直接覆盖再删会把用户的项目配置弄丢。
        let backup = req.config_dir.join(CB_MODELS_BACKUP);
        if models_path.exists() {
            std::fs::copy(&models_path, &backup)?;
        }
        let models = json!({
            "models": [{
                "id": req.model,
                "name": req.model,
                "vendor": "personal-agent",
                // 完整路径：codebuddy 不替我们补 `/chat/completions`。
                "url": format!(
                    "{}/internal/code/v1/chat/completions",
                    req.proxy_url.trim_end_matches('/')
                ),
                // 环境变量引用：令牌不落盘，也不写进仓库文件。
                "apiKey": format!("${{{TOKEN_ENV}}}"),
                "supportsToolCall": true,
                "supportsImages": false,
                "supportsReasoning": false,
                "maxInputTokens": 200_000,
                "maxOutputTokens": 8_192
            }],
            "availableModels": [req.model],
        });
        std::fs::write(&models_path, serde_json::to_vec_pretty(&models)?)?;

        // 2) 钩子配置写在 config_dir（工作树之外），用 `--settings` 显式加载。
        let settings = hook_settings(req.hook.as_ref());
        let settings_path = req.config_dir.join(CB_SETTINGS_FILE);
        std::fs::write(&settings_path, serde_json::to_vec_pretty(&settings)?)?;

        Ok(settings_path)
    }

    fn command(&self, exe: &Path, req: &RunRequest) -> tokio::process::Command {
        let mut command = tokio::process::Command::new(exe);
        command
            .current_dir(&req.worktree)
            // 与 opencode 同理：`current_dir` 不改继承来的 `PWD`。
            .env("PWD", &req.worktree)
            // 无头模式：一次 `-p` 跑完一个任务。
            .arg("-p")
            .arg(&req.prompt)
            .arg("--output-format")
            .arg("stream-json")
            .arg("--model")
            // `custom-local:` 前缀是必需的（实测）：模型名与内置列表重合时
            // （例如 `deepseek-v4.1-flash` 就是内置 id），CLI 会走官方端点而不是
            // 我们写的 models.json —— 那等于绕过 code_proxy 直连它自己的网关。
            .arg(format!("{CB_CUSTOM_PREFIX}{}", req.model))
            // 第二道闸：模型能看到的工具就这六个，MCP / 子代理 / 后台任务都不在。
            .arg("--tools")
            .arg(CB_TOOLS)
            // 屏蔽用户级 MCP：它们的工具不会走我们的钩子，属于盲区。
            .arg("--strict-mcp-config")
            .arg("--mcp-config")
            .arg("{}")
            .arg("--settings")
            .arg(req.config_dir.join(CB_SETTINGS_FILE))
            // 只读项目级设置：用户全局 hooks / 权限不许混进来。
            .arg("--setting-sources")
            .arg("project")
            .env(TOKEN_ENV, &req.token)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

        command
    }

    fn injects_hook(&self) -> bool {
        // `write_config` 会把 `PreToolUse` 写进 settings，每次调用都过钩子。
        true
    }

    fn hook_env(&self, req: &RunRequest) -> std::io::Result<Vec<(String, String)>> {
        Ok(vec![
            // `-p` 单发模式不支持后台任务，开了会直接报错。
            (
                "CODEBUDDY_CODE_DISABLE_BACKGROUND_TASKS".to_string(),
                "1".to_string(),
            ),
            // 子代理与轻量档都指到同一个模型：别的模型名不在代理白名单里。
            // 同样要带 `custom-local:` 前缀，否则它们会回到官方端点。
            (
                "CODEBUDDY_MODEL".to_string(),
                format!("{CB_CUSTOM_PREFIX}{}", req.model),
            ),
            (
                "CODEBUDDY_SMALL_FAST_MODEL".to_string(),
                format!("{CB_CUSTOM_PREFIX}{}", req.model),
            ),
            (
                "CODEBUDDY_BIG_SLOW_MODEL".to_string(),
                format!("{CB_CUSTOM_PREFIX}{}", req.model),
            ),
            (
                "CODEBUDDY_CODE_SUBAGENT_MODEL".to_string(),
                format!("{CB_CUSTOM_PREFIX}{}", req.model),
            ),
        ])
    }

    fn cleanup(&self, req: &RunRequest) {
        // 模型配置写在工作树里，不清掉就会进 `git add -A` 的 diff。
        // 注意只删我们写的那一个文件：仓库自带的 `.codebuddy/` 内容不能被碰。
        let project_dir = req.worktree.join(CB_PROJECT_DIR);
        let models_path = project_dir.join("models.json");
        let backup = req.config_dir.join(CB_MODELS_BACKUP);

        if backup.exists() {
            // 跑之前就有同名文件：还原它，而不是删掉。
            if let Err(err) = std::fs::rename(&backup, &models_path) {
                tracing::warn!(path = %models_path.display(), %err, "还原 codebuddy 模型配置失败");
            }
            return;
        }

        match std::fs::remove_file(&models_path) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => {
                tracing::warn!(path = %models_path.display(), %err, "清理 codebuddy 模型配置失败");
                return;
            }
        }
        // 目录是我们新建的才删得掉；仓库自带的非空目录会保留。
        let _ = std::fs::remove_dir(&project_dir);
    }

    fn parse(&self, line: &str) -> Option<CliEvent> {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;
        let kind = value.get("type")?.as_str()?;

        match kind {
            "system" => match value.get("subtype").and_then(serde_json::Value::as_str)? {
                "init" => Some(CliEvent::Started {
                    session_id: value
                        .get("session_id")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_string),
                }),
                _ => None,
            },
            "assistant" => {
                let blocks = value.get("message")?.get("content")?.as_array()?;
                // 文本优先：审批相关事件走钩子，stdout 里这里只是过程展示。
                if let Some(text) = blocks.iter().find_map(|block| {
                    if block.get("type").and_then(serde_json::Value::as_str) == Some("text") {
                        block.get("text").and_then(serde_json::Value::as_str)
                    } else {
                        None
                    }
                }) {
                    return Some(CliEvent::Text {
                        text: clamp(text, 2_000),
                    });
                }
                blocks
                    .iter()
                    .find(|block| {
                        block.get("type").and_then(serde_json::Value::as_str) == Some("tool_use")
                    })
                    .map(|block| CliEvent::ToolUse {
                        name: block
                            .get("name")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or("tool")
                            .to_string(),
                        detail: clamp(
                            &serde_json::to_string(block.get("input").unwrap_or(&json!({})))
                                .unwrap_or_default(),
                            200,
                        ),
                        input: block.get("input").cloned(),
                        call_id: block
                            .get("id")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string),
                    })
            }
            "user" => {
                let blocks = value.get("message")?.get("content")?.as_array()?;
                let result = blocks.iter().find(|block| {
                    block.get("type").and_then(serde_json::Value::as_str) == Some("tool_result")
                })?;
                let ok = !result
                    .get("is_error")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                Some(CliEvent::ToolResult {
                    ok,
                    summary: clamp(&block_text(result), 200),
                })
            }
            "result" => {
                let is_error = value
                    .get("is_error")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                if is_error {
                    let message = value
                        .get("errors")
                        .and_then(serde_json::Value::as_array)
                        .and_then(|errors| errors.first())
                        .and_then(serde_json::Value::as_str)
                        .or_else(|| value.get("result").and_then(serde_json::Value::as_str))
                        .unwrap_or("codebuddy 未给出错误信息");
                    return Some(CliEvent::Failed {
                        message: clamp(message, 500),
                    });
                }
                let usage = value.get("usage");
                Some(CliEvent::Usage {
                    prompt_tokens: usage
                        .and_then(|usage| usage.get("input_tokens"))
                        .and_then(serde_json::Value::as_u64),
                    completion_tokens: usage
                        .and_then(|usage| usage.get("output_tokens"))
                        .and_then(serde_json::Value::as_u64),
                })
            }
            other => {
                // 未知事件记一次通知：CLI 升级后事件变多，我们不能瞎。
                if self.mark_unknown(other) {
                    Some(CliEvent::Notification {
                        code: "unknown_event".to_string(),
                        message: format!("未识别的 codebuddy 事件类型：{other}"),
                    })
                } else {
                    None
                }
            }
        }
    }
}

impl Codebuddy {
    /// 第一次见到某个未知类型时返回 true。
    fn mark_unknown(&self, kind: &str) -> bool {
        let mut seen = self
            .seen_unknown
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        seen.insert(kind.to_string())
    }
}

/// 把 tool_result 的 content（字符串或分段数组）压成一行摘要。
fn block_text(block: &serde_json::Value) -> String {
    match block.get("content") {
        Some(serde_json::Value::String(text)) => text.clone(),
        Some(serde_json::Value::Array(items)) => items
            .iter()
            .filter_map(|item| item.get("text").and_then(serde_json::Value::as_str))
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::shared::test_support::tempdir;
    use super::super::HookSpec;
    use super::*;

    const CB_FIXTURE: &str = include_str!("../fixtures/codebuddy.ndjson");

    fn cb_request(dir: &Path) -> RunRequest {
        RunRequest {
            model: "deepseek-v4.1-flash".to_string(),
            worktree: dir.join("wt"),
            config_dir: dir.join("conf"),
            proxy_url: "http://127.0.0.1:51234".to_string(),
            token: "spike-token".to_string(),
            prompt: "改个 bug".to_string(),
            hook: Some(HookSpec {
                socket: dir.join("hook.sock"),
                shim: PathBuf::from("/opt/pa/jarvis-worker"),
                timeout_secs: 115,
            }),
        }
    }

    #[test]
    fn codebuddy_parses_every_line_of_the_recorded_fixture() {
        let provider = Codebuddy::default();
        let events: Vec<CliEvent> = CB_FIXTURE
            .lines()
            .filter(|line| !line.trim().is_empty())
            .filter_map(|line| provider.parse(line))
            .collect();

        // 8 行真实录制：init / status / tool_use / tool_result(失败) /
        // tool_use / tool_result(成功) / text / result。
        // 除了 `system/status`（无信息量，按设计跳过），其余都必须被识别。
        assert_eq!(events.len(), 7, "夹具里应识别 7 条：{events:#?}");
        // 会话 id 由 CLI 生成，夹具是真实录制：只断言"拿到了且与 init 行一致"。
        let init: serde_json::Value =
            serde_json::from_str(CB_FIXTURE.lines().next().expect("夹具不应为空"))
                .expect("init 行不是合法 JSON");
        let recorded_session = init["session_id"].as_str().expect("init 行应有 session_id");
        assert!(matches!(
            &events[0],
            CliEvent::Started { session_id: Some(id) } if id == recorded_session
        ));
        assert!(matches!(
            &events[1],
            CliEvent::ToolUse { name, call_id: Some(id), .. }
                if name == "Bash" && id == "call_spike_1"
        ));
        assert!(matches!(
            &events[2],
            CliEvent::ToolResult { ok: false, summary } if summary.contains("hook blocked")
        ));
        assert!(matches!(
            &events[3],
            CliEvent::ToolUse { name, .. } if name == "Read"
        ));
        assert!(matches!(&events[4], CliEvent::ToolResult { ok: true, .. }));
        assert!(matches!(&events[5], CliEvent::Text { text } if text.contains("已处理")));
        assert!(matches!(
            &events[6],
            CliEvent::Usage {
                prompt_tokens: Some(40),
                completion_tokens: Some(5)
            }
        ));
    }

    #[test]
    fn codebuddy_unknown_events_are_reported_once() {
        let provider = Codebuddy::default();
        let line = r#"{"type":"brand_new_event","payload":{}}"#;
        assert!(matches!(
            provider.parse(line),
            Some(CliEvent::Notification { code, .. }) if code == "unknown_event"
        ));
        assert!(provider.parse(line).is_none(), "同一未知类型只该报一次");
        assert!(provider.parse("not json").is_none());
        assert!(
            provider.parse(r#"{"type":"assistant"}"#).is_none(),
            "缺 message 不能 panic"
        );
    }

    #[test]
    fn codebuddy_result_error_becomes_failed() {
        let provider = Codebuddy::default();
        let line = r#"{"type":"result","subtype":"error_during_execution","is_error":true,
            "errors":["401 Authentication required"]}"#;
        assert_eq!(
            provider.parse(line),
            Some(CliEvent::Failed {
                message: "401 Authentication required".to_string()
            })
        );
    }

    #[test]
    fn codebuddy_config_lands_outside_and_inside_the_worktree_as_designed() {
        let dir = tempdir();
        let request = cb_request(&dir);
        std::fs::create_dir_all(&request.worktree).expect("创建工作树失败");

        let provider = Codebuddy::default();
        let settings_path = provider.write_config(&request).expect("写配置失败");

        // 模型配置只能在 `<worktree>/.codebuddy/models.json`（实测：env 覆盖无效）。
        let models_raw = std::fs::read_to_string(request.worktree.join(".codebuddy/models.json"))
            .expect("models.json 应写进工作树");
        let models: serde_json::Value = serde_json::from_str(&models_raw).expect("不是合法 JSON");
        assert_eq!(
            models["models"][0]["url"],
            "http://127.0.0.1:51234/internal/code/v1/chat/completions"
        );
        assert_eq!(
            models["models"][0]["apiKey"],
            "${PERSONAL_AGENT_CODE_TOKEN}"
        );
        assert!(!models_raw.contains("spike-token"), "令牌不能落盘");

        // 钩子配置在工作树之外，且用绝对路径调 shim。
        assert_eq!(settings_path, request.config_dir.join(CB_SETTINGS_FILE));
        let settings_raw = std::fs::read_to_string(&settings_path).expect("读设置失败");
        let settings: serde_json::Value =
            serde_json::from_str(&settings_raw).expect("设置不是合法 JSON");
        let hook = &settings["hooks"]["PreToolUse"][0];
        assert_eq!(hook["matcher"], "*");
        assert!(hook["hooks"][0]["command"]
            .as_str()
            .expect("command 缺失")
            .contains("/opt/pa/jarvis-worker hook-shim --socket"));
        assert_eq!(hook["hooks"][0]["timeout"], 115);

        // 跑完清理：工作树里不能留下 .codebuddy。
        provider.cleanup(&request);
        assert!(!request.worktree.join(".codebuddy").exists());
    }

    #[test]
    fn codebuddy_config_is_byte_stable() {
        // 前缀缓存以"逐字节一致"为前提。我们生成的两份配置里只要掺进时间戳/随机 id，
        // 命中率就会掉到 0，而现象只是"账单变大"。
        let dir = tempdir();
        let request = cb_request(&dir);
        let provider = Codebuddy::default();

        let models_path = provider.write_config(&request).expect("写配置失败");
        let first = std::fs::read_to_string(&models_path).expect("读失败");
        provider.write_config(&request).expect("写配置失败");
        let second = std::fs::read_to_string(&models_path).expect("读失败");
        assert_eq!(first, second, "同一任务重复写配置必须逐字节一致");

        let settings_path = request.config_dir.join(CB_SETTINGS_FILE);
        let first = std::fs::read_to_string(&settings_path).expect("读失败");
        provider.write_config(&request).expect("写配置失败");
        let second = std::fs::read_to_string(&settings_path).expect("读失败");
        assert_eq!(first, second, "钩子配置同样不能掺可变内容");
    }

    #[test]
    fn codebuddy_cleanup_restores_a_repo_owned_models_json() {
        let dir = tempdir();
        let request = cb_request(&dir);
        let project_dir = request.worktree.join(CB_PROJECT_DIR);
        std::fs::create_dir_all(&project_dir).expect("创建工作树配置目录失败");
        // 仓库自带的模型配置：跑完必须原样还回去，不能当成我们的临时文件删掉。
        let original = r#"{"models":[{"id":"team-model"}]}"#;
        std::fs::write(project_dir.join("models.json"), original).expect("写原始配置失败");

        let provider = Codebuddy::default();
        provider.write_config(&request).expect("写配置失败");
        let written = std::fs::read_to_string(project_dir.join("models.json")).expect("读失败");
        assert!(
            written.contains("personal-agent"),
            "任务期间必须用我们的配置"
        );

        provider.cleanup(&request);
        let restored = std::fs::read_to_string(project_dir.join("models.json")).expect("读失败");
        assert_eq!(restored, original, "仓库自带的配置必须还原");
        assert!(
            !request.config_dir.join(CB_MODELS_BACKUP).exists(),
            "备份文件不该留在 config_dir"
        );
    }

    #[test]
    fn codebuddy_command_keeps_the_safety_flags() {
        let dir = tempdir();
        let request = cb_request(&dir);
        let provider = Codebuddy::default();
        let mut command = provider.command(Path::new("/bin/true"), &request);
        // 模型档位与后台任务开关走 `hook_env`，执行前由 mod.rs 统一注入。
        for (key, value) in provider.hook_env(&request).expect("hook_env 不应失败") {
            command.env(key, value);
        }
        let debug = format!("{command:?}");

        for needle in [
            "--output-format",
            "stream-json",
            "--model",
            "--tools",
            "--strict-mcp-config",
            "--settings",
            "--setting-sources",
        ] {
            assert!(debug.contains(needle), "命令缺少 {needle}: {debug}");
        }
        assert!(
            !debug.contains("dangerously-skip-permissions"),
            "必须保留 CLI 自身的权限兜底: {debug}"
        );

        let envs: std::collections::HashMap<_, _> = command
            .as_std()
            .get_envs()
            .filter_map(|(key, value)| {
                value.map(|value| {
                    (
                        key.to_string_lossy().into_owned(),
                        value.to_string_lossy().into_owned(),
                    )
                })
            })
            .collect();
        assert_eq!(
            envs.get("CODEBUDDY_CODE_DISABLE_BACKGROUND_TASKS")
                .map(String::as_str),
            Some("1")
        );
        assert_eq!(
            envs.get("CODEBUDDY_MODEL").map(String::as_str),
            Some("custom-local:deepseek-v4.1-flash")
        );
        // 不加前缀，撞上内置模型名时 CLI 会绕过本机代理。
        assert!(
            debug.contains("custom-local:deepseek-v4.1-flash"),
            "命令必须用 custom-local: 前缀指定模型: {debug}"
        );
        assert_eq!(
            envs.get("PERSONAL_AGENT_CODE_TOKEN").map(String::as_str),
            Some("spike-token")
        );
        assert_eq!(
            envs.get("PWD").map(String::as_str),
            Some(request.worktree.to_string_lossy().as_ref())
        );
    }

    #[test]
    fn codebuddy_capabilities_are_native_tool_approval() {
        let caps = Codebuddy::default().capabilities();
        assert_eq!(caps.tool_approval, protocol::ApprovalSupport::Native);
        assert!(!caps.tool_approval.reject_terminates());
    }
}
