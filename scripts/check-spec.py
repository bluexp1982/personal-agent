#!/usr/bin/env python3
"""校验 api-spec 的自洽性。

检查五件事：
1. OpenAPI 版本为 3.1.x；
2. v0 端点集合与预期完全一致（不多不少）；
3. 每个操作都有成功响应（2xx；WebSocket 升级端点的 101 也算成功）；
4. 统一错误体 ApiError 的必填字段恰好是 code / message / retryable / hint；
5. openapi.yaml 的 ApiError.code 枚举与 errors.md 的码表一致，且所有 $ref 都能解析。

为什么不用 oasdiff：本机没有 Go 工具链，M0 阶段先用无依赖的断言脚本兜住
"端点漏了 / 错误码不一致 / ref 写错" 这三类最常见的问题。等 CI 有稳定网络
再引入 oasdiff 做破坏性变更检查（见「开发方案 › 风险登记」）。

用法：python3 scripts/check-spec.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - 环境问题，给出可执行提示
    # Homebrew Python 受 PEP 668 保护，`pip install --user` 必然失败，别再给这条建议。
    sys.exit(
        "需要 PyYAML，任选一种：\n"
        "  macOS（Homebrew Python）：brew install pyyaml\n"
        "  不装包，临时环境跑：uv run --no-project --with pyyaml python scripts/check-spec.py\n"
        "  虚拟环境：python3 -m venv .venv && .venv/bin/pip install pyyaml"
    )

ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "api-spec" / "openapi.yaml"
ERRORS_PATH = ROOT / "api-spec" / "errors.md"

# v0 契约的全部操作：(路径, 方法)。新增端点必须同时改这里，避免"文档加了代码没加"。
EXPECTED_OPERATIONS = {
    ("/api/pair/request", "post"),
    ("/api/pair/confirm", "post"),
    ("/api/pair/requests/{id}", "get"),
    ("/api/auth/challenge", "post"),
    ("/api/auth/verify", "post"),
    ("/api/auth/me", "get"),
    ("/api/projects", "get"),
    ("/api/projects", "post"),
    ("/api/projects/preflight", "get"),
    ("/api/projects/{id}", "get"),
    ("/api/projects/{id}", "patch"),
    ("/api/projects/{id}", "delete"),
    ("/api/fs/dirs", "get"),
    ("/api/projects/{id}/files", "get"),
    ("/api/projects/{id}/file", "get"),
    ("/api/projects/{id}/raw", "get"),
    # 项目内的 Git 操作：状态 / 差异 / 提交历史 + 暂存、取消暂存、丢弃、提交。
    ("/api/projects/{id}/git/status", "get"),
    ("/api/projects/{id}/git/diff", "get"),
    ("/api/projects/{id}/git/commits", "get"),
    ("/api/projects/{id}/git/stage", "post"),
    ("/api/projects/{id}/git/unstage", "post"),
    ("/api/projects/{id}/git/discard", "post"),
    ("/api/projects/{id}/git/commit", "post"),
    ("/api/conversations", "get"),
    ("/api/conversations", "post"),
    ("/api/conversations/{id}", "get"),
    ("/api/conversations/{id}", "patch"),
    ("/api/conversations/{id}", "delete"),
    ("/api/conversations/{id}/messages", "get"),
    ("/api/conversations/{id}/messages", "post"),
    ("/api/conversations/{id}/stop", "post"),
    # 上下文压缩：手动重算一次、关掉这个会话的压缩。
    ("/api/conversations/{id}/compaction", "post"),
    ("/api/conversations/{id}/compaction", "delete"),
    ("/api/conversations/{id}/file-writes/{request_id}", "post"),
    ("/api/conversations/{id}/file-preview", "get"),
    ("/api/recordings", "get"),
    ("/api/recordings", "post"),
    ("/api/recordings/info", "get"),
    ("/api/recordings/{id}", "get"),
    ("/api/recordings/{id}", "patch"),
    ("/api/recordings/{id}", "delete"),
    ("/api/recordings/{id}/segments/{seq}", "post"),
    ("/api/recordings/{id}/complete", "post"),
    ("/api/recordings/{id}/retry", "post"),
    ("/api/recordings/{id}/summary", "post"),
    ("/api/recordings/{id}/summary", "patch"),
    ("/api/recordings/{id}/summary/audio", "get"),
    ("/api/recordings/{id}/summary/audio", "post"),
    ("/api/recordings/{id}/summary/audio/peaks", "get"),
    ("/api/recordings/{id}/audio", "get"),
    ("/api/tasks", "get"),
    ("/api/tasks", "post"),
    # 派任务前的参数解析：会话里 @ 技能时用，静态段写在 /{id} 之前。
    ("/api/tasks/prepare", "post"),
    ("/api/tasks/{id}", "get"),
    ("/api/tasks/{id}", "delete"),
    ("/api/tasks/{id}/cancel", "post"),
    ("/api/tasks/{id}/approve", "post"),
    ("/api/tasks/{id}/retry", "post"),
    ("/api/tasks/{id}/worktree", "delete"),
    ("/api/artifacts/{id}", "get"),
    ("/api/artifacts/{id}/content", "get"),
    ("/api/media/{id}/content", "get"),
    ("/api/media/{id}/poster", "get"),
    ("/api/media/{id}/save", "post"),
    ("/api/conversations/{id}/draft-file", "get"),
    # 会话附件：上传、删除、取原文件。
    ("/api/attachments", "post"),
    ("/api/attachments/{id}", "delete"),
    ("/api/attachments/{id}/content", "get"),
    ("/api/skills", "get"),
    # 技能包：装、看、启停、卸。安装走 application/zip 的二进制 body。
    ("/api/plugins", "get"),
    ("/api/plugins", "post"),
    ("/api/plugins/{id}", "patch"),
    ("/api/plugins/{id}", "delete"),
    # 主题包：装、看、删。同样是 application/zip 的二进制 body；没有启停。
    ("/api/themes", "get"),
    ("/api/themes", "post"),
    ("/api/themes/{id}", "delete"),
    # 模型配置（第三方 OpenAI 兼容网关）：列表 / 新建 / 改 / 删 / 设为当前 / 连通性探测。
    ("/api/models", "get"),
    ("/api/models", "post"),
    ("/api/models/test", "post"),
    ("/api/models/{id}", "patch"),
    ("/api/models/{id}", "delete"),
    ("/api/models/{id}/activate", "post"),
    ("/api/code/providers", "get"),
    ("/api/ssh", "get"),
    ("/api/ssh/info", "get"),
    ("/api/browser/tunnel", "get"),
    ("/api/browser/info", "get"),
    # 记忆（贾维斯一期 P1）：显式增删改查 + 状态快照 + digest 快照。
    # P2/P3/P4/G 的候选、实体、授权端点落地时再往这里追加。
    ("/api/memories", "get"),
    ("/api/memories", "post"),
    ("/api/memories/state", "get"),
    ("/api/memories/digest", "get"),
    ("/api/memories/digest/{id}", "get"),
    ("/api/memories/{id}", "get"),
    ("/api/memories/{id}", "patch"),
    ("/api/memories/{id}", "delete"),
    # P2：候选确认、整批撤销、反馈、批量遗忘。
    ("/api/memories/candidates/decide", "post"),
    ("/api/memories/batches/{batch_id}/revoke", "post"),
    ("/api/memories/forget", "post"),
    ("/api/memories/{id}/feedback", "post"),
    # P3：项目记忆导出 + 实体页。
    ("/api/memories/export/preview", "post"),
    ("/api/memories/export/apply", "post"),
    ("/api/entities", "get"),
    ("/api/entities/merge", "post"),
    ("/api/entities/{id}", "get"),
    ("/api/entities/{id}", "patch"),
    ("/api/entities/{id}/split", "post"),
    # P4：记忆设置（心跳防噪）。
    ("/api/memories/settings", "patch"),
    # 2026-10-30 补：手动整理 + 清空归档（开发方案 5.3 端点 16 / 16a）。
    ("/api/memories/organize", "post"),
    ("/api/memories/archived/purge", "post"),
    # G：执行授权（只有列表与撤销，创建只能经由审批卡）。
    ("/api/grants", "get"),
    ("/api/grants/{id}", "delete"),
}

HTTP_METHODS = {"get", "post", "put", "patch", "delete", "head", "options"}

# 成功响应不一定是 2xx：WebSocket 升级的成功标志是 101 Switching Protocols。
# 只在这一处放宽，避免"为了过脚本"给升级端点硬凑一个 200 响应，把契约写歪。
SUCCESS_CODES_PREFIXES = ("2",)
SUCCESS_CODES_EXACT = {"101"}
ERROR_FIELDS = {"code", "message", "retryable", "hint"}

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def collect_operations(spec: dict) -> set[tuple[str, str]]:
    operations: set[tuple[str, str]] = set()
    for path, item in (spec.get("paths") or {}).items():
        for method in item:
            if method in HTTP_METHODS:
                operations.add((path, method))
    return operations


def collect_refs(node, found: list[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                found.append(value)
            else:
                collect_refs(value, found)
    elif isinstance(node, list):
        for item in node:
            collect_refs(item, found)


def resolve_ref(spec: dict, ref: str) -> bool:
    if not ref.startswith("#/"):
        return True  # 外部引用不在本脚本职责内
    node = spec
    for part in ref.lstrip("#/").split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        if not isinstance(node, dict) or part not in node:
            return False
        node = node[part]
    return True


def codes_from_errors_md(text: str) -> set[str]:
    return set(re.findall(r"^\|\s*`([a-z_]+)`\s*\|", text, flags=re.MULTILINE))


def main() -> int:
    spec = yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))
    errors_md = ERRORS_PATH.read_text(encoding="utf-8")

    version = str(spec.get("openapi", ""))
    if not version.startswith("3.1"):
        fail(f"OpenAPI 版本应为 3.1.x，实际为 {version!r}")

    operations = collect_operations(spec)
    missing = EXPECTED_OPERATIONS - operations
    extra = operations - EXPECTED_OPERATIONS
    if missing:
        fail("缺少端点：" + ", ".join(f"{m.upper()} {p}" for p, m in sorted(missing)))
    if extra:
        fail("多出未登记端点（请同步本脚本与开发方案）：" + ", ".join(f"{m.upper()} {p}" for p, m in sorted(extra)))

    for path, method in sorted(operations):
        responses = (spec["paths"][path][method].get("responses") or {})
        success = any(
            str(code).startswith(SUCCESS_CODES_PREFIXES)
            or str(code) in SUCCESS_CODES_EXACT
            for code in responses
        )
        if not success:
            fail(f"{method.upper()} {path} 没有成功响应（2xx 或 101）")

    api_error = (spec.get("components", {}).get("schemas", {}) or {}).get("ApiError")
    if not api_error:
        fail("components.schemas.ApiError 不存在")
    else:
        required = set(api_error.get("required") or [])
        if required != ERROR_FIELDS:
            fail(f"ApiError.required 应为 {sorted(ERROR_FIELDS)}，实际为 {sorted(required)}")
        enum_values = set((api_error.get("properties", {}).get("code", {}) or {}).get("enum") or [])
        documented = codes_from_errors_md(errors_md)
        if enum_values != documented:
            only_spec = sorted(enum_values - documented)
            only_doc = sorted(documented - enum_values)
            fail(f"ApiError.code 枚举与 errors.md 不一致：仅规范有 {only_spec}，仅文档有 {only_doc}")

    refs: list[str] = []
    collect_refs(spec, refs)
    broken = sorted({ref for ref in refs if not resolve_ref(spec, ref)})
    if broken:
        fail("无法解析的 $ref：" + ", ".join(broken))

    paths_count = len(spec.get("paths") or {})
    if failures:
        print("契约校验失败：")
        for item in failures:
            print(f"  - {item}")
        return 1

    print(
        "契约校验通过："
        f"openapi {version}，{paths_count} 条路径 / {len(operations)} 个操作，"
        f"{len(codes_from_errors_md(errors_md))} 个错误码，{len(refs)} 处 $ref 全部可解析"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
