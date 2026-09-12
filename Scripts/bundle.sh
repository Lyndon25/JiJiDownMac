#!/usr/bin/env bash
#
# 手工组装 .app bundle。
#
# 为什么需要这个：本机没有 Xcode，因此没有 xcodebuild / actool。
# SPM 只能产出裸可执行文件，而 SwiftUI 应用需要真正的 bundle 才能
# 正常获得菜单栏、Dock 图标和窗口行为。
#
# 用法：
#   ./Scripts/bundle.sh            # debug 构建
#   ./Scripts/bundle.sh release    # release 构建
#
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="JiJiDown"
EXEC_NAME="JiJiDown"
BUNDLE_ID="cc.sabe.jijidown.mac.client"
VERSION="0.1.0"

EXEC_PATH="$ROOT/.build/$CONFIG/$EXEC_NAME"
APP_DIR="$ROOT/dist/$APP_NAME.app"

if [[ ! -x "$EXEC_PATH" ]]; then
  echo "找不到可执行文件：$EXEC_PATH" >&2
  echo "先跑：swift build ${CONFIG/release/-c release}" >&2
  exit 1
fi

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/$EXEC_NAME"

# 核心二进制随包分发，这样用户双击即用，不必自己下载。
# 运行时由 CoreManager 校验 sha256 后复制到 ~/.config/JiJiDown/ 再启动。
if [[ -f "$ROOT/Vendor/JiJiDownCore-darwin-arm64" ]]; then
  cp "$ROOT/Vendor/JiJiDownCore-darwin-arm64" "$APP_DIR/Contents/Resources/JiJiDownCore"
  cp "$ROOT/Vendor/JiJiDownCore-hash.txt" "$APP_DIR/Contents/Resources/JiJiDownCore-hash.txt"
  echo "    已内嵌核心二进制"
else
  echo "    警告：Vendor/ 下没有核心二进制，App 将只能连接外部已运行的核心"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>唧唧</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- 只连本机回环，不需要任何 ATS 例外；ATS 本身也不管 gRPC 的 BSD socket -->
</dict>
</plist>
PLIST

# 临时签名。自用足够；要分发给别人得用开发者证书 + 公证，那是另一回事。
echo "==> 临时签名"
codesign --force --sign - --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/    /'

echo "==> 完成：$APP_DIR"
echo "    打开：open \"$APP_DIR\""
