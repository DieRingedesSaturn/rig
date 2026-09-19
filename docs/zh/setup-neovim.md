# setup-neovim.sh

安装 Neovim（确保 >= 0.9）并写入零依赖、面向终端原生配色的 `init.lua`。在可用时通过 `update-alternatives` 设置默认编辑器。

**不可协商契约：** `~/.config/nvim/init.lua` 缺失时创建；已有配置仅在交互确认（保留/覆盖/追加/看 diff）后才可替换，且先自动备份——绝不静默覆盖。

## 安装内容

| 组件 | 方式 | 说明 |
|------|------|------|
| Neovim | 包管理器（`apt`/`dnf`/`pacman`/`brew`） | 要求 >= 0.9 |
| Neovim（兜底） | 官方静态包 → `~/.local/share/nvim-static`，软链到 `~/.local/bin` | 仅 Linux x86_64，发行版仓库版本 < 0.9 或安装失败时启用 |

## 配置内容

| 项目 | 说明 |
|------|------|
| 系统编辑器 | `update-alternatives --set editor/vi` → nvim（nvim 位于 `$HOME` 下或 sudo 不可用时跳过） |
| rc 文件 | 若 `~/.zshrc`/`~/.bashrc` 缺 `EDITOR="nvim"`，在显式 `y/N` 确认后追加导出项并先备份；无 TTY 时仅打印 |
| `init.lua` | 缺失时写入；已存在则展示 diff 并提供 保留/覆盖/追加 菜单 |

## 默认 init.lua 要点

- Leader = `<Space>`；4 空格缩进、`expandtab`、smart/auto indent；`scrolloff=4`；分屏向右/向下。
- `ignorecase`+`smartcase` 搜索、持久化 undo、无 swap/backup、`<F2>` 切换行号。
- **配色**：本地（非 SSH）会话在已安装 `site/pack/plugins/start/everforest` 时使用 Everforest，并读取 `NVIM_BACKGROUND` / `~/.local/state/nvim/background`。SSH 会话或未安装时回退到手工映射的 ANSI 调色板方案（关闭 termguicolors，零依赖）。
- **剪贴板**：本地 Wayland 且有 `wl-copy` 时启用 `unnamedplus`；远程/无头环境使用 OSC 52——nvim ≥ 0.10 用内置 provider（可视模式 `"+y`），更老版本（如 Debian 源的 0.7.x）用 `TextYankPost` 回退直接向 `/dev/tty` 写 OSC 52 转义。tmux 内回退需要 `set-clipboard on`（rig 的 tmux 基线已带）。
- `mouse = ''` —— 选择与复制交给终端模拟器（Ghostty/Konsole 风格）。

## 创建/修改的文件

| 文件 | 操作 |
|------|------|
| `~/.config/nvim/init.lua` | 缺失时创建；已有配置弹出 diff 菜单，覆盖/追加前自动备份到 `~/.local/share/rig/backups/user/` |
| `~/.local/bin/nvim` | 软链，仅静态包兜底路径 |
| `~/.local/share/nvim-static/` | 静态包内容，仅兜底路径 |
| `/usr/bin/editor`、`/usr/bin/vi` | `update-alternatives` 目标（适用时） |
| `~/.zshrc`、`~/.bashrc` | 编辑器导出项仅在 `y/N` 确认 + 备份后追加 |

## 重复运行行为

完全幂等：版本合格的 nvim 跳过安装，已存在的 `init.lua` 保持不变，`update-alternatives` 重复执行无副作用。

## 依赖

- `sudo` 用于包安装与 `update-alternatives`（不可用时跳过）。
- `curl` + `tar` 仅用于静态包兜底。
