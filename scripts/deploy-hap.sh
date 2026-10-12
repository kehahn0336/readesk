#!/usr/bin/env bash
# 构建 → 校验 → 装机 →（可选）启动。
#
# 为什么不直接写两行命令：旧工程踩过"构建其实失败了，却装了上一次的旧 HAP，还打印成功"
# —— 于是你改了半小时代码，设备上跑的还是旧的。这里把校验做成硬门槛。
#
# 用法: scripts/deploy-hap.sh [--no-install] [--no-start]
set -u

PROJ="$(cd "$(dirname "$0")/.." && pwd)"

# 本机私有设置（目标设备、SDK 路径…）放 .env.local —— 已被 .gitignore 忽略，不入库。
# 可从 .env.local.example 复制一份再改。
[ -f "$PROJ/.env.local" ] && . "$PROJ/.env.local"

# DevEco 工具链路径：优先环境变量/本机设置，其次按常见安装位置推导
HDC="${HDC:-${DEVECO_SDK_HOME:-$HOME/deveco_tools/sdk}/default/openharmony/toolchains/hdc}"

# ── 目标设备 ────────────────────────────────────────────────────────────────
# 2026-10-11 踩过：同时连着 MateBook Pro(TCP) 与 MatePad Mini(USB) 时，
# `hdc install` 默认目标会落到**其中一台**，结果装到了平板、而用户在看本机。
# 所以支持显式指定目标，并把设备型号回显出来 —— 装错设备必须一眼可见。
#   DEPLOY_TARGET=<serial 或 ip:port> bash scripts/deploy-hap.sh
# 留空则由 hdc 自行选择（只连一台设备时够用）。
DEPLOY_TARGET="${DEPLOY_TARGET:-}"
if [ -n "$DEPLOY_TARGET" ]; then HT=(-t "$DEPLOY_TARGET"); else HT=(); fi
RUNNER="${RUNNER:-$HOME/.workbuddy/tools/deveco-run.js}"
export HDC_SERVER_PORT="${HDC_SERVER_PORT:-8710}"

DO_INSTALL=1
DO_START=1
for arg in "$@"; do
  case "$arg" in
    --no-install) DO_INSTALL=0 ;;
    --no-start) DO_START=0 ;;
  esac
done

cd "$PROJ" || exit 1
# notes/ 只放本机构建日志与验收证据（不入库）—— 公开仓库里没有这个目录，这里兜底建出来，
# 免得 `> "$LOG"` 因为目录不存在而失败。
mkdir -p "$PROJ/notes"
LOG="$PROJ/notes/hap-build.log"
HAP="$PROJ/entry/build/default/outputs/default/entry-default-signed.hap"

