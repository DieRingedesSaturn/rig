#!/usr/bin/env bash
set -euo pipefail

# Source library dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"

# Usage:
#   GIT_USER_NAME="Your Name" GIT_USER_EMAIL="you@example.com" ./setup-git.sh
#   ./setup-git.sh   # install only, skip config if env vars not set
#
# Environment variables:
#   GIT_USER_NAME  - git config --global user.name
#   GIT_USER_EMAIL - git config --global user.email

GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

# Ensure dependencies
if ! command -v git &>/dev/null; then
    pkg_install git
fi

echo "=== Git Setup ==="

# When a terminal is available and nothing is configured yet, ask instead of
# silently skipping — a git without user.name/user.email cannot commit.
# install.sh pre-collects this in the plan phase and marks it asked, so the
# prompt never stalls the component stage; standalone runs still ask here.
if rig_can_prompt && [[ -z "${RIG_GIT_IDENTITY_ASKED:-}" && "${RIG_NON_INTERACTIVE:-0}" -eq 0 ]]; then
    if [[ -z "$GIT_USER_NAME" ]] && [[ -z "$(git config --global user.name 2>/dev/null)" ]]; then
        read -rp "  git user.name (blank to skip): " GIT_USER_NAME </dev/tty || GIT_USER_NAME=""
    fi
    if [[ -z "$GIT_USER_EMAIL" ]] && [[ -z "$(git config --global user.email 2>/dev/null)" ]]; then
        read -rp "  git user.email (blank to skip): " GIT_USER_EMAIL </dev/tty || GIT_USER_EMAIL=""
    fi
fi

# [1/2] Configure user
echo "[1/2] Configuring user..."
if [ -n "$GIT_USER_NAME" ]; then
    git config --global user.name "$GIT_USER_NAME"
    echo "  user.name = $GIT_USER_NAME"
else
    echo "  Skipped user.name (GIT_USER_NAME not set)."
fi

if [ -n "$GIT_USER_EMAIL" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
    echo "  user.email = $GIT_USER_EMAIL"
else
    echo "  Skipped user.email (GIT_USER_EMAIL not set)."
fi

# [2/2] Sensible defaults
echo "[2/2] Setting defaults..."
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
git config --global core.autocrlf input
echo "  init.defaultBranch = main"
echo "  pull.rebase = true"
echo "  push.autoSetupRemote = true"
echo "  core.autocrlf = input"

echo ""
echo "=== Done! ==="
echo "Git: $(git --version)"
[ -n "$GIT_USER_NAME" ] && echo "Name:  $GIT_USER_NAME" || echo "Name:  (not set)"
[ -n "$GIT_USER_EMAIL" ] && echo "Email: $GIT_USER_EMAIL" || echo "Email: (not set)"
