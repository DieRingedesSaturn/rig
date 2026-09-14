#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./setup-tailscale.sh                              # install only
#   TAILSCALE_AUTH_KEY=tskey-auth-xxx ./setup-tailscale.sh  # install + auto connect
#
# Environment variables:
#   TAILSCALE_AUTH_KEY             - Auth key for automatic tailscale up (default: empty)
#   TAILSCALE_ADVERTISE_EXIT_NODE  - Set to 1 to also advertise this host as a
#                                    tailnet exit node (default: off — offering
#                                    to route other devices' traffic is a
#                                    network-policy change, so it is opt-in)

# --- Source multi-OS libraries ------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"

TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_ADVERTISE_EXIT_NODE="${TAILSCALE_ADVERTISE_EXIT_NODE:-0}"

echo "=== Tailscale Setup ==="

# [1/2] Install Tailscale
echo "[1/2] Installing Tailscale..."
if command -v tailscale &>/dev/null; then
    echo "  Tailscale already installed, skipping."
elif is_macos; then
    # tailscale.com/install.sh only supports Linux; on macOS use Homebrew.
    if command -v brew &>/dev/null; then
        brew install --cask tailscale
    else
        echo "  Homebrew not found. Install Tailscale from the App Store or" >&2
        echo "  install Homebrew first, then re-run this script." >&2
        exit 1
    fi
else
    # Ensure dependencies (the upstream installer needs curl)
    if ! command -v curl &>/dev/null; then
        pkg_install curl
    fi
    # tailscale.com/install.sh detects the distro and adds its package repo.
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# [2/2] Connect to Tailscale
echo "[2/2] Connecting to Tailscale..."
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    ts_up_args=(--auth-key="$TAILSCALE_AUTH_KEY")
    if [[ "$TAILSCALE_ADVERTISE_EXIT_NODE" == "1" ]]; then
        ts_up_args+=(--advertise-exit-node)
        echo "  Advertising this host as a tailnet exit node (TAILSCALE_ADVERTISE_EXIT_NODE=1)."
    fi
    sudo tailscale up "${ts_up_args[@]}"
    echo "  Connected to Tailscale network."
else
    echo "  No auth key provided. Run 'sudo tailscale up' to connect manually."
fi

echo ""
echo "=== Done! ==="
echo "Tailscale: $(tailscale version 2>/dev/null | head -1 || echo 'installed')"
