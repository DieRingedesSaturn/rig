#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Containers Setup
# https://github.com/DieRingedesSaturn/rig
#
# One component, two interchangeable backends. Which one you get is decided in
# this order (highest priority first):
#
#   1. RIG_CONTAINER_ENGINE   explicit "podman" or "docker" always wins
#   2. the sole installed backend is preserved
#   3. RIG_PROFILE            desktop -> podman, vps -> docker
#   4. the OS default         Fedora/Arch -> podman, Debian/RHEL -> docker
#
# RIG_CONTAINER_MODE picks rootless (default) or rootful.
#
# All three keys live in ~/.config/rig/config:
#
#   RIG_PROFILE="desktop"
#   RIG_CONTAINER_ENGINE="auto"
#   RIG_CONTAINER_MODE="rootless"
#
# Non-negotiable contract — this script never overwrites a config file it did
# not create itself. Existing daemon.json / registries.conf files are merged or
# left alone, never clobbered.
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
# shellcheck source=lib/containers.sh
source "$SCRIPT_DIR/lib/containers.sh"
# shellcheck source=lib/podman.sh
source "$SCRIPT_DIR/lib/podman.sh"
# shellcheck source=lib/docker.sh
source "$SCRIPT_DIR/lib/docker.sh"

ENGINE="$(containers_engine)"
MODE="$(containers_mode)"
SOURCE="$(containers_engine_source)"
SAVE_CHOICE=0

have_podman=0
have_docker=0
command -v podman >/dev/null 2>&1 && have_podman=1
command -v docker >/dev/null 2>&1 && have_docker=1

# When auto detection is ambiguous, let an interactive user make the actual
# either/or decision. A sole existing engine was already selected above.
if [[ "$SOURCE" != "config" ]] && rig_can_prompt && \
   { [[ "$have_podman" -eq 0 && "$have_docker" -eq 0 ]] || \
     [[ "$have_podman" -eq 1 && "$have_docker" -eq 1 ]]; }; then
    echo "Container engine (Podman and Docker are alternatives):"
    echo "  [1] Podman"
    echo "  [2] Docker"
    read -rp "Choice [1/2, default: $ENGINE]: " engine_choice </dev/tty || engine_choice=""
    case "$engine_choice" in
        1) ENGINE="podman"; SOURCE="interactive"; SAVE_CHOICE=1 ;;
        2) ENGINE="docker"; SOURCE="interactive"; SAVE_CHOICE=1 ;;
        "") ;;
        *) echo "  Invalid choice; keeping $ENGINE." ;;
    esac
fi

# Docker rootless cannot work without a usable user systemd session. Make the
# fallback a user decision; never silently switch security models.
if [[ "$ENGINE" == "docker" && "$MODE" == "rootless" ]] && ! containers_have_user_systemd; then
    if rig_can_prompt; then
        echo ""
        echo "Docker rootless needs a working systemd user session, which is unavailable."
        if [[ "$have_podman" -eq 1 ]]; then
            echo "  [1] Keep installed Podman (recommended)"
            echo "  [2] Install/configure rootful Docker"
            echo "  [3] Stop; fix the systemd user session first"
            read -rp "Choice [1/2/3]: " mode_choice </dev/tty || mode_choice="3"
            case "$mode_choice" in
                1) ENGINE="podman"; MODE="rootless"; SOURCE="interactive"; SAVE_CHOICE=1 ;;
                2) MODE="rootful"; SOURCE="interactive"; SAVE_CHOICE=1 ;;
                *) echo "Stopped before changing the container engine."; exit 1 ;;
            esac
        else
            echo "  [1] Install/configure rootful Docker"
            echo "  [2] Stop; fix the systemd user session first (recommended)"
            read -rp "Choice [1/2]: " mode_choice </dev/tty || mode_choice="2"
            case "$mode_choice" in
                1) MODE="rootful"; SOURCE="interactive"; SAVE_CHOICE=1 ;;
                *) echo "Stopped before installing Docker."; exit 1 ;;
            esac
        fi
    else
        echo "Error: Docker rootless requires a usable systemd user session." >&2
        echo "       Fix it first, or explicitly set RIG_CONTAINER_MODE=rootful." >&2
        [[ "$have_podman" -eq 1 ]] && echo "       Podman is already installed; set RIG_CONTAINER_ENGINE=podman to keep it." >&2
        exit 1
    fi
fi

echo "=== Containers Setup ==="
echo "  platform: $OS_DISTRO ($OS_FAMILY, $PKG_MANAGER)"
echo "  backend:  $ENGINE ($MODE)  [chosen by: $SOURCE]"
if [[ -f "$(rig_config_file)" ]]; then
    echo "  config:   $(rig_config_file)"
else
    echo "  config:   $(rig_config_file) (absent — using defaults)"
fi
echo ""

# Explain a surprising backend choice once, so the reason is never a mystery.
case "$SOURCE" in
    installed)
        echo "  Preserving the already-installed $ENGINE backend; the alternative will not be installed."
        echo ""
        ;;
    os)
        echo "  Using the $OS_FAMILY default ($ENGINE). To pin this instead of"
        echo "  relying on detection, put this in $(rig_config_file):"
        echo "      RIG_CONTAINER_ENGINE=\"$ENGINE\""
        echo ""
        ;;
esac

# --- Dispatch ----------------------------------------------------------------

case "$ENGINE" in
    podman)
        setup_podman
        ;;
    docker)
        case "$MODE" in
            rootless) setup_docker_rootless ;;
            rootful)  setup_docker_rootful ;;
        esac
        ;;
    *)
        echo "Error: no backend selected." >&2
        exit 1
        ;;
esac

if [[ "$SAVE_CHOICE" -eq 1 ]]; then
    rig_config_set RIG_CONTAINER_ENGINE "$ENGINE"
    rig_config_set RIG_CONTAINER_MODE "$MODE"
    echo "  Saved container choice in $(rig_config_file)."
fi

# --- Report ------------------------------------------------------------------

echo ""
echo "=== Done ==="
BIN="$(containers_binary "$ENGINE")"
VER="$(containers_version "$ENGINE" 2>/dev/null || true)"
if [[ -n "$BIN" ]]; then
    echo "$ENGINE: $BIN (v${VER:-unknown})"
else
    echo "$ENGINE: not found on PATH"
fi

# Docker and Podman are not drop-in replacements for each other; be explicit
# about which CLI the user should now be typing.
case "$ENGINE" in
    podman)
        echo "Use: podman run ... / podman compose ..."
        if command -v docker >/dev/null 2>&1; then
            echo "Note: a docker CLI is also present. This script does not alias it"
            echo "      to podman — the two are separate tools with separate storage."
        fi
        ;;
    docker)
        echo "Use: docker run ... / docker compose ..."
        ;;
esac
