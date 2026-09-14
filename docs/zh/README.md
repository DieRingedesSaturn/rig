# 文档

[English](../README.md)

每个脚本的详细文档。快速上手请查看[主 README](../../README_CN.md)。

## 操作系统兼容性

所有脚本自动检测操作系统并使用适当的包管理器：

| 组件 | Debian/Ubuntu | CentOS/RHEL | Fedora | Arch Linux | macOS |
|------|---------------|-------------|--------|------------|-------|
| Shell (zsh, Starship, 插件) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Tmux（环境感知剪贴板） | ✓ | ✓ | ✓ | ✓ | ✓ |
| Git | ✓ | ✓ | ✓ | ✓ | ✓ |
| 基础工具 | ✓ | ✓ | ✓ | ✓ | ✓ |
| Neovim（现代单文件配置） | ✓ | ✓ | ✓ | ✓ | ✓ |
| Containers（Podman / Docker） | ✓ | ✓ | ✓ | ✓ | ✓（Podman VM 或 Docker Desktop） |
| Tailscale | ✓ | ✓ | ✓ | ✓ | ✓ |
| SSH（OpenSSH 服务与客户端） | ✓ | ✓ | ✓ | ✓ | ✓ (Remote Login) |
| Security（防失联与防火墙基线） | ✓ | ✓ | ✓ | ✓ | —（仅 Linux 支持 ufw/firewalld） |
| Node.js (nvm) | ✓ | ✓ | ✓ | ✓ | ✓ |
| uv + Python | ✓ | ✓ | ✓ | ✓ | ✓ |

**注意事项：**
- Containers 在 Fedora/Arch 上默认 Podman，在 Debian/RHEL 上默认 Docker；见 [setup-containers.md](setup-containers.md)
- macOS 上的 SSH 配置 Remote Login 而非通过 systemd 配置 OpenSSH 服务器

## 脚本列表

### 基础环境

| 脚本 | 说明 |
|------|------|
| [install.sh](install.md) | 一站式交互/非交互安装器 |
| [setup-shell.sh](setup-shell.md) | zsh + Starship + 插件（无框架） |
| [setup-tmux.sh](setup-tmux.md) | tmux + 鼠标 + 回滚缓冲（带 Diff 对比与交互决策） |
| [setup-git.sh](setup-git.md) | Git 用户身份 + 合理默认值 |
| [setup-tools.sh](setup-tools.md) | 常用 CLI 基础工具链（rg, jq, fd, bat, gh 等） |
| [setup-neovim.sh](../../setup-neovim.sh) | Neovim >= 0.9 现代配置与默认编辑器 |
| [setup-containers.sh](setup-containers.md) | Podman 或 Docker 后端，默认 rootless |
| [setup-tailscale.sh](setup-tailscale.md) | Tailscale VPN 组网 |
| [setup-ssh.sh](setup-ssh.md) | OpenSSH 服务安装、端口与公私钥导入 |
| [setup-security.sh](../../setup-security.sh) | 安全加固核心（防 Lockout、防火墙、端口双层审计） |

### 语言环境

| 脚本 | 说明 |
|------|------|
| [setup-node.sh](setup-node.md) | nvm + Node.js |
| [setup-uv.sh](setup-uv.md) | uv 包管理器 + Python |

### 管理工具

| 脚本 | 说明 |
|------|------|
| [rig](rig-management.md) | CLI 包装器 — 预设、状态、导出/导入、卸载 |
| [update.sh](setup-update.md) | 更新已安装组件 |
| [status.sh](rig-management.md#rig-status) | 显示已安装组件和版本 |
| [export-config.sh](rig-management.md#rig-export) | 导出配置为 JSON + 密钥文件 |
| [import-config.sh](rig-management.md#rig-import) | 从导出文件导入配置 |
| [uninstall.sh](rig-management.md#rig-uninstall) | 安全卸载组件 |

## 设计原则

所有脚本遵循以下约定：

- **幂等** — 可安全重复运行。已安装的组件自动跳过，变更的配置自动更新。
- **独立** — 每个脚本可通过 `curl | bash` 独立运行。
- **可配置** — 通过环境变量或命令行参数控制行为。
- **安全** — API 密钥通过环境变量传递（非命令行参数），配置文件权限设为 `chmod 600`。
- **快速失败** — `set -euo pipefail` 尽早捕获错误。
