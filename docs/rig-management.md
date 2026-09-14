# Rig Management

[中文](zh/rig-management.md)

Tools for managing your rig installation after initial setup — presets, status checking, config export/import, and safe uninstallation.

## OS Support

All management tools work on all supported platforms (Debian/Ubuntu, CentOS/RHEL, Fedora, Arch Linux, and macOS). The tools automatically detect your OS and use the appropriate package manager.

## Overview

Beyond `install.sh` and `update.sh`, rig provides a CLI wrapper (`rig`) and several management scripts:

| Command | Script | Description |
|---------|--------|-------------|
| `rig install` | `install.sh` | Install components (now with `--preset` support) |
| `rig apply --profile NAME` | `install.sh --preset NAME` | Apply a named host profile (`--dry-run` previews it) |
| `rig update` | `update.sh` | Update installed components |
| `rig status` | `status.sh` | Show installed components, versions, config status |
| `rig security` | `setup-security.sh` | Security hardening & port audit (`rig security status` for report) |
| `rig doctor` | `status.sh --doctor` | Full health, component, and security diagnostic report |
| `rig export` | `export-config.sh` | Export configuration to JSON + secrets file |
| `rig import` | `import-config.sh` | Import configuration from exported files |
| `rig uninstall` | `uninstall.sh` | Safely remove components |
| `rig version` | — | Print rig version |
| `rig help` | — | Show usage information |

The `rig` CLI is installed to `~/.local/bin/rig` during installation. Each subcommand downloads and executes its corresponding script from GitHub (respecting `GH_PROXY` if set).

## Preset System

Presets are predefined component bundles for common use cases. Instead of selecting individual components, pick a preset that matches your workflow.

### Available Presets

| Preset | Components | Use Case |
|--------|------------|----------|
| `minimal` | shell, tools, git | Lightweight base environment |
| `agent` | shell, tools, git, node | Shell + tooling + Node.js runtime |
| `devops` | shell, tools, git, node, containers, tailscale, ssh | Server and infrastructure work |
| `vps` | shell, git, tools, neovim, containers, tailscale, ssh, security | Production VPS server baseline with hardening |
| `fullstack` | shell, tmux, git, tools, node, uv, containers, ssh | Everything for full-stack development |

### Usage

```bash
# Install with a preset (interactive — confirms before proceeding)
rig install --preset agent

# Install with a preset (non-interactive via curl)
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --preset minimal

# With proxy
rig install --preset devops --gh-proxy https://gh-proxy.org
```

Presets set the initial component selection. The interactive TUI still appears, so you can add or remove components before confirming. In non-interactive mode (`curl | bash`), the preset selection is used as-is.

Dependencies declared in the registry are resolved automatically. No component currently declares one.

## CLI Commands

### rig install

Install components interactively, by preset, or by component list.

```bash
rig install                          # Interactive TUI
rig install --preset agent           # Preset selection
rig install --components shell,node  # Specific components
rig install --all                    # Everything
```

All flags from `install.sh` are supported: `--gh-proxy`, `--verbose`, `--all`, `--components`, `--preset`.

### rig update

Update installed components. See [setup-update.md](setup-update.md) for details.

```bash
rig update                           # Interactive — select from installed
rig update --all                     # Update all installed components
rig update --components containers,node  # Update specific components
```

### rig status

Show a table of all components with installation status, version, and configuration state.

```bash
rig status
```

Output example:

```
Component               Status    Version              Config
─────────────────────────────────────────────────────────────────
Shell Environment       ✔         zsh 5.9               configured
Tmux                    ✘         —                      —
Git                     ✔         2.43.0                 configured
Essential Tools         ✔         rg 14.1 / jq 1.7      configured
Node.js (nvm)           ✔         v24.1.0                configured
```

Status symbols:

| Symbol | Meaning |
|--------|---------|
| `✔` | Installed and detected |
| `◐` | Partially installed (binary present, not configured) |
| `✘` | Not installed |

### rig export

Export current rig configuration to portable files.

```bash
rig export
```

Creates two files in `~/.rig/`:

- `rig-config.json` — component list and non-sensitive configuration
- `secrets.env` — API keys and sensitive values (chmod 600)

