#!/usr/bin/env bash
#
# 从唧唧官方发布地址获取 JiJiDownCore，并按官方 SHA-256 清单校验。
#
# 为什么要有这一步：JiJiDownCore 是唧唧官方的闭源预编译二进制，版权归其作者，
# 本仓库不随源码分发它。想要构建出可直接运行的 App，就得自己拉一次。
#
# 用法：
#   ./Scripts/fetch-core.sh              # 按当前机器自动选目标
#   ./Scripts/fetch-core.sh darwin-arm64 # 显式指定
#
# 产物落在 Vendor/，bundle.sh 会把它内嵌进 .app。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"

# 唧唧官方的核心发布目录。域名是 IDN，punycode 形式最稳。
BASE="https://jj.xn--5nx14y.top/PC/ReWPF/core"

# 国内直连通常可达；如需代理，自行导出 HTTPS_PROXY 即可。
CURL=(curl -fL --retry 3 --retry-delay 2 --connect-timeout 20)

# ── 选目标 ────────────────────────────────────────────────

if [[ $# -ge 1 ]]; then
  TARGET="$1"
else
  case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    *) echo "不支持的系统：$(uname -s)，请显式传目标名。" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *) echo "不支持的架构：$(uname -m)，请显式传目标名。" >&2; exit 1 ;;
  esac
  TARGET="$OS-$ARCH"
fi

FILE="JiJiDownCore-$TARGET"
mkdir -p "$VENDOR"

echo "==> 目标：$TARGET"

# ── 取官方校验清单 ────────────────────────────────────────

echo "==> 下载校验清单"
"${CURL[@]}" -o "$VENDOR/JiJiDownCore-hash.txt" "$BASE/JiJiDownCore-hash.txt"

# 清单每行：<sha256>|<版本>|<文件名>
EXPECT="$(
  tr -d '\r' < "$VENDOR/JiJiDownCore-hash.txt" \
    | awk -F'|' -v f="$FILE" '$3 == f { print $1; exit }'
)"

if [[ -z "$EXPECT" ]]; then
  echo "清单里没有 $FILE —— 官方可能已改名，看看清单：" >&2
  cat "$VENDOR/JiJiDownCore-hash.txt" >&2
  exit 1
fi

VERSION="$(
  tr -d '\r' < "$VENDOR/JiJiDownCore-hash.txt" \
    | awk -F'|' -v f="$FILE" '$3 == f { print $2; exit }'
)"
echo "    版本 $VERSION"
echo "    期望 sha256 $EXPECT"

# ── 取二进制并校验 ────────────────────────────────────────

echo "==> 下载 $FILE"
"${CURL[@]}" -o "$VENDOR/$FILE" "$BASE/$FILE"

ACTUAL="$(shasum -a 256 "$VENDOR/$FILE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECT" ]]; then
  echo "❌ 校验失败 —— 下载到的东西和官方清单对不上。" >&2
  echo "   期望 $EXPECT" >&2
  echo "   实际 $ACTUAL" >&2
  rm -f "$VENDOR/$FILE"
  exit 1
fi

chmod +x "$VENDOR/$FILE"
echo "==> ✅ 完成：Vendor/$FILE（sha256 已核对）"
echo
echo "下一步："
echo "    swift build && ./Scripts/bundle.sh"
