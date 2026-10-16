#!/usr/bin/env bash
# 用 Linux 版 Electron 重新托管 Windows 版应用代码，组装出可运行的 Linux 应用目录。
#
# 用法: build.sh <Electron版本号> [解包目录] [输出目录]
# 产出: build/app/   （可执行文件已重命名为 todo-list）

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VER="${1:?用法: build.sh <Electron版本号> [解包目录] [输出目录]}"
UNP="${2:-$UNPACK}"
OUT="${3:-$APPDIR}"

WIN_APP="$UNP/app"
[ -d "$WIN_APP/resources" ] || die "找不到 Windows 应用目录: $WIN_APP（先跑 unpack.sh）"

ELECTRON_DIR="$ELECTRON_CACHE/$VER/runtime"
ELECTRON_BIN="$ELECTRON_DIR/electron"
[ -x "$ELECTRON_BIN" ] || die "找不到 Electron $VER 运行时，先跑 fetch-electron.sh $VER"

need unzip node

info "组装 $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"

# ---------- 1. Electron 运行时 ----------
info "[1/4] 复制 Electron $VER 运行时"
cp -a "$ELECTRON_DIR"/. "$OUT"/
chmod +x "$OUT/electron" "$OUT/chrome-sandbox" 2>/dev/null || true

# ---------- 2. 应用代码 ----------
info "[2/4] 放置应用代码（原封不动的 app.asar）"
rm -rf "$OUT/resources/app.asar" "$OUT/resources/app.asar.unpacked"
cp -a "$WIN_APP/resources/app.asar" "$OUT/resources/"
[ -d "$WIN_APP/resources/app.asar.unpacked" ] && cp -a "$WIN_APP/resources/app.asar.unpacked" "$OUT/resources/"

# ---------- 3. 原版 resources 里 Linux 也需要的东西 ----------
info "[3/4] 补齐 resources 下的附加文件"
for f in public; do
  if [ -e "$WIN_APP/resources/$f" ]; then
    cp -a "$WIN_APP/resources/$f" "$OUT/resources/"
    dim "  已复制 $f/"
  fi
done
dim "  跳过 Windows 专有项: lib/showdesktop.node, elevate.exe, app-update.yml"

# ---------- 4. 重命名可执行文件 ----------
info "[4/4] 重命名可执行文件 electron -> todo-list"
mv "$OUT/electron" "$OUT/todo-list"
chmod +x "$OUT/todo-list"

echo
info "组装完成: $OUT"
dim "  大小: $(du -sh "$OUT" | cut -f1)"
dim "  asar: $(stat -c%s "$OUT/resources/app.asar") 字节  ($(sha256 "$OUT/resources/app.asar" | cut -c1-16)...)"
dim ""
dim "  下一步: node scripts/patch.mjs '$OUT/resources/app.asar'"
