# setup-security.sh

安全基线：带防锁定（anti-lockout）保护的 SSH 加固、统一防火墙配置（UFW / firewalld）、以及对照既定策略的监听端口审计。

## 安全模型（防 Lockout）

限制 root 或密码登录时，以下管理员检查必须在修改防火墙或 SSH 配置之前通过。每次运行都检查 Tailscale 连通状态（选用该模式时），并禁止同时关闭密码与公钥认证：

1. `RIG_ADMIN_USER` 必须是非 root 且已存在的账户，密码字段未锁定（`UsePAM` 关闭时），属于 `sudo`/`wheel`/`admin` 组，并通过 sudo 权限查询；以普通用户运行时也会验证。
2. 用户必须在**实际生效的** `AuthorizedKeysFile` 中至少有一个公钥（通过 `sshd -T` 解析，支持 `%u`/`%h`/`%%` 占位符），且 `$HOME`、`~/.ssh` 与密钥文件本身权限安全。
3. `AllowUsers`/`DenyUsers`/`AllowGroups`/`DenyGroups` 不得把 admin 用户排除在外。
4. 当 `RIG_SSH_ACCESS=tailscale` 时，Tailscale 必须已安装**且**已连接。
5. 候选配置的 `PubkeyAuthentication`、`AuthenticationMethods` 和适用的 `Match` 上下文必须允许已验证的管理员公钥登录。禁止同时关闭密码与公钥认证。

候选配置先通过 `sshd -t`，再用 `sshd -T -f candidate -C ...` 解析管理员的有效配置，**之后**才会修改防火墙。连接上下文优先使用 `SSH_CONNECTION`，否则使用 localhost；从本地控制台应用时，可用 `RIG_SSH_TEST_CONTEXT` 指定预期远程连接参数。该检查验证配置，不验证私钥持有或网络登录成功，因此仍需保留当前会话，直到新会话登录成功。

过渡期间同时保护当前与目标 SSH 端口，确认新 SSH 监听建立后才撤销旧规则。后续任一步骤失败都恢复 SSH 配置/服务状态及防火墙快照；恢复失败会明确报告。策略先在临时文件中完整生成，再原子保存。

## 配置内容

| 项目 | 说明 |
|------|------|
| SSH 端口 | `Port` 指令渲染进全局段（绝不落入 `Match` 块） |
| Root 登录 | `PermitRootLogin`（`no` / `prohibit-password` / `yes`） |
| 密码认证 | `PasswordAuthentication` + `KbdInteractiveAuthentication no` |
| 公钥认证 | `PubkeyAuthentication` |
| 防火墙 | 自动探测后端（Debian/Ubuntu/Arch 用 `ufw`，Fedora/RHEL 用 `firewalld`）；默认入站 `deny`、出站 `allow` |
| 公网端口 | 开放 `RIG_PUBLIC_TCP` / `RIG_PUBLIC_UDP`；从配置中移除的端口会被对账清理 |
| Tailscale 模式 | SSH 端口绑定到独立的 `rig-tailscale` DROP zone（firewalld）或 `in on tailscale0`（ufw） |
| 端口审计 | 将 `ss -lntup` 监听者与声明策略 + 防火墙实际规则做双层比对 |

## 防火墙行为

- **ufw**：`allow <port>/tcp`，接口限制用 `in on tailscale0`，默认 `deny incoming` / `allow outgoing`。
- **firewalld**：public zone 永久 `--add-port` 规则；移除默认放行的 `ssh`/`cockpit` service，使声明端口列表成为真实策略；Tailscale 限制使用绑定 `tailscale0` 的 `rig-tailscale` zone。
- 对账：上次声明、本次从 `RIG_PUBLIC_TCP`/`RIG_PUBLIC_UDP` 移除的端口，其放行规则会被删除。
- 未运行的 firewalld 先用 `firewall-offline-cmd` 准备规则，再启动；公共端口明确写入 `--zone=public`，运行中的默认 zone 在新规则加载后才切换。其他绑定接口/来源的 zone（Tailscale 与容器专用 zone 除外）需先人工核对策略，否则拒绝应用。
- 防火墙快照保存在 `~/.local/share/rig/backups/system/firewall-security.*`，firewalld 的运行与永久规则分别保存、分别恢复。回滚不会卸载新安装的软件包。

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
| `RIG_SSH_TEST_CONTEXT` | 当前 SSH 连接 / localhost | 可选 `host=...,addr=...,laddr=...,lport=...`；Rig 自动填写 `user` |

## 修改的文件

| 文件 | 说明 |
|------|------|
| `/etc/ssh/sshd_config` | 每次改动前备份至 `~/.local/share/rig/backups/system/` |
| `~/.config/rig/config` | 持久化策略，仅在全部成功后写入 |

## 重复运行行为

幂等：已存在的规则跳过，不再声明的端口被对账清除，`sshd_config` 每次重新渲染并预检。`--yes` / `--non-interactive` 跳过交互式策略询问。

交互询问涵盖 SSH 访问范围、认证方式、端口与额外公网 TCP 端口。管理员公钥检查失败指候选配置的有效连接上下文；应检查对应的 `Match` 规则与认证限制后重试。

## 依赖

- 需要 `sudo`；只读审计路径使用 `sudo -n`，绝不触发密码提示。
- `sshd -t` 用于预检（Debian 系缺失 `/run/sshd` 时会自动创建）。
- `ss`（macOS 使用 `lsof`）验证新 SSH 监听；端口审计优先 `sudo -n ss -lntup`，失败退回无特权 `ss -lntu`，支持 `*:port` 格式。
- `ssh-keygen` 校验密钥文件；未运行的 firewalld 需要 `firewall-offline-cmd`。
