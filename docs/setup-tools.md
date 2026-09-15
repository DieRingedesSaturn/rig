# setup-tools.sh

Installs essential CLI tools that coding agents depend on daily — fast code search, JSON processing, GitHub CLI, build tools, and more.

## OS-Specific Package Names

The script automatically detects your OS and installs the appropriate packages:

| Tool | Debian/Ubuntu | CentOS/RHEL/Fedora | Arch Linux | macOS (Homebrew) |
|------|---------------|-------------------|------------|------------------|
| ripgrep | `ripgrep` | `ripgrep` | `ripgrep` | `ripgrep` |
| jq | `jq` | `jq` | `jq` | `jq` |
| fd | `fd-find` → symlink to `fd` | `fd-find` | `fd` | `fd` |
| bat | `bat` → symlink to `batcat` | `bat` | `bat` | `bat` |
| tree | `tree` | `tree` | `tree` | `tree` |
| gh | `gh` (via GitHub apt repo) | `gh` | `github-cli` | `gh` |
| shellcheck | `shellcheck` | `ShellCheck` | `shellcheck` | `shellcheck` |
| build tools | `build-essential` (gcc, g++, make) | `gcc`, `gcc-c++`, `make` | `base-devel` | Xcode Command Line Tools |
| wget | `wget` | `wget` | `wget` | `wget` |
| unzip | `unzip` | `unzip` | `unzip` | `unzip` |
| fastfetch | `fastfetch` + upstream fallback | `fastfetch` + upstream fallback | `fastfetch` | `fastfetch` |
| clipboard | `wl-clipboard` (Wayland) or `xclip` (X11) | same | same | `pbcopy` (built-in) |

**Notes:**
- `fastfetch` is **optional** and installed separately from the batch — it is absent from older Debian/Ubuntu repos, and one unresolvable package name would fail the whole `apt-get` transaction. See [fastfetch fallback](#fastfetch-fallback).
- On Debian/Ubuntu, `fd-find` and `bat` are symlinked to `fd` and `bat` in `~/.local/bin/`
- On macOS, Xcode Command Line Tools are installed automatically if not present
- macOS uses the built-in `pbcopy`/`pbpaste` instead of an external helper
- The clipboard helper is **chosen by session detection**, not hardcoded: Wayland gets `wl-clipboard`, X11 gets `xclip`, a headless server gets neither (there is no display server to talk to), and macOS uses what it already has. See [Clipboard helper](#clipboard-helper).

## What Gets Installed

| Binary | Purpose |
|--------|---------|
| `rg` | Fast code search |
| `jq` | JSON processing |
| `fd` | Fast file finder |
| `bat` | Syntax-highlighted cat |
| `tree` | Directory structure visualization |
| `gh` | GitHub CLI (PRs, issues, API) |
| `shellcheck` | Shell script linting |
| `gcc`, `g++`, `make` | Native npm module compilation |
| `wget` | HTTP downloads |
| `unzip` | Archive extraction |
| `fastfetch` | Fast, lightweight system information display |

## How It Works

### Step 1: apt packages

Installs all packages via `apt-get install -y`. This is naturally idempotent — already-installed packages are skipped by apt.

### Step 2: GitHub CLI

The `gh` CLI requires adding GitHub's official apt repository:

```bash
# Add GitHub apt repo keyring and source list
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/...
echo "deb [...] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/...
sudo apt-get install -y gh
```

If `gh` is already installed, this step is skipped entirely.

### Step 3: Convenience symlinks

On Debian/Ubuntu, `fd-find` installs as `fdfind` and `bat` installs as `batcat` to avoid name conflicts. The script creates symlinks in `~/.local/bin/`:

- `~/.local/bin/fd` → `/usr/bin/fdfind`
- `~/.local/bin/bat` → `/usr/bin/batcat`

Symlinks are only created if the canonical name (`fd`, `bat`) is not already available.

## Re-run Behavior

The script is fully idempotent:

- `apt-get install` is naturally idempotent for already-installed packages.
- `gh` installation is skipped if the command already exists.
- Symlinks are only created if the target name is not already available.

## Dependencies

None. This component has no dependencies on other rig components.

## Environment Variables

None required. The script uses only system apt repositories and GitHub's official apt repo.

## Files Created

| File | Description |
|------|-------------|
| `~/.local/bin/bat` | Symlink to `batcat` (if needed) |
| `~/.local/bin/fd` | Symlink to `fdfind` (if needed) |
| `/etc/apt/keyrings/githubcli-archive-keyring.gpg` | GitHub CLI apt signing key |
| `/etc/apt/sources.list.d/github-cli.list` | GitHub CLI apt repository |

## Clipboard helper

`xclip` is an X11 program: on Wayland or on a headless server it does nothing. Installing it unconditionally, or expecting it in status output, produces a permanent false gap on machines that are in fact correctly provisioned. So the helper is derived from the session:

| Session | Helper | Package |
|---------|--------|---------|
| macOS | `pbcopy` | built in |
| Wayland (`WAYLAND_DISPLAY` set) | `wl-copy` | `wl-clipboard` |
| X11 (`DISPLAY` set, no Wayland) | `xclip` | `xclip` |
| Headless — no display server | none | none installed |

Wayland is checked **before** X11, because a Wayland session usually still exports `DISPLAY` for XWayland; checking `DISPLAY` first would pick `xclip` on a Wayland desktop.

Override it for an unusual setup:

```bash
RIG_CLIPBOARD_TOOL=auto      # default: detect
RIG_CLIPBOARD_TOOL=xclip     # force
RIG_CLIPBOARD_TOOL=none      # never install one
```

`status.sh` uses the same detection, so it only ever expects the helper that applies to the current session.

## fastfetch fallback

`fastfetch` is optional. Per the [upstream README](https://github.com/fastfetch-cli/fastfetch), the distro repos only carry it on Arch, Fedora, Alpine, openSUSE, Void, Debian 13+, and Ubuntu 25.04+. When the native repos miss it, the script asks once before reaching for upstream GitHub release assets (third-party binaries need consent):

```
fastfetch is not in debian's package repositories.
  Install from the upstream GitHub release (.deb/.rpm via sudo, else tarball into ~/.local/bin)? [y/N]
```

If confirmed, the first applicable method wins:

| System | Asset | Method |
|--------|-------|--------|
| Debian family | `fastfetch-linux-<arch>.deb` | `sudo dpkg -i` (+ `apt-get install -f` for deps) |
| dnf systems (Fedora/RHEL…) | `fastfetch-linux-<arch>.rpm` | `sudo dnf install` |
| zypper systems (openSUSE…) | `fastfetch-linux-<arch>.rpm` | `sudo zypper install` |
| anything else (incl. Alpine → musl asset, macOS, no sudo) | `fastfetch-<os>-<arch>.tar.gz` | extract binary into `~/.local/bin` — **rootless** |

If the installed binary fails to run (glibc too old), the `-polyfilled` build variant is retried automatically. A broken tarball copy left by us is removed again; a pre-existing `~/.local/bin/fastfetch` is never deleted.

Without a TTY nothing is downloaded — the script prints the asset names so you can install manually. `status.sh` does not count fastfetch as a required tool.

## Post-Install

Verify all tools are available:

```bash
command -v rg jq fd bat tree gh shellcheck gcc wget unzip
# plus your session's clipboard helper, if any:
command -v wl-copy   # Wayland
command -v xclip     # X11
```
