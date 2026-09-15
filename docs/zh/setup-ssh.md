# setup-ssh.sh

配置 SSH 服务器：自定义端口、密钥登录和可选的 GitHub SSH 传输代理。

> **术语区分：** `SSH_PROXY_*` 与 `GH_PROXY` 互不相干。`SSH_PROXY_*` 让 *git 的 SSH 连接*经本地 HTTP 代理到达 github.com（用于封锁出站 SSH:22 的网络）；`GH_PROXY` 是下载 rig 脚本本身的 URL 前缀镜像（用于 raw.githubusercontent.com 不可达的网络）。

## 操作系统特定行为

| 操作系统 | SSH 服务器 | 服务管理 | 配置文件 |
|---------|-----------|---------|---------|
| Debian/Ubuntu | openssh-server | systemctl | /etc/ssh/sshd_config |
| CentOS/RHEL | openssh-server | systemctl | /etc/ssh/sshd_config |
| Fedora | openssh-server | systemctl | /etc/ssh/sshd_config |
| Arch Linux | openssh | systemctl | /etc/ssh/sshd_config |
| macOS | 内置 | Remote Login (系统偏好设置) | /etc/ssh/sshd_config |

**macOS 注意事项：**
- SSH 服务器为内置（无需安装包）
- 通过系统偏好设置中的 Remote Login 启用而非 systemctl
- 配置文件位置与 Linux 相同：`/etc/ssh/sshd_config`
- 通过 `sudo launchctl stop/start com.openssh.sshd` 重启

## 配置内容

| 项目 | 说明 |
|------|------|
| SSH 服务器 | 缺失时安装/启用 |
| 端口 | 自定义 SSH 端口（可选） |
| 私钥 | 导入到 `~/.ssh/`，用于对外 SSH（如 GitHub） |
| 公钥 | 添加到 `~/.ssh/authorized_keys`，用于被连入 |
| GitHub SSH 传输代理 | `~/.ssh/config`：`git@github.com` → `ssh.github.com:443` 经 corkscrew（可选，`SSH_PROXY_PORT`） |
| 安全加固 | 禁用密码/Root 登录等由 `setup-security.sh` 统一门禁处理 |

## 执行流程

| 步骤 | 操作 |
|------|------|
| 1/5 | 确保 `sshd` 已安装并运行 |
| 2/5 | 导入私钥到 `~/.ssh/`（如设置了 `SSH_PRIVATE_KEY`），自动生成 `.pub` |
| 3/5 | 设置自定义端口（如设置了 `SSH_PORT`） |
| 4/5 | 添加公钥到 `~/.ssh/authorized_keys`（如设置了 `SSH_PUBKEY`） |
| 5/5 | 配置 GitHub SSH 传输代理到 `~/.ssh/config`（如设置了 `SSH_PROXY_PORT`） |

## 创建/修改的文件

| 文件 | 说明 |
|------|------|
| `/etc/ssh/sshd_config` | SSH 服务端配置（修改前备份至 `~/.local/share/rig/backups/system/`） |
| `~/.ssh/authorized_keys` | 授权公钥文件（被连入） |
| `~/.ssh/id_ed25519` | 导入的私钥（自动检测 RSA/ECDSA） |
| `~/.ssh/id_ed25519.pub` | 自动派生的公钥 |
| `~/.ssh/config` | SSH 客户端配置；可选 `Host github.com` 走代理块 |
| `~/.ssh/` | 目录不存在时创建，权限 `700` |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SSH_PORT` | _（空）_ | 自定义 SSH 端口。留空则不修改。 |
| `SSH_PUBKEY` | _（空）_ | 公钥字符串（如 `ssh-ed25519 AAAA...`）。设置后添加密钥到 `authorized_keys`（密码禁用由 security 组件处理）。 |
| `SSH_PRIVATE_KEY` | _（空）_ | 私钥内容。设置后写入 `~/.ssh/` 并自动派生公钥。密钥类型自动检测。 |
| `SSH_PROXY_HOST` | `127.0.0.1` | 本地 HTTP 代理主机（如 Clash）。仅在设置了 `SSH_PROXY_PORT` 时生效。 |
| `SSH_PROXY_PORT` | _（空）_ | 本地 HTTP 代理端口（如 `7890`）。设置后 `~/.ssh/config` 让 `git@github.com` 经 corkscrew CONNECT 隧道走 `ssh.github.com:443`——用于封锁出站 SSH:22 的网络。 |

## 重复运行行为

- openssh-server：已安装则跳过。
- 端口：已设为目标端口则跳过。
- 私钥：密钥文件已存在则跳过。
- 公钥：已在 `authorized_keys` 中则跳过。
- GitHub SSH 配置：`~/.ssh/config` 中已有 `Host github.com` 则跳过。
- 修改 `sshd_config` 前会自动备份到 Rig 的集中备份目录。

## 依赖

- 需要 `sudo`。
- `openssh-server`（缺失时自动安装）。
- `corkscrew`（设置 `SSH_PROXY_PORT` 时自动安装）。

## 安装后

如果修改了 SSH 端口，请注意：

1. 更新防火墙规则：`sudo ufw allow <端口>/tcp`
2. 使用新端口连接：`ssh -p <端口> user@host`

**警告：** 启用密钥登录后，请确保密钥可以正常使用再关闭当前会话。

测试 GitHub SSH 连接：`ssh -T git@github.com`
