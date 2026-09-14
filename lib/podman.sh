#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Containers — Podman backend
# https://github.com/DieRingedesSaturn/rig
#
# Podman is daemonless: there is no background service to install, enable or
# restart, and a normal user runs containers rootless with no extra setup
# beyond the subordinate UID/GID range every modern distro already allocates.
# On Fedora this makes it a single package install.
#
# Must be sourced after lib/containers.sh.
#
# Exported functions:
#   setup_podman   - Install and verify Podman
# =============================================================================

if [[ -n "${_CONTAINERS_PODMAN_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_CONTAINERS_PODMAN_LOADED=1

if ! declare -f containers_engine >/dev/null 2>&1; then
    echo "Error: lib/podman.sh requires lib/containers.sh to be sourced first." >&2
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# Optional registry mirrors, comma separated. Podman has no daemon.json; its
# equivalent lives in ~/.config/containers/registries.conf.
PODMAN_REGISTRY_MIRRORS="${PODMAN_REGISTRY_MIRRORS:-${RIG_REGISTRY_MIRRORS:-}}"

# _podman_write_registries_conf - Write user-level registry mirrors, if asked.
# Only ever writes when mirrors were configured; an existing file is backed up.
_podman_write_registries_conf() {
    [[ -n "$PODMAN_REGISTRY_MIRRORS" ]] || return 0

    local dir="$HOME/.config/containers"
    local conf="$dir/registries.conf"
    mkdir -p "$dir"

    if [[ -f "$conf" ]]; then
        echo "  keeping existing $conf (registry mirrors not applied)"
        return 0
    fi

    {
        echo "# Written by rig — user-level registry configuration for Podman."
        echo "# Reference: https://github.com/containers/image/blob/main/docs/containers-registries.conf.5.md"
        echo "unqualified-search-registries = [\"docker.io\"]"
        echo ""
        local mirror
        IFS=',' read -ra _mirrors <<< "$PODMAN_REGISTRY_MIRRORS"
        for mirror in "${_mirrors[@]}"; do
            mirror="$(echo "$mirror" | tr -d '[:space:]')"
            [[ -n "$mirror" ]] || continue
            echo "[[registry]]"
            echo "prefix = \"docker.io\""
            echo "location = \"docker.io\""
            echo "  [[registry.mirror]]"
            echo "  location = \"$mirror\""
            echo ""
        done
    } > "$conf"
    unset _mirrors
    echo "  wrote $conf (registry mirrors)"
}

# setup_podman - Install Podman and verify rootless operation.
setup_podman() {
    echo "[podman] Installing Podman..."

    if command -v podman >/dev/null 2>&1; then
        echo "  already installed: $(command -v podman) ($(podman --version 2>/dev/null))"
    else
        pkg_install podman
        if ! command -v podman >/dev/null 2>&1; then
            echo "Error: podman is still not available after installation." >&2
            exit 1
        fi
        echo "  installed: $(command -v podman) ($(podman --version 2>/dev/null))"
    fi

    if is_macos; then
        # Podman on macOS runs containers inside a Linux VM, so a machine has to
        # be created before anything works. That downloads a large image, so it
        # is reported rather than triggered silently.
        echo ""
        echo "[podman] Podman on macOS needs a Linux VM:"
        if podman machine list 2>/dev/null | grep -q '^podman-machine'; then
            echo "  a machine already exists:"
            podman machine list 2>/dev/null | sed 's/^/    /'
        else
            echo "  run these yourself:"
            echo "      podman machine init"
            echo "      podman machine start"
        fi
        return 0
    fi

    # Linux: rootless is the default mode and needs no daemon.
    echo ""
    echo "[podman] Verifying rootless operation..."

    if [[ "$(containers_subid_status)" != "ok" ]]; then
        containers_report_subid
        containers_ensure_subid
    else
        containers_report_subid
    fi

    local rootless
    rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
    if [[ "$rootless" == "true" ]]; then
        echo "  rootless: yes"
    elif [[ -n "$rootless" ]]; then
        echo "  rootless: no (running as root)"
    else
        echo "  rootless: could not determine (podman info failed)"
    fi

    local mode
    mode="$(containers_mode)"
    if [[ "$mode" == "rootful" ]]; then
        echo ""
        echo "  note: RIG_CONTAINER_MODE=rootful, but Podman is daemonless."
        echo "        The same package serves both modes; containers run as root only"
        echo "        when you invoke podman through sudo. Nothing extra to install."
    fi

    _podman_write_registries_conf

    echo ""
    echo "[podman] Compose support"
    if podman compose version >/dev/null 2>&1; then
        echo "  'podman compose' is available"
    elif command -v podman-compose >/dev/null 2>&1; then
        echo "  podman-compose is available"
    else
        echo "  no compose provider installed — 'podman compose' needs one:"
        echo "      Fedora:        sudo dnf install podman-compose"
        echo "      Arch:          sudo pacman -S podman-compose"
        echo "      Debian/Ubuntu: sudo apt install podman-compose"
        echo "  (or keep using docker compose against the Docker backend)"
    fi
}
