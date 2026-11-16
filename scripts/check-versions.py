#!/usr/bin/env python3
"""版本一致性校验。

发版时最容易出的事：二进制、客户端、契约三处版本号各说各话。
这里一次性比对三个来源，任何一处不一致直接失败。

检查项：
  1. Cargo workspace 版本
  2. protocol::VERSION（由 CARGO_PKG_VERSION 派生，随 workspace）
  3. Flutter pubspec 版本（去掉 +build；客户端界面显示的版本在运行时读安装包，
     源头就是这一处）
  4. api-spec/openapi.yaml 的 info.version
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read(path: Path) -> str:
    if not path.is_file():
        fail(f"缺少文件：{path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def fail(message: str) -> None:
    print(f"[版本校验失败] {message}", file=sys.stderr)
    raise SystemExit(1)


def cargo_version() -> str:
    text = read(ROOT / "Cargo.toml")
    # 只取 [workspace.package] 段里的 version
    block = re.search(r"\[workspace\.package\](.*?)(?:\n\[|\Z)", text, re.S)
    if not block:
        fail("Cargo.toml 缺少 [workspace.package]")
    match = re.search(r'^version\s*=\s*"([^"]+)"', block.group(1), re.M)
    if not match:
        fail("Cargo.toml 缺少 workspace.package.version")
    return match.group(1)


def pubspec_version() -> str:
    text = read(ROOT / "jarvis-app" / "pubspec.yaml")
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+\d+)?", text, re.M)
    if not match:
        fail("pubspec.yaml 缺少 version")
    return match.group(1)


def openapi_version() -> str:
    text = read(ROOT / "api-spec" / "openapi.yaml")
    match = re.search(r"^info:\n(?:.*\n)*?\s+version:\s*([^\s#]+)", text, re.M)
    if not match:
        fail("openapi.yaml 缺少 info.version")
    return match.group(1).strip('"\'')


def main() -> None:
    versions = {
        "Cargo workspace": cargo_version(),
        "pubspec": pubspec_version(),
        "openapi info.version": openapi_version(),
    }

    print("版本来源：")
    for name, value in versions.items():
        print(f"  {name}: {value}")

    distinct = set(versions.values())
    if len(distinct) != 1:
        fail(f"版本不一致：{versions}")

    print(f"版本一致性通过：{distinct.pop()}")


if __name__ == "__main__":
    main()
