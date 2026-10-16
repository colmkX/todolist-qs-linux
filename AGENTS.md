# AGENTS.md — 给后续 AI / 维护者的操作手册

> 你拿到的是一个新版本的 `Todo清单 Setup X.Y.Z.exe`，需要把它变成可用的
> Arch Linux 版本。**先读本文再动手**，这里记录了所有踩过的坑和不能改的东西。

---

## 0. 三十秒理解这个仓库

```
Windows 安装包 (.exe)
  └─ NSIS 外壳
      └─ app-64.7z
          ├─ Todo清单.exe         ← 原版 Windows Electron 运行时，**丢弃**
          └─ resources/app.asar   ← 应用代码（跨平台的 JS），**保留**
                  + app.asar.unpacked/  ← 原生模块等，**保留**
                  + public/icon.png     ← 主窗口图标，**保留**

组装方式：官方 Linux 版 Electron 运行时
          + 上面保留的 resources/
          + 一处 asar 字节补丁
        = 可用的 Linux 应用
```

**核心心智模型**：应用代码（JS）本身是跨平台的，作者也写了 Linux 分支；
真正缺的只是「用 Linux 的 Electron 把它跑起来」。所以这不是重写，是换底。

---

## 1. 铁律（违反必坏，不要"优化"）

| 铁律 | 原因 |
|---|---|
| **PKGBUILD 必须 `options=('!strip')`** | makepkg 默认 strip 二进制，**Electron 主程序 strip 后会损坏**。Arch 官方 electron 包同样禁用 |
| **不要打成 AppImage** | AppImage 会设置 `APPIMAGE` 环境变量 → 激活内置 electron-updater → 官方更新源只有 Windows/macOS 产物 → 必然 404。pacman 包则让更新器安静跳过 |
| **不要用 `pkill -f "<路径>"`** | 调用方命令行里往往含同一路径，**pkill 会杀掉脚本自己**（本仓库踩过）。用 `lib.sh` 里的 `stop_app` |
| **不要给 `timeout` 的结果直接赋值** | `lib.sh` 开了 `set -e`，`timeout` 超时返回 124 是非零，会让脚本当场退出。用 `rc=0; timeout ... \|\| rc=$?` |
| **`app.asar` 尽量只做等长替换** | 等长时只需改 26 个字节 + 更新头部哈希；变长则要重打包整个 290 MB 文件。`patch.mjs` 两者都支持，但等长更稳 |
| **不要保留 Windows 专有文件** | `lib/showdesktop.node`、`elevate.exe`、`app-update.yml` 都不用带。`resources/public/` 必须带 |
| **`.mjs` 判断"是否被直接调用"不要比较 `import.meta.url` 与 `` `file://${argv[1]}` ``** | `import.meta.url` 会对路径做**百分号编码**；本仓库路径含中文（`Todo清单逆向项目`），编码后与原始 `argv[1]` 永不相等 → 脚本**静默什么都不做、退出码还是 0**。本仓库因此产出过 0 字节的图标且不报错。正确写法：`path.resolve(argv[1]) === fileURLToPath(import.meta.url)` |
| **提取出的资源要校验大小** | 上一条的后果是"静默产出空文件"。任何从 asar 提取的文件（图标等）都必须断言大小/类型，不能只信退出码 |

---

## 2. 更新流程（标准动作）

```bash
# 一条命令走完
scripts/update.sh "二进制安装包/Todo清单 Setup <新版本>.exe" --install
```

它会依次执行：

| 步骤 | 脚本 | 预期输出 |
|---|---|---|
| 1 | `unpack.sh` | NSIS 与 7z 两层解开，确认 `resources/app.asar` 存在 |
| 2 | `fingerprint.sh` | 输出指纹 JSON：Electron 版本、应用版本号、依赖、**补丁目标是否存在** |
| 3 | `fetch-electron.sh` | 按指纹里的 Electron 版本取运行时（有缓存则秒过） |
| 4 | `build.sh` + `patch.mjs` | 组装并打补丁，**必须看到「全部补丁应用成功 ✓」** |
| 5 | `verify.sh` | 六项启动里程碑全绿 |

### 重点看第 2 步的 `patchTargets`

