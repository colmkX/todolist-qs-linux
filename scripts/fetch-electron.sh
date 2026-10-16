#!/usr/bin/env bash
# 下载并缓存指定版本的 Electron linux-x64 运行时。
# 优先用国内镜像（快），失败回退 GitHub 官方。
#
# 用法: fetch-electron.sh <版本号>        例如: fetch-electron.sh 43.4.0
#
# 缓存布局:
#   build/electron/<版本>/electron-v<版本>-linux-x64.zip   下载的压缩包
#   build/electron/<版本>/runtime/                          解压后的完整运行时
#
# 注意：必须保留**完整**运行时目录（electron 二进制 + resources/ + locales/
# + *.so）。只拷贝 electron 单个文件是跑不起来的。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VER="${1:?用法: fetch-electron.sh <Electron版本号>}"
ZIP="electron-v${VER}-linux-x64.zip"
DEST="$ELECTRON_CACHE/$VER"
RUNTIME="$DEST/runtime"

if [ -x "$RUNTIME/electron" ]; then
  info "已缓存: $RUNTIME"
  dim "  $("$RUNTIME/electron" --version 2>/dev/null | head -1 || echo '(无法执行，可能缓存不完整)')"
  exit 0
fi

MIRRORS=(
  "https://cdn.npmmirror.com/binaries/electron/${VER}/${ZIP}"
  "https://github.com/electron/electron/releases/download/v${VER}/${ZIP}"
)

mkdir -p "$DEST"
cd "$DEST"
ok=0
for url in "${MIRRORS[@]}"; do
  if [ -f "$ZIP" ]; then
    dim "  已有压缩包: $ZIP"
    ok=1; break
  fi
  info "下载: $url"
  if curl -fL --retry 3 --retry-delay 2 -o "$ZIP.part" "$url"; then
    mv -f "$ZIP.part" "$ZIP"; ok=1; break
  fi
  warn "失败，换下一个源"
done
[ "$ok" = 1 ] || die "所有源都下载失败"

info "解压完整运行时"
rm -rf "$RUNTIME"; mkdir -p "$RUNTIME"
unzip -q -o "$ZIP" -d "$RUNTIME" || die "解压失败"
[ -x "$RUNTIME/electron" ] || die "解压后找不到 electron 可执行文件，压缩包结构可能变了"
chmod +x "$RUNTIME/electron" "$RUNTIME/chrome-sandbox" 2>/dev/null || true

info "完成"
dim "  zip sha256: $(sha256 "$ZIP")"
dim "  运行时    : $RUNTIME ($(du -sh "$RUNTIME" | cut -f1))"
dim "  版本      : $("$RUNTIME/electron" --version 2>/dev/null | head -1 || echo '未知')"
