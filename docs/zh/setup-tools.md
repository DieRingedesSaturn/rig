# setup-tools.sh

安装编码代理日常依赖的核心 CLI 工具 — 快速代码搜索、JSON 处理、GitHub CLI、编译工具等。

## 操作系统特定包名

脚本自动检测您的操作系统并安装相应的包：

| 工具 | Debian/Ubuntu | CentOS/RHEL/Fedora | Arch Linux | macOS (Homebrew) |
|------|---------------|-------------------|------------|------------------|
| ripgrep | `ripgrep` | `ripgrep` | `ripgrep` | `ripgrep` |
| jq | `jq` | `jq` | `jq` | `jq` |
| fd | `fd-find` → 符号链接到 `fd` | `fd-find` | `fd` | `fd` |
| bat | `bat` → 符号链接到 `batcat` | `bat` | `bat` | `bat` |
| tree | `tree` | `tree` | `tree` | `tree` |
| gh | `gh` (通过 GitHub apt 仓库) | `gh` | `github-cli` | `gh` |
| shellcheck | `shellcheck` | `ShellCheck` | `shellcheck` | `shellcheck` |
| 编译工具 | `build-essential` (gcc, g++, make) | `gcc`, `gcc-c++`, `make` | `base-devel` | Xcode Command Line Tools |
| wget | `wget` | `wget` | `wget` | `wget` |
| unzip | `unzip` | `unzip` | `unzip` | `unzip` |
| fastfetch | `fastfetch` | `fastfetch` | `fastfetch` | `fastfetch` |
| 剪贴板 | `xclip` | `xclip` | `xclip` | `pbcopy` (内置) |

**注意事项：**
- Debian/Ubuntu 上，`fd-find` 和 `bat` 会在 `~/.local/bin/` 中创建符号链接到 `fd` 和 `bat`
- macOS 上，Xcode Command Line Tools 会在不存在时自动安装
- macOS 使用内置的 `pbcopy`/`pbpaste` 命令代替 `xclip`

## 安装内容

| 二进制 | 用途 |
|--------|------|
| `rg` | 快速代码搜索 |
| `jq` | JSON 处理 |
| `fd` | 快速文件查找 |
| `bat` | 语法高亮的 cat |
| `tree` | 目录结构可视化 |
| `gh` | GitHub CLI（PR、Issue、API） |
| `shellcheck` | Shell 脚本静态检查 |
| `gcc`, `g++`, `make` | 原生 npm 模块编译 |
| `wget` | HTTP 下载 |
| `unzip` | 解压缩 |
| `fastfetch` | 快速现代化系统信息展示 |

## 执行方式

### 步骤 1：apt 包

通过 `apt-get install -y` 安装所有包。apt 天然幂等 — 已安装的包会自动跳过。

### 步骤 2：GitHub CLI

`gh` CLI 需要添加 GitHub 官方 apt 仓库：

```bash
# 添加 GitHub apt 仓库密钥和源列表
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/...
echo "deb [...] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/...
sudo apt-get install -y gh
```

如果 `gh` 已安装，此步骤完全跳过。

### 步骤 3：便捷符号链接

在 Debian/Ubuntu 上，`fd-find` 安装为 `fdfind`，`bat` 安装为 `batcat`（避免名称冲突）。脚本在 `~/.local/bin/` 创建符号链接：

- `~/.local/bin/fd` → `/usr/bin/fdfind`
- `~/.local/bin/bat` → `/usr/bin/batcat`

仅在规范名称（`fd`、`bat`）尚不可用时才创建符号链接。

## 重复运行行为

脚本完全幂等：

- `apt-get install` 对已安装的包天然幂等。
- 如果 `gh` 命令已存在，跳过安装。
- 仅在目标名称尚不可用时才创建符号链接。

## 依赖

无。此组件不依赖其他 rig 组件。

## 环境变量

无需配置。脚本仅使用系统 apt 仓库和 GitHub 官方 apt 仓库。

## 创建的文件

| 文件 | 说明 |
|------|------|
| `~/.local/bin/bat` | 指向 `batcat` 的符号链接（如需要） |
| `~/.local/bin/fd` | 指向 `fdfind` 的符号链接（如需要） |
| `/etc/apt/keyrings/githubcli-archive-keyring.gpg` | GitHub CLI apt 签名密钥 |
| `/etc/apt/sources.list.d/github-cli.list` | GitHub CLI apt 仓库 |

## 剪贴板工具

`xclip` 是 X11 程序：在 Wayland 上或没有显示器的服务器上它什么都做不了。无条件安装它、或者在状态检查里期待它，会让**配置完全正确的机器**永远显示一个缺口。所以这个工具由会话推导：

| 会话 | 工具 | 包 |
|------|------|-----|
| macOS | `pbcopy` | 系统自带 |
| Wayland（设置了 `WAYLAND_DISPLAY`） | `wl-copy` | `wl-clipboard` |
| X11（设置了 `DISPLAY`，非 Wayland） | `xclip` | `xclip` |
| 无头 —— 无显示服务器 | 无 | 不安装 |

Wayland 的检测**先于** X11，因为 Wayland 会话通常仍会为 XWayland 导出 `DISPLAY`；先查 `DISPLAY` 会在 Wayland 桌面上错误地选中 `xclip`。

特殊场景可覆盖：

```bash
RIG_CLIPBOARD_TOOL=auto      # 默认：自动检测
RIG_CLIPBOARD_TOOL=xclip     # 强制
RIG_CLIPBOARD_TOOL=none      # 从不安装
```

`status.sh` 使用同一套检测，因此只会期待当前会话真正适用的那个工具。

## 安装后

验证所有工具可用：

```bash
command -v rg jq fd bat tree gh shellcheck gcc wget unzip
# 再加上你当前会话的剪贴板工具（如果有）：
command -v wl-copy   # Wayland
command -v xclip     # X11
```
