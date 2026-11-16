# personal-agent

English | [中文](README.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Rust](https://img.shields.io/badge/Rust-stable-orange)
![Flutter](https://img.shields.io/badge/Flutter-stable-02569B)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-lightgrey)
![Version](https://img.shields.io/badge/version-0.14.0--dev-orange)

A personal assistant that runs on your own machine: your phone or laptop connects straight to the
computer at home, you ask, delegate and read results, and the data stays local by default.

Rust powers the `jarvis-service` daemon and the `jarvis-worker` task process, backed by SQLite and
an OpenAPI-first contract. The client is Flutter and covers macOS / Windows / Linux plus Android /
iOS. AI is the core: chat, tasks and recordings share one model gateway (DeepSeek by default), and
keys are only read from environment variables.

Current version is **0.14.0** — a developer preview, so breaking changes will happen. The API
contract lives in [api-spec/](api-spec/).

## What it does

| Capability | Summary |
| --- | --- |
| Chat | Calls read-only tools (search / fetch / weather) to verify facts and cites sources; when intent is clear it offers a suggestion card and only creates a task when you click it; text-to-image and text-to-video are wired into chat |
| Tasks | The model advances a task step by step and summarizes a result, bounded by call and token budgets; coding tasks run through a local CLI in an isolated worktree and merge only after you confirm |
| Projects | A single level of ownership: project → conversations / tasks; Git projects can take coding tasks, plain projects are for everyday work |
| Recordings | Realtime or batch recording with transcription, three summary styles and spoken summaries; audio stays local unless you opt in |
| Browser panel | One page with switchable sources: client machine, server loopback ports over a WebSocket tunnel, the internet, or a static directory |
| Remote / mobile | Direct LAN connection with self-signed TLS and certificate-fingerprint pinning; Android / iOS share the same client |
| Context compaction | Long conversations fold earlier turns into a summary once they exceed the assembly limit; no message is ever deleted |

## Layout

```
api-spec/             OpenAPI contract v0 (single source of truth) + error code dictionary
crates/protocol       Shared contract types: error body, cursor pagination, version constants
crates/jarvis-service Daemon: business authority, pairing auth, tasks and approvals, admin surface
crates/jarvis-worker  Long-running task process, spawned by the service, no public endpoints
jarvis-app            Flutter client (macOS / Windows / Linux / Android / iOS)
jarvis-gui            v1.2 placeholder: egui desktop ops panel
jarvis-tui            v1.2 placeholder: ratatui terminal ops panel
scripts               Development, build and contract-check scripts
```

## Quick start

You need Rust stable and Flutter stable. During development one script brings everything up and
keeps data in `.dev/`, leaving `~/.local/share` untouched:

```bash
./scripts/dev.sh            # start the service (falls back to another port if 8787 is taken)
./scripts/dev.sh pair       # pairing code plus the address to type into the client
./scripts/dev.sh client     # start the Flutter client (local desktop platform by default)
./scripts/dev.sh status     # service / worker / coding / devices / data overview
./scripts/build.sh          # version & contract checks + lints + tests + release + installer
```

Manual equivalents: `cargo run -p jarvis-service -- --foreground` for the service and
`cd jarvis-app && flutter run -d macos` for the client; both default to `http://127.0.0.1:8787`.
Long-lived environment variables go into `.dev/env` (`AGENT_CODE_ROOTS`, `AGENT_PROJECT_ROOTS`,
`PERSONAL_AGENT_LLM_API_KEY`, …); `dev.sh` rewrites `.dev/config.json` on every run but keeps it.

## Pairing

The server identity is a key pair generated on the machine, so a new client must be confirmed
locally by a human:

1. On the client, enter the server address, a device name and the 12-digit pairing code, then start pairing.
2. The client waits for local confirmation and shows the server certificate fingerprint.
3. On the machine, run `jarvis-service pair --approve <request_id>` (the id is printed by `pair`).
4. The client pins the fingerprint, logs in automatically and opens the conversation view; every later connection compares fingerprints again.

When the service listens on a LAN address it enables self-signed TLS by default, so the client must
use `https://<IP>:8787` and you should compare the fingerprint character by character.

## Enabling a model (optional)

Models are off by default, and the key is read from the environment only — never from the config
file or the repository:

```bash
export PERSONAL_AGENT_LLM_API_KEY='...'
```

```json
{
  "llm": {
    "enabled": true,
    "base_url": "https://api.deepseek.com",
    "model": "deepseek-v4.1-flash",
    "api_key_env": "PERSONAL_AGENT_LLM_API_KEY"
  }
}
```

Any OpenAI-compatible endpoint works; set `base_url` and `model` to what your gateway offers. With
no model configured (or no key) everything falls back to deterministic behaviour: tasks still
finish, verification results are just marked "unverified".

## Configuration at a glance

Configuration is JSON. Installed builds use built-in defaults (data directory
`~/.local/share/personal-agent`); development builds get `.dev/config.json` from `dev.sh`.

| Section | Purpose | Default |
| --- | --- | --- |
| `llm` | Model gateway for chat and tasks | disabled |
| `tool` | Tool budgets, search provider, fetch fallback | 12 calls / 4 rounds / 300 s |
| `task` | Hard limits on task calls, tokens and time | 12 calls / 60000 tokens / 15 min |
| `compaction` | Compaction thresholds, kept messages, output budget | on, 20 messages / keep 8 |
| `project` | Mountable project roots and default project directory | home directory + data directory |
| `code` | Coding tasks: CLI, allowed roots, budget, tool approval | off; empty `allow_roots` denies everything |
| `browser` | Right-panel tunnel port allowlist and concurrency | on, common dev ports |
| `asr` / `recording` | Recording transcription and quotas | disabled |
| `summary` / `tts` | Recording summaries and spoken summaries | summary on, TTS on |
| `media` | Text-to-image / text-to-video (hidden when off) | disabled |
| `tls` | `auto` / `on` / `off`; non-loopback binds enable self-signed TLS | `auto` |

## Conventions

- **One lint baseline in the workspace**: `[workspace.lints]` in the root `Cargo.toml`, inherited by every crate, enforced with `-D warnings` in CI.
- **lib + bin split**: `jarvis-service` keeps its implementation in `src/lib.rs`; `main.rs` only handles the CLI and daemon lifecycle, so integration tests call internals directly.
- **Cross-module types only through `protocol`**: database rows, I/O types and business logic stay out.
- **Contract first**: change `api-spec/`, then `protocol`, then the implementation.
- **dev and release are the same binary with the same semantics**: there is no "dev switch that relaxes safe defaults".

## Toolchain

| Tool | Purpose |
| --- | --- |
| Rust stable (with rustfmt / clippy) | the three crates |
| `git` on PATH | repository checks and isolated worktrees for Git projects |
| Flutter stable | the client |

iOS builds also need Xcode and a signing team; Android needs SDK 36 and CMake 3.22.1; contract
checks need Python 3 + PyYAML. CI checks run on GitHub runners, so a local install is optional.

## Docs

- [api-spec/](api-spec/): OpenAPI contract and error codes — the single source of truth for the API.
- Requirements, architecture and UI prototypes are internal material and are not published here.

## License

[MIT](LICENSE)
