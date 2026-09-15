# rig

[中文](README_CN.md)

Automated baseline manager and lightweight VPS state manager for Linux and macOS.

### What does this program specifically do?

1. **Detect & Audit System State**
   - **Port Exposure & Container Audit**: Runs `ss -lntup` to inspect all active TCP/UDP listening sockets and bind addresses, distinguishing `127.0.0.1` (internal) from `0.0.0.0` (publicly exposed), cross-referencing against the declared firewall whitelist, and alerting on undeclared public container/system ports (mitigating Docker port forwards bypassing UFW);
   - **Security Baseline Checks**: Verifies the presence of a non-root admin user, `sudo` access, authorized public keys in `~/.ssh/authorized_keys`, and current `PermitRootLogin` and `PasswordAuthentication` settings in `/etc/ssh/sshd_config`;
   - **Runtime Conflict Detection**: Scans for pre-existing system `node`/`npm` prior to installing nvm to prevent shadowed binaries and npm global path conflicts; detects distro-specific command aliases (e.g. `fdfind`, `batcat` on Debian) and manages symlinks.

2. **Install Core Packages**
   - **Terminal & Base Tools**: Installs `zsh`, `starship`, `tmux`, `git`, `neovim` (>= 0.9), and zsh-autosuggestions / zsh-syntax-highlighting directly via native package managers (apt, dnf, pacman, brew);
   - **Essential CLI Toolchain**: Installs `ripgrep` (`rg`), `jq`, `fd`, `bat`, `gh` (GitHub CLI), `tree`, `shellcheck`, `curl`, `wget`, `unzip`, and build essentials (gcc/make);
   - **Runtimes & Containers**: Installs `nvm` with Node.js LTS (v24) and the Python `uv` package manager; provisions and configures `docker-ce` (with rootless support) or `podman`;
   - **Networking & Services**: Installs the `tailscale` mesh VPN client, `openssh-server`, and the distro-native firewall manager (`ufw` on Debian/Ubuntu, `firewalld` on Fedora/RHEL).

3. **Configure & Harden System Files**
   - **`/etc/ssh/sshd_config`**: Applies `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, and custom ports, guarded by preflight syntax validation (`sshd -t`);
   - **Firewall Policy**: Sets default inbound deny (`deny incoming`) and outbound allow (`allow outgoing`), pre-opens the SSH port (restricted to `tailscale0`, using a dedicated firewalld zone when needed), and opens declared public ports (e.g. `80/tcp`, `443/tcp`);
   - **User Configurations**:
     - `~/.config/nvim/init.lua`: Writes a dependency-free, high-performance single-file Lua configuration (Everforest 16-color ANSI palette, adaptive Wayland / OSC 52 clipboard), configures default system editor (`EDITOR`, `VISUAL`, `SUDO_EDITOR`, `update-alternatives`) to `nvim`, and sets `alias vim=nvim`;
     - `~/.config/starship.toml`: Writes a clean, modern prompt configuration (repo-anchored directory path, trailing `[HH:MM]` timestamp, Python venv & Node.js runtime aware);
     - `~/.tmux.conf`: Configures mouse wheel support, large scrollback buffers, and auto-adapts clipboard integration (`wl-copy` on Wayland, `xclip` on X11, `pbcopy` on macOS, and OSC 52 on headless VPS);
     - `~/.gitconfig`: Sets `init.defaultBranch=main`, `pull.rebase=true`, and user identity;
     - `~/.ssh/config`: Injects a `Host github.com` block routing git SSH via `ssh.github.com:443` + `corkscrew` when `SSH_PROXY_PORT` is set;
     - `~/.config/rig/config`: Persists host-level component profiles and baseline settings.

4. **Safety Guarantees & Non-Invasive Constraints**
   - **Zero Unprompted Overwrites**: Existing files such as `~/.zshrc`, `~/.tmux.conf`, `~/.config/starship.toml`, and `~/.config/nvim` are never overwritten; missing snippets are reported as a checklist;
   - **Anti-Lockout Gate**: Strictly refuses to disable root SSH login or password authentication unless a non-root admin user with verified `sudo` rights and working SSH public key is present;
   - **Data Preservation**: The uninstaller preserves `~/.nvm` (protecting all installed Node versions and global packages) and `~/.ssh/` keys by default.

## Supported Operating Systems

| OS | Package Manager | Status |
|----|----------------|--------|
| Debian/Ubuntu | `apt` | ✓ Full support |
| CentOS/RHEL | `yum`/`dnf` | ✓ Full support |
| Fedora | `dnf` | ✓ Full support |
| Arch Linux | `pacman` | ✓ Full support |
| macOS | `brew` | ✓ Full support (see [macOS notes](#macos-notes)) |

> All scripts are **idempotent** — safe to run multiple times. Already installed components are skipped automatically. Requires `curl`, `git`, and `sudo` (except some macOS operations).

## Quick Start

Use `install.sh` for a one-stop interactive or non-interactive installation.

> **Note:** After installation, the `rig` CLI will be automatically installed to `~/.local/bin/rig`. You can then use commands like `rig status`, `rig security status`, `rig doctor`, `rig export`, `rig uninstall`, etc. See [Management Tools](docs/rig-management.md) for details.

<p align="center">
  <img src="assets/demo.gif" alt="install.sh demo" width="700">
</p>

Interactive TUI — select what to install:

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash
```

