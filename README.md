# Todo清单 · Linux 版（非官方移植）

把官方 **Windows 安装包**里的应用代码，用官方 **Linux 版 Electron** 重新托管，
得到一个能在 Arch Linux 上正常使用的版本。

> **这不是重写，是重新托管（re-host）**：`app.asar` 里 290 MB 的应用字节
> 原封不动，只做了一处 26 字节的等长替换（见 [补丁清单](docs/补丁清单.md)）。
> 换掉的是它下面那层 Electron 运行时。

| 项目 | 值 |
|---|---|
| 上游产品 | Todo清单 3.14.2（杭州乾夕科技有限公司，闭源商业软件） |
| Electron | 43.4.0 / Chrome 150 |
| 已验证平台 | Arch Linux + KDE Plasma (Wayland) + x86_64 |
| 打包形式 | pacman 本地包（`.pkg.tar.zst`） |
| 官方 Linux 版 | **不存在**（官方只发 Windows / macOS / iOS / Android / 各品牌手表） |

![界面](docs/evidence/补丁后-顶部有标题栏.png)

---

## 快速开始

### 只想装来用

```bash
sudo pacman -U packaging/todo-list-3.14.2-1-x86_64.pkg.tar.zst
```

然后从应用菜单搜索「Todo清单」，或终端执行 `todo-list`。

> **重要**：关闭窗口 ≠ 退出。关窗口会缩到**系统托盘**，应用继续运行
> （这也是"再次点菜单图标好像闪退"的原因——单实例锁让第二个进程立刻退出）。
> 彻底退出：托盘图标右键 → **退出**，或 `pkill -f todo-list`。

### 拿到新版本安装包后，更新

```bash
scripts/update.sh "二进制安装包/Todo清单 Setup <新版本>.exe" --install
```

一条命令走完：解包 → 指纹扫描 → 取对应 Electron → 组装 → 打补丁 → 冒烟测试
→ 写 `state/manifest.json`。

然后重打 pacman 包：

```bash
packaging/build-pkg.sh
```

### 从零重建（例如换了机器）

```bash
scripts/unpack.sh  "二进制安装包/Todo清单 Setup 3.14.2.exe"
scripts/fetch-electron.sh 43.4.0
scripts/build.sh 43.4.0
scripts/install-user.sh                 # 装到 ~/.local，免 sudo
```

---

## 为什么这条路可行

先看清目标是什么形态，这一步决定了后面所有策略：

```
Todo清单 Setup 3.14.2.exe           174 MB   NSIS 自解压安装器
└── $PLUGINSDIR/app-64.7z           173 MB
    └── 应用目录                    660 MB
        ├── Todo清单.exe            215 MB   ← 改名后的**原版 Electron 运行时**
        │                                       用 Ghidra 逆向它毫无意义
        └── resources/app.asar      290 MB   ← 真正的应用代码（Electron 43.4.0）
```

两个原本会致命的问题，实测都自动化解：

1. **原生模块**：`better-sqlite3-multiple-ciphers` 自带 8 个平台的预编译
   `.node`，包括 `linux-x64.node`。它能跨 Node 大版本加载 ⇒ 是 **N-API**
   （ABI 稳定）⇒ 在 Electron 43 里直接可用，**不需要 electron-rebuild**。
2. **Windows 专有代码**：`showdesktop.node` 是条件加载 + try/catch，
   Linux 上走 `非 Windows 平台，跳过 showdesktop.node 加载` 分支，不崩。

真正需要人工修的只有**一处**：窗口没有任何关闭按钮。原因与修复见
[补丁清单](docs/补丁清单.md)。

---

## 目录结构

```
├── README.md                  本文
├── AGENTS.md                  ★ 给后续 AI / 维护者的操作手册（要更新版本先读它）
├── docs/
│   ├── 应用剖析.md             目标结构、技术栈、功能验证矩阵
│   ├── 移植原理.md             为什么这样移植、关键取舍（含为何不打 AppImage）
│   ├── 补丁清单.md             asar 补丁的原理与实现细节
│   ├── 故障排查.md             按症状查原因
│   └── evidence/               补丁前后的截图证据
├── scripts/                   可复现流水线
│   ├── lib.sh                 共享配置与 stop_app（避免 pkill 自匹配）
│   ├── unpack.sh              NSIS → 7z → 应用目录
│   ├── fingerprint.sh         扫描安装包，输出指纹 JSON（版本/依赖/补丁目标）
│   ├── fetch-electron.sh      按版本取 Electron linux-x64 并缓存
│   ├── build.sh               组装 Linux 应用目录
│   ├── patch.mjs              ★ 通用 asar 补丁引擎
│   ├── install-user.sh        装到 ~/.local（免 sudo）
│   ├── verify.sh              冒烟测试（不需要人看界面）
│   └── update.sh              ★ 一键更新入口
├── packaging/                 Arch 打包
│   ├── PKGBUILD
│   ├── build-pkg.sh           makepkg 一键出包
│   ├── todo-list.sh           启动器（日志 + 失败自动降级）
│   ├── todo-list.desktop
│   └── todo-list.install
└── state/
    └── manifest.json          当前已验证版本的指纹快照
```

`build/`、`01-解包/`、`02-分析/`、`03-重建/`、`二进制安装包/` 都是工作目录，
已在 `.gitignore` 中排除。

---

## 打包方案的取舍

在 Arch 上只有 pacman 本地包是合适答案，理由：

| 方案 | 结论 |
|---|---|
| **pacman 本地包** | ✅ **推荐**。原生、卸载干净、依赖自动处理、可 `pacman -Qo` 溯源 |
| AppImage | ❌ **不要用**。会设置 `APPIMAGE` 环境变量，从而**激活**应用内置的 electron-updater；而官方更新源只发 Windows/macOS 产物，Linux 上必然 404 失败。用 pacman 包时更新器检测不到 `APPIMAGE`，会安静跳过 |
| 手动装到 `~/.local` | ⚠️ 可用（`scripts/install-user.sh`），适合快速试；但不进包管理，升级要手动 |
| 从源码重建 | ❌ 没有源码。上游只发二进制 |

打包时有两个**不能改**的点（改了必坏）：

- `options=('!strip')` —— makepkg 默认会 strip 二进制，**Electron 主程序
  strip 后会损坏**（Arch 官方 `electron` 包同样禁用 strip）
- 装到 `/opt` 而非 `/usr/lib` —— 整个目录是自包含的运行时

---

## 已知差异与限制

| 项目 | 状态 |
|---|---|
| 桌面小组件 / 番茄悬浮窗 | ❌ **Wayland 下不可用**（协议不允许客户端定位窗口与强制置顶）。加 `--ozone-platform=x11` 走 XWayland 可恢复，启动器已把它列为第 2 备选参数 |
| 自动更新 | ⛔ 不可用且**建议保持禁用**（见上表） |
| 开机自启 | 上游**本来就没有**这个功能（全代码 0 处引用） |
| 全局快捷键 | 上游**本来就没有** |
| 数据迁移 | Windows 版数据在 `%APPDATA%\todo-list`，Linux 版在 `~/.config/todo-list`，schema 相同，`todos.db` 可直接搬 |

## 法律提示

Todo清单 是**闭源商业软件**。为个人使用 / 互操作性做本地平台适配，与
**再分发**是两回事；对外分发本仓库产出的修改版会侵犯著作权。

本仓库的脚本、文档、补丁工具为原创；`app.asar` 及其内容仍属原著作权人。
请仅作本地自用，不要公开传播构建产物。
