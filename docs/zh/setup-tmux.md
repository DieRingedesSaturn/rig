# setup-tmux.sh

安装 tmux，并且**仅在没有任何配置存在时**写入一份按当前机器情况生成的最小 `tmux.conf`：鼠标支持、大回滚缓冲、与已安装 tmux 版本匹配的选项语法，以及按会话类型选择的剪贴板方案。生成的文件不含任何运行时的版本或环境检测——一切都在生成时就已确定。

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
| `wl-copy` / `xclip` | 包管理器，当会话需要但尚未安装时 |

**不装**：TPM、Catppuccin 主题、任何插件。

## 生成的模板

`~/.tmux.conf` 与 `~/.config/tmux/tmux.conf` 均缺失时写入。存在两个版本层级——生成时按实际安装的 tmux 选择其一：

```tmux
# ─── General ───
set -g default-terminal "tmux-256color"   # infocmp 查不到该 terminfo 条目时
                                        # 回退为 screen-256color
set -as terminal-features ",*:RGB"        # tmux >= 3.2
# set -as terminal-overrides ",*:Tc"      # tmux < 3.2 改用它
set -g focus-events on
set -sg escape-time 10
set -g mouse on
set -g history-limit 100000
set -g base-index 1
# 另有 vi copy-mode 绑定、分屏键、状态栏 …

# ─── Clipboard ───
set -g set-clipboard on                   # 复制同时经 OSC 52 送出
# 桌面 + tmux >= 3.2：set -s copy-command "<helper>"
# 桌面 + tmux < 3.2：  Enter/MouseDragEnd1Pane 的 copy-pipe 绑定
# 无头环境：           不多写——OSC 52 已覆盖
```

`extended-keys`/`csi-u` **不在**基线里：没有协商 kitty 键盘协议的程序（如 Neovim < 0.10）会把 Ctrl+J/换行收到成 `^[[106;5u` 之类的原始转义序列。整套应用栈都支持 CSI-u 后可手动开启。

## 版本层级

生成的语法取决于安装时检测到的 tmux 版本：

| 选项 | tmux >= 3.2 | tmux < 3.2 |
|------|-------------|------------|
| 真彩色 | `set -as terminal-features ",*:RGB"` | `set -as terminal-overrides ",*:Tc"` |
| 桌面剪贴板 | `set -s copy-command "<helper>"`（y/Enter/鼠标拖选都经它复制） | y/Enter/鼠标拖选各自的 `copy-pipe-and-cancel "<helper>"` 绑定 |

`allow-passthrough` 从不写入（需要 tmux >= 3.3，而 `set-clipboard` 已覆盖该用途）。tmux 低于 2.4 的机器完全不写配置——基线要求 2.4+。

## 剪贴板处理

剪贴板命令**按机器实际情况探测**，绝不写死——写死 `xclip` 在 Wayland 和无头服务器上只会静默失效：

| 环境 | 写入 |
|------|------|
| macOS | `pbcopy` |
| Linux + Wayland | `wl-copy` |
| Linux + X11 | `xclip -selection clipboard` |
| 无显示器（VPS / SSH） | 不写 helper 绑定，只用 `set -g set-clipboard on`（OSC 52） |

可用 `RIG_CLIPBOARD_TOOL=auto|pbcopy|wl-copy|xclip|none` 强制指定或关闭。`none` 即使在桌面也只生成无头（OSC 52）档案。

## 已有配置的处理

如果 `~/.tmux.conf` 或 `~/.config/tmux/tmux.conf` 已存在，脚本先做逐项关键配置检查（`mouse`、`history-limit`、`clipboard`；已存在的 `extended-keys` 会给出兼容性提示），再警告本机 tmux 无法识别的选项（如 tmux < 3.3 上的 `allow-passthrough`）以及 `mode-keys vi` 下永远不会执行的 emacs `copy-mode` 表 `copy-pipe` 绑定，最后将现有文件与本机推荐基线比对：

1. **若配置完全一致**：直接提示匹配，不作任何改动；
2. **若存在差异**：调用 `git diff` 输出彩色 Unified Diff；
3. **决策分支**：
   - **交互终端 (TTY)**：提示交互菜单：
     - `[k] Keep`（默认）：保持现有配置不变；
     - `[o] Overwrite`：先集中备份，再全量替换为推荐基线；
     - `[a] Append`：先集中备份，再将推荐基线追加到文件末尾；
     - `[d] Diff`：重新打印彩色 Diff。
   - **非交互终端（管道 / CI）**：安全回退为 `Keep`，保持原有文件不变并输出缺失项提示。

注释行全程不会被误判为生效配置。

### 剪贴板可用性告警

如果配置里调用了本机不存在的命令，会给出明确提示：

```
  note: ~/.tmux.conf calls 'pbcopy', which is not installed here.
        pbcopy is macOS-only — that binding does nothing on Fedora.
        Or drop the binding and use: set -g set-clipboard on (OSC 52).
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TMUX_MOUSE` | `1` | 设为 `0` 则不写 `set -g mouse on` |
| `TMUX_HISTORY_LIMIT` | `100000` | 回滚缓冲行数 |
| `RIG_CLIPBOARD_TOOL` | `auto` | 要安装并写入配置的剪贴板工具：`auto`、`pbcopy`、`wl-copy`、`xclip` 或 `none` |

## 重复运行行为

完全幂等安全。已装则跳过安装；已有配置默认安全保持不变，任何写入操作前均强制创建带时间戳备份。

## 依赖

- Linux 下装包需要 `sudo`
- 无需网络（不下载任何东西）

## 备注

- tmux 3.1+ 优先读取 `$XDG_CONFIG_HOME/tmux/tmux.conf`，回退到 `~/.tmux.conf`。两者任一存在都算"你已有配置"。
- `default-terminal` 默认为 `tmux-256color`（`infocmp` 能找到该 terminfo 条目时；现代 ncurses 自带），否则用 `screen-256color`。
