# install.sh

一站式交互或非交互安装器。下载并按依赖顺序执行各个安装脚本。

## 概述

`install.sh` 是一个调度器，提供 TUI 复选框菜单选择组件、解析依赖、收集 API 密钥、从 GitHub 下载所需的 `setup-*.sh` 脚本并按序执行。它本身不包含安装逻辑 — 每个组件的逻辑在各自的脚本中。

**操作系统支持：** 适用于 Debian/Ubuntu (apt)、CentOS/RHEL (yum/dnf)、Fedora (dnf)、Arch Linux (pacman) 和 macOS (brew)。安装器自动检测操作系统并使用相应的包管理器。

## 模式

### 交互式 TUI

有终端且未使用 `--all`/`--components` 时，显示复选框菜单：

```
  > [x] Shell Environment        zsh + Starship, no Oh My Zsh                [sudo]
    [ ] Tmux                     tmux + Catppuccin + TPM plugins              [sudo]
    [x] Node.js (nvm)            nvm + Node.js 24
    ...
```

操作：`↑↓` 导航、`Space` 切换、`a` 全选/全不选、`Enter` 确认、`q` 退出。

### 非交互式

- `--all` — 选择全部组件。
- `--components shell,containers,node` — 按 ID 选择指定组件。

通过管道（`curl | bash`）、无标志、且未配置 `RIG_COMPONENTS` 时，脚本会退出并给出用法提示。

### 从配置文件读取

`~/.config/rig/config` 中声明的组件列表，会在命令行未指定选择时作为默认选择：

```bash
# ~/.config/rig/config
RIG_COMPONENTS="
shell
tmux
git
containers
"
```

此时裸执行 `rig install` 就会非交互地精确安装这些组件。值也可以写成单行 —— 逗号、空格和换行都算分隔符。命令行上的 `--all`、`--components`、`--preset` 优先级更高。

该文件是**解析**的，不会被 source，且只读取这几个键：`RIG_COMPONENTS`、`RIG_PROFILE`、`RIG_CONTAINER_ENGINE`、`RIG_CONTAINER_MODE`。同名环境变量可在单次运行时覆盖它。

## 执行流程

1. **解析参数** — `--all`、`--components`、`--gh-proxy`、`--verbose`。
2. **显示 TUI**（交互）或验证选择（非交互）。
3. **解析依赖** — 自动添加注册表中声明的缺失依赖。目前没有组件声明依赖，机制保留给未来的组件。
4. **展示计划** — 按安装顺序列出组件，带标签（`sudo`、`key`、`install only`）。
5. **收集凭据** — 需要令牌的组件（目前只有 Tailscale）会在交互模式下提示输入（用 `*` 遮掩）；非交互模式下读取环境变量。缺失则标记为「仅安装」。
6. **缓存 sudo** — 如有组件需要 sudo，预先认证并在后台保持活跃。
7. **下载脚本** — 将所需的 `setup-*.sh` 下载到临时目录（快速失败：所有下载必须成功才开始执行）。
8. **执行** — 按序运行。默认显示 spinner，`--verbose` 模式显示原始输出。
9. **汇总** — 带颜色的通过/失败报告，附安装后提示。

## 依赖解析

注册表中带有每组件的依赖列表（`COMP_DEPS`），依赖会自动添加并优先安装。**目前没有任何组件声明依赖**，因此当前不会自动添加任何东西。

安装顺序按组件注册表的数组索引排列。

## 凭据处理

只有 Tailscale 需要凭据（auth key，仅令牌）：

- **有环境变量**（`TAILSCALE_AUTH_KEY`）— 安装并自动连接。
- **无环境变量** — 交互模式下提示输入（用 `*` 遮掩）；留空则标记「仅安装」。
- **仅安装** — 安装工具但不配置。汇总中会提示需要设置的环境变量。

## 错误处理

- `install.sh` 使用 `set -uo pipefail`（**没有** `-e`），某个组件失败不会中断其余组件。
- 每个子脚本在独立的 `bash` 子进程中运行，使用 `set -euo pipefail`。
- 失败时显示日志最后 15 行，并给出完整日志路径。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `GH_PROXY` | _（空）_ | GitHub 代理 URL 前缀 |
| `TAILSCALE_AUTH_KEY` | _（空）_ | Tailscale 自动连接的 auth key |

各脚本自身的环境变量同样生效（如 `NODE_VERSION`、`DOCKER_MIRROR`）。

## 创建的文件

| 文件 | 说明 |
|------|------|
| `/tmp/rig-install-*` | 下载脚本的临时目录（退出时清理） |
| `/tmp/rig-install-*.component` | 各组件的日志文件（失败时保留） |
