//! opencode 适配（实测 v2.1.4）。
//!
//! 三条实测结论决定了实现形状：
//! - 必须带 `--standalone`，否则会连本机常驻服务，per-task 配置不生效；
//! - 配置只能靠 `OPENCODE_CONFIG_DIR` + 配置文件注入；
//! - 它按环境变量 `PWD` 认项目根，Rust 的 `current_dir` 不改继承来的 `PWD`。

use std::path::{Path, PathBuf};

use serde_json::json;

use super::shared::{clamp, which};
use super::{CliEvent, CodingProvider, RunRequest};

/// opencode（实测 v2.1.4）。
#[derive(Debug)]
pub(crate) struct Opencode;

/// 自定义 provider 的 id：`-m` 前缀与配置文件里的键必须一致。
const PROVIDER_ID: &str = "personal-agent";
/// 令牌环境变量名：配置文件里用 `{env:...}` 引用它，不在文件里写明文。
const TOKEN_ENV: &str = "PERSONAL_AGENT_CODE_TOKEN";

impl CodingProvider for Opencode {
    fn id(&self) -> &'static str {
        "opencode"
    }

    fn resolve(&self, bin: Option<&Path>) -> Option<PathBuf> {
        if let Some(bin) = bin {
            return bin.exists().then(|| bin.to_path_buf());
        }
        which("opencode")
    }

    fn write_config(&self, req: &RunRequest) -> std::io::Result<PathBuf> {
        // 键是动态的（provider id 与模型名），json! 宏只吃字面量键，所以用 Map 拼。
        let mut models = serde_json::Map::new();
        models.insert(req.model.clone(), json!({ "name": req.model.clone() }));

        let mut providers = serde_json::Map::new();
        providers.insert(
            PROVIDER_ID.to_string(),
            json!({
                "npm": "@ai-sdk/openai-compatible",
                "name": "personal-agent gateway",
                "options": {
                    // 代理路由是 `{baseURL}/chat/completions`，所以这里停在 `/v1`。
                    "baseURL": format!("{}/internal/code/v1", req.proxy_url.trim_end_matches('/')),
                    "apiKey": format!("{{env:{TOKEN_ENV}}}"),
                },
                "models": serde_json::Value::Object(models),
            }),
        );

        let config = json!({
            "$schema": "https://opencode.ai/config.json",
            "provider": serde_json::Value::Object(providers),
        });

        std::fs::create_dir_all(&req.config_dir)?;
        let path = req.config_dir.join("opencode.json");
        std::fs::write(&path, serde_json::to_vec_pretty(&config)?)?;
        Ok(path)
    }

    fn command(&self, exe: &Path, req: &RunRequest) -> tokio::process::Command {
        let mut command = tokio::process::Command::new(exe);
        command
            .current_dir(&req.worktree)
            // opencode 认的是环境变量 `PWD` 而不是真实 cwd（实测 v2.1.4）：Rust 的
            // `current_dir` 只改 cwd，不会更新继承来的 `PWD`，不覆盖就会把 service
            // 的启动目录当成"项目根"，`write` 直接写到隔离工作树之外。
            .env("PWD", &req.worktree)
            .arg("run")
            // 必需：否则会连本机常驻服务，那里没有本任务的 provider 配置。
            .arg("--standalone")
            .arg("--format")
            .arg("json")
            // --auto 只自动批准"未被显式拒绝"的权限；真正的边界靠 worktree 与仓库白名单。
            .arg("--auto")
            .arg("-m")
            .arg(format!("{PROVIDER_ID}/{}", req.model))
            .arg(&req.prompt)
            .env("OPENCODE_CONFIG_DIR", &req.config_dir)
            .env(TOKEN_ENV, &req.token)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

        // 进程组由 `code::process::run` 统一设置：那才是真正负责杀进程的地方。
        command
    }

    fn parse(&self, line: &str) -> Option<CliEvent> {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;

        match value.get("type")?.as_str()? {
            "step_start" => Some(CliEvent::Started {
                session_id: value
                    .get("sessionID")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_string),
            }),
            "text" => Some(CliEvent::Text {
                text: value.get("part")?.get("text")?.as_str()?.to_string(),
            }),
            "tool_use" => {
                let part = value.get("part")?;
                Some(CliEvent::ToolUse {
                    name: part
                        .get("tool")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("tool")
                        .to_string(),
                    detail: tool_detail_of(part),
                    input: part
                        .get("state")
                        .and_then(|state| state.get("input"))
                        .cloned(),
                    // opencode 的 part 里带 id 时用它，仅作观测标识。
                    call_id: part
                        .get("id")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_string),
                })
            }
            "step_finish" => {
                let tokens = value.get("part")?.get("tokens");
                Some(CliEvent::Usage {
                    prompt_tokens: tokens
                        .and_then(|tokens| tokens.get("input"))
                        .and_then(serde_json::Value::as_u64),
                    completion_tokens: tokens
                        .and_then(|tokens| tokens.get("output"))
                        .and_then(serde_json::Value::as_u64),
                })
            }
            "error" => Some(CliEvent::Failed {
                message: value
                    .get("error")
                    .and_then(|error| error.get("message"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("opencode 未给出错误信息")
                    .to_string(),
            }),
            _ => None,
        }
    }
}

