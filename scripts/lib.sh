#!/usr/bin/env bash
# 共享配置与工具函数。所有脚本 source 本文件。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$REPO/build"
UNPACK="$WORK/unpack"
ELECTRON_CACHE="$WORK/electron"
APPDIR="$WORK/app"
STATE="$REPO/state"
MANIFEST="$STATE/manifest.json"

C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

need() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"; done
}

# 从 manifest.json 读字段（无 jq 依赖）
manifest_get() {
  [ -f "$MANIFEST" ] || return 1
  python3 -c "
import json,sys
d=json.load(open('$MANIFEST'))
for k in sys.argv[1].split('.'):
    if not isinstance(d,dict) or k not in d: sys.exit(1)
    d=d[k]
print(d if not isinstance(d,bool) else str(d).lower())
" "$1" 2>/dev/null
}

manifest_set() { # manifest_set <点分路径> <值>
  python3 - "$MANIFEST" "$1" "$2" <<'PY'
import json,sys
path,val,src=sys.argv[2],sys.argv[3],sys.argv[1]
try: d=json.load(open(src))
except Exception: d={}
cur=d
keys=path.split('.')
for k in keys[:-1]: cur=cur.setdefault(k,{})
try: v=json.loads(val)
except Exception: v=val
cur[keys[-1]]=v
json.dump(d,open(src,'w'),ensure_ascii=False,indent=2)
PY
}

sha256() { sha256sum "$1" | cut -d' ' -f1; }

# 精确停止某个可执行文件启动的全部进程。
#
# 不要用 `pkill -f "<路径>"`：调用方的命令行里往往也含这个路径，
# pkill 会把脚本自己一起杀掉（本仓库踩过这个坑）。
# 这里改为：按进程名找候选 -> 再用 /proc/<pid>/exe 核实真实路径。
stop_app() {
  local bin="${1:?stop_app 需要可执行文件路径}"
  local real target base
  real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
  base="$(basename "$bin")"
  local pids
  pids="$(pgrep -x "$base" 2>/dev/null || true)"
  local pid exe
  for pid in $pids; do
    [ "$pid" = "$$" ] && continue
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    if [ "$exe" = "$real" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  # 给 Electron 一点时间收尾
  sleep 1
  for pid in $(pgrep -x "$base" 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [ "$exe" = "$real" ] && kill -9 "$pid" 2>/dev/null || true
  done
  return 0
}

