#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Tmux Setup (lightweight)
# https://github.com/DieRingedesSaturn/rig
#
# Installs tmux and, only when no configuration exists yet, writes a baseline
# tmux.conf decided for this machine: the option syntax matches the installed
# tmux version and the clipboard handling matches the session (desktop helper
# or OSC 52 on a headless host).
#
# Deliberately NOT a tmux framework installer: no TPM, no Catppuccin, no
# plugin git clones. The config is a handful of lines you can read in one go.
#
# Configuration contract:
#
#   ~/.tmux.conf                  read-only by default (offers diff & interactive options)
#   ~/.config/tmux/tmux.conf      read-only by default (offers diff & interactive options)
#   anything else                 untouched
#
# Existing configurations are never overwritten without explicit interactive confirmation
# and automatic timestamped backup.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"
# shellcheck source=lib/rig-config.sh
source "$SCRIPT_DIR/lib/rig-config.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/tools.sh
source "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=lib/tmux.sh
source "$SCRIPT_DIR/lib/tmux.sh"

TMUX_MOUSE="${TMUX_MOUSE:-1}"
TMUX_HISTORY_LIMIT="${TMUX_HISTORY_LIMIT:-100000}"

TMUX_CONF="$HOME/.tmux.conf"
TMUX_CONF_XDG="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
MISSING_CONF=()

echo "=== Tmux Setup (lightweight) ==="
echo "  platform: $OS_DISTRO ($OS_FAMILY, $PKG_MANAGER)"
echo ""

# --- [1/3] Package -----------------------------------------------------------

echo "[1/3] Installing tmux..."
if command -v tmux >/dev/null 2>&1; then
    echo "  already installed: $(command -v tmux) ($(tmux -V 2>/dev/null))"
else
    pkg_install tmux
    if ! command -v tmux >/dev/null 2>&1; then
        echo "Error: tmux is still not available after installation." >&2
        exit 1
    fi
    echo "  installed: $(command -v tmux) ($(tmux -V 2>/dev/null))"
fi

TMUX_VER="$(tmux_version)"
if ! rig_version_ge "$TMUX_VER" 2.4; then
    echo ""
    echo "  The rig baseline needs tmux 2.4 or newer; this host has $TMUX_VER."
    echo "  Leaving any existing configuration untouched."
    exit 0
fi

# Clipboard handling is decided per machine: a desktop helper when one fits
# the session, OSC 52 on headless hosts. tmux runs before tools in the
# install order, so the helper may still be missing — install it now.
CLIP="$(tools_clipboard_tool)"
if [[ -n "$CLIP" ]] && ! command -v "$CLIP" >/dev/null 2>&1; then
    CLIP_PKG="$(tools_clipboard_package)"
    if [[ -n "$CLIP_PKG" ]]; then
        if pkg_install "$CLIP_PKG"; then
            echo "  installed clipboard helper: $CLIP_PKG"
        else
            echo "  note: could not install $CLIP_PKG — clipboard copies will rely on OSC 52"
        fi
    fi
fi

# --- [2/3] Locate an existing configuration ---------------------------------

# tmux 3.1+ prefers $XDG_CONFIG_HOME/tmux/tmux.conf and falls back to
# ~/.tmux.conf. Either counts as "you already have a config".
echo ""
echo "[2/3] Locating your tmux configuration..."
EXISTING_CONF=""
for candidate in "$TMUX_CONF_XDG" "$TMUX_CONF"; do
    if [[ -f "$candidate" ]]; then
        EXISTING_CONF="$candidate"
        break
    fi
done

if [[ -n "$EXISTING_CONF" ]]; then
    echo "  keeping existing $EXISTING_CONF (left untouched)"
else
    echo "  no tmux configuration found"
fi

# --- [3/3] Write a starter config only when none exists ---------------------

echo ""
echo "[3/3] Tmux configuration..."
if [[ -n "$EXISTING_CONF" ]]; then
    # Read-only check: report what the existing config is missing rather than
    # editing it blindly.
    rc_lines() { grep -n "$1" "$EXISTING_CONF" 2>/dev/null | grep -v ':[[:space:]]*#' || true; }
    rc_has() { [[ -n "$(rc_lines "$1")" ]]; }

    if rc_has 'extended-keys'; then
        echo "  [note] extended-keys is on — apps without CSI-u support (nvim<0.10) receive raw escape sequences"
    fi

    for setting in 'mouse' 'history-limit'; do
        if rc_has "$setting"; then
            echo "  [ok] $setting is set"
        else
            echo "  [--] $setting is not set"
            MISSING_CONF+=("$setting")
        fi
    done

    if rc_has 'set-clipboard'; then
        echo "  [ok] clipboard handling is configured"
    elif rc_has 'copy-pipe' || rc_has 'copy-pipe-and-cancel'; then
        echo "  [ok] clipboard handling is configured"
    else
        echo "  [--] no clipboard handling found"
        MISSING_CONF+=("clipboard")
    fi

    # Advisory: external clipboard command mismatch
    for probe in pbcopy wl-copy xclip; do
        if rc_has "$probe" && ! command -v "$probe" >/dev/null 2>&1; then
            echo ""
            echo "  note: $EXISTING_CONF calls '$probe', which is not installed here."
            if [[ "$probe" == "pbcopy" ]] && ! is_macos; then
                echo "        pbcopy is macOS-only — that binding does nothing on $OS_DISTRO."
            elif [[ "$probe" == "xclip" && -n "${WAYLAND_DISPLAY:-}" ]]; then
                echo "        You are on Wayland; 'wl-copy' (wl-clipboard) is the right tool."
            elif [[ "$probe" == "wl-copy" && -z "${WAYLAND_DISPLAY:-}" ]]; then
                echo "        No Wayland session detected; use xclip on X11."
            fi
            echo "        Or drop the binding and use: set -g set-clipboard on (OSC 52)."
        fi
    done

    if [[ "${#MISSING_CONF[@]}" -gt 0 ]]; then
        echo "  Missing recommended options: ${MISSING_CONF[*]}"
    fi

    # Options the installed tmux would reject, and dead emacs-table bindings.
    tmux_config_advisories "$EXISTING_CONF" "$TMUX_VER"

    TMP_BASELINE="$(mktemp "${TMPDIR:-/tmp}/rig-tmux-baseline.XXXXXX")"
    tmux_baseline "$TMUX_VER" "$CLIP" "$EXISTING_CONF" "$TMUX_MOUSE" "$TMUX_HISTORY_LIMIT" > "$TMP_BASELINE"

    rig_offer_config_baseline "$EXISTING_CONF" "$TMP_BASELINE" tmux --allow-append
    rm -f "$TMP_BASELINE"
else
    tmux_baseline "$TMUX_VER" "$CLIP" "$TMUX_CONF" "$TMUX_MOUSE" "$TMUX_HISTORY_LIMIT" > "$TMUX_CONF"
    echo "  created $TMUX_CONF"
    sed -n '2p' "$TMUX_CONF"
fi

echo ""
echo "=== Done ==="
echo "tmux: $(tmux -V 2>/dev/null || echo 'not found')"
if [[ -n "${TMUX:-}" ]]; then
    echo "Run 'tmux source-file ${EXISTING_CONF:-$TMUX_CONF}' to reload."
fi
