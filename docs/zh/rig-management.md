# Rig 管理

[English](../rig-management.md)

初始安装之后的管理工具 — 预设、状态检查、配置导出/导入和安全卸载。

## 操作系统支持

所有管理工具适用于所有支持的平台（Debian/Ubuntu、CentOS/RHEL、Fedora、Arch Linux 和 macOS）。工具自动检测您的操作系统并使用相应的包管理器。

## 概述

除了 `install.sh` 和 `update.sh`，rig 还提供 CLI 包装器（`rig`）和多个管理脚本：

| 命令 | 脚本 | 说明 |
|------|------|------|
| `rig install` | `install.sh` | 安装组件（现支持 `--preset`） |
| `rig apply --profile NAME` | `install.sh --preset NAME` | 应用主机 Profile（加 `--dry-run` 仅预览） |
| `rig update` | `update.sh` | 更新已安装组件 |
| `rig status` | `status.sh` | 显示已安装组件、版本、配置状态 |
| `rig security` | `setup-security.sh` | 安全基线加固与端口审计（`rig security status` 查看报告） |
| `rig doctor` | `status.sh --doctor` | 一键健康与安全诊断报告 |
| `rig export` | `export-config.sh` | 导出配置为 JSON + 密钥文件 |
| `rig import` | `import-config.sh` | 从导出文件导入配置 |
| `rig uninstall` | `uninstall.sh` | 安全卸载组件 |
| `rig version` | — | 打印 rig 版本 |
| `rig help` | — | 显示用法信息 |

`rig` CLI 在安装过程中被安装到 `~/.local/bin/rig`。每个子命令从 GitHub 下载并执行对应脚本（如设置了 `GH_PROXY` 则通过代理下载）。

## 预设系统

预设是针对常见使用场景的预定义组件组合。无需逐个选择组件，选择一个匹配你工作流的预设即可。

### 可用预设

| 预设 | 组件 | 适用场景 |
|------|------|----------|
| `minimal` | shell、tools、git | 轻量级基础环境 |
| `agent` | shell、tools、git、node | Shell + 工具链 + Node.js 运行时 |
| `devops` | shell、tools、git、node、containers、tailscale、ssh | 服务器和基础设施运维 |
| `vps` | shell、git、tools、neovim、containers、tailscale、ssh、security | 生产 VPS 完整运维与安全加固基线 |
| `fullstack` | shell、tmux、git、tools、node、uv、containers、ssh | 全栈开发全家桶 |

### 用法

```bash
# 使用预设安装（交互式 — 确认后执行）
rig install --preset agent

# 使用预设安装（通过 curl 非交互式）
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --preset minimal

# 配合代理使用
rig install --preset devops --gh-proxy https://gh-proxy.org
```

预设设置初始组件选择。交互模式下 TUI 仍会出现，你可以在确认前增减组件。非交互模式（`curl | bash`）下直接使用预设选择。

注册表中声明的依赖会自动解析。目前没有组件声明依赖。

## CLI 命令

### rig install

交互式、按预设或按组件列表安装。

```bash
rig install                          # 交互式 TUI
rig install --preset agent           # 预设选择
rig install --components shell,node  # 指定组件
rig install --all                    # 全部安装
```

支持 `install.sh` 的所有标志：`--gh-proxy`、`--verbose`、`--all`、`--components`、`--preset`。

### rig update

更新已安装组件。详见 [setup-update.md](setup-update.md)。

```bash
rig update                           # 交互式 — 从已安装中选择
rig update --all                     # 更新所有已安装组件
rig update --components containers,node  # 更新指定组件
```

### rig status

以表格显示所有组件的安装状态、版本和配置状态。

```bash
rig status
```

输出示例：

```
Component               Status    Version              Config
─────────────────────────────────────────────────────────────────
Shell Environment       ✔         zsh 5.9               configured
Tmux                    ✘         —                      —
Git                     ✔         2.43.0                 configured
Essential Tools         ✔         rg 14.1 / jq 1.7      configured
Node.js (nvm)           ✔         v24.1.0                configured
```

状态符号：

| 符号 | 含义 |
|------|------|
| `✔` | 已安装并检测到 |
| `◐` | 部分安装（有二进制文件，未配置） |
| `✘` | 未安装 |

### rig export

将当前 rig 配置导出为可移植文件。

```bash
rig export
```

在 `~/.rig/` 中创建两个文件：

- `rig-config.json` — 组件列表和非敏感配置
- `secrets.env` — API 密钥和敏感信息（chmod 600）

