# setup-neovim.sh

Installs Neovim (**>= 0.9 is enforced**) and writes a dependency-free, terminal-native `init.lua` decided for this machine. Sets the default editor via `update-alternatives` on Debian-family systems.

**Non-negotiable contract:** `~/.config/nvim/init.lua` is created when absent; an existing config is only replaced after an explicit interactive choice (keep/overwrite/diff) with a timestamped backup — never silently.

## What Gets Installed

| Component | Method | Notes |
|-----------|--------|-------|
| Neovim | Package manager (`apt`/`dnf`/`pacman`/`brew`) | Accepted only when >= 0.9 |
| Neovim (fallback) | Official binary tarball → `~/.local/share/nvim-static`, symlinked into `~/.local/bin` | Linux only, on x86_64 and aarch64/arm64; used when the distro ships < 0.9 or installation fails |

The fallback verifies that the downloaded binary actually runs on this glibc before installing it, then swaps the new tree in through a `nvim-static.new` directory (clearing leftovers from an interrupted run) and removes its own symlink if the swap fails, so `~/.local/bin/nvim` never dangles. A rig static build is found on re-runs even when `~/.local/bin` is not on `PATH`. Set `GH_PROXY` to an `https://` mirror prefix when GitHub is unreachable. When a static build wins over a distro nvim on `PATH`, the script notes that `~/.local/bin` must come first (`setup-shell` already exports it in `~/.zshrc`).

## What Gets Configured

| Item | Description |
|------|-------------|
| System editor | `update-alternatives --set editor/vi` → nvim — Debian family only, and skipped when nvim lives under `$HOME` or sudo is unavailable |
| rc files | If `EDITOR="nvim"` is missing from `~/.zshrc`/`~/.bashrc`, the exports are appended after an explicit `y/N` confirmation with a backup; without a TTY they are only printed |
| `init.lua` | Written when absent; existing file triggers a diff + keep/overwrite/diff prompt |

An existing `init.vim` blocks the write entirely: with both files present Neovim loads only `init.lua` and reports E5422, silently ignoring the `init.vim` — so writing the baseline beside it would silently disable the user's config. The script leaves `init.vim` alone and explains the situation instead. Move `init.vim` aside and re-run to get the baseline.

## Host Profiles

The generated file is a flat config with no runtime detection — the profile is picked once, at setup time, and printed as the file's second line:

| Profile | When | Clipboard | Colors |
|---------|------|-----------|--------|
| desktop | a desktop session is detected (macOS, Wayland or X11) or forced via `RIG_CLIPBOARD_TOOL` | `vim.opt.clipboard = 'unnamedplus'` — Neovim picks the helper itself | Everforest when it was found under `site/pack/*/start` at setup time, else terminal palette |
| headless | no display session (SSH/VPS), or `RIG_CLIPBOARD_TOOL=none` | copy-only OSC 52 provider | terminal palette |

Everforest is wired only when detected at setup time on a desktop — the config never scans for it at runtime, and there is no hand-mapped ANSI palette or `NVIM_BACKGROUND` file.

### Headless clipboard

Yanks reach the local terminal through OSC 52, which survives SSH and tmux (inside tmux this needs `set -g set-clipboard on` — the rig tmux baseline writes it, and the script warns when the host's tmux config lacks it). Puts return the last yank instead of asking the terminal, which would block or prompt on every `p`.

- **nvim >= 0.10**: provider built on `require('vim.ui.clipboard.osc52')` with copy wrapped to remember the last yank.
- **nvim 0.9**: no OSC 52 module exists, so the escape is built with `base64(1)` and written to `v:stderr`, which is the terminal.

## Default init.lua Highlights

- Leader = `<Space>`; 4-space tabs, `expandtab`; `scrolloff=4`; splits open right/below.
- `ignorecase`+`smartcase` search, persistent undo, `<F2>` toggles line numbers.
- `mouse = ''` — leaves selection/copy to the terminal emulator (Ghostty/Konsole style).

## Files Created / Modified

| File | Action |
|------|--------|
| `~/.config/nvim/init.lua` | Created when absent; existing config shows a diff menu (keep/overwrite/diff) — writes take a backup to `~/.local/share/rig/backups/user/` first |
| `~/.local/bin/nvim` | Symlink, only via the static-binary fallback |
| `~/.local/share/nvim-static/` | Static binary payload, fallback only |
| `/usr/bin/editor`, `/usr/bin/vi` | `update-alternatives` targets (Debian family, system nvim, passwordless sudo) |
| `~/.zshrc`, `~/.bashrc` | Editor exports appended only after `y/N` confirmation + backup |

## Re-run Behavior

Idempotent: an up-to-date nvim skips installation and an existing `init.lua` that matches the baseline is left alone. Re-run after moving the config to a different machine or upgrading Neovim across 0.10 — the generated file is specific to the host it was written for.

`rig update` (or `update.sh`) upgrades the distro package normally; when `~/.local/bin/nvim` is the rig-managed static build it re-fetches the latest release instead. `rig uninstall` removes the package only when the package manager installed it, removes the static build and symlink when present, and notes when the editor exports were left in `~/.zshrc`/`~/.bashrc`.

## Dependencies

- `sudo` for package installation and `update-alternatives` (skipped when unavailable).
- `curl` + `tar` only for the static-binary fallback.
