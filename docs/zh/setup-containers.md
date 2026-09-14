# setup-containers.sh

一个组件，两个可互换的后端。安装 **Podman** 或 **Docker**，选择依据来自你的配置，而不是靠猜。

## 为什么合成一个组件

Docker 和 Podman 提供的都是"跑容器"这同一件事。把它们当成两个独立组件，意味着 `rig status` 会永远给你**刻意没装的那个**标红叉。这里它们是同一能力的两种实现，只报告其中一个。

## 后端选择

优先级从高到低：

| # | 来源 | 示例 |
|---|------|------|
| 1 | `RIG_CONTAINER_ENGINE` | `podman` / `docker` —— 永远最高 |
| 2 | 已安装的唯一后端 | 保留现有 Podman 或 Docker，不安装另一套 |
| 3 | `RIG_PROFILE` | `desktop` → Podman，`vps` → Docker |
| 4 | OS 默认 | Fedora/Arch → Podman，Debian/RHEL → Docker |

**你显式配置的后端绝不会被探测结果顶掉。** 自动模式下，如果只检测到 Podman，就继续使用 Podman 而不安装 Docker；反之亦然。两者都没有或两者都存在时，交互运行会询问用户。

`RIG_CONTAINER_MODE` 选择 `rootless`（默认）或 `rootful`。

选择 Docker rootless 但 systemd user session 不可用时，脚本不会静默切换模式：交互运行会让用户选择保留已有 Podman、使用 rootful Docker，或停止并先修复 session；非交互运行则安全失败并给出操作提示。

### 配置文件

```bash
# ~/.config/rig/config
RIG_PROFILE="desktop"
RIG_CONTAINER_ENGINE="auto"
RIG_CONTAINER_MODE="rootless"
```

该文件是**解析**的，不会被 source。同名环境变量可以覆盖它，用于一次性调整：

```bash
RIG_CONTAINER_ENGINE=podman rig install containers
```

建议配置：

```bash
# Fedora 桌面
RIG_PROFILE="desktop"
RIG_CONTAINER_ENGINE="podman"
RIG_CONTAINER_MODE="rootless"
```

```bash
# Debian/Ubuntu VPS
RIG_PROFILE="vps"
RIG_CONTAINER_ENGINE="docker"
RIG_CONTAINER_MODE="rootless"
```

## Podman

在 Fedora 和 Arch 上，Podman 就是一个包。它是 daemonless 的，没有服务需要 enable / start / restart，普通用户无需额外配置就能 rootless 运行容器。

| 步骤 | 操作 |
|------|------|
| 1 | `sudo dnf install -y podman`（或其他发行版等价命令） |
| 2 | 检查 subordinate UID/GID 范围；仅在缺失或过小时才分配 |
| 3 | 验证 `podman info` 报告 `Host.Security.Rootless = true` |
| 4 | 报告 compose 现状（见下） |

macOS 上 Podman 在 Linux 虚拟机里跑容器，需要先创建 machine：

```bash
podman machine init
podman machine start
```

这会下载一个很大的 VM 镜像，所以脚本只装包并**打印这两条命令，不代为执行**。

## Docker

Rootless 和 rootful Docker 是两套真正不同的安装。它们的 socket、存储目录、配置文件和 systemd 作用域都不同：

| | Rootless | Rootful |
|---|----------|---------|
| Socket | `/run/user/$UID/docker.sock` | `/var/run/docker.sock` |
| 数据 | `~/.local/share/docker` | `/var/lib/docker` |
| 配置 | `~/.config/docker/daemon.json` | `/etc/docker/daemon.json` |
| 服务 | `systemctl --user` | `systemctl` |

### Rootless（默认）

| 步骤 | 操作 |
|------|------|
| 1 | 要求存在可用的 `systemd --user` 会话 |
| 2 | Debian/RHEL 上安装 `uidmap` 以提供 `newuidmap`/`newgidmap`（Fedora/Arch 由 `shadow-utils` 提供） |
| 3 | 检查 subordinate UID/GID 范围 —— Docker 要求至少 65536 个 ID；仅在缺失时分配 |
| 4 | 安装 Docker Engine 包 |
| 5 | 安装 `docker-ce-rootless-extras`（提供 `dockerd-rootless-setuptool.sh`） |
| 6 | 若之前启用过系统级 daemon，则将其停用 |
| 7 | `dockerd-rootless-setuptool.sh install` |
| 8 | `systemctl --user enable --now docker` |
| 9 | `loginctl enable-linger`，让服务在登出和重启后仍然存活 —— **在无头 VPS 上至关重要** |
| 10 | `docker context use rootless` |
| 11 | 写入 `~/.config/docker/daemon.json` |
| 12 | 用 `docker info` 验证 |

