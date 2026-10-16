#!/usr/bin/env bash
# 把组装好的 Linux 应用安装到用户目录（无需 sudo）。
#
# 用法: install-user.sh [应用目录]     默认 build/app
#
# 安装位置：
#   ~/.local/opt/todo-list/                                  应用本体
#   ~/.local/share/applications/todo-list.desktop            桌面项
#   ~/.local/share/icons/hicolor/256x256/apps/todo-list.png  图标
#   ~/.local/bin/todo-list                                   命令行入口
#
# 卸载：
#   rm -rf ~/.local/opt/todo-list \
#          ~/.local/share/applications/todo-list.desktop \
#          ~/.local/share/icons/hicolor/*/apps/todo-list.png \
#          ~/.local/bin/todo-list
#   （用户数据 ~/.config/todo-list 自行决定是否保留）

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="${1:-$APPDIR}"
DEST="$HOME/.local/opt/todo-list"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor"
BINDIR="$HOME/.local/bin"

[ -d "$SRC" ] || die "找不到组装好的应用目录: $SRC（先跑 build.sh）"
[ -f "$SRC/resources/app.asar" ] || die "$SRC 里没有 resources/app.asar"
need node

info "[1/5] 复制到 $DEST"
rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"
cp -a "$SRC" "$DEST"

info "[2/5] 应用 asar 补丁"
node "$REPO/scripts/patch.mjs" "$DEST/resources/app.asar" || warn "补丁未全部应用，请检查上面的输出"

info "[3/5] 安装图标"
mkdir -p "$ICONS/256x256/apps"
node "$REPO/scripts/asar.mjs" cat "$DEST/resources/app.asar" icon.png > "$ICONS/256x256/apps/todo-list.png"
ICON_BYTES="$(stat -c%s "$ICONS/256x256/apps/todo-list.png")"
dim "    ${ICON_BYTES} 字节"
# 图标提取曾因 asar.mjs 入口判断写错而静默产出 0 字节，必须拦住
[ "$ICON_BYTES" -gt 1000 ] || die "图标提取失败（只有 ${ICON_BYTES} 字节）"

info "[4/5] 安装启动器"
cp -f "$REPO/packaging/todo-list.sh" "$DEST/launch.sh"
chmod +x "$DEST/launch.sh"

info "[5/5] 桌面项 + 命令行入口"
mkdir -p "$APPS" "$BINDIR"
cat > "$APPS/todo-list.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Todo清单
GenericName=待办事项与时间管理
Comment=Todo清单是一款强大的跨平台待办事项和时间管理应用
Exec=$DEST/launch.sh %U
Icon=todo-list
Terminal=false
Categories=Office;ProjectManagement;
Keywords=todo;task;待办;清单;番茄;
StartupNotify=true
StartupWMClass=Todo清单
EOF
printf '#!/usr/bin/env bash\nexec "%s/launch.sh" "$@"\n' "$DEST" > "$BINDIR/todo-list"
chmod +x "$BINDIR/todo-list"

command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
command -v gtk-update-icon-cache   >/dev/null && gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || true

echo
info "安装完成"
dim "  启动 : 应用菜单搜索「Todo清单」，或终端执行 todo-list"
dim "  目录 : $DEST"
dim "  数据 : ~/.config/todo-list"
dim ""
dim "  注意：关闭窗口 = 缩到托盘（应用继续运行）。"
dim "        彻底退出：托盘图标右键 → 退出，或 pkill -f todo-list"
