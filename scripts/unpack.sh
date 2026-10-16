#!/usr/bin/env bash
# 解包 Windows 安装包：NSIS 外壳 -> app-64.7z -> 应用目录
#
# 用法: unpack.sh <安装包.exe> [输出目录]
# 产出:
#   <输出>/nsis/     NSIS 层内容（含 app-64.7z、$PLUGINSDIR 等）
#   <输出>/app/      应用完整目录（含 Electron 运行时、resources/app.asar）

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="${1:?用法: unpack.sh <安装包.exe> [输出目录]}"
OUT="${2:-$UNPACK}"
[ -f "$INSTALLER" ] || die "找不到安装包: $INSTALLER"

need 7z file python3

info "安装包: $INSTALLER"
info "SHA-256: $(sha256 "$INSTALLER")"
info "大小: $(stat -c%s "$INSTALLER") 字节"

mkdir -p "$OUT"
rm -rf "$OUT/nsis" "$OUT/app"

# ---------- 第 1 层：NSIS ----------
info "[1/2] 解 NSIS 外壳"
7z x "$INSTALLER" -o"$OUT/nsis" -y >/dev/null || die "NSIS 解包失败"
PAYLOAD="$(find "$OUT/nsis" -name 'app-*.7z' | head -1)"
[ -n "$PAYLOAD" ] || die "NSIS 里没找到 app-*.7z；安装器结构可能变了，请手动查看 $OUT/nsis"
dim "  载荷: $PAYLOAD  ($(stat -c%s "$PAYLOAD") 字节)"

# ---------- 第 2 层：应用载荷 ----------
info "[2/2] 解应用载荷"
7z x "$PAYLOAD" -o"$OUT/app" -y >/dev/null || die "应用载荷解包失败"

# ---------- 结构自检 ----------
[ -f "$OUT/app/resources/app.asar" ] || die "解出来不是预期的 Electron 结构（缺 resources/app.asar）"

info "完成"
dim "  应用目录 : $OUT/app"
dim "  asar     : $OUT/app/resources/app.asar ($(stat -c%s "$OUT/app/resources/app.asar") 字节)"
if [ -d "$OUT/app/resources/app.asar.unpacked" ]; then
  dim "  unpacked : $(du -sh "$OUT/app/resources/app.asar.unpacked" | cut -f1)"
fi
dim "  resources 目录内容:"
for x in "$OUT/app/resources"/*; do dim "    - $(basename "$x")"; done
