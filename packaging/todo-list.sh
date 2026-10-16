#!/usr/bin/env bash
# Todo清单 Linux 启动器
#
# 终端里运行  -> 前台直通，报错直接可见
# 桌面菜单启动 -> 记录 Chromium 级 + 应用级全部输出；失败时按序自动降级重试
#
# 诊断日志： ${XDG_CONFIG_HOME:-$HOME/.config}/todo-list/launch.log

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/todo-list"
LOG="${XDG_CONFIG_HOME:-$HOME/.config}/todo-list/launch.log"
mkdir -p "$(dirname "$LOG")"

# 让 Chromium 也把日志写到 stderr —— 即使应用代码还没跑到就崩，也能看到原因
export ELECTRON_ENABLE_LOGGING=1
export ELECTRON_ENABLE_STACK_DUMPING=1

# ---------- 终端模式：直通 ----------
if [ -t 1 ]; then
  exec "$BIN" "$@"
fi

# ---------- 桌面模式 ----------
[ -s "$LOG" ] && mv -f "$LOG" "$LOG.prev"
: > "$LOG"
{
  echo "===== $(date '+%F %T') 桌面启动 ====="
  echo "DISPLAY=$DISPLAY   WAYLAND_DISPLAY=$WAYLAND_DISPLAY   XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
  echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR   XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
  echo "X11 socket 文件 : $(ls /tmp/.X11-unix/ 2>&1 | tr '\n' ' ')"
  echo "wayland socket  : $(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-* 2>&1 | tr '\n' ' ')"
  echo "userns 开关     : $(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo '(无)')"
  echo "apparmor userns : $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo '(无)')"
  echo "chrome-sandbox  : $(stat -c '%U:%G %a' "$DIR/chrome-sandbox" 2>/dev/null)"
  echo "GPU 设备        : $(ls /dev/dri/ 2>&1 | tr '\n' ' ')"
} >> "$LOG" 2>&1

is_single_instance_exit() { grep -qa "单实例保护生效" "$LOG" 2>/dev/null; }

try_variant() {
  local desc="$1"; shift
  { echo; echo "########## 尝试: ${desc} ##########"; echo "参数: $*"; } >> "$LOG" 2>&1

  "$BIN" "$@" >> "$LOG" 2>&1 &
  local pid=$!
  sleep 6

  if kill -0 "$pid" 2>/dev/null; then
    echo "########## 成功：存活(pid $pid)，进入正常运行 ##########" >> "$LOG" 2>&1
    wait "$pid"; exit 0
  fi
  wait "$pid" 2>/dev/null
  local rc=$?

  if is_single_instance_exit; then
    echo "########## 已有实例在运行，本次退出（非崩溃） ##########" >> "$LOG" 2>&1
    exit 0
  fi
  echo "########## 失败：${desc} 6 秒内退出，退出码 $rc ##########" >> "$LOG" 2>&1
  return 1
}

# 顺序：默认 -> X11(实测 GPU 更稳，且能恢复窗口定位/置顶) -> 关 GPU -> 关沙箱 -> 组合兜底
try_variant "默认"                                    && exit 0
try_variant "X11/XWayland"            --ozone-platform=x11                          && exit 0
try_variant "关闭 GPU 加速"           --disable-gpu                                 && exit 0
try_variant "关闭沙箱"                --no-sandbox                                  && exit 0
try_variant "X11 + 关 GPU"            --ozone-platform=x11 --disable-gpu            && exit 0
try_variant "X11 + 关 GPU + 关沙箱"   --ozone-platform=x11 --disable-gpu --no-sandbox && exit 0
try_variant "Wayland + 关 GPU + 关沙箱" --ozone-platform=wayland --disable-gpu --no-sandbox && exit 0

{ echo; echo "########## 所有启动变体均失败 ##########"; echo "把这个文件交给排查者：$LOG"; } >> "$LOG" 2>&1
exit 1
