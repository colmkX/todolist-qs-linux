#!/usr/bin/env bash
# 一键更新：从新的 Windows 安装包更新出新的 Linux 版本。
#
# 用法:
#   scripts/update.sh <新安装包.exe>            解包+指纹+组装+打补丁+验证
#   scripts/update.sh <新安装包.exe> --install  额外安装到 ~/.local
#
# 这个脚本是给"未来的 AI/维护者"用的入口：
# 它不做任何猜测，每一步都打印依据；失败时明确指出卡在哪一步。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need python3 file curl unzip 7z node

INSTALLER="${1:?用法: update.sh <安装包.exe> [--install]}"
DO_INSTALL=0
for a in "$@"; do [ "$a" = "--install" ] && DO_INSTALL=1; done

[ -f "$INSTALLER" ] || die "找不到安装包: $INSTALLER"
mkdir -p "$WORK"

echo "═══════════════════════════════════════════════════════════"
info "第 1 步 / 5：解包"
echo "═══════════════════════════════════════════════════════════"
bash "$REPO/scripts/unpack.sh" "$INSTALLER" "$UNPACK"

echo
echo "═══════════════════════════════════════════════════════════"
info "第 2 步 / 5：指纹扫描（判断新包和已知版本的差异）"
echo "═══════════════════════════════════════════════════════════"
bash "$REPO/scripts/fingerprint.sh" "$UNPACK/app" "$WORK/fingerprint.json"
cat "$WORK/fingerprint.json"

EV="$(python3 -c "import json;print(json.load(open('$WORK/fingerprint.json'))['electronVersion'] or '')")"

echo
echo "═══════════════════════════════════════════════════════════"
info "第 3 步 / 5：取 Electron 运行时（版本 $EV）"
echo "═══════════════════════════════════════════════════════════"
[ -n "$EV" ] || die "没能从安装包里识别出 Electron 版本，请人工确认后手动执行 fetch-electron.sh"
bash "$REPO/scripts/fetch-electron.sh" "$EV"

echo
echo "═══════════════════════════════════════════════════════════"
info "第 4 步 / 5：组装 + 打补丁"
echo "═══════════════════════════════════════════════════════════"
bash "$REPO/scripts/build.sh" "$EV" "$UNPACK" "$APPDIR"
node "$REPO/scripts/patch.mjs" "$APPDIR/resources/app.asar"

echo
echo "═══════════════════════════════════════════════════════════"
info "第 5 步 / 5：冒烟测试"
echo "═══════════════════════════════════════════════════════════"
bash "$REPO/scripts/verify.sh" "$APPDIR/todo-list" 25 || warn "冒烟测试有未通过项，请查看日志"

# ---------- 更新 manifest ----------
python3 - "$MANIFEST" "$WORK/fingerprint.json" "$INSTALLER" "$EV" <<'PY'
import json,sys,hashlib,os
mf, fp, installer, ev = sys.argv[1:5]
d=json.load(open(mf)) if os.path.exists(mf) else {}
f=json.load(open(fp))
def sha(p):
    h=hashlib.sha256()
    with open(p,'rb') as fh:
        for b in iter(lambda: fh.read(1<<20), b''): h.update(b)
    return h.hexdigest()
d['product']=f['app'].get('name')
d['version']=f['app'].get('version')
d['electronVersion']=ev
d['installer']={'name':os.path.basename(installer),'sha256':sha(installer),'bytes':os.path.getsize(installer)}
d['app']=f['app']
# 只记大小与条目数：fingerprint 里的 path 是本机绝对路径，
# 写进仓库会泄露用户名，没必要
d['asar']={'bytes':f['asar']['bytes'],'entries':f['asar']['entries']}
d['nativePrebuilds']=f['nativePrebuilds']
d['patchTargets']=f['patchTargets']
json.dump(d,open(mf,'w'),ensure_ascii=False,indent=2)
print('已更新', mf)
PY

if [ "$DO_INSTALL" = 1 ]; then
  echo
  echo "═══════════════════════════════════════════════════════════"
  info "附加：安装到 ~/.local"
  echo "═══════════════════════════════════════════════════════════"
  bash "$REPO/scripts/install-user.sh" "$APPDIR"
fi

echo
info "更新流程结束"
dim "  组装产物: $APPDIR"
dim "  指纹快照: $WORK/fingerprint.json"
dim "  版本清单: $MANIFEST"
dim ""
dim "  如需打 pacman 包: bash packaging/build-pkg.sh"
