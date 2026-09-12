#!/usr/bin/env bash
#
# 核心二进制冒烟测试：校验 → 配置 → 启动 → 确认监听 4000 → 收尾。
#
# 在写任何 Swift 代码之前先跑这个，确认 JiJiDownCore 在本机真的能起来。
# 这一步排除了 Gatekeeper、架构不匹配、配置格式错误等一整类问题。
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Vendor/JiJiDownCore-darwin-arm64"
HASHES="$ROOT/Vendor/JiJiDownCore-hash.txt"
CFG_DIR="$HOME/.config/JiJiDown"
CFG="$CFG_DIR/config.yaml"
RUNDIR="$ROOT/.run"
LOG="$RUNDIR/core.log"
DL_DIR="${JJD_DOWNLOAD_DIR:-$HOME/Downloads/JiJiDown}"

mkdir -p "$RUNDIR" "$CFG_DIR" "$DL_DIR"

# ── 1. 校验 sha256 ────────────────────────────────────────────────
echo "==> [1/5] 校验 sha256"
# 注意：官方 hash 文件是 CRLF 换行，必须先去掉 \r，否则行尾锚点匹配不上、取到空值。
EXPECTED="$(tr -d '\r' < "$HASHES" | grep 'JiJiDownCore-darwin-arm64$' | cut -d'|' -f1)"
ACTUAL="$(shasum -a 256 "$SRC" | cut -d' ' -f1)"
echo "    期望 $EXPECTED"
echo "    实际 $ACTUAL"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "    ✗ 校验失败，二进制可能损坏或被篡改，中止" >&2
  exit 1
fi
echo "    ✓ 校验通过"

# ── 2. 架构与可执行权限 ───────────────────────────────────────────
echo "==> [2/5] 架构检查"
file "$SRC" | sed 's/^/    /'
install -m 0755 "$SRC" "$CFG_DIR/JiJiDownCore"
echo "    ✓ 已安装到 $CFG_DIR/JiJiDownCore"

# ── 3. 写最小配置 ─────────────────────────────────────────────────
echo "==> [3/5] 写配置 $CFG"
# grpc-web 设 0 关掉 —— 我们不需要浏览器端，少开一个端口少一分暴露。
# 三个端口都无鉴权，绝不能监听 0.0.0.0。
# 必须写全字段：核心对缺失字段不做兜底，例如 session-workers 缺省会取 0
# 而它要求 1-3，直接 FATA 退出。空字符串要显式写成 ""，否则 YAML 解析成 null。
cat > "$CFG" <<YAML
log-level: info
external-controller-port:
    grpc: 4000
    grpc-web: 0
    restful-api: 64001
user-info:
    access-token: ""
    refresh-token: ""
    cookies: ""
    raw-access-token: ""
    raw-cookies: ""
    hide-nickname: false
download-task:
    temp-dir: ""
    download-dir: "$DL_DIR"
    ffmpeg-path: ""
    max-task: 2
    download-speed-limit: 0
    disable-mcdn: false
jdm:
    max-retry: 5
    retry-wait: 10
    session-workers: 1
    part-workers: 5
    min-split-size: 30
    proxy-addr: ""
    check-best-mirror: true
    cache-in-ram: false
    cache-in-ram-limit: 500
    insecure-skip-verify: false
    custom-root-certificates: ""
YAML
sed 's/^/    | /' "$CFG"

# ── 4. 启动并等待监听 ─────────────────────────────────────────────
echo "==> [4/5] 启动核心"
: > "$LOG"
"$CFG_DIR/JiJiDownCore" >"$LOG" 2>&1 &
CORE_PID=$!
echo "    pid=${CORE_PID}, 日志 $LOG"

LISTENING=0
for i in $(seq 1 30); do
  if ! kill -0 "$CORE_PID" 2>/dev/null; then
    echo "    ✗ 进程已退出，日志：" >&2
    sed 's/^/      /' "$LOG" >&2
    exit 1
  fi
  if lsof -nP -iTCP:4000 -sTCP:LISTEN >/dev/null 2>&1; then
    LISTENING=1
    echo "    ✓ 4000 端口已监听（等了 ${i} 秒）"
    break
  fi
  sleep 1
done

if [[ "$LISTENING" != "1" ]]; then
  echo "    ✗ 30 秒内没监听 4000，日志：" >&2
  sed 's/^/      /' "$LOG" >&2
  kill "$CORE_PID" 2>/dev/null
  exit 1
fi

echo "    监听详情："
lsof -nP -iTCP:4000 -sTCP:LISTEN | sed 's/^/      /'
echo "    启动日志："
sed 's/^/      /' "$LOG" | head -20

# ── 5. 收尾 ──────────────────────────────────────────────────────
echo "==> [5/5] 停止核心"
kill "$CORE_PID" 2>/dev/null
wait "$CORE_PID" 2>/dev/null
echo "    ✓ 冒烟测试通过"