详见[导出/导入工作流](#导出导入工作流)。

### rig import

从导出文件导入配置。

```bash
rig import ~/.rig/rig-config.json
```

读取 JSON 配置，如有 `secrets.env` 则自动加载，展示安装计划后使用相应的组件和环境变量运行 `install.sh`。

### rig uninstall

带依赖检查和配置备份的组件卸载。

```bash
rig uninstall containers         # 卸载容器后端（带安全检查）
rig uninstall containers --force # 跳过依赖检查
```

详见[卸载安全机制](#卸载安全机制)。

### rig version

打印 rig 版本。

```bash
rig version
```

### rig help

显示用法信息和可用命令。

```bash
rig help
```

## 导出/导入工作流

导出和导入功能允许你捕获 rig 配置并在另一台机器上复现。

### 导出内容

**非敏感配置**（`rig-config.json`）：

- 已安装组件列表
- Git 用户名和邮箱
- Node.js 版本
- 容器引擎与镜像源
- Go 版本
- 组件特定设置

**敏感数据**（`secrets.env`）：

- `TAILSCALE_AUTH_KEY`

### JSON 格式

`rig-config.json` 包含 rig 状态的结构化表示：

```json
{
  "version": "1",
  "exported_at": "2025-05-14T12:00:00Z",
  "components": ["shell", "tools", "git", "node", "containers"],
  "config": {
    "git_user": "Your Name",
    "git_email": "you@example.com",
    "node_version": "24",
    "containers_engine": "podman"
  }
}
```

### secrets.env 格式

`secrets.env` 使用标准 shell 变量语法：

```bash
TAILSCALE_AUTH_KEY=tskey-auth-xxxxx
```

### 安全注意事项

- `secrets.env` 以 `chmod 600` 创建（仅所有者可读写）。
- 在 `~/.rig/` 中自动生成 `.gitignore` 防止意外提交：
  ```
  secrets.env
  ```
- 导出脚本会打印关于 `secrets.env` 中敏感数据的警告。
- 通过安全通道传输 `secrets.env`（scp、加密通讯）。不要将其提交到版本控制。

### 团队配置示例

在团队间共享 rig 配置：

```bash
# 在源机器上 — 导出配置
rig export

# 配置文件可安全提交到版本控制
cp ~/.rig/rig-config.json /path/to/team-repo/rig-config.json

# 密钥文件需单独传输（切勿提交）
scp ~/.rig/secrets.env user@new-machine:~/.rig/secrets.env

# 在目标机器上 — 导入并安装
rig import /path/to/team-repo/rig-config.json
```

导入脚本自动从 JSON 配置同目录或 `~/.rig/secrets.env` 加载 `secrets.env`。

## 卸载安全机制

卸载系统通过依赖检查、配置备份和数据保留提示防止意外损坏。

### 依赖检查

卸载组件前，`uninstall.sh` 检查是否有其他已安装组件依赖它：

```bash
$ rig uninstall docker
Error: Cannot uninstall Docker — the following components depend on it:
  - some-future-component

Use --force to override dependency checks.
```

### 配置备份

Rig 创建的备份统一保存在 `~/.local/share/rig/backups/`，不会在用户主目录或 `/etc` 的原文件旁散落：

| 组件 | 备份来源 |
|------|----------|
| Shell | 无 —— 它从不写你的 `~/.zshrc` 或 `starship.toml` |
| Tmux | `~/.tmux.conf` |
| Git | `~/.gitconfig` |
| SSH | `/etc/ssh/sshd_config` |

用户配置进入 `backups/user/`，需要 sudo 读取的系统配置进入 `backups/system/`，两者最终都归当前用户所有。备份在卸载后保留，不会自动清理；旧版散落的 `.bak.*` / `.rig-backup` 仍可用于恢复。

### 数据保留提示

对于包含用户数据的组件，卸载脚本会在删除前询问：

```
Docker has local data:
  - Volumes in /var/lib/docker
  - Container images

Delete all Docker data? [y/N]
```

回答 `N`（默认）会卸载 Docker 包但保留磁盘上的数据。

### 强制模式

`--force` 标志跳过依赖检查，但仍执行配置备份和数据提示：

```bash
rig uninstall node --force    # 即使有依赖组件也卸载 Node.js
```

## 示例

### 使用预设快速开始

为 AI 编码代理工作配置一台机器：

```bash
# 安装 rig CLI
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --preset agent

# 验证安装结果
rig status
```

### 在预设基础上自定义

从 `minimal` 开始，逐步添加组件：

```bash
# 从最小基础开始
rig install --preset minimal

# 之后添加容器和 Python 工具链
rig install --components containers,uv
```

已安装的组件会自动跳过 — `install.sh` 是幂等的。

### 为团队导出配置

```bash
# 导出当前配置
rig export

# JSON 配置文件可安全提交到版本控制
cat ~/.rig/rig-config.json

# 团队成员在新机器上导入
#（通过安全通道接收 secrets.env 后）
rig import rig-config.json
```

### 安全卸载组件

```bash
# 先查看已安装内容
rig status

# 卸载组件（带安全检查）
rig uninstall containers

# 需要时强制卸载
rig uninstall node --force

# 验证结果
rig status
```
