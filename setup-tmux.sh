#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Tmux Setup (lightweight)
# https://github.com/DieRingedesSaturn/rig
#
# Installs tmux and, only when no configuration exists yet, writes a minimal
# tmux.conf: extended keys, mouse support, a large scrollback, and a clipboard
# binding that is correct for the machine it runs on.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

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

# Clipboard handling depends on the machine, so probe instead of guessing:
#
#   macOS            -> pbcopy
#   Linux + Wayland  -> wl-copy      (package: wl-clipboard)
#   Linux + X11      -> xclip        (package: xclip)
#   headless / VPS   -> no external tool; rely on OSC 52 passthrough
#
# The headless case matters: a server has no display server, so a binding that
# shells out to wl-copy or xclip would simply fail there.

detect_clipboard() {
    if is_macos; then
        if command -v pbcopy >/dev/null 2>&1; then
            echo "pbcopy"
        fi
        return 0
    fi
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
        echo "wl-copy"
        return 0
    fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
        echo "xclip -selection clipboard"
        return 0
    fi
    return 0
}

CLIPBOARD_CMD="$(detect_clipboard)"

generate_config() {
    echo '# Rig Tmux Baseline'
    echo '# ─── General ───'
    echo 'set -g extended-keys on'
    echo 'set -g extended-keys-format csi-u'
    if [[ "$TMUX_MOUSE" == "1" ]]; then
        echo 'set -g mouse on'
    fi
    echo "set -g history-limit $TMUX_HISTORY_LIMIT"
    echo ''
    echo '# ─── Clipboard ───'
    if [[ -n "$CLIPBOARD_CMD" ]]; then
        echo "# Dragging a selection copies it via $CLIPBOARD_CMD"
        printf 'bind -T copy-mode MouseDragEnd1Pane send -X copy-pipe-and-cancel "%s"\n' "$CLIPBOARD_CMD"
        echo 'set -g set-clipboard on'
    else
        echo '# No display server or clipboard helper found, so tmux talks to the'
        echo '# terminal directly using OSC 52. Works over SSH with a terminal'
        echo '# that supports it (kitty, Konsole, WezTerm, iTerm2, Ghostty, ...).'
        echo 'set -g set-clipboard on'
    fi
}

show_diff() {
    local old_file="$1"
    local new_file="$2"
    echo ""
    echo "─── Configuration Diff (- existing / + recommended) ───"
    if command -v git >/dev/null 2>&1; then
        git diff --no-index --color=always "$old_file" "$new_file" || true
    elif diff --help 2>&1 | grep -q -- '--color'; then
        diff -u --color=always "$old_file" "$new_file" || true
    else
        diff -u "$old_file" "$new_file" || true
    fi
    echo "───────────────────────────────────────────────────────"
}

echo ""
echo "[3/3] Tmux configuration..."
if [[ -n "$EXISTING_CONF" ]]; then
    # Read-only check: report what the existing config is missing rather than
    # editing it blindly.
    rc_lines() { grep -n "$1" "$EXISTING_CONF" 2>/dev/null | grep -v ':[[:space:]]*#' || true; }
    rc_has() { [[ -n "$(rc_lines "$1")" ]]; }

    for setting in 'extended-keys' 'mouse' 'history-limit'; do
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

    TMP_BASELINE="$(mktemp "${TMPDIR:-/tmp}/rig-tmux-baseline.XXXXXX")"
    generate_config > "$TMP_BASELINE"

    # Compare existing with recommended baseline
    if cmp -s "$EXISTING_CONF" "$TMP_BASELINE"; then
        echo ""
        echo "  ✔ $EXISTING_CONF already matches the recommended baseline perfectly."
        rm -f "$TMP_BASELINE"
    else
        echo ""
        echo "  Notice: $EXISTING_CONF differs from the recommended baseline."
        show_diff "$EXISTING_CONF" "$TMP_BASELINE"

        if rig_can_prompt; then
            echo ""
            echo "How would you like to handle your existing $EXISTING_CONF?"
            echo "  [k] Keep existing configuration unchanged (default / safe)"
            echo "  [o] Overwrite with recommended baseline (creates a Rig backup)"
            echo "  [a] Append recommended baseline settings to end of file"
            echo "  [d] Show diff again"
            while true; do
                read -r -p "Choice [K/o/a/d]: " choice </dev/tty || choice="k"
                choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                case "$choice" in
                    o|overwrite)
                        BACKUP_CONF="$(rig_user_backup "$EXISTING_CONF" tmux)"
                        cat "$TMP_BASELINE" > "$EXISTING_CONF"
                        echo "  ✔ Backed up existing config to: $BACKUP_CONF"
                        echo "  ✔ Overwrote $EXISTING_CONF with recommended baseline."
                        break
                        ;;
                    a|append)
                        BACKUP_CONF="$(rig_user_backup "$EXISTING_CONF" tmux)"
                        {
                            echo ""
                            echo "# --- Appended by rig on $(date '+%Y-%m-%d %H:%M:%S') ---"
                            cat "$TMP_BASELINE"
                        } >> "$EXISTING_CONF"
                        echo "  ✔ Backed up existing config to: $BACKUP_CONF"
                        echo "  ✔ Appended baseline settings to $EXISTING_CONF."
                        break
                        ;;
                    d|diff)
                        show_diff "$EXISTING_CONF" "$TMP_BASELINE"
                        ;;
                    ""|k|keep)
                        echo "  Keeping existing $EXISTING_CONF untouched."
                        break
                        ;;
                    *)
                        echo "  Invalid choice: please enter k, o, a, or d."
                        ;;
                esac
            done
        else
            echo "  Non-interactive terminal: keeping existing $EXISTING_CONF untouched (default)."
            if [[ "${#MISSING_CONF[@]}" -gt 0 ]]; then
                echo "  Missing recommended options: ${MISSING_CONF[*]}"
            fi
        fi
        rm -f "$TMP_BASELINE"
    fi
else
    generate_config > "$TMUX_CONF"
    echo "  created $TMUX_CONF"
    if [[ -n "$CLIPBOARD_CMD" ]]; then
        echo "  clipboard: $CLIPBOARD_CMD"
    else
        echo "  clipboard: OSC 52 (no display server or clipboard helper detected)"
    fi
fi

echo ""
echo "=== Done ==="
echo "tmux: $(tmux -V 2>/dev/null || echo 'not found')"
if [[ -n "${TMUX:-}" ]]; then
    echo "Run 'tmux source-file ${EXISTING_CONF:-$TMUX_CONF}' to reload."
fi
