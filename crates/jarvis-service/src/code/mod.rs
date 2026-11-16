//! 编码任务的服务端支撑：provider 可用性探测与任务路由。
//!
//! 与 `code_proxy`（模型出口）分开：这里回答"派给谁、用什么模型"，
//! 代理回答"怎么把请求送到网关"。两者的失败语义也不同——前者是
//! `code_unavailable`（装或配），后者是上游错误（重试或换模型）。

pub mod router;

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use crate::config::{Config, SUPPORTED_CODE_PROVIDERS};

/// 探测 `git ls-files` 的超时。路由不该为了数文件把任务下发卡住。
const FILE_COUNT_TIMEOUT: Duration = Duration::from_secs(2);
/// 计数上限：超过它就不再读，`large_repo_min` 默认也远小于这个数。
const FILE_COUNT_CAP: usize = 500;

/// 某个 provider 现在能不能用：已启用 + 可执行文件存在。
///
/// worker 侧还会再 `resolve` 一次（PATH 可能不同），这里只做"尽量别派出一个必然失败的任务"。
pub fn provider_available(config: &Config, id: &str) -> bool {
    if !config.code_provider_enabled(id) {
        return false;
    }
    match config.code_provider_bin(id) {
        Some(bin) => bin.is_file(),
        None => {
            // codebuddy 的官方安装器同时提供短名 `cbc`：与 worker 的 resolve 一致。
            which(default_binary(id)).is_some() || (id == "codebuddy" && which("cbc").is_some())
        }
    }
}

/// 按路由优先级排好的可用 provider 列表。
///
/// 顺序：`routing.preferred` → `routing.fallback` → `code.provider` →（其余已注册且
/// 可用的）。去重，且只保留真的能用的。
///
/// 末尾那一档**不参与自动路由**：`router::pick_provider` 只按前三档的优先级挑。
/// 把它们放进列表的唯一目的是让"用户显式点名"能生效——否则客户端能选到本机装好的
/// CLI，后端却回一句"指定的编码 CLI 不可用"。
pub fn available_providers(config: &Config) -> Vec<String> {
    let mut ordered: Vec<&str> = Vec::new();
    for id in config
        .code
        .routing
        .preferred
        .iter()
        .chain(config.code.routing.fallback.iter())
        .chain(std::iter::once(&config.code.provider))
    {
        if !ordered.contains(&id.as_str()) {
            ordered.push(id.as_str());
        }
    }
    // 注册表顺序即稳定顺序：本机装了几个就能选几个。
    for id in SUPPORTED_CODE_PROVIDERS {
        if !ordered.contains(id) {
            ordered.push(id);
        }
    }

    ordered
        .into_iter()
        .filter(|id| SUPPORTED_CODE_PROVIDERS.contains(id) && provider_available(config, id))
        .map(str::to_string)
        .collect()
}

/// 仓库文件数（有上界）。不是 git 仓库、超时、命令不存在都返回 `None`。
///
/// 用 `git ls-files` 而不是遍历目录：只数被 git 跟踪的文件，`node_modules`
/// 与构建产物不会把"小项目"误判成"大仓"。
pub async fn count_repo_files(repo: &Path) -> Option<usize> {
    let mut child = tokio::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .arg("ls-files")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;

    let stdout = child.stdout.take()?;
    let counted = tokio::time::timeout(FILE_COUNT_TIMEOUT, count_lines(stdout)).await;
    let _ = child.kill().await;

    match counted {
        Ok(Some(count)) => Some(count),
        _ => None,
    }
}

async fn count_lines(stream: impl tokio::io::AsyncRead + Unpin) -> Option<usize> {
    use tokio::io::{AsyncBufReadExt, BufReader};

    let mut lines = BufReader::new(stream).lines();
    let mut count = 0usize;
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        count += 1;
        if count >= FILE_COUNT_CAP {
            break;
        }
    }
    Some(count)
}

/// 每个 provider 的默认可执行文件名（与 worker 的 `resolve` 保持一致）。
fn default_binary(id: &str) -> &'static str {
    match id {
        "opencode" => "opencode",
        "codebuddy" => "codebuddy",
        "codex" => "codex",
        "claude" => "claude",
        _ => "",
    }
}

fn which(name: &str) -> Option<std::path::PathBuf> {
    if name.is_empty() {
        return None;
    }
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::CodeProviderConfig;

    #[test]
    fn default_binary_names_match_the_worker_side() {
        assert_eq!(default_binary("opencode"), "opencode");
        // codebuddy 的官方安装器同时提供短名 cbc；主名仍按长名，可用性探测再退回短名。
        assert_eq!(default_binary("codebuddy"), "codebuddy");
        assert_eq!(default_binary("codex"), "codex");
        assert_eq!(default_binary("claude"), "claude");
        assert_eq!(default_binary("nope"), "");
    }

    /// `provider_available` 只看 `is_file()`，不需要真有执行权限。
    fn bin_in(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, b"#!/bin/sh\n").expect("写临时 bin");
        path
    }

    /// 把四个 provider 的 bin 全部钉死。不钉的话 `provider_available` 会去读真实
    /// PATH，断言就取决于跑测试的机器上装了什么。
    fn config_with_bins(dir: &std::path::Path, installed: &[&str]) -> Config {
        let mut config = Config::default();
        config.code.provider = "opencode".to_string();
        for id in SUPPORTED_CODE_PROVIDERS {
            let bin = if installed.contains(id) {
                bin_in(dir, id)
            } else {
                dir.join(format!("missing-{id}"))
            };
            config.code.providers.insert(
                (*id).to_string(),
                CodeProviderConfig {
                    bin: Some(bin),
                    enabled: true,
                },
            );
        }
        config
    }

    #[test]
    fn installed_cli_outside_the_routing_list_is_still_selectable() {
        // routing 为空时默认 provider 是唯一候选，它没装的话，已装的 codex 也必须
        // 留在列表里——否则用户在下拉里选了它，后端会回"指定的编码 CLI 不可用"。
        let dir = tempfile::tempdir().expect("tempdir");
        let config = config_with_bins(dir.path(), &["codex"]);
        assert_eq!(available_providers(&config), vec!["codex"]);
    }

    #[test]
    fn routing_order_comes_first_and_installed_extras_go_last() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut config = config_with_bins(dir.path(), &["opencode", "claude", "codex"]);
        config.code.routing.preferred = vec!["codex".to_string()];

        // 顺序即路由优先级：首选和默认在前，其余按注册表顺序追加在后。
        assert_eq!(
            available_providers(&config),
            vec!["codex", "opencode", "claude"]
        );
    }

    #[test]
    fn disabled_provider_is_never_listed() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut config = config_with_bins(dir.path(), &["opencode", "codex"]);
        config
            .code
            .providers
            .get_mut("codex")
            .expect("已登记")
            .enabled = false;

        assert_eq!(available_providers(&config), vec!["opencode"]);
    }
}
