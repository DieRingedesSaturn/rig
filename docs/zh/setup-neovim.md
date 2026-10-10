# setup-neovim.sh

安装 Neovim（**强制要求 >= 0.9**）并写入零依赖、面向终端原生配色的 `init.lua`，内容按当前机器情况生成。仅在 Debian 系通过 `update-alternatives` 设置默认编辑器。

**不可协商契约：** `~/.config/nvim/init.lua` 缺失时创建；已有配置仅在交互确认（保留/覆盖/看 diff）后才可替换，且先自动备份——绝不静默覆盖。

## 安装内容

| 组件 | 方式 | 说明 |
|------|------|------|
| Neovim | 包管理器（`apt`/`dnf`/`pacman`/`brew`） | 仅当版本 >= 0.9 才接受 |
| Neovim（兜底） | 官方二进制包 → `~/.local/share/nvim-static`，软链到 `~/.local/bin` | 仅 Linux，支持 x86_64 与 aarch64/arm64；发行版仓库版本 < 0.9 或安装失败时启用 |

兜底安装会先验证下载的二进制能在本机 glibc 上运行，然后经 `nvim-static.new` 目录换入新树（会先清掉中断运行留下的残留），若换入失败还会移除自己的软链，保证 `~/.local/bin/nvim` 绝不悬空。重跑时即使 `~/.local/bin` 不在 `PATH` 上，rig 的静态构建也会被识别复用。GitHub 不可达时可设 `GH_PROXY` 为 `https://` 镜像前缀。当静态包需要压过 PATH 上已有的发行版 nvim 时，脚本会提示 `~/.local/bin` 必须排在其前面（`setup-shell` 已在 `~/.zshrc` 中导出该路径）。

## 配置内容

| 项目 | 说明 |
|------|------|
| 系统编辑器 | `update-alternatives --set editor/vi` → nvim——仅限 Debian 系，且 nvim 位于 `$HOME` 下或 sudo 不可用时跳过 |
| rc 文件 | 若 `~/.zshrc`/`~/.bashrc` 缺 `EDITOR="nvim"`，在显式 `y/N` 确认后追加导出项并先备份；无 TTY 时仅打印 |
| `init.lua` | 缺失时写入；已存在则展示 diff 并提供 保留/覆盖/diff 菜单 |

存在 `init.vim` 时完全跳过写入：当两个文件共存时 Neovim 只加载 `init.lua` 并报 E5422，`init.vim` 会被静默忽略——在旁边写入基线会让用户配置被静默禁用。脚本保持 `init.vim` 原样并说明情况。把 `init.vim` 移走后重跑即可获得基线。

## 主机档案

生成的文件是没有任何运行时检测的纯配置——档案在生成时一次性选定，并写在文件第二行：

| 档案 | 触发条件 | 剪贴板 | 配色 |
|------|---------|--------|------|
| desktop | 检测到桌面会话（macOS、Wayland 或 X11），或由 `RIG_CLIPBOARD_TOOL` 强制 | `vim.opt.clipboard = 'unnamedplus'`——由 Neovim 自己挑 helper | 生成时若在 `site/pack/*/start` 下发现 Everforest 则启用，否则用终端调色板 |
| headless | 无显示会话（SSH/VPS），或 `RIG_CLIPBOARD_TOOL=none` | 单向 OSC 52 provider | 终端调色板 |

Everforest 只在桌面环境下且生成时检测到才启用——配置不会在运行时再去扫描插件目录，也没有手工映射的 ANSI 调色板或 `NVIM_BACKGROUND` 文件。

### 无头剪贴板

yank 经 OSC 52 直达本地终端，可穿透 SSH 与 tmux（tmux 内需要 `set -g set-clipboard on`——rig 的 tmux 基线已写入，脚本也会在主机 tmux 配置缺少该项时提醒）。put 直接返回最近一次 yank，不会向终端发起询问——后者会让每次 `p` 都阻塞或弹提示。

- **nvim >= 0.10**：provider 基于 `require('vim.ui.clipboard.osc52')`，copy 被包了一层以记住最近一次 yank。
- **nvim 0.9**：没有 OSC 52 模块，转义序列改用 `base64(1)` 构造并写入 `v:stderr`（即终端）。

## 默认 init.lua 要点

- Leader = `<Space>`；4 空格缩进、`expandtab`；`scrolloff=4`；分屏向右/向下。
- `ignorecase`+`smartcase` 搜索、持久化 undo、`<F2>` 切换行号。
- `mouse = ''` —— 选择与复制交给终端模拟器（Ghostty/Konsole 风格）。

## 创建/修改的文件

| 文件 | 操作 |
|------|------|
| `~/.config/nvim/init.lua` | 缺失时创建；已有配置弹出 diff 菜单（保留/覆盖/diff），写入前自动备份到 `~/.local/share/rig/backups/user/` |
| `~/.local/bin/nvim` | 软链，仅静态包兜底路径 |
| `~/.local/share/nvim-static/` | 静态包内容，仅兜底路径 |
| `/usr/bin/editor`、`/usr/bin/vi` | `update-alternatives` 目标（Debian 系、系统级 nvim、免密 sudo 时适用） |
| `~/.zshrc`、`~/.bashrc` | 编辑器导出项仅在 `y/N` 确认 + 备份后追加 |

## 重复运行行为

幂等：版本合格的 nvim 跳过安装，与基线一致的 `init.lua` 保持不变。把配置搬到另一台机器、或 Neovim 升级跨过 0.10 之后请重跑——生成的文件是针对当初那台主机的。

`rig update`（或 `update.sh`）照常升级发行版包；当 `~/.local/bin/nvim` 是 rig 托管的静态构建时改为重新拉取最新 release。`rig uninstall` 仅在包确实由包管理器安装时才移除它，会清掉静态构建与软链，并提示 `~/.zshrc`/`~/.bashrc` 中的编辑器导出项被保留。

## 依赖

- `sudo` 用于包安装与 `update-alternatives`（不可用时跳过）。
- `curl` + `tar` 仅用于静态包兜底。
