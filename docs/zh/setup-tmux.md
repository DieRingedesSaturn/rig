# setup-tmux.sh

安装 tmux，并且**仅在没有任何配置存在时**写入一份最小 `tmux.conf`：扩展按键、鼠标支持、大回滚缓冲，以及一个在**当前机器上真正可用**的剪贴板绑定。

刻意**不是** tmux 框架安装器：没有 TPM、没有 Catppuccin、不做插件 git clone。配置就几行，一眼能读完。

## 设计契约

| 路径 | 行为 |
|------|------|
| `~/.tmux.conf` | 存在则默认保留（提供 Diff 与交互式选择） |
| `~/.config/tmux/tmux.conf` | 存在则默认保留（提供 Diff 与交互式选择） |
| 其他 | 不触碰 |

未得到明确交互授权时绝不擅自覆盖现有文件；选择覆写或追加时自动在 `~/.local/share/rig/backups/user/` 创建带时间戳的备份。

## 安装内容

| 工具 | 来源 |
|------|------|
| tmux | 包管理器（apt / dnf / yum / pacman / brew） |

**不装**：TPM、Catppuccin 主题、任何插件。这些在旧版脚本里会装 6 个插件并直接覆盖你的 `~/.tmux.conf`。

## 生成的模板

`~/.tmux.conf` 缺失时写入：

```tmux
# ─── General ───
#（extended-keys/csi-u 有意不启用——见下方备注）
set -as terminal-features ",*:RGB"
set -g focus-events on
set -g escape-time 0
set -g mouse on
set -g history-limit 100000
set -g base-index 1
# 另有 vi copy-mode 绑定、分屏键、状态栏 …

# ─── Clipboard ───
# 按平台自动选择
```

## 剪贴板处理

绑定的命令**按机器实际情况探测**，因为写死一个命令会在别的环境里静默失效：

| 环境 | 写入的绑定 |
|------|-----------|
| Linux + Wayland + `wl-copy` | `copy-pipe-and-cancel "wl-copy"` |
| Linux + X11 + `xclip` | `copy-pipe-and-cancel "xclip -selection clipboard"` |
| macOS + `pbcopy` | `copy-pipe-and-cancel "pbcopy"` |
| 无显示器（VPS / SSH） | 不写绑定，改用 `set -g set-clipboard on`（OSC 52） |

**无显示器这一支很重要。** 服务器没有显示服务器，绑定 `wl-copy` 或 `xclip` 只会在复制时报错。此时改用 OSC 52 转义序列，只要终端支持（kitty、Konsole、WezTerm、iTerm2、Ghostty 等）就能在 SSH 下正常复制。

## 已有配置的处理

如果 `~/.tmux.conf` 或 `~/.config/tmux/tmux.conf` 已存在，脚本首先进行逐项关键配置检查（`mouse`、`history-limit`、`clipboard`；已存在的 `extended-keys` 会给出兼容性提示），并比对现有文件与当前环境推荐 Baseline：

1. **若配置完全一致**：直接提示匹配，不作任何改动；
2. **若存在差异**：调用 `git diff` 输出彩色 Unified Diff；
3. **决策分支**：
   - **交互终端 (TTY)**：提示交互菜单：
     - `[k] Keep`（默认）：保持现有配置不变；
     - `[o] Overwrite`：先集中备份，再全量替换为推荐基线；
     - `[a] Append`：先集中备份，再将推荐基线追加到文件末尾；
     - `[d] Diff`：重新打印彩色 Diff。
   - **非交互终端（管道 / CI）**：安全回退为 `Keep`，保持原有文件不变并输出缺失项提示。

### 剪贴板可用性告警

如果配置里调用了本机不存在的命令，会给出明确提示：

```
  note: ~/.tmux.conf calls 'pbcopy', which is not installed here.
        pbcopy is macOS-only — that binding does nothing on Fedora.
        Or drop the binding and use: set -g set-clipboard on (OSC 52).
```

注释行不会被误判为生效配置。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TMUX_MOUSE` | `1` | 设为 `0` 则不写 `set -g mouse on` |
| `TMUX_HISTORY_LIMIT` | `100000` | 回滚缓冲行数 |

## 重复运行行为

完全幂等安全。已装则跳过安装；已有配置默认安全保持不变，任何写入操作前均强制创建带时间戳备份。

## 依赖

- Linux 下装包需要 `sudo`
- 无需网络（不下载任何东西）

## 备注

- tmux 3.1+ 优先读取 `$XDG_CONFIG_HOME/tmux/tmux.conf`，回退到 `~/.tmux.conf`。两者任一存在都算"你已有配置"。
- `extended-keys`/`csi-u` **不在**基线里：没有协商 kitty 键盘协议的程序（如 Neovim < 0.10）会把 Ctrl+J/换行收到成 `^[[106;5u` 之类的原始转义序列。若你整套应用栈都支持 CSI-u，可手动加 `set -g extended-keys on` + `set -g extended-keys-format csi-u`。
