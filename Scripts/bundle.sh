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

# 提示里的构建命令必须按 CONFIG 分叉写死。
# 不能用 ${CONFIG/release/-c release} 这种字符串替换去拼：CONFIG=debug 时替换不命中，
# 会打印出 "swift build debug"，而这条命令实测直接报错（error: Unexpected argument 'debug'）。
# 另外本机没有 Xcode，默认构建引擎会全量重编依赖并失败，所以提示里必须点名 --build-system native，
# 否则照着提示跑照样起不来。
case "$CONFIG" in
  debug)   BUILD_CMD="swift build --build-system native" ;;
  release) BUILD_CMD="swift build --build-system native -c release" ;;
  *)       BUILD_CMD="swift build --build-system native -c $CONFIG" ;;
esac

if [[ ! -x "$EXEC_PATH" ]]; then
  echo "找不到可执行文件：$EXEC_PATH" >&2
  echo "先跑：$BUILD_CMD" >&2
  exit 1
fi

# 打包来源必须在拷贝前摊开，否则存在「静默打包另一棵树」的风险：
# .build/<config> 是个符号链接，指向哪棵树取决于「最后一次跑的是哪个构建引擎」——
# 默认引擎指向 .build/out/Products/<Config>（可能是很久以前的产物），
# native 引擎指向 arm64-apple-macosx/<config>。链接一旦停在默认引擎那一侧，
# 本脚本仍会照常退出 0 并打印完成，但打进 app 的是陈旧二进制。
EXEC_DIR_REAL="$(cd "$(dirname "$EXEC_PATH")" && pwd -P)"
EXEC_REAL="$EXEC_DIR_REAL/$(basename "$EXEC_PATH")"
MARKER_FILE="$ROOT/.build/.buildSystem_$CONFIG"
MARKER="$(cat "$MARKER_FILE" 2>/dev/null || echo '（该标记不存在）')"
EXEC_SHA="$(shasum -a 256 "$EXEC_REAL" | awk '{print $1}')"

echo "==> 打包来源"
echo "    符号链接：$EXEC_PATH"
echo "    真实路径：$EXEC_REAL"
echo "    引擎标记：$MARKER_FILE = $MARKER"
echo "    sha256：$EXEC_SHA"
echo "    大小/时间：$(stat -f '%z 字节  %Sm' -t '%Y-%m-%d %H:%M:%S' "$EXEC_REAL")"
if [[ "$MARKER" != "native" ]]; then
  echo "    警告：引擎标记不是 native，上面这份多半来自另一棵树（.build/out/Products/），可能是陈旧产物" >&2
fi

# 这里只做「让来源可见」，刻意不做基于 mtime 的新鲜度校验：
# 实测这套构建系统按内容哈希判定，源文件 mtime 晚于二进制 40 秒仍算「当前」，用 mtime 会误报。

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
