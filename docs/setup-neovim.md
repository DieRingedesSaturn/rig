# setup-neovim.sh

Installs Neovim (ensuring >= 0.9) and writes a dependency-free, terminal-native `init.lua`. Sets the default editor via `update-alternatives` where available.

**Non-negotiable contract:** `~/.config/nvim/init.lua` is created when absent; an existing config is only replaced after an explicit interactive choice (keep/overwrite/append/diff) with a timestamped backup — never silently.

## What Gets Installed

| Component | Method | Notes |
|-----------|--------|-------|
| Neovim | Package manager (`apt`/`dnf`/`pacman`/`brew`) | Requires >= 0.9 |
| Neovim (fallback) | Official static tarball → `~/.local/share/nvim-static`, symlinked into `~/.local/bin` | Linux x86_64 only, used when the distro ships < 0.9 or installation fails |

## What Gets Configured

| Item | Description |
|------|-------------|
| System editor | `update-alternatives --set editor/vi` → nvim (skipped when nvim lives under `$HOME` or sudo is unavailable) |
| rc files | If `EDITOR="nvim"` is missing from `~/.zshrc`/`~/.bashrc`, the exports are appended after an explicit `y/N` confirmation with a backup; without a TTY they are only printed |
| `init.lua` | Written when absent; existing file triggers a diff + keep/overwrite/append prompt |

## Default init.lua Highlights

- Leader = `<Space>`; 4-space tabs, `expandtab`, smart/auto indent; `scrolloff=4`; splits open right/below.
- `ignorecase`+`smartcase` search, persistent undo, no swap/backup files, `<F2>` toggles line numbers.
- **Color scheme**: locally (non-SSH) uses the Everforest plugin when installed at `site/pack/plugins/start/everforest`, honoring `NVIM_BACKGROUND` / `~/.local/state/nvim/background`. On SSH sessions or when Everforest is absent, falls back to a hand-mapped ANSI-palette scheme (no termguicolors, zero dependencies).
- **Clipboard**: local Wayland sessions with `wl-copy` get `unnamedplus`; remote/headless sessions use OSC 52 (`"+y` in visual mode yanks back to the local terminal).
- `mouse = ''` — leaves selection/copy to the terminal emulator (Ghostty/Konsole style).

## Files Created / Modified

| File | Action |
|------|--------|
| `~/.config/nvim/init.lua` | Created when absent; existing config shows a diff menu — overwrite/append both take a backup to `~/.local/share/rig/backups/user/` first |
| `~/.local/bin/nvim` | Symlink, only via the static-binary fallback |
| `~/.local/share/nvim-static/` | Static binary payload, fallback only |
| `/usr/bin/editor`, `/usr/bin/vi` | `update-alternatives` targets (when applicable) |
| `~/.zshrc`, `~/.bashrc` | Editor exports appended only after `y/N` confirmation + backup |

## Re-run Behavior

Fully idempotent: an up-to-date nvim skips installation, an existing `init.lua` is left alone, and `update-alternatives` calls are re-applied harmlessly.

## Dependencies

- `sudo` for package installation and `update-alternatives` (skipped when unavailable).
- `curl` + `tar` only for the static-binary fallback.
