# setup-shell.sh

Installs zsh, Starship, and the zsh-autosuggestions + zsh-syntax-highlighting plugins — all from the distro package manager. Deliberately **not** a zsh framework installer: no Oh My Zsh, no plugin git clones, no prompt presets.

## Design Contract

This component is non-destructive by construction. Nothing is ever overwritten silently:

| Path | Behaviour |
|------|-----------|
| `~/.zshrc` | Read-only by default. Missing plugin/Starship init lines are appended only after an explicit `y/N` confirmation, with a timestamped backup first. |
| `~/.config/starship.toml` | Created when absent. An existing config triggers a diff + keep/overwrite/append prompt; overwrite/append take a timestamped backup first. |
| Default login shell | Reported; changed via `chsh` only after an explicit `y/N` confirmation. |
| Packages | Installed via the distro package manager only. The sole exception is the Starship fallback below. |

Without a usable `/dev/tty` (non-interactive run), nothing is edited at all — anything that would require touching your files is printed as a checklist at the end of the run, for you to apply yourself. This keeps the component compatible with dotfiles repositories that track `~/.zshrc` and `~/.config/starship.toml` — declining every prompt leaves those repos clean.

## OS Support

| OS | Package Manager | sudo Required |
|----|----------------|---------------|
| Debian/Ubuntu | `apt` | ✓ |
| CentOS/RHEL | `yum`/`dnf` | ✓ |
| Fedora | `dnf` | ✓ |
| Arch Linux | `pacman` | ✓ |
| macOS | `brew` | Not for zsh/curl (built in); Homebrew operations only |

## What Gets Installed

| Tool | Source | Notes |
|------|--------|-------|
| zsh | Package manager | Built in on macOS |
| curl | Package manager | Needed only for the Starship fallback |
| Starship | Package manager, or [starship.rs](https://starship.rs/) installer | Fallback installs to `~/.local/bin` (no sudo) when the distro does not package it; asks `y/N` first since it pipes a remote script to sh |
| zsh-autosuggestions | Package manager | distro package, not a git clone |
| zsh-syntax-highlighting | Package manager | distro package, not a git clone |

Package names are resolved through `lib/pkg-maps.sh`, so the same abstract names work across all supported distros.

## How It Works

| Step | Action |
|------|--------|
| 1/5 | Install `zsh` and `curl` (skipped on macOS, where both are built in). Then best-effort install `starship`, `zsh-autosuggestions`, `zsh-syntax-highlighting`; a package the distro does not ship is reported, not fatal |
| 2/5 | Ensure Starship exists. If the package manager could not provide it, run the upstream installer into `~/.local/bin` |
| 3/5 | Probe for the plugin files. Package managers disagree about where they land, so a candidate list is searched rather than one path hardcoded |
| 4/5 | Create `~/.config/starship.toml` when missing; existing files get the diff + keep/overwrite/append menu |
| 5/5 | Read `~/.zshrc` and report: which plugins it loads, whether the Starship init line is present, whether zsh is the login shell, and any line-order advisory. Missing init lines and a non-zsh login shell can be fixed on the spot via `y/N` prompts (backup first) |

## Plugin Locations Probed

| OS | Paths searched |
|----|----------------|
| Fedora / Debian / RHEL | `/usr/share/<name>/<file>`, `/usr/local/share/<name>/<file>` |
| Arch | `/usr/share/zsh/plugins/<name>/<file>`, `/usr/share/<name>/<file>` |
| macOS | `/opt/homebrew/share/<name>/<file>` (Apple Silicon), `/usr/local/share/<name>/<file>` (Intel) |

## Files Created / Modified

| File | Action |
|------|--------|
| `~/.config/starship.toml` | Created when absent (existing files get the diff menu); default prompt shows path, git state, language runtimes and time — plus a red `ssh:<hostname>` prefix inside SSH sessions |
| `~/.zshrc` | Appended to only after explicit `y/N` confirmation + backup |
| `/etc/passwd` | Login shell field updated only via `chsh` after `y/N` confirmation |

## Re-run Behaviour

Fully idempotent. Already-installed packages are skipped, an existing `starship.toml` is left alone unless you explicitly choose otherwise, and nothing is written without confirmation — declining every prompt leaves the disk unchanged.

## Post-Install Checklist

The script prints exactly what is still missing. Typically:

```bash
# add to ~/.zshrc yourself — the script will not do it for you
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
eval "$(starship init zsh)"

# and if zsh is not your login shell yet
chsh -s "$(command -v zsh)"
```

### Line order

Upstream requires `zsh-syntax-highlighting` to be sourced **last**, because it wraps the ZLE line editor; anything that loads after it can bypass the highlighting widget. If the script detects that autosuggestions or the Starship init line come after it, it prints an advisory. This is informational — changing it is optional.

## What the .zshrc offer contains

Step 5/5 collects every missing piece and shows the full list before asking — one `y/N` covers the whole block, and a backup is taken first:

| Missing in your `.zshrc` | Line appended |
|--------------------------|---------------|
| plugin not loaded | `source <plugin path>` (autosuggestions first, syntax-highlighting **last**) |
| Starship init absent | `eval "$(starship init zsh)"` |
| no `bindkey -e/-v` anywhere | `bindkey -e` — zsh picks vi mode when `EDITOR` contains "vi" (nvim counts), which breaks Ctrl+A/E |
| no `color=auto`/`CLICOLOR` | Linux: `eval "$(dircolors -b)"` + `ls`/`ll`/`la`/`grep --color=auto` aliases · macOS: `export CLICOLOR=1` + `ls -G` |

Each line is only offered when genuinely missing — your own aliases and keymap choices are never overwritten.

## Dependencies

- `sudo` on Linux for package installation
- Network access only if the Starship fallback installer is needed

## Notes

- Starship icons require a [Nerd Font](https://www.nerdfonts.com/) in your terminal.
- Removing this component with `uninstall.sh` deletes the packages it installed but **keeps your `~/.zshrc` and `starship.toml`**, and does not revert your login shell.
