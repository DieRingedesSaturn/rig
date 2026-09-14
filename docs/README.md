# Documentation

[中文](zh/README.md)

Detailed documentation for each setup script. For quick start, see the [main README](../README.md).

## OS Compatibility

All scripts automatically detect the operating system and use the appropriate package manager:

| Component | Debian/Ubuntu | CentOS/RHEL | Fedora | Arch Linux | macOS |
|-----------|---------------|-------------|--------|------------|-------|
| Shell (zsh, Starship, plugins) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Tmux (environment-aware clipboard) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Git | ✓ | ✓ | ✓ | ✓ | ✓ |
| Essential Tools | ✓ | ✓ | ✓ | ✓ | ✓ |
| Neovim (modern single-file config) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Containers (Podman / Docker) | ✓ | ✓ | ✓ | ✓ | ✓ (Podman VM or Docker Desktop) |
| Tailscale | ✓ | ✓ | ✓ | ✓ | ✓ |
| SSH (OpenSSH server & client) | ✓ | ✓ | ✓ | ✓ | ✓ (Remote Login) |
| Security (Anti-Lockout & firewall) | ✓ | ✓ | ✓ | ✓ | — (Linux ufw/firewalld only) |
| Node.js (nvm) | ✓ | ✓ | ✓ | ✓ | ✓ |
| uv + Python | ✓ | ✓ | ✓ | ✓ | ✓ |

**Notes:**
- Containers defaults to Podman on Fedora/Arch and Docker on Debian/RHEL; see [setup-containers.md](setup-containers.md)
- SSH on macOS configures Remote Login instead of the OpenSSH server via systemd

## Scripts

### Base Environment

| Script | Description |
|--------|-------------|
| [install.sh](install.md) | All-in-one interactive/non-interactive installer |
| [setup-shell.sh](setup-shell.md) | zsh + Starship + plugins (no framework) |
| [setup-tmux.sh](setup-tmux.md) | tmux + mouse + scrollback (Unified Diff & interactive resolution) |
| [setup-git.sh](setup-git.md) | Git user identity + sensible defaults |
| [setup-tools.sh](setup-tools.md) | Essential CLI toolchain (rg, jq, fd, bat, gh, etc.) |
| [setup-neovim.sh](../setup-neovim.sh) | Neovim >= 0.9 modern config & default editor |
| [setup-containers.sh](setup-containers.md) | Podman or Docker backend, rootless by default |
| [setup-tailscale.sh](setup-tailscale.md) | Tailscale VPN mesh network |
| [setup-ssh.sh](setup-ssh.md) | OpenSSH server installation, custom port, and key import |
| [setup-security.sh](../setup-security.sh) | Security hardening core (Anti-Lockout, firewall, port audit) |

### Language Runtimes

| Script | Description |
|--------|-------------|
| [setup-node.sh](setup-node.md) | nvm + Node.js |
| [setup-uv.sh](setup-uv.md) | uv package manager + Python |

### Management

| Script | Description |
|--------|-------------|
| [rig](rig-management.md) | CLI wrapper — presets, status, export/import, uninstall |
| [update.sh](setup-update.md) | Update installed components |
| [status.sh](rig-management.md#rig-status) | Show installed components and versions |
| [export-config.sh](rig-management.md#rig-export) | Export configuration to JSON + secrets |
| [import-config.sh](rig-management.md#rig-import) | Import configuration from exported files |
| [uninstall.sh](rig-management.md#rig-uninstall) | Safely remove components |

## Design Principles

All scripts follow these conventions:

- **Idempotent** — safe to run multiple times. Already installed components are skipped, changed configuration is updated.
- **Standalone** — each script can be run independently via `curl | bash`.
- **Configurable** — behavior controlled via environment variables or CLI arguments.
- **Secure** — API keys passed via environment variables (not command arguments), config files set to `chmod 600`.
- **Fail-safe** — `set -euo pipefail` catches errors early.
