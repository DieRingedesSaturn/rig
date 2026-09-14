#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Tool Selection Helpers
# https://github.com/DieRingedesSaturn/rig
#
# Some tools are only meaningful in a particular session. A clipboard helper is
# the clearest example: xclip is an X11 program and does nothing on Wayland or
# on a headless server, where wl-copy or nothing at all is correct.
#
# Expecting the wrong one produces a permanent false "missing" in status output
# on machines that are in fact correctly provisioned.
#
# Must be sourced after lib/os-detect.sh.
#
# Exported functions:
#   tools_command_available    - whether an abstract tool capability exists
#   tools_clipboard_tool      - the command this session needs, or empty
#   tools_clipboard_package   - the package providing it, or empty
# =============================================================================

if [[ -n "${_LIB_TOOLS_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_LIB_TOOLS_LOADED=1

if [[ -z "${OS_FAMILY:-}" ]]; then
    echo "Error: lib/tools.sh requires lib/os-detect.sh to be sourced first." >&2
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# tools_command_available <abstract package name>
# Check capabilities rather than package names: Fedora's wget2-wget and
# Debian's fd-find/batcat are valid providers even though their RPM/DEB names
# differ from the traditional command package.
tools_command_available() {
    case "$1" in
        ripgrep)     command -v rg >/dev/null 2>&1 ;;
        jq)          command -v jq >/dev/null 2>&1 ;;
        fd)          command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1 ;;
        bat)         command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1 ;;
        tree)        command -v tree >/dev/null 2>&1 ;;
        shellcheck)  command -v shellcheck >/dev/null 2>&1 ;;
        build-tools) command -v make >/dev/null 2>&1 && command -v cc >/dev/null 2>&1 ;;
        wget)        command -v wget >/dev/null 2>&1 ;;
        unzip)       command -v unzip >/dev/null 2>&1 ;;
        fastfetch)   command -v fastfetch >/dev/null 2>&1 ;;
        *)           return 1 ;;
    esac
}

# RIG_CLIPBOARD_TOOL - auto (default) | pbcopy | wl-copy | xclip | none
#
# auto       detect from the session
# <command>  force a specific helper, for unusual setups
# none       never install one
#
# Resolved through lib/rig-config.sh when it is loaded, so the key can live in
# ~/.config/rig/config per machine. Otherwise the plain environment variable is
# used. Precedence is the same either way: environment beats config file.
tools_clipboard_preference() {
    if declare -f rig_config_get >/dev/null 2>&1; then
        rig_config_get RIG_CLIPBOARD_TOOL auto
    else
        printf '%s\n' "${RIG_CLIPBOARD_TOOL:-auto}"
    fi
}

# tools_clipboard_tool - Print the clipboard command this session needs.
# Empty output means no helper is needed (or wanted).
tools_clipboard_tool() {
    local pref
    pref="$(tools_clipboard_preference)"

    case "$pref" in
        none) printf '\n'; return 0 ;;
        pbcopy|wl-copy|xclip) printf '%s\n' "$pref"; return 0 ;;
        ''|auto) ;;
        *)
            echo "Warning: RIG_CLIPBOARD_TOOL='$pref' is not recognised" >&2
            echo "         (expected auto, pbcopy, wl-copy, xclip or none)" >&2
            ;;
    esac

    # macOS has pbcopy built in.
    if is_macos; then
        printf 'pbcopy\n'
        return 0
    fi

    # Wayland first: a Wayland session often still exports DISPLAY for XWayland,
    # so checking DISPLAY first would pick xclip on a Wayland desktop.
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        printf 'wl-copy\n'
        return 0
    fi

    if [[ -n "${DISPLAY:-}" ]]; then
        printf 'xclip\n'
        return 0
    fi

    # Headless: no display server, so there is nothing for a clipboard helper
    # to talk to. tmux covers this case with OSC 52 instead.
    printf '\n'
}

# tools_clipboard_package - Print the package providing tools_clipboard_tool.
# Empty output means nothing to install.
tools_clipboard_package() {
    case "$(tools_clipboard_tool)" in
        wl-copy) printf 'wl-clipboard\n' ;;
        xclip)   printf 'xclip\n' ;;
        *)       printf '\n' ;;
    esac
}

# tools_clipboard_origin - Print a short human-readable reason, for reporting.
tools_clipboard_origin() {
    case "$(tools_clipboard_preference)" in
        none)
            echo "disabled by RIG_CLIPBOARD_TOOL"
            return 0
            ;;
        pbcopy|wl-copy|xclip)
            # Explicitly requested, so do not claim it was detected.
            echo "set explicitly"
            return 0
            ;;
    esac

    case "$(tools_clipboard_tool)" in
        pbcopy)  echo "built into macOS" ;;
        wl-copy) echo "Wayland session detected" ;;
        xclip)   echo "X11 session detected" ;;
        *)       echo "no display server (headless)" ;;
    esac
}
