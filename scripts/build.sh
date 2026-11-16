#!/usr/bin/env bash
# 发布构建：校验 → 测试 → release 二进制 → 安装包。
#
# 用法：
#   ./scripts/build.sh                # 全量：校验 + 测试 + 构建 + 打包
#   ./scripts/build.sh --skip-tests   # 只校验契约/版本后构建（改文档或急着出包时用）
#
# 与 dev.sh 的关系：同一个 workspace、同一套语义，差别只在 release 优化与签名/打包。
# 这里刻意不提供"跳过校验"的开关给版本号：版本不一致的包发出去比构建失败更贵。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

SKIP_TESTS=0
for arg in "$@"; do
  case "${arg}" in
    --skip-tests) SKIP_TESTS=1 ;;
    -h | --help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "未知参数：${arg}" >&2
      exit 2
      ;;
  esac
done

info() { printf '\033[36m›\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

echo "== 契约与版本 =="
python3 scripts/check-versions.py
# check-spec.py 依赖 PyYAML。macOS 的 Homebrew Python 受 PEP 668（externally-managed）
# 保护，pip 装不进去也 --user 不了；本机有 uv 就用一次性临时环境兜底，
# 不为一个校验脚本去污染系统 Python。
if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 scripts/check-spec.py
elif command -v uv >/dev/null 2>&1; then
  info "python3 缺 PyYAML，改用 uv 临时环境"
  uv run --quiet --no-project --with pyyaml python scripts/check-spec.py
else
  fail "需要 PyYAML：macOS 用 brew install pyyaml；或 python3 -m venv .venv 装进虚拟环境"
fi

if [[ "${SKIP_TESTS}" -eq 0 ]]; then
  echo "== 静态检查 =="
  cargo fmt --all --check
  cargo clippy --workspace --all-targets -- -D warnings

  echo "== 测试 =="
  cargo test --workspace
  ( cd jarvis-app && flutter analyze && flutter test )
else
  info "--skip-tests：跳过 fmt / clippy / 测试"
fi

echo "== release 二进制 =="
cargo build --release -p jarvis-service -p jarvis-worker

case "$(uname -s)" in
  Darwin)
    # package-macos.sh 自己会再 release 构建一次（cargo 命中缓存，几乎不耗时），
    # 并在 pkgbuild 前校验 entitlements——那一步不能绕过，所以直接复用它。
    echo "== macOS 安装包 =="
    ./scripts/package-macos.sh
    ;;
  Linux)
    echo "== Linux 压缩包 =="
    VERSION="$(python3 scripts/check-versions.py | tail -1 | sed 's/.*：//')"
    ARCH="$(uname -m)"
    DIST="${ROOT}/dist"
    mkdir -p "${DIST}"
    ARCHIVE="${DIST}/personal-agent-${VERSION}-linux-${ARCH}.tar.gz"
    rm -f "${ARCHIVE}"
    tar -czf "${ARCHIVE}" -C "${ROOT}/target/release" jarvis-service jarvis-worker
    ( cd "${DIST}" && shasum -a 256 "$(basename "${ARCHIVE}")" >"$(basename "${ARCHIVE}").sha256" )
    echo
    echo "压缩包：${ARCHIVE}"
    echo "大小：$(du -h "${ARCHIVE}" | cut -f1)"
    ;;
  *)
    fail "未适配的平台：$(uname -s)（macOS / Linux 之外请手动打包）"
    ;;
esac

echo
echo "== 产物 =="
# 只列文件：dist/ 下还有 pkgroot 中间目录，列出来只会让人以为那也是交付物
ls -lh "${ROOT}/dist" 2>/dev/null | awk 'NR > 1 && $1 !~ /^d/' || true