See [Export/Import Workflow](#exportimport-workflow) for details.

### rig import

Import configuration from previously exported files.

```bash
rig import ~/.rig/rig-config.json
```

Reads the JSON config, sources the companion `secrets.env` if present, shows an install plan, and runs `install.sh` with the appropriate components and environment variables.

### rig uninstall

Remove a component with dependency checking and config backup.

```bash
rig uninstall containers         # Remove the container backend (safety checks)
rig uninstall containers --force # Skip dependency checks
```

See [Uninstall Safety](#uninstall-safety) for details.

### rig version

Print the rig version.

```bash
rig version
```

### rig help

Show usage information and available commands.

```bash
rig help
```

## Export/Import Workflow

Export and import allow you to capture a rig configuration and reproduce it on another machine.

### What Gets Exported

**Non-sensitive configuration** (`rig-config.json`):

- List of installed components
- Git user name and email
- Node.js version
- Container engine and registry mirrors
- Go version
- Component-specific settings

**Sensitive data** (`secrets.env`):

- `TAILSCALE_AUTH_KEY`

### JSON Format

The `rig-config.json` file contains a structured representation of the rig state:

```json
{
  "version": "1",
  "exported_at": "2025-05-14T12:00:00Z",
  "components": ["shell", "tools", "git", "node", "containers"],
  "config": {
    "git_user": "Your Name",
    "git_email": "you@example.com",
    "node_version": "24",
    "containers_engine": "podman"
  }
}
```

### secrets.env Format

The `secrets.env` file uses standard shell variable syntax:

```bash
TAILSCALE_AUTH_KEY=tskey-auth-xxxxx
```

### Security Considerations

- `secrets.env` is created with `chmod 600` (owner read/write only).
- A `.gitignore` is auto-generated in `~/.rig/` to prevent accidental commits:
  ```
  secrets.env
  ```
- The export script prints a warning about sensitive data in `secrets.env`.
- Transfer `secrets.env` via secure channels (scp, encrypted messaging). Do not commit it to version control.

### Team Setup Example

Share a rig configuration across a team:

```bash
# On the source machine — export config
rig export

# Share the config file (safe to commit)
cp ~/.rig/rig-config.json /path/to/team-repo/rig-config.json

# Share secrets separately (never commit)
scp ~/.rig/secrets.env user@new-machine:~/.rig/secrets.env

# On the target machine — import and install
rig import /path/to/team-repo/rig-config.json
```

The import script automatically picks up `secrets.env` from the same directory as the JSON config, or from `~/.rig/secrets.env`.

## Uninstall Safety

The uninstall system prevents accidental breakage through dependency checking, config backup, and data preservation prompts.

### Dependency Checking

Before removing a component, `uninstall.sh` checks if other installed components depend on it:

```bash
$ rig uninstall docker
Error: Cannot uninstall Docker — the following components depend on it:
  - some-future-component

Use --force to override dependency checks.
```

No component currently declares a dependent, so this check passes for every
component today. The mechanism is driven by the `COMP_DEPENDENTS` array in
`uninstall.sh`.

### Config Backups

Rig-created backups are centralized under `~/.local/share/rig/backups/` instead of being scattered beside live files in the home directory or `/etc`:

| Component | Backup Source |
|-----------|----------------|
| Shell | Nothing — it never writes your `~/.zshrc` or `starship.toml` |
| Tmux | `~/.tmux.conf` |
| Git | `~/.gitconfig` |
| SSH | `/etc/ssh/sshd_config` |

User configuration goes to `backups/user/`; privileged configuration goes to `backups/system/`, with ownership returned to the current user. Backups remain after uninstall and are never automatically deleted. Legacy `.bak.*` / `.rig-backup` files are still recognized for restore compatibility.

### Data Preservation Prompts

For components with user data, the uninstall script asks before deleting:

```
Docker has local data:
  - Volumes in /var/lib/docker
  - Container images

Delete all Docker data? [y/N]
```

Answering `N` (the default) removes the Docker packages but preserves data on disk.

### Force Mode

The `--force` flag bypasses dependency checks but still performs config backups and data prompts:

```bash
rig uninstall node --force    # Remove Node.js even if dependents exist
```

## Examples

### Quick Start with a Preset

Set up a machine for AI coding agent work:

```bash
# Install the rig CLI
curl -fsSL https://raw.githubusercontent.com/DieRingedesSaturn/rig/master/install.sh | bash -s -- --preset agent

# Verify what was installed
rig status
```

### Customizing After a Preset

Start with `minimal` and add components:

```bash
# Start with minimal base
rig install --preset minimal

# Later, add containers and uv
rig install --components containers,uv
```

Components already installed are skipped — `install.sh` is idempotent.

### Exporting Config for a Team

```bash
# Export your current setup
rig export

# The JSON config is safe for version control
cat ~/.rig/rig-config.json

# Teammate imports it on a fresh machine
# (after receiving secrets.env via secure channel)
rig import rig-config.json
```

### Safely Removing Components

```bash
# Check what's installed first
rig status

# Remove a component (with safety checks)
rig uninstall containers

# Force-remove if needed
rig uninstall node --force

# Verify the result
rig status
```