```json
"patchTargets": [
  { "path": "/js/chunk-common.8f60109a.js",
    "hasWin32Guard": true,      ← 补丁目标还在，可以自动打
    "alreadyPatched": false }
]
```

- `hasWin32Guard: true` → 补丁能自动打，继续
- **所有项都是 `false`** → ⚠️ 上游改了这段代码，**补丁打不上**，见第 3 节
- 文件名里的哈希（`8f60109a`）**每次构建都会变**，所以 `patch.mjs` 是按
  正则搜索内容而不是按文件名匹配的，不要改成硬编码文件名

### 第 1 步可能失败：安装器结构变了

若报「NSIS 里没找到 `app-*.7z`」：

```bash
7z l "<安装包>"          # 看第 1 层结构
# 若是 Inno Setup / Squirrel 等别的壳，需换解包方式
```

目前只见过 NSIS-3。换壳的话 `unpack.sh` 要改，但后续步骤不变。

---

## 3. 补丁打不上时怎么办（唯一需要动脑的地方）

### 3.1 先确认症状

`patch.mjs` 会打印：

```
✗ [titlebar-on-linux] 未找到目标，跳过。新版本可能改了这段代码，需要人工确认。
```

### 3.2 定位新的目标

Linux 上「窗口没有关闭按钮」的根因是这两个判断组合：

```js
// 主进程 background.js（BUNDLE，webpack 压缩过）
frame: "darwin" === process.platform        // 非 macOS 一律无边框

// 渲染进程 js/*.js（Vuex store）
hasTitleBar: "win32" === process.platform   // 只给 win32 开自绘标题栏
```

在解包后的 asar 里搜：

```bash
# 快速定位含 hasTitleBar 的文件
node scripts/asar.mjs list build/unpack/app/resources/app.asar | grep -E "^ *[0-9]+  /js/"
node scripts/asar.mjs cat  build/unpack/app/resources/app.asar /js/chunk-common.<hash>.js \
  | grep -o 'hasTitleBar:[^,]*'
```

### 3.3 改 `patch.mjs` 的补丁声明

补丁表在 `scripts/patch.mjs` 顶部 `PATCHES` 数组。改 `pattern` 与 `replace` 即可：

```js
{
  id: 'titlebar-on-linux',
  files: /^\/js\/[^/]*\.js$/,              // 候选文件；用正则避免硬编码哈希
  pattern: /hasTitleBar\s*:\s*"win32"\s*===\s*process\.platform/g,
  replace: () => 'hasTitleBar:process.platform!="darwin"',
  allowRepack: true,
}
```

**优先凑等长替换**。常用等价写法与长度：

| 原串 | 等长替换 | 长度 |
|---|---|---|
| `"win32"===process.platform` | `process.platform!="darwin"` | 26 |
| `"win32" == process.platform` | `process.platform != "darwin"` | 29 |

凑不出等长也没关系：`patch.mjs` 会自动转入重打包路径（把 290 MB 重新写一遍，
约 1-2 分钟），并同步修正所有文件偏移与完整性哈希。

### 3.4 如果上游换成了别的方式

例如改成读配置或用了别的状态字段，那就得顺着 `hasTitleBar` 的赋值链找。
辅助手段：

```bash
# 找一个变量/字符串出现在哪些文件
grep -c "hasTitleBar" build/unpack/app-code/js/*.js

# 反压缩（需要 Wakaru），把 webpack 输出摊成可读模块
# REA 的 recover_javascript_sources 工具可做这件事
```

### 3.5 打不上补丁的后果与兜底

补丁失败 ≠ 应用不能用，只是**窗口没有关闭按钮**。临时兜底：

- `Alt+F4` 可以关（触发的是同一个 close 事件）
- 托盘图标右键 → 退出
- 或临时改 `build.sh` 让主进程对 Linux 也用 `frame: true`（会有系统标题栏，
  但和应用自绘的界面可能重叠，不推荐长期用）

---

## 4. 验证清单（不要只看"能启动"）

