# setup-tmux.sh

Installs tmux and, **only when no configuration exists yet**, writes a minimal `tmux.conf` decided for this machine: mouse support, a large scrollback, option syntax matching the installed tmux version, and clipboard handling chosen for the session. The generated file contains no runtime version or environment checks — everything was already decided when it was written.

Deliberately **not** a tmux framework installer: no TPM, no Catppuccin, no plugin git clones. The config is a handful of lines you can read in one go.

## Design Contract

| Path | Behaviour |
|------|-----------|
| `~/.tmux.conf` | Preserved by default (offers diff & interactive options) |
| `~/.config/tmux/tmux.conf` | Preserved by default (offers diff & interactive options) |
| Anything else | Untouched |

Existing configurations are never overwritten without explicit interactive confirmation and automatic timestamped backup.

## What Gets Installed

| Tool | Source |
|------|--------|
| tmux | Package manager (apt / dnf / yum / pacman / brew) |
| `wl-copy` / `xclip` | Package manager, when the session calls for one and it is missing |

**Not installed**: TPM, the Catppuccin theme, or any plugin.

## Generated Template

Written only when `~/.tmux.conf` and `~/.config/tmux/tmux.conf` are absent. Two version tiers exist — everything shown is emitted at setup time for the tmux actually installed:

```tmux
# ─── General ───
set -g default-terminal "tmux-256color"   # falls back to screen-256color when
                                        # infocmp has no tmux-256color entry
set -as terminal-features ",*:RGB"        # tmux >= 3.2
# set -as terminal-overrides ",*:Tc"      # tmux < 3.2 instead
set -g focus-events on
set -sg escape-time 10
set -g mouse on
set -g history-limit 100000
set -g base-index 1
# + vi copy-mode bindings, split keys, status line …

# ─── Clipboard ───
set -g set-clipboard on                   # copies also leave via OSC 52
# desktop on tmux >= 3.2: set -s copy-command "<helper>"
# desktop on tmux < 3.2:  Enter/MouseDragEnd1Pane copy-pipe bindings
# headless:               nothing extra — OSC 52 does it all
```

`extended-keys`/`csi-u` is **not** in the baseline: applications that never negotiate the kitty keyboard protocol (e.g. Neovim < 0.10) then receive raw sequences like `^[[106;5u`. Opt in manually once every app in your stack speaks CSI-u.

## Version Tiers

The emitted syntax follows the tmux found at setup time:

| Option | tmux >= 3.2 | tmux < 3.2 |
|--------|-------------|------------|
| true colour | `set -as terminal-features ",*:RGB"` | `set -as terminal-overrides ",*:Tc"` |
| desktop clipboard | `set -s copy-command "<helper>"` (y/Enter/mouse-drag all pipe to it) | explicit `copy-pipe-and-cancel "<helper>"` bindings for y/Enter/mouse-drag |

`allow-passthrough` is never emitted (it needs tmux >= 3.3 and `set-clipboard` already covers the use case). Hosts below tmux 2.4 get no config at all — the baseline requires 2.4+.

## Clipboard Handling

The helper is **chosen by session detection**, never assumed — a hardcoded `xclip` binding fails silently on Wayland and on a headless server:

| Environment | Written |
|-------------|---------|
| macOS | `pbcopy` |
| Linux + Wayland | `wl-copy` |
| Linux + X11 | `xclip -selection clipboard` |
| Headless (VPS / SSH) | no helper binding; `set -g set-clipboard on` (OSC 52) only |

Force or disable the choice with `RIG_CLIPBOARD_TOOL=auto|pbcopy|wl-copy|xclip|none`. `none` yields the headless (OSC 52) profile even on a desktop.

## Existing Configuration

If `~/.tmux.conf` or `~/.config/tmux/tmux.conf` already exists, the script performs a baseline check (`mouse`, `history-limit`, `clipboard`; an existing `extended-keys` gets a compatibility note), warns about options the installed tmux cannot honour (e.g. `allow-passthrough` on tmux < 3.3) and about `copy-pipe` bindings in the emacs `copy-mode` table that never run under `mode-keys vi`, then compares your file with the recommended baseline for your machine:

1. **Exact match**: reports that the file already matches the recommended baseline;
2. **Differences found**: renders a colorized Unified Diff via `git diff`;
3. **Decision flow**:
   - **Interactive TTY**: presents an interactive prompt:
     - `[k] Keep` (default): keeps existing file untouched;
     - `[o] Overwrite`: creates a backup under `~/.local/share/rig/backups/user/`, then writes the recommended baseline;
     - `[a] Append`: creates the centralized backup, then appends baseline settings to the end of the file;
     - `[d] Diff`: prints the colorized diff again.
   - **Non-interactive (CI / pipe)**: safely falls back to `Keep` and prints checklist advice.

Comment lines are ignored throughout, so a commented-out entry is never mistaken for an active one.

### Clipboard advisory

If the config calls a command that is not installed here, it says so plainly:

```
  note: ~/.tmux.conf calls 'pbcopy', which is not installed here.
        pbcopy is macOS-only — that binding does nothing on Fedora.
        Or drop the binding and use: set -g set-clipboard on (OSC 52).
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TMUX_MOUSE` | `1` | Set to `0` to omit `set -g mouse on` |
| `TMUX_HISTORY_LIMIT` | `100000` | Scrollback buffer size |
| `RIG_CLIPBOARD_TOOL` | `auto` | Clipboard helper to install and write into the config: `auto`, `pbcopy`, `wl-copy`, `xclip` or `none` |

## Re-run Behaviour

Fully idempotent. Already-installed packages are skipped, existing configurations are preserved by default, and any write operation requires interactive confirmation with an automatic timestamped backup.

## Dependencies

- `sudo` on Linux for package installation
- No network access required (nothing is downloaded)

## Notes

- tmux 3.1+ prefers `$XDG_CONFIG_HOME/tmux/tmux.conf` and falls back to `~/.tmux.conf`. Either one counts as "you already have a config".
- The default `default-terminal` is `tmux-256color` when `infocmp` finds that terminfo entry (modern ncurses ships it), otherwise `screen-256color`.
