# rig

[English](README.md)

Linux 和 macOS 自动化配置与轻量级 VPS 主机状态管理器 (Personal Server Baseline Manager)。

### 这个程序具体会做什么？

1. **扫描与审计系统现状 (Detect & Audit)**
   - **端口暴露与容器审计**：执行 `ss -lntup` 扫描所有实际监听的 TCP/UDP 端口与绑定 IP，精确区分 `127.0.0.1`（本地内网）与 `0.0.0.0`（公网暴露），对比防火墙白名单，实时告警未声明却向公网暴露的 Docker/系统服务（防范 Docker 端口映射绕过 UFW 的隐患）；
   - **安全基线体检**：检查是否存在非 root 管理员账号、是否具备 `sudo` 提权权限、`~/.ssh/authorized_keys` 是否有有效公钥，以及当前 `sshd_config` 中的 `PermitRootLogin` 与 `PasswordAuthentication` 状态；
   - **运行环境冲突排查**：在部署 Node 前先排查系统自带的 `node`/`npm`，避免与 nvm 产生同版本或全局包路径冲突；自动检测发行版命令别名（如 Debian 的 `fdfind`、`batcat` 并创建软链接）。

2. **安装核心软件包 (Install Packages)**
   - **终端与基础环境**：通过系统原生包管理器（apt/dnf/pacman/brew）安装 `zsh`、`starship`、`tmux`、`git`、`neovim` (>= 0.9) 以及 zsh-autosuggestions、zsh-syntax-highlighting 插件；
   - **日常 CLI 工具链**：安装 `ripgrep` (`rg`)、`jq`、`fd`、`bat`、`gh` (GitHub CLI)、`tree`、`shellcheck`、`curl`、`wget`、`unzip` 和构建工具（gcc/make/build-essential）；
   - **开发运行态与容器**：安装 `nvm` 并拉取 Node.js LTS (v24)、安装 Python `uv` 包管理器；安装并配置 `docker-ce`（支持 rootless 用户态模式）或 `podman`；
   - **组网与服务**：安装 `tailscale` 异地组网客户端、`openssh-server`，以及对应发行版的防火墙管理工具（Debian/Ubuntu 安装 `ufw`，Fedora/RHEL 安装 `firewalld`）。

3. **写入与调整配置文件 (Config & Hardening)**
   - **`/etc/ssh/sshd_config`**：在通过 `sshd -t` 语法预检的前提下，写入 `PermitRootLogin no`、`PasswordAuthentication no`、`PubkeyAuthentication yes`；
   - **防火墙策略**：配置默认入站拒绝（`deny incoming`）、出站允许（`allow outgoing`），先放行 SSH 端口（限定 `tailscale0`，firewalld 使用独立的接口区域），再放行声明的业务端口（如 `80/tcp`, `443/tcp`）；
   - **用户级配置文件**：
     - `~/.config/nvim/init.lua`：写入零插件依赖的现代单文件 Lua 配置（Everforest 终端 16 色调色、本地与远程 OSC 52 剪贴板自适应），并将系统默认编辑器（`EDITOR`, `VISUAL`, `SUDO_EDITOR`, `update-alternatives`）设为 `nvim`，配置 `alias vim=nvim`；
     - `~/.config/starship.toml`：写入简洁现代的终端提示符配置（Git 仓库路径锚定防超长、第一行尾随时间戳 `[HH:MM]`、感知 Python 虚拟环境与 Node.js 状态）；
     - `~/.tmux.conf`：配置鼠标滚轮、大行数回滚缓冲，并自动适配系统剪贴板（Wayland 用 `wl-copy`、X11 用 `xclip`、macOS 用 `pbcopy`、无头服务器使用 OSC 52）；
     - `~/.gitconfig`：配置默认分支 `init.defaultBranch=main`、`pull.rebase=true` 及用户名和邮箱；
     - `~/.ssh/config`：设置 `SSH_PROXY_PORT` 时注入 `Host github.com` 块，让 git SSH 经 `ssh.github.com:443` + `corkscrew`；
     - `~/.config/rig/config`：持久化当前机器的组件清单与 Profile（如 `vps` 预设）。

