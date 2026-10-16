#!/usr/bin/env bash
# 把组装好的应用打成 Arch 本地包（.pkg.tar.zst），供 pacman -U 安装。
#
# 用法: build-pkg.sh [应用目录]     默认 build/app
# 产出: packaging/todo-list-<版本>-1-x86_64.pkg.tar.zst
#
# 为什么不打 AppImage：
#   应用内置的 electron-updater 在检测到 APPIMAGE 环境变量后会激活，而官方
#   更新源只发布 Windows/macOS 产物，Linux 上必然 404 失败。用 pacman 包则
#   更新器保持静默（详见 docs/移植原理.md 第 9.5 节）。

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

SRC="${1:-$APPDIR}"
PKGDIR="$REPO/packaging"
[ -d "$SRC" ] || die "找不到应用目录: $SRC（先跑 scripts/build.sh）"
[ -f "$SRC/resources/app.asar" ] || die "$SRC 里没有 resources/app.asar"
need makepkg tar zstd python3 node

VER="$(python3 -c "
import json
try: print(json.load(open('$MANIFEST'))['version'] or '')
except Exception: print('')
")"
[ -n "$VER" ] || die "读不到应用版本号，请先跑 scripts/update.sh（它会写 $MANIFEST）"

info "应用版本: $VER"
info "源目录  : $SRC ($(du -sh "$SRC" | cut -f1))"

cd "$PKGDIR"

# ---------- 1. 打包源目录（makepkg 的 source） ----------
TARBALL="todo-list-${VER}.tar.zst"
if [ ! -f "$TARBALL" ]; then
  info "[1/4] 生成源包 $TARBALL（较慢，仅首次）"
  tar -I 'zstd -3 -T0' -cf "$TARBALL" -C "$(dirname "$SRC")" "$(basename "$SRC")" \
    --transform "s|^$(basename "$SRC")|todo-list-${VER}|" || die "打包失败"
else
  dim "[1/4] 复用已有 $TARBALL"
fi
SHA="$(sha256 "$TARBALL")"

# ---------- 2. 生成图标 ----------
info "[2/4] 生成图标"
node "$REPO/scripts/asar.mjs" cat "$SRC/resources/app.asar" icon.png > todo-list.png
ICON_BYTES="$(stat -c%s todo-list.png)"
dim "    ${ICON_BYTES} 字节"
# 必须校验：asar.mjs 曾因入口判断写错而静默空转，产出 0 字节图标却不报错，
# 结果打出一个图标损坏的包。这里fail fast。
[ "$ICON_BYTES" -gt 1000 ] || die "图标提取失败（只有 ${ICON_BYTES} 字节），拒绝继续打包"
file -b todo-list.png | grep -q "PNG image" || die "图标不是有效 PNG：$(file -b todo-list.png)"

# ---------- 3. 实例化 PKGBUILD ----------
info "[3/4] 生成 PKGBUILD"
sed -e "s/@PKGVER@/${VER}/" -e "s/@SHA256@/${SHA}/" PKGBUILD > PKGBUILD.generated
dim "    sha256sums = $SHA"

# ---------- 4. makepkg ----------
info "[4/4] makepkg 构建（!strip，Electron 二进制不能 strip）"
# makepkg 不允许以 root 运行
[ "$(id -u)" != 0 ] || die "makepkg 不能以 root 运行"
# 用生成的 PKGBUILD 覆盖式构建
cp -f PKGBUILD PKGBUILD.bak
cp -f PKGBUILD.generated PKGBUILD
trap 'mv -f PKGBUILD.bak PKGBUILD 2>/dev/null || true' EXIT

makepkg -f --noconfirm || die "makepkg 构建失败"

mv -f PKGBUILD.bak PKGBUILD
trap - EXIT

PKG="$(ls -t todo-list-${VER}-1-*.pkg.tar.zst 2>/dev/null | head -1)"
[ -n "$PKG" ] || die "没找到产出的包"

echo
info "打包完成"
dim "  包文件: $PKGDIR/$PKG"
dim "  大小  : $(du -h "$PKG" | cut -f1)"
dim "  sha256: $(sha256 "$PKG")"
echo
dim "  安装  : sudo pacman -U '$PKGDIR/$PKG'"
dim "  卸载  : sudo pacman -R todo-list"