/// 工具调用的一行摘要：优先 `title`，否则压平参数。
fn tool_detail_of(part: &serde_json::Value) -> String {
    let state = part.get("state");
    if let Some(title) = state
        .and_then(|state| state.get("title"))
        .and_then(serde_json::Value::as_str)
    {
        return clamp(title, 120);
    }
    match state.and_then(|state| state.get("input")) {
        Some(input) => clamp(&serde_json::to_string(input).unwrap_or_default(), 120),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::shared::test_support::tempdir;
    use super::*;

    const FIXTURE: &str = include_str!("../fixtures/opencode.ndjson");

    fn events() -> Vec<CliEvent> {
        FIXTURE
            .lines()
            .filter(|line| !line.trim().is_empty())
            .filter_map(|line| Opencode.parse(line))
            .collect()
    }

    #[test]
    fn parses_every_line_of_the_recorded_fixture() {
        // 夹具是 spike 用真实 opencode 录下来的；解析器必须能吃掉全部行，
        // 一旦升级 CLI 后出现"跳过整段"，这个断言会先失败。
        let events = events();
        assert_eq!(events.len(), 5, "夹具里的 5 行都应被识别");

        assert!(matches!(
            &events[0],
            CliEvent::Started { session_id: Some(id) } if id == "ses_fixture"
        ));
        assert!(matches!(
            &events[1],
            CliEvent::ToolUse { name, detail, .. } if name == "write" && detail == "write"
        ));
        assert!(matches!(
            &events[2],
            CliEvent::Usage {
                prompt_tokens: Some(3631),
                completion_tokens: Some(75)
            }
        ));
        assert!(matches!(&events[4], CliEvent::Text { text } if text.contains("hello.txt")));
    }

    #[test]
    fn unknown_or_broken_lines_are_skipped_not_fatal() {
        assert!(Opencode.parse("not json").is_none());
        assert!(Opencode
            .parse(r#"{"type":"brand_new_event","part":{}}"#)
            .is_none());
        assert!(
            Opencode.parse(r#"{"type":"text"}"#).is_none(),
            "缺 part 不能 panic"
        );
    }

    #[test]
    fn error_event_carries_message() {
        let line = r#"{"type":"error","error":{"type":"provider.no-route","message":"Model unavailable: x/y"}}"#;
        assert_eq!(
            Opencode.parse(line),
            Some(CliEvent::Failed {
                message: "Model unavailable: x/y".to_string()
            })
        );
    }

    #[test]
    fn config_points_at_proxy_and_references_token_by_env() {
        let dir = tempdir();
        let request = RunRequest {
            model: "deepseek-v4.1-flash".to_string(),
            worktree: dir.join("wt"),
            config_dir: dir.join("conf"),
            proxy_url: "http://127.0.0.1:51234/".to_string(),
            token: "secret".to_string(),
            prompt: "hi".to_string(),
            hook: None,
        };

        let path = Opencode.write_config(&request).expect("写配置失败");
        let text = std::fs::read_to_string(&path).expect("读配置失败");
        let value: serde_json::Value = serde_json::from_str(&text).expect("配置不是合法 JSON");

        let provider = &value["provider"][PROVIDER_ID];
        assert_eq!(provider["npm"], "@ai-sdk/openai-compatible");
        assert_eq!(
            provider["options"]["baseURL"],
            "http://127.0.0.1:51234/internal/code/v1"
        );
        assert_eq!(
            provider["options"]["apiKey"], "{env:PERSONAL_AGENT_CODE_TOKEN}",
            "令牌不能落进配置文件"
        );
        assert!(provider["models"]["deepseek-v4.1-flash"].is_object());
        assert!(
            !text.contains("secret"),
            "配置文件里不能出现令牌明文：{text}"
        );
    }

    #[test]
    fn command_carries_the_flags_the_spike_proved_necessary() {
        let dir = tempdir();
        let request = RunRequest {
            model: "m".to_string(),
            worktree: dir.clone(),
            config_dir: dir.join("conf"),
            proxy_url: "http://127.0.0.1:1".to_string(),
            token: "t".to_string(),
            prompt: "改个 bug".to_string(),
            hook: None,
        };
        let command = Opencode.command(Path::new("/bin/true"), &request);
        let debug = format!("{command:?}");

        // 这几项每一条都是 spike 里踩出来的，缺一个就跑不通。
        for needle in ["run", "--standalone", "--format", "json", "--auto", "-m"] {
            assert!(debug.contains(needle), "命令缺少 {needle}: {debug}");
        }
        assert!(debug.contains("personal-agent/m"), "{debug}");
    }

    #[test]
    fn command_pins_pwd_to_the_worktree() {
        let dir = tempdir();
        let request = RunRequest {
            model: "m".to_string(),
            worktree: dir.clone(),
            config_dir: dir.join("conf"),
            proxy_url: "http://127.0.0.1:1".to_string(),
            token: "t".to_string(),
            prompt: "改个 bug".to_string(),
            hook: None,
        };

        let command = Opencode.command(Path::new("/bin/true"), &request);
        let pwd = command
            .as_std()
            .get_envs()
            .find(|(key, _)| *key == "PWD")
            .and_then(|(_, value)| value)
            .map(std::ffi::OsStr::to_owned);

        // opencode 按 `PWD` 认项目根：漏了这条，文件会写到隔离工作树之外。
        assert_eq!(
            pwd.as_deref(),
            Some(dir.as_os_str()),
            "PWD 必须指向本次任务的隔离工作树"
        );
    }

    #[test]
    fn capabilities_come_from_the_shared_registry() {
        let caps = Opencode.capabilities();
        assert_eq!(
            caps.tool_approval,
            protocol::ApprovalSupport::Degraded,
            "opencode 没有工具执行前拦截点"
        );
        assert!(caps.stream_events);
    }

    #[test]
    fn tool_detail_prefers_the_state_title() {
        let part = serde_json::json!({
            "state": { "title": "  读取   README  ", "input": { "path": "README.md" } }
        });
        assert_eq!(tool_detail_of(&part), "读取 README");
    }
}
