#!/usr/bin/env bash
# 扫描一个已解包的 Windows 版应用目录，输出「指纹」JSON。
# 这是版本升级时的第一站：先看清新包长什么样，再决定后续步骤。
#
# 用法: fingerprint.sh <解包后的应用目录> [输出json]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP="${1:?用法: fingerprint.sh <解包后的应用目录> [输出json]}"
OUT="${2:-}"

[ -d "$APP" ] || die "目录不存在: $APP"
need python3 file

RES="$APP/resources"
ASAR="$RES/app.asar"
[ -f "$ASAR" ] || die "找不到 $ASAR（可能不是 Electron 应用，或解包层级不对）"

# --- 从主可执行文件抓 Electron / Chrome 版本 ---
MAIN_EXE="$(find "$APP" -maxdepth 1 -name '*.exe' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2)"
ELECTRON_VER=""; CHROME_VER=""
if [ -n "$MAIN_EXE" ]; then
  ELECTRON_VER="$(strings -n 6 "$MAIN_EXE" 2>/dev/null | grep -oE 'Electron/[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -1 | cut -d/ -f2 || true)"
  CHROME_VER="$(strings -n 6 "$MAIN_EXE" 2>/dev/null | grep -oE 'Chrome/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -1 | cut -d/ -f2 || true)"
fi

# --- 读 asar 内的 package.json 与关键文件名 ---
ASAR_TOOL="$REPO/scripts/asar.mjs"
python3 - "$ASAR" "$ASAR_TOOL" "$ELECTRON_VER" "$CHROME_VER" "$MAIN_EXE" <<'PY' > "${OUT:-/dev/stdout}"
import json,sys,subprocess,struct,re,os
asar, asar_tool, elver, chver, main_exe = sys.argv[1:6]

def asar_open(p):
    f=open(p,'rb'); h=f.read(16)
    hs=struct.unpack('<I',h[4:8])[0]; jl=struct.unpack('<I',h[12:16])[0]
    tree=json.loads(f.read(jl).decode('utf-8'))
    return f, tree, 8+hs

f, tree, data_start = asar_open(asar)
entries={}
def walk(n,pre):
    for k,c in (n.get('files') or {}).items():
        q=pre+'/'+k
        if c.get('files'): walk(c,q)
        else: entries[q]=c
walk(tree,'')

def read(p):
    e=entries[p]; f.seek(data_start+int(e['offset'])); return f.read(e['size'])

pkg={}
try: pkg=json.loads(read('/package.json').decode('utf-8'))
except Exception: pass

# 找补丁目标：哪些 js 里含 hasTitleBar 的 win32 判断
targets=[]
for p,e in entries.items():
    if not p.endswith('.js') or e.get('unpacked'): continue
    if '/node_modules/' in p: continue
    try: txt=read(p).decode('utf-8','replace')
    except Exception: continue
    if 'hasTitleBar' in txt:
        targets.append({
            'path': p,
            'size': e.get('size'),
            'hasWin32Guard': bool(re.search(r'hasTitleBar\s*:\s*"win32"\s*===\s*process\.platform', txt)),
            'alreadyPatched': bool(re.search(r'hasTitleBar\s*:\s*process\.platform\s*!=\s*"darwin"', txt)),
        })

# 原生模块预编译
napi=sorted(p for p in entries if '/prebuilds/' in p)

# Windows 专有资源
res_dir=os.path.dirname(asar)
extra=sorted(os.listdir(res_dir)) if os.path.isdir(res_dir) else []

print(json.dumps({
  'electronVersion': elver or None,
  'chromeVersion': chver or None,
  'mainExecutable': os.path.basename(main_exe) if main_exe else None,
  'app': {
    'name': pkg.get('name'),
    'version': pkg.get('version'),
    'description': pkg.get('description'),
    'main': pkg.get('main'),
    'dependencies': pkg.get('dependencies'),
    'engines': pkg.get('engines'),
  },
  'asar': {'path': asar, 'bytes': os.path.getsize(asar), 'entries': len(entries)},
  'resourcesEntries': extra,
  'nativePrebuilds': napi,
  'patchTargets': targets,
}, ensure_ascii=False, indent=2))
PY