4. **安全底线与非侵入约束 (Safety Guarantees)**
   - **绝不盲目覆盖用户配置**：若 `~/.zshrc`、`~/.config/starship.toml`、`~/.config/nvim` 已经存在，脚本仅做只读检查，绝不强制覆写；`setup-tmux.sh` 则提供彩色 Unified Diff 比对与交互式决策（支持保留原有 [Keep]、备份后覆盖 [Overwrite] 或追加 [Append]），杜绝任何暴力覆盖；
   - **防失联硬性门禁 (Anti-Lockout)**：若未检测到具备 sudo 权限且拥有可用 SSH Key 的非 root 管理员，**程序硬性拒绝禁用 root 和密码登录**；
   - **数据资产防误删**：卸载时默认保护 `~/.nvm`（防止多版本 Node 与全局 npm 包丢失）及 `~/.ssh/` 密钥。

## 支持的操作系统

| 操作系统 | 包管理器 | 状态 |
|---------|---------|------|
| Debian/Ubuntu | `apt` | ✓ 完全支持 |
| CentOS/RHEL | `yum`/`dnf` | ✓ 完全支持 |
| Fedora | `dnf` | ✓ 完全支持 |
| Arch Linux | `pacman` | ✓ 完全支持 |
| macOS | `brew` | ✓ 完全支持（见 [macOS 注意事项](#macos-注意事项)） |

> 所有脚本均支持**重复运行** — 已安装的组件会自动跳过，配置变更时自动更新。需要 `curl`、`git` 和 `sudo`（部分 macOS 操作除外）。

## 快速开始

使用 `install.sh` 进行一站式交互或非交互安装。

> **注意：** 安装完成后，`rig` CLI 会自动安装到 `~/.local/bin/rig`。之后可以使用 `rig status`、`rig security status`、`rig doctor`、`rig export`、`rig uninstall` 等命令。详见 [管理工具文档](docs/zh/rig-management.md)。

<p align="center">
  <img src="assets/demo.gif" alt="install.sh 演示" width="700">
</p>

交互式 TUI — 选择要安装的组件：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash
```

通过代理（推荐国内用户）：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --gh-proxy https://gh-proxy.org
```

> **💡 国内用户：** 这里所有下载都支持 `--gh-proxy` / `GH_PROXY`。设置一次，后续脚本都不用再加。

非交互式安装全部：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --all
```

指定组件：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --components shell,tools,neovim,containers,security
```

详细模式（显示原始脚本输出而非 spinner）：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --all --verbose
```

可用组件：`shell`、`tmux`、`git`、`tools`、`neovim`、`node`、`uv`、`containers`、`tailscale`、`ssh`、`security`

**新功能：** 使用预设快速安装常用配置：
```bash
# VPS 运维安全基线 (shell, git, tools, neovim, containers, tailscale, ssh, security)
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --preset vps

# 只预览该 Profile，不修改本机
rig apply --profile vps --dry-run

# 查看所有预设：minimal（最小化）、agent（智能体）、devops（运维）、vps（安全基线）、fullstack（全栈）
# 文档：https://github.com/DieRingedesSaturn/rig/blob/master/docs/zh/rig-management.md
```

## 组件详解

每个脚本也可以单独运行，支持直连和代理两种方式：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/<script> | bash
```

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/<script> | bash
```

---

### 基础环境

#### Shell 环境 (`setup-shell.sh`)

安装 zsh、[Starship](https://starship.rs/) 和 autosuggestions + syntax-highlighting 两个插件——全部来自发行版包管理器。没有 Oh My Zsh、没有框架、不做 git clone。

Linux 下需要 `sudo`（装包用）。

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-shell.sh | bash
```

通过代理：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-shell.sh | bash
```

**这个组件绝不修改不是它自己创建的文件。** `~/.zshrc` 只读不写；`~/.config/starship.toml` 仅在缺失时创建（已存在就绝不覆盖，连应用预设都不会做）；默认 shell 只做报告、不做修改。任何需要改你文件才能完成的事，都会以清单形式打印出来让你自己决定。

参考 [docs/zh/setup-shell.md](docs/zh/setup-shell.md)。

#### Tmux (`setup-tmux.sh`)

安装 [tmux](https://github.com/tmux/tmux)，并且**仅在没有任何配置存在时**写入一份最小 `~/.tmux.conf`：扩展按键、鼠标支持、大回滚缓冲，以及一个按机器实际情况选择的剪贴板绑定。没有 TPM、没有 Catppuccin、没有插件。

Linux 下需要 `sudo`。

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tmux.sh | bash
```

通过代理：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tmux.sh | bash
```

**已存在的 `~/.tmux.conf` 绝不覆盖** —— 只做读取检查，缺什么会打印成清单。剪贴板绑定随机器自适应：Wayland 用 `wl-copy`、X11 用 `xclip`、macOS 用 `pbcopy`、无头 VPS 用 OSC 52（不需要任何外部命令）。

配置项：`TMUX_MOUSE`、`TMUX_HISTORY_LIMIT` — 详见[配置速查表](#配置速查表)。

#### Git (`setup-git.sh`)

配置 Git 全局 `user.name`、`user.email` 及合理默认值（`init.defaultBranch=main`、`pull.rebase=true` 等）。

```bash
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@example.com"
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-git.sh | bash
```

配置项：`GIT_USER_NAME`、`GIT_USER_EMAIL` — 详见[配置速查表](#配置速查表)。

#### 基础工具 (`setup-tools.sh`)

安装日常 CLI 工具集：`rg`、`jq`、`fd`、`bat`、`tree`、`shellcheck`、`fastfetch`、`gh`、`wget`、`unzip`，以及构建工具（gcc/make）。

剪贴板工具由**会话检测**决定，而非写死 —— `xclip` 是 X11 程序，在 Wayland 或无头服务器上毫无作用：

| 会话 | 工具 | 包 |
|------|------|-----|
| macOS | `pbcopy` | 系统自带 |
| Wayland | `wl-copy` | `wl-clipboard` |
| X11 | `xclip` | `xclip` |
| 无头 / VPS | 无 | 不安装 |

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tools.sh | bash
```

可用 `RIG_CLIPBOARD_TOOL=auto|pbcopy|wl-copy|xclip|none` 强制指定或关闭。

配置项：`RIG_CLIPBOARD_TOOL` — 详见[配置速查表](#配置速查表)。

#### Containers (`setup-containers.sh`)

一个组件，两个可互换的后端。安装 **Podman** 或 **Docker**，选择依据来自你的配置：

| # | 来源 | 结果 |
|---|------|------|
| 1 | `RIG_CONTAINER_ENGINE` | `podman` / `docker` —— 永远最高 |
| 2 | 已安装的唯一后端 | 已有 Podman 就保留 Podman；已有 Docker 就保留 Docker |
| 3 | `RIG_PROFILE` | `desktop` → Podman，`vps` → Docker |
| 4 | OS 默认 | Fedora/Arch → Podman，Debian/RHEL → Docker |

`RIG_CONTAINER_MODE` 选择 `rootless`（默认）或 `rootful`。显式配置始终优先；自动模式把 Podman/Docker 当作二选一，不会在已有 Podman 时再自动安装 Docker。Docker rootless 缺少可用的 systemd user session 时，交互模式会让用户选择保留 Podman、改用 rootful Docker，或停止后先修复 session。

Linux 下需要 `sudo`。

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-containers.sh | bash
```

在命令行直接指定后端：

```bash
RIG_CONTAINER_ENGINE=podman RIG_CONTAINER_MODE=rootless \
  bash <(curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-containers.sh)
```

通过代理：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-containers.sh | bash
```

Podman 是 daemonless 的：一个包，没有服务需要 enable。Rootless Docker 是 `systemctl --user` 下的用户级 daemon，数据在 `~/.local/share/docker`、配置在 `~/.config/docker/daemon.json` —— 不是 `/etc/docker`。脚本会启用 linger，让它在无头 VPS 重启后依然存活。

`rig status` 只报告选中的那一个后端，例如 `Podman 5.8.4 (rootless)`。

配置项：`RIG_CONTAINER_ENGINE`、`RIG_CONTAINER_MODE`、`RIG_PROFILE`、`PODMAN_REGISTRY_MIRRORS`、`DOCKER_MIRROR`、`DOCKER_LOG_SIZE`、`DOCKER_LOG_FILES` — 详见[配置速查表](#配置速查表)。

#### Tailscale (`setup-tailscale.sh`)

安装 [Tailscale](https://tailscale.com/) VPN 组网。

仅安装：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tailscale.sh | bash
```

安装并自动连接：

```bash
export TAILSCALE_AUTH_KEY=tskey-auth-xxxxx
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tailscale.sh | bash
```

#### SSH (`setup-ssh.sh`)

配置 OpenSSH 服务器：自定义端口、密钥登录和可选的 GitHub SSH 传输代理。

仅确保 sshd 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-ssh.sh | bash
```

修改端口 + 启用密钥登录：

```bash
export SSH_PORT=2222
export SSH_PUBKEY="ssh-ed25519 AAAA..."
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-ssh.sh | bash
```

配置 GitHub SSH 传输代理——让 `git@github.com` 经本地 HTTP 代理走 `ssh.github.com:443`，用于封锁出站 SSH:22 的网络（与 `GH_PROXY` 脚本下载镜像无关）：

```bash
export SSH_PROXY_PORT=7890
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-ssh.sh | bash
```

配置项：`SSH_PORT`、`SSH_PUBKEY`、`SSH_PROXY_PORT` — 详见[配置速查表](#配置速查表)。

`setup-security.sh` 在交互终端中会分别确认 SSH 是公网访问还是仅限 Tailscale，以及除 SSH 外还要开放哪些公网 TCP 端口。默认不再自动加入 80/443；输入 `none` 可清空额外公网端口。成功应用后的选择会写入 Rig 配置。

Rig 创建的用户级和系统级配置备份统一放在 `~/.local/share/rig/backups/{user,system}/`，不会散落在原文件旁。

---

### 语言环境

#### Node.js (`setup-node.sh`)

安装 [nvm](https://github.com/nvm-sh/nvm) 和 Node.js。

默认安装 Node.js 24：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-node.sh | bash
```

指定版本：

```bash
export NODE_VERSION=22
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-node.sh | bash
```

通过代理：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-node.sh | bash
```

#### uv + Python (`setup-uv.sh`)

安装 [uv](https://docs.astral.sh/uv/) 包管理器，可选安装 Python 版本。

仅安装 uv：

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-uv.sh | bash
```

uv + Python：

```bash
export UV_PYTHON=3.12
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-uv.sh | bash
```

通过代理：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-uv.sh | bash
```

---

## 配置速查表

所有脚本的环境变量汇总。

### 通用

| 变量 | 作用域 | 默认值 | 说明 |
|------|--------|--------|------|
| `GH_PROXY` | `install.sh` | _（空）_ | 下载 rig 脚本本身的 URL 前缀镜像（如 `https://gh-proxy.org`），GitHub raw 不可达时使用 |

### Tmux

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TMUX_MOUSE` | `1` | 启用鼠标支持（设为 `0` 禁用） |
| `TMUX_HISTORY_LIMIT` | `100000` | 回滚缓冲行数 |

### Git

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `GIT_USER_NAME` | _（空）_ | `git config --global user.name` 的值 |
| `GIT_USER_EMAIL` | _（空）_ | `git config --global user.email` 的值 |

### Node.js

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `NODE_VERSION` | `24` | Node.js 主版本号（也可作为第一个参数传入） |
| `NVM_NODEJS_ORG_MIRROR` | _（空）_ | Node.js 二进制下载镜像。设置 `GH_PROXY` 时自动启用。 |
| `NPM_REGISTRY` | _（空）_ | npm registry 地址。设置 `GH_PROXY` 时自动启用。 |

### uv + Python

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `UV_PYTHON` | _（空）_ | 要安装的 Python 版本（也可作为第一个参数传入） |

### 基础工具

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RIG_CLIPBOARD_TOOL` | `auto` | 要安装的剪贴板工具：`auto`、`pbcopy`、`wl-copy`、`xclip` 或 `none` |

### Containers

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RIG_CONTAINER_ENGINE` | `auto` | `auto`、`podman` 或 `docker`。显式值优先于其他一切规则 |
| `RIG_CONTAINER_MODE` | `rootless` | `rootless` 或 `rootful` |
| `RIG_PROFILE` | _（空）_ | `desktop`（→ Podman）或 `vps`（→ Docker） |
| `PODMAN_REGISTRY_MIRRORS` | _（空）_ | Podman 的镜像加速地址，逗号分隔 |
| `DOCKER_MIRROR` | _（空）_ | Docker 的镜像加速地址，逗号分隔 |
| `DOCKER_LOG_SIZE` | `20m` | 单个日志文件最大大小（Docker） |
| `DOCKER_LOG_FILES` | `3` | 最多保留日志文件数（Docker） |

### 配置文件

`~/.config/rig/config` 存放跨命令生效的设置。它是**解析**的，不会被 source；同名环境变量可以覆盖它：

```bash
RIG_PROFILE="desktop"
RIG_CONTAINER_ENGINE="auto"
RIG_CONTAINER_MODE="rootless"

RIG_COMPONENTS="
shell
tmux
git
containers
"
```

| 键 | 说明 |
|----|------|
| `RIG_COMPONENTS` | 未指定 `--all` / `--components` / `--preset` 时，`rig install` 的默认组件列表 |
| `RIG_PROFILE` | `desktop` 或 `vps` |
| `RIG_CONTAINER_ENGINE` | `auto`、`podman` 或 `docker` |
| `RIG_CONTAINER_MODE` | `rootless` 或 `rootful` |
| `RIG_CLIPBOARD_TOOL` | `auto`、`pbcopy`、`wl-copy`、`xclip` 或 `none` |

### Tailscale

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TAILSCALE_AUTH_KEY` | _（空）_ | 自动连接的 Auth Key。留空则仅安装。 |

### SSH

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SSH_PORT` | _（空）_ | 自定义 SSH 端口。留空则不修改。 |
| `SSH_PUBKEY` | _（空）_ | 公钥字符串。设置后添加公钥至 authorized_keys（密码与账号安全加固由 security 统一执行）。 |
| `SSH_PRIVATE_KEY` | _（空）_ | 私钥内容。设置后导入到 `~/.ssh/`，用于对外 SSH 连接。 |
| `SSH_PROXY_HOST` | `127.0.0.1` | 本地 HTTP 代理主机（如 Clash）。仅在设置了 `SSH_PROXY_PORT` 时生效。 |
| `SSH_PROXY_PORT` | _（空）_ | 本地 HTTP 代理端口（如 `7890`）。让 `git@github.com` 经 corkscrew 走 `ssh.github.com:443`，用于封锁出站 SSH:22 的网络。与 `GH_PROXY` 无关。 |

## 从零开始

全新机器的完整配置流程。推荐顺序确保依赖关系正确。

**1. 代理**（后续下载更快 —— 换成你自己的代理地址）

```bash
export GH_PROXY=https://gh-proxy.org
```

**2. 一键安装**

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --all
```

或按以下顺序逐个安装：

1. `setup-shell.sh` — Shell 环境（zsh、Starship、插件，无框架）
2. `setup-tmux.sh` — Tmux + 鼠标 + 回滚缓冲（带 Diff 对比与交互决策）
3. `setup-git.sh` — Git 用户身份 + 默认值
4. `setup-tools.sh` — 核心 CLI 基础工具链（rg, jq, fd, bat, gh 等）
5. `setup-neovim.sh` — 现代轻量 Neovim 配置与默认编辑器
6. `setup-node.sh` — nvm + Node.js
7. `setup-uv.sh` — uv + Python
8. `setup-containers.sh` — Podman 或 Docker 后端
9. `setup-tailscale.sh` — Tailscale VPN 组网
10. `setup-ssh.sh` — OpenSSH 服务安装与客户端配置
11. `setup-security.sh` — 安全加固核心模块（防 Lockout、防火墙、端口审计）

## 详细文档

查看 [docs/zh/](docs/zh/) 目录获取每个脚本的详细文档 — 安装内容、创建/修改的文件、重复运行行为以及特定操作系统的注意事项。

## macOS 注意事项

macOS 支持有以下差异：

- **Containers**: macOS 上 Podman 在 Linux 虚拟机里运行容器，因此脚本只打印 `podman machine init` / `start` 命令，不会静默下载 VM 镜像。macOS 上的 Docker 指 Docker Desktop，没有 rootless 模式。
- **SSH**: 使用 macOS Remote Login 而非通过 `systemctl` 配置 OpenSSH 服务器。
- **Homebrew**: 若未安装会自动安装。脚本会自动检测并使用 `brew` 而非 `apt`/`yum`/`dnf`/`pacman`。
- **sudo**: 部分 Homebrew 操作不需要 sudo。脚本会自动处理。

## 注意事项

- Starship 需要终端支持 [Nerd Font](https://www.nerdfonts.com/) 才能正常显示图标。
- 如果 `gh-proxy.org` 不可用，可到 [ghproxy.link](https://ghproxy.link/) 查找其他可用代理。
- 携带不同的 API 密钥/配置重新运行脚本，会自动更新配置而不重复安装。