# 前端产物必须比源码新：否则会把**旧的 webapp** 打进包里
# （2026-10-03 就发生过一次：前端构建失败，deploy 仍带着旧 webapp 装机成功）。
# 判据：比较"rawfile/webapp 最新文件"与"repo 的 src/public 最新文件"的时间戳。
WEBAPP_DIR="$PROJ/entry/src/main/resources/rawfile/webapp"
APP_SRC="$PROJ/../repo/apps/readest-app/src"
APP_PUBLIC="$PROJ/../repo/apps/readest-app/public"
if [ -d "$WEBAPP_DIR" ] && [ -d "$APP_SRC" ]; then
  NEWEST_WEBAPP=$(find "$WEBAPP_DIR" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  NEWEST_SRC=$(find "$APP_SRC" "$APP_PUBLIC" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  if [ -n "$NEWEST_WEBAPP" ] && [ -n "$NEWEST_SRC" ] && \
     awk "BEGIN{exit !($NEWEST_SRC > $NEWEST_WEBAPP)}"; then
    echo "✗ webapp 比源码旧 —— 先跑：node scripts/run-frontend-build.mjs && node scripts/prepare-webapp.mjs"
    exit 1
  fi
fi

MODEL=$($HDC "${HT[@]}" shell "param get const.product.model" 2>/dev/null | tr -d '\r')
NAME=$($HDC "${HT[@]}" shell "param get const.product.name" 2>/dev/null | tr -d '\r')
echo "[0/4] 目标设备: $DEPLOY_TARGET  →  ${MODEL:-?} ${NAME:-?}"
echo "[1/4] 构建…"
echo "[1/4] 桥单一来源校验…"
# 页面实际加载的是 rawfile/webapp/readest-bridge.js（由 prepare-webapp 注入），
# 不是 rawfile/readest-bridge.js。旧工程就栽在"只改了前者、页面加载后者"，
# 表现是 unsupported bridge command / 行为像没改。这里做成硬门槛：
# 两份不一致就自动重新注入，注入后仍不一致直接拒绝构建。
SHIM="$PROJ/entry/src/main/resources/rawfile/readest-bridge.js"
SHIM_WEB="$PROJ/entry/src/main/resources/rawfile/webapp/readest-bridge.js"
if [ -f "$SHIM_WEB" ]; then
  SHIM_A=$(sha256sum "$SHIM" | cut -d' ' -f1)
  SHIM_B=$(sha256sum "$SHIM_WEB" | cut -d' ' -f1)
  if [ "$SHIM_A" != "$SHIM_B" ]; then
    echo "  桥有改动，重新注入 webapp…"
    node "$PROJ/scripts/prepare-webapp.mjs" >/dev/null 2>&1 || { echo "✗ prepare-webapp 失败"; exit 1; }
    SHIM_B=$(sha256sum "$SHIM_WEB" | cut -d' ' -f1)
    if [ "$SHIM_A" != "$SHIM_B" ]; then echo "✗ 注入后两份 shim 仍不一致，拒绝构建"; exit 1; fi
  fi
  echo "  ✓ 一致 (${SHIM_A:0:12})"
else
  echo "  ! webapp 里没有 shim，先跑 prepare-webapp"
  node "$PROJ/scripts/prepare-webapp.mjs" >/dev/null 2>&1 || { echo "✗ prepare-webapp 失败"; exit 1; }
fi

MODEL=$($HDC "${HT[@]}" shell "param get const.product.model" 2>/dev/null | tr -d '\r')
NAME=$($HDC "${HT[@]}" shell "param get const.product.name" 2>/dev/null | tr -d '\r')
echo "[0/4] 目标设备: $DEPLOY_TARGET  →  ${MODEL:-?} ${NAME:-?}"
echo "[1/4] 构建…"
node "$RUNNER" "$PROJ" build --product default --build-mode debug > "$LOG" 2>&1
BUILD_EXIT=$?

CLEAN_LOG=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG")
if [ "$BUILD_EXIT" -ne 0 ] || echo "$CLEAN_LOG" | grep -q "Error Message:" \
   || ! echo "$CLEAN_LOG" | grep -q "BUILD SUCCESSFUL"; then
  echo "✗ 构建失败 —— 拒绝装机（否则会装到旧包）"
  echo "$CLEAN_LOG" | grep -E "Error Message:|ERROR:|BUILD FAILED" | head -20
  exit 1
fi
echo "✓ 构建成功，无 Error Message"

if [ ! -f "$HAP" ]; then
  echo "✗ 找不到 $HAP"; exit 1
fi
echo "[2/4] 产物: $(ls -la "$HAP" | awk '{print $5}') 字节, $(date -r "$HAP" '+%H:%M:%S')"

if [ "$DO_INSTALL" -eq 0 ]; then echo "[3/4] 跳过装机"; exit 0; fi
echo "[3/4] 装机…"
OUT=$($HDC "${HT[@]}" install -r "$HAP" 2>&1)
# 成功信息不一定在最后一行（后面还会打印 "AppMod finish"），必须全文匹配。
echo "$OUT" | grep -E "successfully|error|Error" | tail -2
if ! echo "$OUT" | grep -q "install bundle successfully"; then echo "✗ 装机失败"; exit 1; fi

if [ "$DO_START" -eq 0 ]; then echo "[4/4] 跳过启动"; exit 0; fi
echo "[4/4] 启动…"
# 必须先 force-stop：应用已在运行时 `aa start` 只是切到前台，页面不会重新加载，
# 于是你看不到任何新日志，误以为"改的代码没生效"。
$HDC "${HT[@]}" shell aa force-stop com.kehahn.readest >/dev/null 2>&1
sleep 2
$HDC "${HT[@]}" shell aa start -a EntryAbility -b com.kehahn.readest 2>&1 | head -1
