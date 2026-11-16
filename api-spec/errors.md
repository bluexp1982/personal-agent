# 错误码字典

所有非 2xx 响应都使用统一错误体：

```json
{ "code": "not_found", "message": "task not found", "retryable": false, "hint": "任务不存在或已被删除" }
```

约定：

- `code` 一旦发布不可改变语义，只能新增；客户端按 `code` 分支，不解析 `message`。
- `retryable` 由服务端决定（与错误码一一对应），客户端据此决定是否显示"重试"。
- `hint` 面向用户，可直接展示；`message` 面向开发者与日志，可能含内部细节，不直接展示。

## 错误码

| code | HTTP | retryable | 触发场景 | hint 示例 |
| --- | --- | --- | --- | --- |
| `invalid_request` | 400 | 否 | 参数缺失、类型错误、cursor 无法解析 | 请求参数有问题，请检查后重试 |
| `unauthenticated` | 401 | 否 | 未配对、challenge 过期、签名校验失败 | 设备未授权，请重新配对 |
| `forbidden` | 403 | 否 | 已认证但无权执行（如未获 L2 审批） | 该操作需要你的确认 |
| `not_found` | 404 | 否 | 会话、任务、产物不存在或已删除 | 找不到该内容，可能已被删除 |
| `conflict` | 409 | 否 | 状态冲突（任务已取消、审批已处理、删除仍有任务的会话、删除未结束的任务） | 当前状态不允许该操作 |
| `rate_limited` | 429 | 是 | 触发限流（信令加入、配对尝试） | 操作过于频繁，请稍后再试 |
| `approval_expired` | 409 | 否 | 审批超过 `expires_at` 自动拒绝 | 确认已超时，请重新发起 |
| `idempotency_conflict` | 409 | 否 | 同一幂等键被不同参数重复提交 | 该操作已在处理中 |
| `dependency_unavailable` | 503 | 是 | 模型服务商不可达、目标站点超时 | 外部服务暂时不可用，稍后重试 |
| `worker_unavailable` | 503 | 是 | 执行进程未连接或已退出 | 执行进程未就绪，任务已排回队列 |
| `skill_unknown` | 409 | 否 | 任务声明的技能未加载或已被禁用 | 该技能不可用，请检查配置 |
| `output_missing` | 409 | 否 | 产物未覆盖技能声明的 outputs | 任务产出不完整，可重试 |
| `budget_exceeded` | 409 | 否 | 单任务模型调用次数或 token 超过 `task` / `code.budget` 配置上限 | 单任务模型用量已超上限，可缩小范围或调高预算后重试 |
| `code_unavailable` | 503 | 否 | 编码能力未启用、CLI 二进制缺失、代理未就绪或上游密钥缺失 | 编码能力不可用，请检查 code 配置与模型密钥 |
| `code_project_denied` | 400 | 否 | 目标仓库不在 `code.allow_roots` 内、不是 git 仓库、不是仓库根目录、仓库还没有任何提交、HEAD 处于游离状态，或所属项目没有启用 Git 仓库 | 按提示修正路径或分支后重试：填仓库根目录、先提交一次、切回分支，或把会话建在 Git 项目里 |
| `code_failed` | 502 | 是 | 编码 CLI 非零退出、执行超时或内部错误 | 代码任务执行失败，可重试；现场已保留 |
| `code_merge_conflict` | 409 | 否 | 合并回目标分支时冲突 | 改动与该分支冲突，已保留分支与工作树 |
| `ssh_unavailable` | 503 | 是 | 服务端未开启 SSH 隧道（`ssh.enabled=false`），或 `ssh.target` 的 sshd 连不上 | 服务端未开启远程登录（sshd），打开后再试 |
| `browser_unavailable` | 503 | 是 | 服务端未开启浏览器隧道（`browser.enabled=false`），或目标端口拒绝连接 | 服务端没有开启浏览器访问，或该端口的服务还没启动；启动后重试 |
| `browser_target_denied` | 403 | 否 | 目标不是回环地址，或端口不在 `browser.allowed_ports` 内 | 该端口未被服务端允许：在服务端配置的 `browser.allowed_ports` 里加上它后重启 |
| `recording_not_found` | 404 | 否 | 录音不存在或已被删除 | 录音不存在或已被删除 |
| `invalid_audio` | 400 | 否 | 分段不是 WAV、不是 16kHz 单声道 PCM16，或时长与 `start_ms`/`end_ms` 明显不符 | 音频格式不对：请用 16kHz 单声道 WAV 重新上传 |
| `asr_unavailable` | 503 | 是 | 服务端未开启转写（`asr.enabled=false`）、缺少密钥或 provider 未就绪 | 转写服务未就绪，音频已保存在服务端；开启后可重试 |
| `asr_failed` | 502 | 是 | 上游转写失败、超时或返回无法解析 | 转写失败，音频已保留；可重试失败分段 |
| `payload_too_large` | 413 | 否 | 分段或归档音频超过配置上限（`recording.max_segment_bytes` / `max_total_bytes`） | 文件过大，请缩短单段录音或调整服务端限额 |
| `recording_quota_exceeded` | 409 | 否 | 单条录音的时长或总字节数超过 `recording` 配置上限 | 录音超出服务端配额，请拆分录音或调高上限 |
| `summary_unavailable` | 503 | 是 | 未开启总结（`summary.enabled=false`），或模型未配置 | 服务端未开启总结或模型未配置；开启后可重试 |
| `summary_not_ready` | 409 | 是 | 录音未结束、还有分段未转写完成，或没有可总结的文字 | 全部分段转写完成后再生成总结 |
| `tts_unavailable` | 503 | 是 | 未开启语音合成（`tts.enabled=false`）、缺少密钥或 provider 未就绪 | 服务端未开启语音合成；总结文字仍可查看 |
| `summary_audio_not_ready` | 409 | 是 | 总结语音还在合成、合成失败或文件缺失 | 语音还没准备好，稍后重试 |
| `memory_unavailable` | 503 | 否 | 记忆功能未启用（`memory.enabled=false`），或启用但缺少可用模型 | 记忆功能未启用：在配置里打开 `memory.enabled` 后重启服务 |
| `plugin_invalid` | 400 | 否 | 技能包结构不可识别（找不到 `SKILL.md` 或清单）、清单字段非法、压缩包损坏、超出大小/文件数/解压限额 | 这个包不是可识别的技能包：确认 zip 里含 `SKILL.md` 或 `skills/*/SKILL.md` |
| `plugin_conflict` | 409 | 否 | 插件 id 已存在，或技能名与内置技能、其它插件重名 | 同名技能已存在，先卸载旧版本或改名后重装 |
| `plugin_not_found` | 404 | 否 | 插件不存在或已被卸载 | 插件不存在或已卸载 |
| `theme_invalid` | 400 | 否 | 主题包不合法：缺 `theme.json`、字段校验失败、颜色格式非法、压缩包损坏或超出限额 | 这个包不是可识别的主题包：确认 zip 里含 `theme.json` 且 `brightness` 为标准取值 |
| `theme_not_found` | 404 | 否 | 主题包不存在或已被删除 | 主题包不存在或已删除 |
| `internal_error` | 500 | 是 | 未预期异常，详情见本地日志 | 出现内部错误，请查看日志 |

