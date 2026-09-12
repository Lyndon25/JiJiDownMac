#!/usr/bin/env bash
#
# 核心二进制冒烟测试：校验 → 安装 → 起进程 → 确认真的在监听 → 收掉。
#
# 用来在没有 App 的情况下确认「这个二进制在这台机器上跑得起来」，
# 比如换架构、换核心版本之后先验一下。
#
# ## 为什么这个脚本一定要备份配置
#
# 核心**不按当前工作目录找 config.yaml**，它认死了一个固定路径
# `~/.config/JiJiDown/config.yaml`（实测：cwd 换到别处，它照样去读 home 下那份）。
# 所以想控制它跑在哪个端口，就只能改那个文件 —— 没别的办法。
#
# 而那个文件里存着用户登录后的 access-token 和 cookies。一脚踩空就是
# 「跑一次冒烟测试把人踢下线」。所以这里开跑前先原样备份，跑完无条件还原
# （trap EXIT，中途报错也还原）。
#
# 用法：
#   ./Scripts/smoke-core.sh
#   JJD_PORT=4100 ./Scripts/smoke-core.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
RUNDIR="$ROOT/.run/smoke"
PORT="${JJD_PORT:-4100}"
DL_DIR="${JJD_DOWNLOAD_DIR:-$HOME/Downloads/JiJiDown}"

CFG_DIR="$HOME/.config/JiJiDown"
CFG="$CFG_DIR/config.yaml"
BACKUP="$RUNDIR/config.yaml.orig"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  TARGET=darwin-arm64 ;;
  Darwin-x86_64) TARGET=darwin-amd64 ;;
  Linux-aarch64) TARGET=linux-arm64 ;;
  Linux-x86_64)  TARGET=linux-amd64 ;;
  *) echo "不认识的目标平台：$(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

SRC="$VENDOR/JiJiDownCore-$TARGET"
HASHES="$VENDOR/JiJiDownCore-hash.txt"
BIN="$RUNDIR/JiJiDownCore"
LOG="$RUNDIR/core.log"

if [[ ! -f "$SRC" ]]; then
  echo "找不到 $SRC" >&2
  echo "先跑：./Scripts/fetch-core.sh" >&2
  exit 1
fi

# App 正跑着的时候别动 —— 它托管着同一个核心和同一份配置，抢起来两边都不好看。
if lsof -nP -iTCP:4000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "有个核心正跑在 4000 上（可能是 App 托管的）。" >&2
  echo "先退出 App，或者：JJD_PORT=4100 $0" >&2
  exit 1
fi

mkdir -p "$RUNDIR" "$CFG_DIR" "$DL_DIR"

CORE_PID=""
restore_config() {
  kill "$CORE_PID" 2>/dev/null || true
  if [[ -f "$BACKUP" ]]; then
    cp "$BACKUP" "$CFG"
    rm -f "$BACKUP"
    echo "==> 原配置已还原（登录凭据没丢）"
  else
    rm -f "$CFG"
    echo "==> 本来就没有配置，已清掉测试写的那份"
  fi
}
trap restore_config EXIT

# ── 1. 校验 sha256 并备份配置 ────────────────────────────────────
echo "==> [1/4] 校验 sha256"
if [[ ! -f "$HASHES" ]]; then
  echo "    没有 ${HASHES}，跳过校验（建议先跑 fetch-core.sh）" >&2
else
  # 清单是 CRLF 换行，格式 SHA256|version|filename。
  EXPECT="$(tr -d '\r' < "$HASHES" | awk -F'|' -v f="JiJiDownCore-$TARGET" '$3 == f { print $1; exit }')"
  ACTUAL="$(shasum -a 256 "$SRC" | awk '{print $1}')"
  if [[ -z "$EXPECT" ]]; then
    echo "    清单里没有 JiJiDownCore-$TARGET" >&2; exit 1
  fi
  if [[ "$EXPECT" != "$ACTUAL" ]]; then
    echo "    ✗ 校验失败" >&2
    echo "      期望 $EXPECT" >&2
    echo "      实际 $ACTUAL" >&2
    exit 1
  fi
  echo "    ✓ 校验通过（${EXPECT:0:16}…）"
fi

if [[ -f "$CFG" ]]; then
  cp "$CFG" "$BACKUP"
  echo "    已备份现有配置 → 测试结束会还原"
fi

# ── 2. 安装 ──────────────────────────────────────────────────────
echo "==> [2/4] 安装到 $RUNDIR"
install -m 0755 "$SRC" "$BIN"
echo "    ✓ 架构：$(file -b "$BIN" | cut -c1-60)"

# ── 3. 写配置并启动 ──────────────────────────────────────────────
echo "==> [3/4] 启动（端口 ${PORT}）"
# 核心对缺失字段**不做兜底**：例如 session-workers 缺省会取 0，而它要求 1-3，
# 结果是启动时直接 FATA 退出。所以每个字段都要写全，空串要显式写成 ""。
# grpc-web / restful 设 0 关掉 —— 冒烟测试不需要它们，少开一个端口少一分暴露。
cat > "$CFG" <<YAML
log-level: info
external-controller-port:
    grpc: $PORT
    grpc-web: 0
    restful-api: 0
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
    max-task: 1
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

: > "$LOG"
"$BIN" >"$LOG" 2>&1 &
CORE_PID=$!
echo "    pid=${CORE_PID}，日志 $LOG"

LISTENING=0
for i in $(seq 1 30); do
  if ! kill -0 "$CORE_PID" 2>/dev/null; then
    echo "    ✗ 进程已退出，日志：" >&2
    sed 's/^/      /' "$LOG" >&2
    exit 1
  fi
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    LISTENING=1
    echo "    ✓ $PORT 已监听（等了 ${i} 秒）"
    break
  fi
  sleep 1
done

if [[ "$LISTENING" != "1" ]]; then
  echo "    ✗ 30 秒内没监听 ${PORT}，日志：" >&2
  sed 's/^/      /' "$LOG" >&2
  exit 1
fi

sed 's/^/      /' "$LOG" | head -12

# ── 4. 收尾 ──────────────────────────────────────────────────────
echo "==> [4/4] 停止核心"
kill "$CORE_PID" 2>/dev/null || true
wait "$CORE_PID" 2>/dev/null || true
CORE_PID=""
