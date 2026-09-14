# setup-tailscale.sh

Installs [Tailscale](https://tailscale.com/) VPN mesh network, optionally connects to a tailnet.

## OS Support

Tailscale's official installer supports all major platforms:

| OS | Installation Method |
|----|-------------------|
| Debian/Ubuntu | Official script (adds apt repository) |
| CentOS/RHEL | Official script (adds yum/dnf repository) |
| Fedora | Official script (adds dnf repository) |
| Arch Linux | Official script (uses pacman) |
| macOS | Official script (uses Homebrew or App Store) |

## What Gets Installed

| Tool | Source | Description |
|------|--------|-------------|
| Tailscale | [tailscale.com/install.sh](https://tailscale.com/install.sh) | VPN mesh network client |

## How It Works

| Step | Action |
|------|--------|
| 1/2 | Install Tailscale: Linux via the official install script, macOS via `brew install --cask tailscale`. Skip if `tailscale` command exists. |
| 2/2 | If `TAILSCALE_AUTH_KEY` is set, run `tailscale up --auth-key=KEY`. Adds `--advertise-exit-node` only when `TAILSCALE_ADVERTISE_EXIT_NODE=1`. Otherwise print hint. |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TAILSCALE_AUTH_KEY` | _(empty)_ | Auth key for automatic `tailscale up`. Leave empty to install only. Create one at [Tailscale Admin Console](https://login.tailscale.com/admin/machines/new-linux). |
| `TAILSCALE_ADVERTISE_EXIT_NODE` | `0` | Set to `1` to advertise this host as a tailnet exit node. Off by default: offering to route other devices' traffic is a network-policy change and is opt-in. |

## Re-run Behavior

- Installation: skipped if `tailscale` command exists.
- Connection: `tailscale up` runs again with the provided auth key (Tailscale handles reconnection).

## Dependencies

- `curl`, `sudo`.

## Post-Install

```bash
# If no auth key was provided:
sudo tailscale up                              # interactive login
sudo tailscale up --auth-key=tskey-auth-xxxxx  # non-interactive

# Check status
tailscale status
tailscale ip
```
