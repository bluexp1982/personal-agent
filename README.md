# personal-agent

[English](README.en.md) | 中文

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Rust](https://img.shields.io/badge/Rust-stable-orange)
![Flutter](https://img.shields.io/badge/Flutter-stable-02569B)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-lightgrey)
![Version](https://img.shields.io/badge/version-0.14.0--dev-orange)

跑在自有机器上的个人助理：手机或电脑直连家里的电脑，提问、派活、看结果，数据默认留在本机。

Rust 写 `jarvis-service` 常驻服务与 `jarvis-worker` 任务进程，SQLite 落库、OpenAPI 契约先行；
客户端是 Flutter，覆盖 macOS / Windows / Linux 与 Android / iOS。AI 是主体：对话、任务、
录音共用一个模型网关（默认 DeepSeek），密钥只从环境变量读。

当前版本 **0.14.0**，处于开发者预览阶段，会出现破坏兼容性的变更。接口契约见
[api-spec/](api-spec/)。

## 能做什么

| 能力 | 说明 |
| --- | --- |
| 对话 | 调只读工具（搜索 / 抓取 / 天气）联网查证并标注来源；意图明确时给建议卡，点一下才建任务；文生图、文生视频已进对话 |
| 任务 | 由模型逐步推进、最后归纳成产物，受调用次数与 token 预算约束；编码任务交给本机 CLI 在隔离工作树里跑，确认后才合并 |
| 项目 | 只有一层归属：项目 → 会话 / 任务；Git 项目可派编码任务，普通项目只做生活与办公 |
| 录音笔记 | 实时或批量录音，转写、三种形式总结与语音摘要；音频默认不出本机 |
| 浏览器面板 | 单页内切换客户端本机、服务端回环端口（WebSocket 隧道）、互联网与静态目录 |
| 远程 / 移动端 | 局域网直连 + 自签 TLS，按证书指纹固定服务端身份；Android / iOS 与桌面共用一套客户端 |
| 上下文压缩 | 长会话超出装配上限时把更早的对话归纳成摘要，原文一条不删 |

## 项目结构

```
api-spec/             OpenAPI 契约 v0（唯一真相源）+ 错误码字典
crates/protocol       共享契约类型：错误体、cursor 分页、版本常量
crates/jarvis-service 常驻服务：业务权威、配对鉴权、任务与审批、管理面
crates/jarvis-worker  长任务执行进程：由 service 拉起，不对外暴露端点
jarvis-app            Flutter 客户端（macOS / Windows / Linux / Android / iOS）
jarvis-gui            v1.2 占位：egui 桌面运维面板
jarvis-tui            v1.2 占位：ratatui 终端运维面板
scripts               开发、构建、契约校验脚本
```

## 快速开始

需要 Rust stable 与 Flutter stable；开发期用脚本一条命令起环境，数据写在 `.dev/`，
不碰 `~/.local/share`：

```bash
./scripts/dev.sh            # 起服务（8787 被占会自动后移）
./scripts/dev.sh pair       # 配对码 + 客户端该填的地址
./scripts/dev.sh client     # 起 Flutter 客户端（默认本机桌面平台）
./scripts/dev.sh status     # 服务 / worker / 编码 / 设备 / 数据量
./scripts/build.sh          # 版本与契约校验 + 静态检查 + 测试 + release + 安装包
```

手动等价：`cargo run -p jarvis-service -- --foreground` 起服务，
`cd jarvis-app && flutter run -d macos` 起客户端，两者默认都在 `http://127.0.0.1:8787`。
长期生效的环境变量写进 `.dev/env`（`AGENT_CODE_ROOTS`、`AGENT_PROJECT_ROOTS`、
`PERSONAL_AGENT_LLM_API_KEY` 等），`dev.sh` 每次重写 `.dev/config.json` 会保留它。

## 配对

服务端身份是本机生成的一对密钥，客户端首次连接必须由**本机人工确认**：

1. 客户端首页填服务地址、设备名、12 位配对码 → 点「开始配对」；
2. 客户端进入「等待本机确认」，同时显示服务端证书指纹；
3. 本机终端执行 `jarvis-service pair --approve <request_id>`（`pair` 的输出里有）；
4. 客户端拿到指纹并自动登录，进入对话页；之后的每次连接都会比对指纹。

局域网访问时服务默认启用自签 TLS，客户端必须填 `https://<IP>:8787`，并逐字核对指纹。

## 启用模型（可选）

模型默认关闭；密钥只从环境变量读，不进配置文件、不进仓库：

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

任何 OpenAI 兼容端点都可以，`base_url` 与 `model` 按实际网关填。未配置模型或缺少密钥时
全部退回确定性行为，任务仍能跑完，只是查证结果会标注「未核实」。

## 配置速查

配置文件是 JSON，安装版默认用内置默认值（数据目录 `~/.local/share/personal-agent`），
开发版由 `dev.sh` 生成 `.dev/config.json`。

| 段 | 作用 | 默认 |
| --- | --- | --- |
| `llm` | 对话与任务使用的模型网关 | 关闭 |
| `tool` | 工具预算、搜索上游、网页抓取兜底 | 12 次 / 4 轮 / 300 秒 |
| `task` | 任务调用次数、token 与超时硬上限 | 12 次 / 60000 token / 15 分钟 |
| `compaction` | 上下文压缩阈值、保留条数与输出预算 | 开启，保留 20 条 / 预留 8 条 |
| `project` | 项目可挂载的目录、默认项目目录 | 用户主目录 + 数据目录 |
| `code` | 编码任务：CLI、白名单目录、预算、工具级审批 | 关闭；`allow_roots` 空 = 全拒 |
| `browser` | 右侧栏隧道的端口白名单与并发上限 | 开启，常见开发端口 |
| `asr` / `recording` | 录音转写与配额 | 关闭 |
| `summary` / `tts` | 录音总结与语音摘要 | 总结开启，TTS 开启 |
| `media` | 文生图 / 文生视频（默认关，未启用时工具不可见） | 关闭 |
| `tls` | `auto` / `on` / `off`；非回环绑定自动启用自签 TLS | `auto` |

## 工程约定

- **lint 基线集中在 workspace**：根 `Cargo.toml` 的 `[workspace.lints]` 统一定义，各 crate 继承，CI 以 `-D warnings` 执行。
- **二进制拆 lib + bin**：`jarvis-service` 的实现放在 `src/lib.rs`，`main.rs` 只负责 CLI 与 daemon 生命周期，便于集成测试直接调用内部函数。
- **跨模块类型只走 `protocol`**：数据库行结构、IO 类型与业务逻辑都不进 `protocol`。
- **契约先行**：改接口先改 `api-spec/`，再改 `protocol`，最后改实现。
- **dev 与 release 是同一份二进制、同一套语义**：没有「改安全默认值的 dev 开关」。

## 工具链要求

| 工具 | 用途 |
| --- | --- |
| Rust stable（含 rustfmt / clippy） | 三个 crate |
| `git`（PATH 里可用） | Git 项目的仓库校验与隔离工作树 |
| Flutter stable | 客户端 |

iOS 构建另需 Xcode 与签名 Team，Android 另需 SDK 36 与 CMake 3.22.1；
契约校验需要 Python 3 + PyYAML。CI 的检查由 GitHub 机器执行，本机不装也能通过。

## 文档

- [api-spec/](api-spec/)：OpenAPI 契约与错误码字典，是接口的唯一真相源。
- 需求、架构与页面原型属内部资料，不随本仓库发布。

## 许可证

[MIT](LICENSE)