### Rootful

经典的系统级 daemon：装包、把用户加入 `docker` 组、写 `/etc/docker/daemon.json`、启用系统服务。

## Compose

脚本**不会**把 `docker` 别名到 `podman`。它们是各自独立的工具、各自独立的存储，而且 `docker compose` 与 `podman compose` 并非同一实现 —— `podman compose` 会委派给外部 provider。

- **Docker** —— 安装了 `docker-compose-plugin`，`docker compose` 可直接用。
- **Podman** —— `podman compose` 需要 provider。脚本会告诉你该装哪个包，而不是替你选。

compose 文件尽量保持可移植，用与当台机器后端匹配的那个 CLI 即可。

## 镜像源

镜像源是 opt-in 的，且绝不写入已存在的文件。

| 后端 | 文件 |
|------|------|
| Podman | `~/.config/containers/registries.conf` |
| Rootless Docker | `~/.config/docker/daemon.json` |
| Rootful Docker | `/etc/docker/daemon.json` |

```bash
PODMAN_REGISTRY_MIRRORS="https://mirror.example.com" ./setup-containers.sh
DOCKER_MIRROR="https://mirror.example.com" ./setup-containers.sh
```

Docker 的 `daemon.json` 是**合并**而非替换：有 `python3` 时保留未知键，否则已存在的文件原样不动。`default-address-pools` 只在 rootful 下写入 —— rootless 走 slirp4netns，没有网桥可供分配。

## 状态显示

`status.sh` 只报告**配置选中的那一个**后端：

```
✔     Containers               Podman 5.8.4 (rootless) configured
```

在配置为 Docker 的机器上：

```
✔     Containers               Docker 29.1.2 (rootless) configured
```

rootless/rootful 分别取自 `podman info` 的 `Host.Security.Rootless` 和 `docker info`，而不是靠组成员身份推测。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RIG_CONTAINER_ENGINE` | `auto` | `auto`、`podman` 或 `docker` |
| `RIG_CONTAINER_MODE` | `rootless` | `rootless` 或 `rootful` |
| `RIG_PROFILE` | _（空）_ | `desktop` 或 `vps` |
| `PODMAN_REGISTRY_MIRRORS` | _（空）_ | Podman 的镜像源，逗号分隔 |
| `DOCKER_MIRROR` | _（空）_ | Docker 的镜像源，逗号分隔 |
| `DOCKER_LOG_SIZE` | `20m` | 单个日志文件上限 |
| `DOCKER_LOG_FILES` | `3` | 日志文件数量上限 |

## 更新

`rig update containers` 用同样的方式解析，并且只更新实际安装的那一套：

| 后端 | 操作 |
|------|------|
| Podman | 升级 `podman` 包（daemonless，无需重启任何东西） |
| Rootless Docker | 升级引擎包（含 `docker-ce-rootless-extras`），然后 `systemctl --user restart docker` |
| Rootful Docker | 升级引擎包，然后 `systemctl restart docker` |

## 卸载

镜像和卷属于用户数据，**默认一律不删**。

| 后端 | 删除 | 保留 |
|------|------|------|
| Podman | `podman` 包 | `~/.local/share/containers`、`~/.config/containers/` |
| Rootless Docker | 用户服务、引擎包 | `~/.local/share/docker`、`~/.config/docker/` |
| Rootful Docker | 系统服务、引擎包、`/etc/docker/` | `/var/lib/docker` |

加 `--remove-docker-data` 才会连镜像/卷存储一起删除。

## 依赖

- Linux 下装包和 `usermod`/`loginctl` 需要 `sudo`
- 安装 Docker 时需要访问 `get.docker.com`

## 备注

- `setup-containers.sh` 绝不覆盖已存在的 `daemon.json` 或 `registries.conf`。
- macOS 上的 Docker 指 Docker Desktop，那里没有 rootless 模式，所以 Podman 后端是更合理的选择。
