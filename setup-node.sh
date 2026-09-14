#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Node.js Setup (nvm, non-destructive)
# https://github.com/DieRingedesSaturn/rig
#
# Installs nvm and a Node.js version through it, and reports every other Node
# installation it can find instead of pretending they do not exist. A machine
# can easily have three: a distro package, an older nvm version, and the nvm
# version currently active.
#
# Non-negotiable contract — this script never removes or edits what it did not
# create itself:
#
#   ~/.nvm              never deleted; an incomplete install is reported, not
#                       cleaned up behind your back
#   ~/.zshrc            read-only, always
#   ~/.npmrc            written only when you explicitly ask for a registry
#   system node/npm     reported, never touched
#
# Usage:
#   ./setup-node.sh            # install nvm + Node.js 24 (fresh machines only)
#   ./setup-node.sh 22         # install Node.js 22 via nvm
#   NODE_VERSION=20 ./setup-node.sh
#
# Environment variables:
#   NODE_VERSION              Node.js major version (also accepted as $1)
#   NVM_NODEJS_ORG_MIRROR     Node binary mirror
#   NPM_REGISTRY              npm registry to write into ~/.npmrc
#   GH_PROXY                  GitHub proxy URL; auto-sets both mirrors above
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"

# Empty means the user did not specify, so an existing Node.js is left alone.
_USER_NODE_VERSION="${NODE_VERSION:-${1:-}}"
NODE_VERSION="${_USER_NODE_VERSION:-24}"
NVM_NODEJS_ORG_MIRROR="${NVM_NODEJS_ORG_MIRROR:-}"
NPM_REGISTRY="${NPM_REGISTRY:-}"
GH_PROXY="${GH_PROXY:-}"

if [[ -n "$GH_PROXY" ]]; then
    [[ -z "$NVM_NODEJS_ORG_MIRROR" ]] && NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
    [[ -z "$NPM_REGISTRY" ]]          && NPM_REGISTRY="https://registry.npmmirror.com"
fi

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
ZSHRC="$HOME/.zshrc"

echo "=== Node.js Setup (nvm) ==="
echo "  platform: $OS_DISTRO ($OS_FAMILY, $PKG_MANAGER)"
echo ""

# --- Helpers -----------------------------------------------------------------

# node_outside_nvm / npm_outside_nvm - Find a binary that is NOT managed by nvm.
# Run these before nvm is loaded so PATH still resolves to the system install.
_binary_outside_nvm() {
    local name="$1" candidate
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        case "$candidate" in
            "$NVM_DIR"/*) continue ;;
        esac
        printf '%s\n' "$candidate"
        return 0
    done < <(type -a -p "$name" 2>/dev/null || true)
    return 1
}

# nvm_versions - Print the Node versions nvm has installed, space separated.
nvm_versions() {
    [[ -d "$NVM_DIR/versions/node" ]] || return 0
    local d
    for d in "$NVM_DIR"/versions/node/*/; do
        [[ -d "$d" ]] || continue
        basename "$d"
    done | sort | tr '\n' ' '
}

# --- [1/4] Survey every Node.js on this machine -------------------------------

# Detected before nvm is loaded, so nothing is shadowed.
SYSTEM_NODE="$(_binary_outside_nvm node || true)"
SYSTEM_NPM="$(_binary_outside_nvm npm || true)"

echo "[1/4] Existing Node.js installations"
if [[ -n "$SYSTEM_NODE" ]]; then
    echo "  system node:    $SYSTEM_NODE ($("$SYSTEM_NODE" --version 2>/dev/null || echo '?'))"
else
    echo "  system node:    none found outside nvm"
fi
if [[ -n "$SYSTEM_NPM" ]]; then
    echo "  system npm:     $SYSTEM_NPM ($("$SYSTEM_NPM" --version 2>/dev/null || echo '?'))"
fi

if [[ -f "$NVM_DIR/nvm.sh" ]]; then
    echo "  nvm:            $NVM_DIR (installed)"
    _versions="$(nvm_versions)"
    echo "  nvm versions:   ${_versions:-(none yet)}"
else
    echo "  nvm:            not installed"
fi

# --- [2/4] Install nvm when absent -------------------------------------------

echo ""
echo "[2/4] nvm"

if [[ -f "$NVM_DIR/nvm.sh" ]]; then
    echo "  already installed, skipping"