```bash
# 1) 自动冒烟测试：六项里程碑
scripts/verify.sh build/app/todo-list 25

# 2) 人工看界面（截图比"我跑了没报错"可靠得多）
#    需要 X11 可达（XWayland 即可）
DISPLAY=:1 ./build/app/todo-list --ozone-platform=x11 &
sleep 12
ID=$(xdotool search --pid $(pgrep -f build/app/todo-list | head -1) | head -1)
import -window "$ID" /tmp/shot.png
#    期望：右上角有 — □ ✕ 三个按钮
```

**必须确认的三件事**：

1. 主窗口能显示，界面完整（不是白屏）
2. 右上角有 **—** / **□** / **✕**（补丁生效的标志）
3. 点 ✕ 后应用**不会退出**而是缩到托盘，且日志出现
   `主窗口关闭行为:` —— 说明按钮真的接上了窗口对象

### 打包后再验一次

```bash
packaging/build-pkg.sh
# 确认包里的 asar 是打过补丁的（流式比对，不落盘）
bsdtar -xOf packaging/todo-list-<版本>-1-x86_64.pkg.tar.zst \
       opt/todo-list/resources/app.asar | sha256sum
# 与 build/app/resources/app.asar 的 sha256 比对，必须一致
```

---

## 5. 常见故障速查

| 症状 | 原因 | 处理 |
|---|---|---|
| `EBADF: bad file descriptor, write` | `patch.mjs` 以只读打开 asar | 必须是 `fs.openSync(path, 'r+')`（已修，勿回退） |
| 脚本无输出就退出 | `set -e` + 非零返回（如 `timeout` 的 124） | 用 `\|\| rc=$?` 接住 |
| `pkill` 把脚本自己杀了 | `pkill -f "<路径>"` 自匹配 | 用 `lib.sh:stop_app` |
| makepkg：`cp: 无法保留...的所有权: 无效的参数` | fakeroot 下 `cp -a` 尝试保留属主 | 用 `bsdtar ... --no-same-owner`（已改） |
| 打包后图标/任务栏不对 | `StartupWMClass` 不匹配 | 应用内 `app.setName("Todo清单")`，桌面项用 `StartupWMClass=Todo清单` |
| **打包后图标空白 / 是 0 字节** | `asar.mjs` 入口判断写错导致**静默空转**，图标被写成空文件 | 已修（见铁律表）。自查：`node scripts/asar.mjs cat <asar> icon.png \| wc -c` 应 >1000。已加打包前校验 |
| 再次点菜单图标"闪退" | 单实例锁：已有实例（在托盘） | 正常行为，不是 bug。托盘右键 → 打开 |
| `GPU process exited unexpectedly: exit_code=139` | 无 `/dev/dri` 或 GPU 驱动问题 | 加 `--disable-gpu`（启动器已列备选） |
| 提示 `APPIMAGE env is not defined` | 非 AppImage 运行 | **正常且期望**，更新器据此跳过 |
| 小组件/番茄悬浮窗不显示 | Wayland 不允许客户端定位窗口与置顶 | 用 `--ozone-platform=x11`（启动器第 2 备选） |

---

## 6. 环境事实（本机已验证）

- 系统：Arch Linux，KDE Plasma，**Wayland** 会话，x86_64
- 工具：`7z` `unzip` `curl` `xdotool` `imagemagick(import/convert)` `pkgfile`
  `fakeroot` `makepkg` `bsdtar` `python3` `node`
- Node.js 26.x（只用于跑本仓库脚本；应用自带 Node 24，来自 Electron）
- 构建产物约 624 MB（未压缩），pacman 包约 196 MB
- 不依赖 sudo，除非执行 `pacman -U`

---

## 7. 汇报格式建议

改完版本后，向人类汇报时请包含：

1. 新版本号与 Electron 版本
2. 补丁是**自动应用成功**还是**人工适配**（后者说明改了什么）
3. `scripts/verify.sh` 的六项结果
4. 界面截图（确认右上角三个按钮）
5. pacman 包路径、大小、sha256
6. 与上一版的差异（依赖变化、原生模块版本变化等）

**不要只说"成功了"**——这个项目的历史教训是：应用能启动 ≠ 功能完整
（"能启动但没有任何关闭按钮"就是这么漏过去的，直到有人实际看了一眼界面）。
