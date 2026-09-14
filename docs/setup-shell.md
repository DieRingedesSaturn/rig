# setup-shell.sh

Installs zsh, Starship, and the zsh-autosuggestions + zsh-syntax-highlighting plugins — all from the distro package manager. Deliberately **not** a zsh framework installer: no Oh My Zsh, no plugin git clones, no prompt presets.

## Design Contract

This component is non-destructive by construction. It never overwrites a file it did not create itself:

| Path | Behaviour |
|------|-----------|
| `~/.zshrc` | **Read-only, always.** Never created, never appended to, never backed up, never restored. |
| `~/.config/starship.toml` | Created **only when absent**. An existing config is never overwritten — not even to apply a preset. |
| Default login shell | **Reported, never changed.** No `chsh` is ever run. |
| Packages | Installed via the distro package manager only. The sole exception is the Starship fallback below. |

Anything that would require editing your files is printed as a checklist at the end of the run, for you to apply yourself. This keeps the component compatible with dotfiles repositories that track `~/.zshrc` and `~/.config/starship.toml` — running it leaves those repos clean.

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
| Starship | Package manager, or [starship.rs](https://starship.rs/) installer | Fallback installs to `~/.local/bin` (no sudo) when the distro does not package it |
| zsh-autosuggestions | Package manager | distro package, not a git clone |
| zsh-syntax-highlighting | Package manager | distro package, not a git clone |

Package names are resolved through `lib/pkg-maps.sh`, so the same abstract names work across all supported distros.

## How It Works

| Step | Action |
|------|--------|
| 1/5 | Install `zsh` and `curl` (skipped on macOS, where both are built in). Then best-effort install `starship`, `zsh-autosuggestions`, `zsh-syntax-highlighting`; a package the distro does not ship is reported, not fatal |
| 2/5 | Ensure Starship exists. If the package manager could not provide it, run the upstream installer into `~/.local/bin` |
| 3/5 | Probe for the plugin files. Package managers disagree about where they land, so a candidate list is searched rather than one path hardcoded |
| 4/5 | Create `~/.config/starship.toml` **only if missing** |
| 5/5 | Read `~/.zshrc` and report: which plugins it loads, whether the Starship init line is present, whether zsh is the login shell, and any line-order advisory |

## Plugin Locations Probed

| OS | Paths searched |
|----|----------------|
| Fedora / Debian / RHEL | `/usr/share/<name>/<file>`, `/usr/local/share/<name>/<file>` |
| Arch | `/usr/share/zsh/plugins/<name>/<file>`, `/usr/share/<name>/<file>` |
| macOS | `/opt/homebrew/share/<name>/<file>` (Apple Silicon), `/usr/local/share/<name>/<file>` (Intel) |

## Files Created / Modified

| File | Action |
|------|--------|
| `~/.config/starship.toml` | Created only when absent; commented stub pointing at the upstream config reference |
| `~/.zshrc` | **Never touched** |
| `/etc/passwd` | **Never touched** |

## Re-run Behaviour

Fully idempotent. Already-installed packages are skipped, an existing `starship.toml` is left alone, and the `.zshrc` report is read-only — re-running it any number of times changes nothing on disk.

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

## Dependencies

- `sudo` on Linux for package installation
- Network access only if the Starship fallback installer is needed

## Notes

- Starship icons require a [Nerd Font](https://www.nerdfonts.com/) in your terminal.
- Removing this component with `uninstall.sh` deletes the packages it installed but **keeps your `~/.zshrc` and `starship.toml`**, and does not revert your login shell.
