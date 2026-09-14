# setup-shell.sh

安装 zsh、Starship，以及 zsh-autosuggestions + zsh-syntax-highlighting 两个插件——全部来自发行版包管理器。**刻意不是** zsh 框架安装器：没有 Oh My Zsh、不做插件 git clone、不套用提示符预设。

## 设计契约

这个组件在设计上就是非破坏性的——绝不静默覆盖任何文件：

| 路径 | 行为 |
|------|------|
| `~/.zshrc` | **永远只读。** 不创建、不追加、不备份、不还原。 |
| `~/.config/starship.toml` | 缺失时创建。已存在的配置会展示 diff 并提供 保留/覆盖/追加 菜单，覆盖/追加前自动备份。 |
| 默认登录 Shell | **只报告，不修改。** 任何时候都不会执行 `chsh`。 |
| 软件包 | 只通过发行版包管理器安装。唯一例外是下面的 Starship 回退方案。 |

任何"必须改你文件才能完成"的事，都会在运行结束时以清单形式打印出来，由你自己决定是否执行。这样组件与用 dotfiles 仓库跟踪 `~/.zshrc` 和 `~/.config/starship.toml` 的做法完全兼容——跑完之后那些仓库仍然是干净的。

## 操作系统支持

| 操作系统 | 包管理器 | 需要 sudo |
|---------|---------|----------|
| Debian/Ubuntu | `apt` | ✓ |
| CentOS/RHEL | `yum`/`dnf` | ✓ |
| Fedora | `dnf` | ✓ |
| Arch Linux | `pacman` | ✓ |
| macOS | `brew` | zsh/curl 不需要（系统自带）；仅 Homebrew 操作需要 |

## 安装内容

| 工具 | 来源 | 说明 |
|------|------|------|
| zsh | 包管理器 | macOS 自带 |
| curl | 包管理器 | 仅 Starship 回退方案需要 |
| Starship | 包管理器，或 [starship.rs](https://starship.rs/) 官方安装器 | 发行版未打包时回退安装到 `~/.local/bin`（无需 sudo） |
| zsh-autosuggestions | 包管理器 | 发行版包，不是 git clone |
| zsh-syntax-highlighting | 包管理器 | 发行版包，不是 git clone |

包名通过 `lib/pkg-maps.sh` 解析，因此同一套抽象名在所有支持的发行版上都可用。

## 执行步骤

| 步骤 | 操作 |
|------|------|
| 1/5 | 安装 `zsh` 和 `curl`（macOS 跳过，系统自带）。然后尽力安装 `starship`、`zsh-autosuggestions`、`zsh-syntax-highlighting`；发行版没打包的只报告、不中断 |
| 2/5 | 确保 Starship 存在。若包管理器提供不了，运行官方安装器装到 `~/.local/bin` |
| 3/5 | 探测插件文件位置。各包管理器放置路径不一致，因此搜索候选列表而非硬编码单一路径 |
| 4/5 | 缺失时创建 `~/.config/starship.toml`；已存在则弹出 diff 菜单 |
| 5/5 | 读取 `~/.zshrc` 并报告：加载了哪些插件、是否有 Starship 初始化行、zsh 是否为登录 Shell，以及加载顺序建议 |

## 探测的插件路径

| 系统 | 搜索路径 |
|------|---------|
| Fedora / Debian / RHEL | `/usr/share/<name>/<file>`、`/usr/local/share/<name>/<file>` |
| Arch | `/usr/share/zsh/plugins/<name>/<file>`、`/usr/share/<name>/<file>` |
| macOS | `/opt/homebrew/share/<name>/<file>`（Apple Silicon）、`/usr/local/share/<name>/<file>`（Intel） |

## 创建/修改的文件

| 文件 | 操作 |
|------|------|
| `~/.config/starship.toml` | 缺失时创建（已存在走 diff 菜单）；默认提示符显示路径、git 状态、语言运行时与时间，SSH 会话中额外显示红色 `ssh:<主机名>` 前缀 |
| `~/.zshrc` | **绝不触碰** |
| `/etc/passwd` | **绝不触碰** |

## 重复运行行为

完全幂等。已安装的包会跳过，已存在的 `starship.toml` 不动，`.zshrc` 检查是只读的——无论重跑多少次，磁盘上不会有任何变化。

## 安装后清单

脚本会明确打印还缺什么。通常是这样：

```bash
# 自己加进 ~/.zshrc —— 脚本不会替你做
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
eval "$(starship init zsh)"

# 如果 zsh 还不是你的登录 Shell
chsh -s "$(command -v zsh)"
```

### 加载顺序

上游要求 `zsh-syntax-highlighting` **最后**被 source，因为它会包裹 ZLE 行编辑器；任何在它之后加载的东西都可能绕过高亮组件。如果脚本检测到 autosuggestions 或 Starship 初始化行排在它后面，会打印一条提示。这只是信息，改不改随你。

## 依赖

- Linux 下装包需要 `sudo`
- 只有需要 Starship 回退安装器时才需要网络

## 备注

- Starship 图标需要终端支持 [Nerd Font](https://www.nerdfonts.com/)。
- 用 `uninstall.sh` 卸载本组件会删掉它安装的包，但**保留你的 `~/.zshrc` 和 `starship.toml`**，也不会回滚你的登录 Shell。
