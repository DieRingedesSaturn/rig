# install.sh

All-in-one interactive or non-interactive installer. Downloads and executes individual setup scripts in dependency order.

## Overview

`install.sh` is a dispatcher that provides a TUI checkbox menu for selecting components, resolves dependencies, collects API keys, downloads the needed `setup-*.sh` scripts from GitHub, and executes them in order. It does not contain installation logic itself — each component's logic lives in its own script.

**OS Support:** Works on Debian/Ubuntu (apt), CentOS/RHEL (yum/dnf), Fedora (dnf), Arch Linux (pacman), and macOS (brew). The installer automatically detects the OS and uses the appropriate package manager.

## Modes

### Interactive TUI

When run with a terminal available and no `--all`/`--components` flag, a checkbox menu appears:

```
  > [x] Shell Environment        zsh + Starship, no Oh My Zsh                [sudo]
    [ ] Tmux                     tmux + Catppuccin + TPM plugins              [sudo]
    [x] Node.js (nvm)            nvm + Node.js 24
    ...
```

Controls: `↑↓` navigate, `Space` toggle, `a` toggle all, `Enter` confirm, `q` quit.

### Non-Interactive

- `--all` — select all components.
- `--components shell,node,containers` — select specific components by ID.

If piped (`curl | bash`) without flags and no `RIG_COMPONENTS` is configured, the script exits with a usage hint.

### From the config file

A component list declared in `~/.config/rig/config` is used as the default selection when the command line does not specify one:

```bash
# ~/.config/rig/config
RIG_COMPONENTS="
shell
tmux
git
containers
"
```

A bare `rig install` then installs exactly those components, non-interactively. The value may also be a single line — commas, spaces and newlines are all treated as separators. An explicit `--all`, `--components` or `--preset` on the command line takes precedence.

The file is parsed, never sourced, and only these keys are read: `RIG_COMPONENTS`, `RIG_PROFILE`, `RIG_CONTAINER_ENGINE`, `RIG_CONTAINER_MODE`. An environment variable of the same name overrides the file for one run.

## Execution Flow

1. **Parse arguments** — `--all`, `--components`, `--gh-proxy`, `--verbose`.
2. **Show TUI** (interactive) or validate selection (non-interactive).
3. **Resolve dependencies** — auto-adds any missing dependency declared in the registry. No component currently declares one, but the mechanism remains for future components.
4. **Show plan** — lists components in install order with tags (`sudo`, `key`, `install only`).
5. **Collect credentials** — prompts for a token where a component needs one (currently only Tailscale), or reads it from env vars (non-interactive). A missing token results in "install only" mode.
6. **Cache sudo** — pre-authenticates sudo if any selected component needs it, then keeps it alive in the background.
7. **Download scripts** — fetches all needed `setup-*.sh` to a temp directory (fail-fast: all downloads must succeed before any execution).
8. **Execute** — runs each script in order. In default mode, shows a spinner; in `--verbose` mode, shows raw output.
9. **Summary** — colored pass/fail report with post-install hints.

## Dependency Resolution

The registry carries a per-component dependency list (`COMP_DEPS`), and dependencies are auto-added and installed first. **No component currently declares a dependency**, so nothing is auto-added today.

Install order follows the array index in the component registry.

## Credential Handling

Only Tailscale needs a credential (an auth key, token-only):

- **With the env var set** (`TAILSCALE_AUTH_KEY`) — the tool is installed and connected.
- **Without it** — in interactive mode the script prompts for it (input is masked with `*`). Leaving it blank results in "install only" mode.
- **Install only** — the tool is installed but not configured. Post-install hints show which env var to set later.

## Error Handling

- `install.sh` uses `set -uo pipefail` (**no** `-e`), so one component's failure does not abort the rest.
- Each sub-script runs in its own `bash` subprocess with `set -euo pipefail`.
- On failure, the last 15 lines of the component's log are shown, with a path to the full log.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GH_PROXY` | _(empty)_ | GitHub proxy URL prefix for script downloads |
| `TAILSCALE_AUTH_KEY` | _(empty)_ | Auth key for Tailscale auto-connect |

All env vars from individual scripts are also respected (e.g., `NODE_VERSION`, `DOCKER_MIRROR`).

## Files Created

| File | Description |
|------|-------------|
| `/tmp/rig-install-*` | Temp directory for downloaded scripts (cleaned up on exit) |
| `/tmp/rig-install-*.component` | Per-component log files (kept on failure) |