Via proxy (recommended for China):

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --gh-proxy https://gh-proxy.org
```

> **💡 China users:** Every download here respects `--gh-proxy` / `GH_PROXY`. Set it once and the rest of the scripts no longer need it.

Install everything non-interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --all
```

Specific components only:

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --components shell,tools,neovim,containers,security
```

Verbose mode (show raw script output instead of spinner):

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --all --verbose
```

Available components: `shell`, `tmux`, `git`, `tools`, `neovim`, `node`, `uv`, `containers`, `tailscale`, `ssh`, `security`

**New:** Use presets for common setups:
```bash
# VPS baseline with security & firewall (shell, git, tools, neovim, containers, tailscale, ssh, security)
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --preset vps

# Preview the same profile without changing the machine
rig apply --profile vps --dry-run

# See all presets: minimal, agent, devops, vps, fullstack
# Docs: https://github.com/DieRingedesSaturn/rig/blob/master/docs/rig-management.md
```

## Components

Each script can also be run standalone. All scripts support two install styles — direct and via gh-proxy:

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/<script> | bash
```

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/<script> | bash
```

---

### Base Environment

#### Shell (`setup-shell.sh`)

Installs zsh, [Starship](https://starship.rs/), and the autosuggestions + syntax-highlighting plugins — all from your distro's package manager. No Oh My Zsh, no framework, no git clones.

Requires `sudo` on Linux (to install packages).

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-shell.sh | bash
```

Via proxy:

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-shell.sh | bash
```

**This component never edits files it did not create.** `~/.zshrc` is read but never written; `~/.config/starship.toml` is only created when absent (an existing config is never overwritten, not even to apply a preset); your login shell is reported but never changed. Anything that would require editing your files is printed as a checklist to run yourself.

See [docs/setup-shell.md](docs/setup-shell.md).

#### Tmux (`setup-tmux.sh`)

Installs [tmux](https://github.com/tmux/tmux) and, only when no configuration exists yet, writes a minimal `~/.tmux.conf`: extended keys, mouse support, a large scrollback, and a clipboard binding chosen for the machine. No TPM, no Catppuccin, no plugins.

Requires `sudo` on Linux.

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tmux.sh | bash
```

Via proxy:

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tmux.sh | bash
```

**An existing `~/.tmux.conf` is never overwritten** — it is only read, and anything missing is printed as a checklist. The clipboard binding adapts to the machine: `wl-copy` on Wayland, `xclip` on X11, `pbcopy` on macOS, and OSC 52 (no external command) on a headless VPS.

Config: `TMUX_MOUSE`, `TMUX_HISTORY_LIMIT` — see [Configuration Reference](#configuration-reference).

#### Git (`setup-git.sh`)

Configures Git global `user.name`, `user.email`, and sensible defaults (`init.defaultBranch=main`, `pull.rebase=true`, etc.).

```bash
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="you@example.com"
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-git.sh | bash
```

Config: `GIT_USER_NAME`, `GIT_USER_EMAIL` — see [Configuration Reference](#configuration-reference).

#### Essential Tools (`setup-tools.sh`)

Installs the everyday CLI set: `rg`, `jq`, `fd`, `bat`, `tree`, `shellcheck`, `fastfetch`, `gh`, `wget`, `unzip`, plus build tools (gcc/make).

The clipboard helper is **chosen by session detection**, not hardcoded — `xclip` is an X11 program and does nothing on Wayland or on a headless server:

| Session | Helper | Package |
|---------|--------|---------|
| macOS | `pbcopy` | built in |
| Wayland | `wl-copy` | `wl-clipboard` |
| X11 | `xclip` | `xclip` |
| Headless / VPS | none | none installed |

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tools.sh | bash
```

Force or disable it with `RIG_CLIPBOARD_TOOL=auto|pbcopy|wl-copy|xclip|none`.

Config: `RIG_CLIPBOARD_TOOL` — see [Configuration Reference](#configuration-reference).

#### Containers (`setup-containers.sh`)

One component with two interchangeable backends. Installs **Podman** or **Docker**, and picks between them from your configuration:

| # | Source | Result |
|---|--------|--------|
| 1 | `RIG_CONTAINER_ENGINE` | `podman` / `docker` — always wins |
| 2 | Sole installed backend | keep Podman when Podman exists; keep Docker when Docker exists |
| 3 | `RIG_PROFILE` | `desktop` → Podman, `vps` → Docker |
| 4 | OS default | Fedora/Arch → Podman, Debian/RHEL → Docker |

`RIG_CONTAINER_MODE` selects `rootless` (default) or `rootful`. Explicit configuration always wins. In auto mode Podman and Docker are alternatives, so Rig does not install Docker over an existing Podman setup. If Docker rootless lacks a usable systemd user session, interactive mode offers to keep Podman, use rootful Docker, or stop and repair the session first.

Requires `sudo` on Linux.

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-containers.sh | bash
```

Pick the backend on the command line:

```bash
RIG_CONTAINER_ENGINE=podman RIG_CONTAINER_MODE=rootless \
  bash <(curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-containers.sh)
```

Via proxy:

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-containers.sh | bash
```

Podman is daemonless: one package, no service to enable. Rootless Docker is a user-level daemon under `systemctl --user`, with state in `~/.local/share/docker` and config in `~/.config/docker/daemon.json` — not `/etc/docker`. Linger is enabled so it survives reboot on a headless VPS.

`rig status` reports only the selected backend, e.g. `Podman 5.8.4 (rootless)`.

Config: `RIG_CONTAINER_ENGINE`, `RIG_CONTAINER_MODE`, `RIG_PROFILE`, `PODMAN_REGISTRY_MIRRORS`, `DOCKER_MIRROR`, `DOCKER_LOG_SIZE`, `DOCKER_LOG_FILES` — see [Configuration Reference](#configuration-reference).

#### Tailscale (`setup-tailscale.sh`)

Installs [Tailscale](https://tailscale.com/) VPN mesh network.

Install only:

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tailscale.sh | bash
```

Install + auto connect:

```bash
export TAILSCALE_AUTH_KEY=tskey-auth-xxxxx
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-tailscale.sh | bash
```

#### SSH (`setup-ssh.sh`)

Configures OpenSSH server: custom port, authorized keys, and an optional GitHub SSH transport proxy (sshd hardening handled by `setup-security.sh`).

Install only (ensure sshd running):

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-ssh.sh | bash
```

Change port + add authorized key:

```bash
export SSH_PORT=2222
export SSH_PUBKEY="ssh-ed25519 AAAA..."
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-ssh.sh | bash
```

With the GitHub SSH transport proxy — routes `git@github.com` via `ssh.github.com:443` through a local HTTP proxy when outbound SSH:22 is blocked (not related to `GH_PROXY`, the script download mirror):

```bash
export SSH_PROXY_PORT=7890
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-ssh.sh | bash
```

Config: `SSH_PORT`, `SSH_PUBKEY`, `SSH_PROXY_PORT` — see [Configuration Reference](#configuration-reference).

In an interactive terminal, `setup-security.sh` separately asks whether SSH is public or Tailscale-only and which public TCP ports, if any, should be opened in addition to SSH. Ports 80/443 are no longer implicit defaults; enter `none` to clear the extra list. Successfully applied choices are saved in Rig's configuration.

Rig-created user and system configuration backups are centralized under `~/.local/share/rig/backups/{user,system}/` rather than scattered beside live files.

---

### Language Runtimes

#### Node.js (`setup-node.sh`)

Installs [nvm](https://github.com/nvm-sh/nvm) and Node.js.

Default (Node.js 24):

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-node.sh | bash
```

Specific version:

```bash
export NODE_VERSION=22
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-node.sh | bash
```

Via proxy:

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-node.sh | bash
```

#### uv + Python (`setup-uv.sh`)

Installs [uv](https://docs.astral.sh/uv/) package manager, optionally installs a Python version.

uv only:

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-uv.sh | bash
```

uv + Python:

```bash
export UV_PYTHON=3.12
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-uv.sh | bash
```

Via proxy:

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/setup-uv.sh | bash
```

---

## Configuration Reference

All environment variables across all scripts in one table.

### General

| Variable | Scope | Default | Description |
|----------|-------|---------|-------------|
| `GH_PROXY` | `install.sh` | _(empty)_ | URL-prefix mirror for downloading rig scripts (e.g. `https://gh-proxy.org`) |

### Tmux

| Variable | Default | Description |
|----------|---------|-------------|
| `TMUX_MOUSE` | `1` | Write `set -g mouse on` into a newly created config (`0` to skip) |
| `TMUX_HISTORY_LIMIT` | `100000` | Scrollback buffer size |

### Git

| Variable | Default | Description |
|----------|---------|-------------|
| `GIT_USER_NAME` | _(empty)_ | `git config --global user.name` value |
| `GIT_USER_EMAIL` | _(empty)_ | `git config --global user.email` value |

### Node.js

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_VERSION` | `24` | Node.js major version (also accepted as first argument) |
| `NVM_NODEJS_ORG_MIRROR` | _(empty)_ | Node.js binary mirror. Auto-set when `GH_PROXY` is set. |
| `NPM_REGISTRY` | _(empty)_ | npm registry URL. Auto-set when `GH_PROXY` is set. |

### uv + Python

| Variable | Default | Description |
|----------|---------|-------------|
| `UV_PYTHON` | _(empty)_ | Python version to install (also accepted as first argument) |

### Tools

| Variable | Default | Description |
|----------|---------|-------------|
| `RIG_CLIPBOARD_TOOL` | `auto` | Clipboard helper to install: `auto`, `pbcopy`, `wl-copy`, `xclip` or `none` |

### Containers

| Variable | Default | Description |
|----------|---------|-------------|
| `RIG_CONTAINER_ENGINE` | `auto` | `auto`, `podman` or `docker`. An explicit value beats every other rule |
| `RIG_CONTAINER_MODE` | `rootless` | `rootless` or `rootful` |
| `RIG_PROFILE` | _(empty)_ | `desktop` (→ Podman) or `vps` (→ Docker) |
| `PODMAN_REGISTRY_MIRRORS` | _(empty)_ | Registry mirrors for Podman, comma-separated |
| `DOCKER_MIRROR` | _(empty)_ | Registry mirror URL(s) for Docker, comma-separated |
| `DOCKER_LOG_SIZE` | `20m` | Max size per log file (Docker) |
| `DOCKER_LOG_FILES` | `3` | Max number of log files (Docker) |

### Config file

`~/.config/rig/config` holds settings that outlive a single command. It is parsed, never sourced, and an environment variable of the same name overrides it:

```bash
RIG_PROFILE="desktop"
RIG_CONTAINER_ENGINE="auto"
RIG_CONTAINER_MODE="rootless"

RIG_COMPONENTS="
shell
tmux
git
containers
"
```

| Key | Description |
|-----|-------------|
| `RIG_COMPONENTS` | Default component list for `rig install` when no `--all` / `--components` / `--preset` is given |
| `RIG_PROFILE` | `desktop` or `vps` |
| `RIG_CONTAINER_ENGINE` | `auto`, `podman` or `docker` |
| `RIG_CONTAINER_MODE` | `rootless` or `rootful` |
| `RIG_CLIPBOARD_TOOL` | `auto`, `pbcopy`, `wl-copy`, `xclip` or `none` |

### Tailscale

| Variable | Default | Description |
|----------|---------|-------------|
| `TAILSCALE_AUTH_KEY` | _(empty)_ | Auth key for auto-connect. Leave empty to install only. |

### SSH

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_PORT` | _(empty)_ | Custom SSH port. Leave empty to keep current port. |
| `SSH_PUBKEY` | _(empty)_ | Public key string. When set, adds key to authorized_keys (password hardening is performed by security component). |
| `SSH_PRIVATE_KEY` | _(empty)_ | Private key content. When set, imports to `~/.ssh/` for outbound SSH. |
| `SSH_PROXY_HOST` | `127.0.0.1` | Local HTTP proxy host for GitHub's SSH transport (e.g. Clash). Only used when `SSH_PROXY_PORT` is set. |
| `SSH_PROXY_PORT` | _(empty)_ | Local HTTP proxy port (e.g. `7890`). Routes `git@github.com` via `ssh.github.com:443` + corkscrew, for networks blocking outbound SSH:22. Unrelated to `GH_PROXY`. |

## Bootstrap Guide

Step-by-step flow for setting up a fresh machine. The recommended order ensures dependencies are met.

**1. Proxy** (so subsequent downloads are faster — replace with your own proxy URL)

```bash
export GH_PROXY=https://gh-proxy.org
```

**2. Install everything**

```bash
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --all
```

Or install components individually in this order:

1. `setup-shell.sh` — Shell environment (zsh, Starship, plugins — no framework)
2. `setup-tmux.sh` — Tmux + mouse + scrollback (with Unified Diff & interactive resolution)
3. `setup-git.sh` — Git user identity + defaults
4. `setup-tools.sh` — Essential CLI toolchain (rg, jq, fd, bat, gh, etc.)
5. `setup-neovim.sh` — Modern lightweight Neovim config & default editor
6. `setup-node.sh` — nvm + Node.js
7. `setup-uv.sh` — uv + Python
8. `setup-containers.sh` — Podman or Docker backend
9. `setup-tailscale.sh` — Tailscale VPN mesh network
10. `setup-ssh.sh` — OpenSSH server installation & client setup
11. `setup-security.sh` — Security hardening (Anti-Lockout, firewall, port audit)

## Detailed Documentation

See the [docs/](docs/) directory for in-depth documentation on each script — what gets installed, which files are created/modified, re-run behavior, and OS-specific notes.

## macOS Notes

macOS support has the following differences:

- **Containers**: Podman runs containers inside a Linux VM on macOS, so the script prints the `podman machine init` / `start` commands rather than downloading a VM image silently. Docker on macOS means Docker Desktop, and has no rootless mode.
- **SSH**: Uses macOS Remote Login instead of OpenSSH server configuration via `systemctl`.
- **Homebrew**: Automatically installed if not present. The scripts detect and use `brew` instead of `apt`/`yum`/`dnf`/`pacman`.
- **sudo**: Some Homebrew operations don't require sudo. The scripts handle this automatically.

## Notes

- Starship icons require a [Nerd Font](https://www.nerdfonts.com/) in your terminal.
- If `gh-proxy.org` is unavailable, check [ghproxy.link](https://ghproxy.link/) for alternatives.
- Re-running a script with different API keys/config will update the configuration without reinstalling.