## 删除语义

| 操作 | 成功 | 拒绝条件 | 备注 |
| --- | --- | --- | --- |
| `DELETE /api/projects/{id}` | 204 | `not_found`（不存在或已删）、`conflict`（项目下仍有未结束的任务：queued / running / needs_input / needs_approval） | **逻辑删除**：只写 `deleted_at`，项目与其下会话、任务一起从接口视图消失，库中数据全部保留；当前无恢复接口 |
| `DELETE /api/conversations/{id}` | 204 | `not_found`（不存在或已删）、`conflict`（会话下仍有未结束的任务：queued / running / needs_input / needs_approval） | **逻辑删除**：写 `deleted_at`，会话与消息都留在库里；会话名下**已结束**的任务级联软删（同时释放幂等键），当前无恢复接口 |
| `DELETE /api/tasks/{id}` | 204 | `not_found`（不存在或已删）、`conflict`（queued / running / needs_input / needs_approval） | **逻辑删除**：写 `deleted_at` 并释放幂等键；步骤、审批、产物元信息保留，产物文件与工作树保留，产物端点随任务一起 404 |
| `DELETE /api/recordings/{id}` | 204 | `not_found`（不存在） | **物理删除**：录音元信息、分段记录与服务端归档音频一起删除，不可恢复 |

重复删除同一 id 返回 `not_found`；客户端批量删除时按「已不存在」视为成功。
项目 / 会话 / 任务的软删数据永久保留，不自动清理；录音例外，删除即释放磁盘。

## 新增错误码的流程

1. 先确认现有码无法表达该语义（宁可复用，不轻易新增）。
2. 在 `crates/protocol/src/error.rs` 的 `ErrorCode` 中新增变体，并补 `as_str()`。
3. 同步更新本表与 `openapi.yaml` 的 `ApiError.code` 枚举。
4. 跑 `python3 scripts/check-spec.py`，它会校验三处是否一致。
