#!/usr/bin/env bash
# 生成 macOS 安装包（未签名）。
#
# 产物：
#   dist/personal-agent-<version>-macos-<arch>.pkg
#     /usr/local/bin/jarvis-service
#     /usr/local/bin/jarvis-worker
#     /Applications/Jarvis.app
#
# 为什么不放 postinstall 注册服务：launchd 的 LaunchAgent 属于**当前登录用户**，
# 而 pkg 的 postinstall 以 root 运行，注册到 root 域下服务不会随用户登录启动。
# 因此安装包只落文件，服务注册由首次启动客户端或手动 `jarvis-service install` 完成。
#
# 签名与公证需要 Apple Developer 证书，当前为 ad-hoc 签名；对外分发前必须补：
#   codesign --deep --options runtime --sign "Developer ID Application: ..." ...
#   xcrun notarytool submit ... --wait && xcrun stapler staple ...
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(python3 scripts/check-versions.py | tail -1 | sed 's/.*：//')"
ARCH="$(uname -m)"
DIST="$ROOT/dist"
PKGROOT="$DIST/pkgroot"
# 产物名来自 macos/Runner/Configs/AppInfo.xcconfig 的 PRODUCT_NAME：Dock 悬停提示与
# 启动台显示的就是它，所以是 Jarvis 而不是 Dart 包名 jarvis_app。
APP_NAME="Jarvis.app"
PKG="$DIST/personal-agent-${VERSION}-macos-${ARCH}.pkg"

echo "== 版本 ${VERSION} / ${ARCH} =="

echo "== 构建 Rust 二进制（release）=="
cargo build --release -p jarvis-service -p jarvis-worker

echo "== 构建 Flutter 应用（release）=="
( cd jarvis-app && flutter build macos --release >/dev/null )

echo "== 校验应用权限声明 =="
BUILT_APP="jarvis-app/build/macos/Build/Products/Release/${APP_NAME}"
# 「另存为」依赖 files.user-selected.read-write；缺了它沙箱会拒绝写入，
# 用户在界面上只会看到「保存失败」。这里在打包阶段就拦下来，而不是等运行时。
ENTITLEMENTS="$(codesign -d --entitlements :- "$BUILT_APP" 2>/dev/null || true)"
if ! printf '%s' "$ENTITLEMENTS" | grep -q 'com.apple.security.files.user-selected.read-write'; then
  echo "错误：构建出的应用缺少 com.apple.security.files.user-selected.read-write" >&2
  echo "      检查 jarvis-app/macos/Runner/Release.entitlements 后重新打包。" >&2
  exit 1
fi
# 录音要直接采集麦克风：沙箱里缺这个 entitlement 时系统会静默拒绝，
# 界面上只表现成"点了没反应"，比打包失败难查得多。
if ! printf '%s' "$ENTITLEMENTS" | grep -q 'com.apple.security.device.audio-input'; then
  echo "错误：构建出的应用缺少 com.apple.security.device.audio-input" >&2
  echo "      检查 jarvis-app/macos/Runner/Release.entitlements 后重新打包。" >&2
  exit 1
fi
echo "权限声明齐备（files.user-selected.read-write、device.audio-input）"

echo "== 组装安装根 =="
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/usr/local/bin" "$PKGROOT/Applications"
install -m 0755 target/release/jarvis-service "$PKGROOT/usr/local/bin/jarvis-service"
install -m 0755 target/release/jarvis-worker "$PKGROOT/usr/local/bin/jarvis-worker"
cp -R "jarvis-app/build/macos/Build/Products/Release/${APP_NAME}" "$PKGROOT/Applications/${APP_NAME}"

echo "== 生成 pkg =="
mkdir -p "$DIST"
rm -f "$PKG"
# 关掉 bundle relocation：Installer 默认拿 CFBundleIdentifier 去 LaunchServices
# 问"这台机器上是否已有同 ID 的 app"，有就把 payload 里的 app 装到那个旧位置去。
# 开发机上只要跑过一次 Debug 构建，正式包就会被"装进" build/ 目录，
# /Applications 里永远看不到——日志里表现为 "will be atomically shoved"。
# 显式把 BundleIsRelocatable 设为 false，装到哪就是哪。
COMPONENT_PLIST="$DIST/component.plist"
pkgbuild --analyze --root "$PKGROOT" "$COMPONENT_PLIST" >/dev/null
python3 - "$COMPONENT_PLIST" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    components = plistlib.load(handle)
for component in components:
    if "BundleIsRelocatable" in component:
        component["BundleIsRelocatable"] = False
with open(path, "wb") as handle:
    plistlib.dump(components, handle)
PY
pkgbuild \
  --root "$PKGROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier "com.personalagent.desktop" \
  --version "$VERSION" \
  --install-location "/" \
  "$PKG" >/dev/null

shasum -a 256 "$PKG" > "${PKG}.sha256"

echo
echo "安装包：$PKG"
echo "大小：$(du -h "$PKG" | cut -f1)"
echo "校验：$(cat "${PKG}.sha256")"
echo
echo "安装后："
echo "  sudo installer -pkg \"$PKG\" -target /"
echo "  /usr/local/bin/jarvis-service install          # 注册自启：普通用户执行，不要 sudo"
echo "  open /Applications/${APP_NAME}"
echo
echo "注意：只装启动卷（-target /）。装到外置卷时二进制会落在 /Volumes/<卷>/usr/local/bin，"
echo "      那个路径不在 PATH 里，launchd 与 Launchpad 也不会认，服务起不来。"
