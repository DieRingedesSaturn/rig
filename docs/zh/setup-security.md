# setup-security.sh

安全基线：带防锁定（anti-lockout）保护的 SSH 加固、统一防火墙配置（UFW / firewalld）、以及对照既定策略的监听端口审计。

## 安全模型（防 Lockout）

只有全部前置条件成立才会执行加固——否则脚本在**任何改动之前**退出：

1. `RIG_ADMIN_USER` 必须是非 root 且已存在的账户，密码字段未锁定（`UsePAM` 关闭时），属于 `sudo`/`wheel`/`admin` 组，并且——当以 root 运行时——通过 `sudo -n -l -U <user>` 验证。
2. 用户必须在**实际生效的** `AuthorizedKeysFile` 中至少有一个公钥（通过 `sshd -T` 解析，支持 `%u`/`%h`/`%%` 占位符），且 `$HOME`、`~/.ssh` 与密钥文件本身权限安全。
3. `AllowUsers`/`DenyUsers`/`AllowGroups`/`DenyGroups` 不得把 admin 用户排除在外。
4. 当 `RIG_SSH_ACCESS=tailscale` 时，Tailscale 必须已安装**且**已连接。

候选 `sshd_config` 先渲染到临时文件并通过 `sshd -t` 预检，**之后**才会触碰防火墙或替换线上配置。若安装后复检或服务重载失败，自动恢复原配置。只有所有步骤成功，策略才会写入 `~/.config/rig/config`。

## 配置内容

| 项目 | 说明 |
|------|------|
| SSH 端口 | `Port` 指令渲染进全局段（绝不落入 `Match` 块） |
| Root 登录 | `PermitRootLogin`（`no` / `prohibit-password` / `yes`） |
| 密码认证 | `PasswordAuthentication` + `KbdInteractiveAuthentication no` |
| 公钥认证 | `PubkeyAuthentication` |
| 防火墙 | 自动探测后端（Debian/Ubuntu 用 `ufw`，Fedora/RHEL/Arch 用 `firewalld`）；默认入站 `deny`、出站 `allow` |
| 公网端口 | 开放 `RIG_PUBLIC_TCP` / `RIG_PUBLIC_UDP`；从配置中移除的端口会被对账清理 |
| Tailscale 模式 | SSH 端口绑定到独立的 `rig-tailscale` DROP zone（firewalld）或 `in on tailscale0`（ufw） |
| 端口审计 | 将 `ss -lntup` 监听者与声明策略 + 防火墙实际规则做双层比对 |

## 防火墙行为

- **ufw**：`allow <port>/tcp`，接口限制用 `in on tailscale0`，默认 `deny incoming` / `allow outgoing`。
- **firewalld**：public zone 永久 `--add-port` 规则；移除默认放行的 `ssh`/`cockpit` service，使声明端口列表成为真实策略；Tailscale 限制使用绑定 `tailscale0` 的 `rig-tailscale` zone。
- 对账：上次声明、本次从 `RIG_PUBLIC_TCP`/`RIG_PUBLIC_UDP` 移除的端口，其放行规则会被删除。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RIG_ADMIN_USER` | `$SUDO_USER` 或 `whoami` | 用于锁定校验的非 root 管理员 |
| `RIG_SSH_PORT` | 当前 `Port` | SSH 监听端口 |
| `RIG_SSH_ROOT_LOGIN` | `no` | `PermitRootLogin` 取值 |
| `RIG_SSH_PASSWORD_AUTH` | `no` | `PasswordAuthentication` 取值 |
| `RIG_SSH_PUBKEY_AUTH` | `yes` | `PubkeyAuthentication` 取值 |
| `RIG_SSH_ACCESS` | `public` | `public` 或 `tailscale`（SSH 限定 tailscale0） |
| `RIG_FIREWALL` | `auto` | `auto` / `ufw` / `firewalld` / `none` |
| `RIG_FIREWALL_DEFAULT_IN` | `deny` | 入站默认策略 |
| `RIG_FIREWALL_DEFAULT_OUT` | `allow` | 出站默认策略（firewalld 下拒绝 `deny`） |
| `RIG_PUBLIC_TCP` | SSH 端口 | 逗号分隔的公网 TCP 端口 |
| `RIG_PUBLIC_UDP` | _(空)_ | 逗号分隔的公网 UDP 端口 |
| `RIG_CHECK_LISTENING_PORTS` | `yes` | 是否执行监听端口审计 |
| `RIG_WARN_UNDECLARED_PORTS` | `yes` | 对未声明却暴露的监听者发出警告 |

## 修改的文件

| 文件 | 说明 |
|------|------|
| `/etc/ssh/sshd_config` | 每次改动前备份至 `~/.local/share/rig/backups/system/` |
| `~/.config/rig/config` | 持久化策略，仅在全部成功后写入 |

## 重复运行行为

幂等：已存在的规则跳过，不再声明的端口被对账清除，`sshd_config` 每次重新渲染并预检。`--yes` / `--non-interactive` 跳过交互式策略询问。

交互询问涵盖：SSH 访问范围、`PermitRootLogin`、`PasswordAuthentication`、`PubkeyAuthentication`、SSH 端口与额外公网 TCP 端口。若防 lockout 检查报 `PubkeyAuthentication is 'no'`，说明当前 sshd 生效配置禁用了密钥登录——用 `sudo grep -rni pubkeyauthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/` 定位该指令，改为 yes 并 reload sshd，先在**新会话**里验证密钥登录可用，再重跑加固关闭密码认证。

## 依赖

- 需要 `sudo`；只读审计路径使用 `sudo -n`，绝不触发密码提示。
- `sshd -t` 用于预检（Debian 系缺失 `/run/sshd` 时会自动创建）。
- `ss` 用于端口审计（优先 `sudo -n ss -lntup`，失败退回无特权 `ss -lntu`）。
