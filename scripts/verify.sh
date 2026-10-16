#!/usr/bin/env bash
# 冒烟测试：启动应用，静置若干秒，检查启动里程碑是否全部达成。
# 不需要人看界面；应用自己的日志会说明它走到了哪一步。
#
# 用法: verify.sh [要测试的可执行文件] [等待秒数]
# 默认测试 ~/.local/opt/todo-list/todo-list

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="${1:-$HOME/.local/opt/todo-list/todo-list}"
WAIT="${2:-25}"
LOG="$WORK/verify.log"

[ -x "$BIN" ] || die "找不到可执行文件: $BIN"

mkdir -p "$WORK"
# 注意：用 stop_app 而不是 pkill -f —— 本脚本的 argv 里就含 $BIN，
# pkill -f 会把脚本自己杀掉。
stop_app "$BIN"

info "启动 $BIN（静置 ${WAIT}s）"
: > "$LOG"
# 注意：lib.sh 开着 set -e，而 timeout 超时返回 124 是非零，
# 直接写会让脚本当场退出。必须用 || rc=$? 接住。
rc=0
timeout "$WAIT" "$BIN" > "$LOG" 2>&1 || rc=$?
if [ "$rc" = 124 ]; then
  dim "  进程存活到超时被终止 —— 正常，说明没有启动即崩溃"
else
  warn "  进程提前退出，退出码 $rc"
fi

# 若因单实例锁退出，说明已有实例在跑，不算失败
if grep -qa "单实例保护生效" "$LOG"; then
  warn "已有实例在运行，本次未做验证。请先 pkill -f todo-list"
  exit 0
fi

echo
info "启动里程碑："
fail=0
check() { # check <说明> <正则>
  if grep -qaE "$2" "$LOG"; then
    printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$1"
  else
    printf '  %s✗%s %s\n' "$C_ERR" "$C_OFF" "$1"; fail=$((fail+1))
  fi
}
check "主进程启动"           "App starting"
check "单实例锁获取成功"     "成功获得单实例锁"
check "app:// 协议注册"      "注册 app:// 协议处理器"
check "数据库初始化"         "TodoDB. 数据库初始化完成"
check "渲染进程加载完成"     "主窗口 did-finish-load"
check "主窗口已显示"         "主窗口已显示"

echo
if grep -qa "非 Windows 平台，跳过 showdesktop.node" "$LOG"; then
  printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "Windows 专有模块正确跳过"
else
  printf '  %s·%s %s\n' "$C_WARN" "$C_OFF" "未看到 showdesktop 跳过日志（版本差异，不一定是问题）"
fi

echo
if grep -qa "主窗口关闭行为" "$LOG"; then :; fi
# 标题栏补丁是否生效：看渲染进程有无报错，以及能否在截图工具下看到按钮
if command -v xdotool >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
  dim "提示：可用 packaging/../scripts 里的截图流程人工确认标题栏按钮"
fi

echo
if [ "$fail" = 0 ]; then
  info "全部里程碑通过 ✓  完整日志: $LOG"
  exit 0
else
  warn "$fail 项未通过。完整日志: $LOG"
  grep -aE "ERROR|Error|错误|失败|无法|Cannot|Uncaught" "$LOG" | head -10
  exit 1
fi
