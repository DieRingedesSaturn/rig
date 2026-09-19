# setup-tmux.sh

Installs tmux and, **only when no configuration exists yet**, writes a minimal `tmux.conf`: extended keys, mouse support, a large scrollback, and a clipboard binding that actually works on the machine it runs on.

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

**Not installed**: TPM, the Catppuccin theme, or any plugin. The previous version of this script installed six plugins and overwrote `~/.tmux.conf` outright.

## Generated Template

Written only when `~/.tmux.conf` is absent:

```tmux
# ─── General ───
# (extended-keys/csi-u intentionally left off — see note below)
set -as terminal-features ",*:RGB"
set -g focus-events on
set -g escape-time 0
set -g mouse on
set -g history-limit 100000
set -g base-index 1
# + vi copy-mode bindings, split keys, status line …

# ─── Clipboard ───
# chosen for this machine
```

## Clipboard Handling

The bound command is **probed, never assumed**, because a hardcoded one fails silently elsewhere:

| Environment | Binding written |
|-------------|-----------------|
| Linux + Wayland + `wl-copy` | `copy-pipe-and-cancel "wl-copy"` |
| Linux + X11 + `xclip` | `copy-pipe-and-cancel "xclip -selection clipboard"` |
| macOS + `pbcopy` | `copy-pipe-and-cancel "pbcopy"` |
| Headless (VPS / SSH) | no binding; `set -g set-clipboard on` (OSC 52) instead |

**The headless branch matters.** A server has no display server, so a binding that shells out to `wl-copy` or `xclip` would just fail at copy time. OSC 52 uses terminal escape sequences instead and works over SSH with any terminal that supports it (kitty, Konsole, WezTerm, iTerm2, Ghostty, ...).

## Existing Configuration

If `~/.tmux.conf` or `~/.config/tmux/tmux.conf` already exists, the script performs a baseline check (`mouse`, `history-limit`, `clipboard`; an existing `extended-keys` gets a compatibility note) and compares your file with the recommended baseline for your system:

1. **Exact match**: reports that the file already matches recommended baseline;
2. **Differences found**: renders a colorized Unified Diff via `git diff`;
3. **Decision flow**:
   - **Interactive TTY**: presents an interactive prompt:
     - `[k] Keep` (default): keeps existing file untouched;
     - `[o] Overwrite`: creates a backup under `~/.local/share/rig/backups/user/`, then writes the recommended baseline;
     - `[a] Append`: creates the centralized backup, then appends baseline settings to the end of the file;
     - `[d] Diff`: prints the colorized diff again.
   - **Non-interactive (CI / pipe)**: safely falls back to `Keep` and prints checklist advice.

### Clipboard advisory

If the config calls a command that is not installed here, it says so plainly:

```
  note: ~/.tmux.conf calls 'pbcopy', which is not installed here.
        pbcopy is macOS-only — that binding does nothing on Fedora.
        Or drop the binding and use: set -g set-clipboard on (OSC 52).
```

Comment lines are ignored, so a commented-out entry is never mistaken for an active one.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TMUX_MOUSE` | `1` | Set to `0` to omit `set -g mouse on` |
| `TMUX_HISTORY_LIMIT` | `100000` | Scrollback buffer size |

## Re-run Behaviour

Fully idempotent. Already-installed packages are skipped, existing configurations are preserved by default, and any write operation requires interactive confirmation with an automatic timestamped backup.

## Dependencies

- `sudo` on Linux for package installation
- No network access required (nothing is downloaded)

## Notes

- tmux 3.1+ prefers `$XDG_CONFIG_HOME/tmux/tmux.conf` and falls back to `~/.tmux.conf`. Either one counts as "you already have a config".
- `extended-keys`/`csi-u` is **not** in the baseline: applications that never negotiate the kitty keyboard protocol (e.g. Neovim < 0.10) then receive raw sequences like `^[[106;5u` for Ctrl+J/newlines. If every app in your stack speaks CSI-u, opt in manually with `set -g extended-keys on` + `set -g extended-keys-format csi-u`.
