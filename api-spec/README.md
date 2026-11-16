# api-spec

`jarvis-service` 对外接口的唯一真相源，被五个模块共同消费：

| 消费方 | 方式 |
| --- | --- |
| `crates/protocol` | 手写 Rust 类型，字段与本规范一一对应（M0 评估过生成器，收益不足，暂手写） |
| `jarvis-gui` / `jarvis-tui` | 通过 `protocol` crate 间接对齐 |
| `jarvis-worker` | 只用业务类型，不消费端点 |
| `jarvis-app` | 后续从本规范生成 Dart 客户端 |

## 文件

| 文件 | 内容 |
| --- | --- |
| `openapi.yaml` | v0 契约：24 条路径 / 32 个操作 |
| `errors.md` | 18 个稳定错误码与新增流程 |

## 校验

```bash
python3 scripts/check-spec.py
```

脚本会检查：OpenAPI 版本、端点集合（不多不少）、统一错误体四字段、错误码三处一致（`openapi.yaml` / `errors.md` / `protocol` 的 `ErrorCode`）、所有 `$ref` 可解析。

> 本机没有 Go，暂时无法用 `oasdiff` 做破坏性变更检查；该脚本覆盖了"端点漏加、错误码漂移、ref 写错"三类高频问题，`oasdiff` 在 CI 有稳定网络后补上。

## 新增端点

1. 在 `openapi.yaml` 写路径与 schema，错误响应引用 `components/responses/*`。
2. 在 `scripts/check-spec.py` 的 `EXPECTED_OPERATIONS` 里登记该操作。
3. 在 `crates/protocol` 补对应类型与单测。
4. 资源边界变化时，同步更新本文件开头的端点规模说明。
5. 跑 `python3 scripts/check-spec.py` 与 `cargo test --project`。

## 端点规模

按资源粗算的"15 个端点"只是近似值；本规范实际落地为 **28 条路径 / 37 个操作**（例如 `/api/conversations` 与 `/api/projects/{id}` 都是同一路径上挂多个方法）。

M2/M3 在原始清单外补了三个操作，均为实现必需：

- `GET /api/pair/requests/{id}`：客户端提交配对码后只能靠它得知是否被批准，否则拿不到服务端公钥与指纹。
- `GET /api/auth/me`：验收要求"带令牌访问受保护端点"，需要一条最小可用且无副作用的受保护路由。
- `POST /api/tasks`：任务必须显式创建（"咨询不建任务"），否则没有任何入口能触发 L3 执行。

0.7.0 又补了项目相关的 6 个操作，0.8.0 再补 1 个预检，同样没有替代方案：

- `GET/POST /api/projects`、`GET/PATCH/DELETE /api/projects/{id}`：会话与任务必须挂在项目下，
  而项目绑定的是**服务端**的真实目录，客户端无法自己拼出合法的归属。
- `GET /api/fs/dirs`：目录在服务端那台电脑上，没有它客户端只能手输绝对路径。
- `GET /api/projects/preflight`：`code_project_denied` 同时覆盖越界、无权限、不是仓库、
  游离 HEAD 四种情况，客户端只有拿到预检结果才知道该不该弹"要不要初始化仓库"。

0.9.0 补了 SSH 隧道的 2 个操作，理由同样是"没有替代路径"：

- `GET /api/ssh`：客户端要一个交互式 shell，但 22 端口不该对外暴露，也不该与 `/api/*`
  的可达性不同。用 WebSocket 做纯字节透传（不解析 SSH 协议），鉴权与 TLS 指纹直接复用。
- `GET /api/ssh/info`：没有它，"服务端没开远程登录"只能表现为一次失败的密码登录，
  与"密码错了"无法区分。预检把这件事提前成一条可展示的结论。