elif [[ -d "$NVM_DIR" ]]; then
    # nvm.sh is gone but the directory is not. This is either an interrupted
    # install or a stray NVM_DIR. Deleting it could destroy installed Node
    # versions and every globally installed package, so it is never automatic.
    echo "  WARNING: $NVM_DIR exists but $NVM_DIR/nvm.sh is missing." >&2
    _versions="$(nvm_versions)"
    if [[ -n "$_versions" ]]; then
        echo "           Installed Node versions found: $_versions" >&2
        echo "           Refusing to touch it. Repair or remove it yourself:" >&2
        echo "             rm -rf $NVM_DIR   # then re-run this script" >&2
        exit 1
    fi
    echo "           No Node versions inside, so it looks like a partial install." >&2
    echo "           Remove it and re-run:" >&2
    echo "             rm -rf $NVM_DIR" >&2
    exit 1
else
    echo "  installing nvm into $NVM_DIR"
    if ! command -v curl >/dev/null 2>&1; then
        pkg_install curl
    fi
    _GH="github.com"
    curl -fsSL "https://${_GH}/nvm-sh/nvm/raw/HEAD/install.sh" | bash
    if [[ ! -f "$NVM_DIR/nvm.sh" ]]; then
        echo "Error: nvm did not install correctly." >&2
        exit 1
    fi
    echo "  installed"
fi

# Load nvm for this run.
export NVM_DIR
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh" || true

# --- [3/4] Node.js -----------------------------------------------------------

echo ""
echo "[3/4] Node.js"

_current="$(nvm current 2>/dev/null || echo none)"

if [[ "$_current" != "none" && "$_current" != "system" && -z "$_USER_NODE_VERSION" ]]; then
    # nvm already provides a Node.js and no specific version was requested, so
    # there is nothing to decide — leave the machine as the user set it up.
    echo "  nvm active version: $_current — nothing to install"
    echo "  (pass a version to add another, e.g. '$0 24')"
else
    # Only nvm-managed versions count here; a distro Node is not a substitute.
    _target="$(nvm ls --no-colors "$NODE_VERSION" 2>/dev/null | grep -E 'v[0-9]' | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "")"

    if [[ -n "$_target" ]]; then
        echo "  Node.js $NODE_VERSION already present via nvm ($_target)"
    else
        if [[ -n "$NVM_NODEJS_ORG_MIRROR" ]]; then
            export NVM_NODEJS_ORG_MIRROR
            echo "  node mirror: $NVM_NODEJS_ORG_MIRROR"
        fi
        echo "  installing Node.js $NODE_VERSION via nvm"
        nvm install "$NODE_VERSION"
    fi

    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION" >/dev/null
    echo "  default alias -> $NODE_VERSION"

    # A distro package with the same major version is a common surprise: two
    # different Node 24s, one of which the shell may or may not pick up.
    if [[ -n "$SYSTEM_NODE" ]]; then
        _sys_major="$("$SYSTEM_NODE" --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
        _want_major="${NODE_VERSION%%.*}"
        if [[ "$_sys_major" == "$_want_major" ]]; then
            echo ""
            echo "  note: the system already has Node $_sys_major at $SYSTEM_NODE."
            echo "        You now have two Node $_want_major installs. nvm comes first"
            echo "        on PATH once ~/.zshrc loads it, but 'sudo npm -g' and other"
            echo "        PATH-independent callers will hit the system one."
        fi
    fi
fi

# --- [4/4] Shell integration and npm -----------------------------------------

echo ""
echo "[4/4] Shell integration"

# Read-only check. This script does not edit ~/.zshrc — the shell component is
# the only thing that ever writes a starter config, and even that refuses to
# touch an existing file.
if [[ -f "$ZSHRC" ]] && grep -q 'NVM_DIR' "$ZSHRC"; then
    echo "  $ZSHRC already loads nvm"
else
    echo "  $ZSHRC does not load nvm; add this yourself:"
    echo ""
    echo "      export NVM_DIR=\"\$HOME/.nvm\""
    echo "      [ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\""
    echo "      [ -s \"\$NVM_DIR/bash_completion\" ] && \\. \"\$NVM_DIR/bash_completion\""
fi

echo ""
if [[ -n "$NPM_REGISTRY" ]]; then
    echo "  npm registry -> $NPM_REGISTRY (writing ~/.npmrc)"
    npm config set registry "$NPM_REGISTRY"
else
    echo "  npm registry: $(npm config get registry 2>/dev/null || echo 'default') (set NPM_REGISTRY to change)"
fi

echo ""
echo "=== Done ==="
echo "node: $(command -v node 2>/dev/null || echo 'not on PATH') ($(node -v 2>/dev/null || echo '?'))"
echo "npm:  $(command -v npm 2>/dev/null || echo 'not on PATH') ($(npm -v 2>/dev/null || echo '?'))"
echo "nvm:  $(command -v nvm 2>/dev/null >/dev/null && echo 'loaded' || echo "$NVM_DIR")"
