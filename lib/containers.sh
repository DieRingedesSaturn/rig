#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Containers — shared helpers
# https://github.com/DieRingedesSaturn/rig
#
# The containers component is one component with two interchangeable backends.
# This library owns everything that is backend-agnostic:
#
#   * resolving which backend to use (Podman or Docker)
#   * resolving rootless vs rootful
#   * subordinate UID/GID checks shared by both backends
#
# Backend specifics live in lib/podman.sh and lib/docker.sh.
#
# Must be sourced after lib/os-detect.sh, lib/pkg-maps.sh, lib/pkg-manager.sh
# and lib/rig-config.sh.
#
# Engine resolution order — highest priority first:
#   1. RIG_CONTAINER_ENGINE when explicitly set to podman or docker
#   2. the sole already-installed backend (preserve it; do not install another)
#   3. RIG_PROFILE            (desktop -> podman, vps -> docker)
#   4. OS default             (Fedora/Arch -> podman, Debian/RHEL -> docker)
# =============================================================================

# Guard against double-sourcing
if [[ -n "${_CONTAINERS_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_CONTAINERS_LOADED=1

for _chk in "os-detect:OS_FAMILY" "pkg-manager:pkg_install" "rig-config:rig_config_get"; do
    _file="${_chk%%:*}"
    _fn="${_chk##*:}"
    if [[ "$_file" == "os-detect" ]]; then
        if [[ -z "${OS_FAMILY:-}" ]]; then
            echo "Error: lib/containers.sh requires lib/os-detect.sh to be sourced first." >&2
            # shellcheck disable=SC2317
            return 1 2>/dev/null || exit 1
        fi
    elif ! declare -f "$_fn" >/dev/null 2>&1; then
        echo "Error: lib/containers.sh requires lib/${_file}.sh to be sourced first." >&2
        # shellcheck disable=SC2317
        return 1 2>/dev/null || exit 1
    fi
done
unset _chk _file _fn

# Rootless containers need a subordinate UID/GID range of at least this size.
# Both Docker and Podman document 65536 as the expected allocation.
CONTAINERS_MIN_SUBID=65536

# --- Engine / mode resolution ------------------------------------------------

# containers_profile - Print the configured profile ("desktop", "vps" or empty).
containers_profile() {
    rig_config_get RIG_PROFILE ''
}

# containers_engine_os_default - Print the backend this OS defaults to.
containers_engine_os_default() {
    case "$OS_FAMILY" in
        fedora|arch)
            echo "podman"
            ;;
        debian|rhel)
            echo "docker"
            ;;
        macos)
            # Both are reasonable on macOS; prefer whichever is already here,
            # otherwise Podman (no Docker Desktop licence involved).
            if command -v podman >/dev/null 2>&1; then
                echo "podman"
            elif command -v docker >/dev/null 2>&1; then
                echo "docker"
            else
                echo "podman"
            fi
            ;;
        *)
            echo "docker"
            ;;
    esac
}

# containers_engine_source - Print where the engine choice came from.
# One of: config | installed | profile | os. Must mirror containers_engine, so an
# invalid value is reported as the fallback it actually is.
containers_engine_source() {
    local want
    want="$(rig_config_get RIG_CONTAINER_ENGINE auto)"
    case "$want" in
        podman|docker) echo "config"; return 0 ;;
    esac
    if command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        echo "installed"; return 0
    elif command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
        echo "installed"; return 0
    fi
    case "$(containers_profile)" in
        desktop|vps) echo "profile"; return 0 ;;
    esac
    echo "os"
}

# containers_engine - Resolve the backend to use. Prints "podman" or "docker".
containers_engine() {
    local want
    want="$(rig_config_get RIG_CONTAINER_ENGINE auto)"
    case "$want" in
        podman|docker)
            printf '%s\n' "$want"
            return 0
            ;;
        ''|auto)
            ;;
        *)
            echo "Warning: RIG_CONTAINER_ENGINE='$want' is not a known backend" >&2
            echo "         (expected 'auto', 'podman' or 'docker') — falling back." >&2
            ;;
    esac

    # Podman and Docker are alternatives. If exactly one is already installed,
    # keep it instead of adding the other merely because a profile prefers it.
    if command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        echo "podman"
        return 0
    elif command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
        echo "docker"
        return 0
    fi

    case "$(containers_profile)" in
        desktop) echo "podman"; return 0 ;;
        vps)     echo "docker"; return 0 ;;
        ''|auto) ;;
        *)
            echo "Warning: RIG_PROFILE='$(containers_profile)' is not a known profile" >&2
            echo "         (expected 'desktop' or 'vps') — falling back to the OS default." >&2
            ;;
    esac

    containers_engine_os_default
}

# containers_mode - Resolve rootless vs rootful. Prints "rootless" or "rootful".
# Rootless is the default everywhere; rootful has to be asked for explicitly.
containers_mode() {
    local want
    want="$(rig_config_get RIG_CONTAINER_MODE rootless)"
    case "$want" in
        rootless|rootful)
            printf '%s\n' "$want"
            ;;
        *)
            echo "Warning: RIG_CONTAINER_MODE='$want' is not valid" >&2
            echo "         (expected 'rootless' or 'rootful') — using 'rootless'." >&2
            echo "rootless"
            ;;
    esac
}

# containers_binary - Print the CLI binary for a backend, or nothing.
containers_binary() {
    case "${1:-}" in
        podman) command -v podman 2>/dev/null || true ;;
        docker) command -v docker 2>/dev/null || true ;;
    esac
}

# --- Subordinate UID/GID -----------------------------------------------------
#
# Rootless containers map the user to root inside a namespace, which requires a
# subordinate UID/GID range. Fedora allocates one for every user it creates, so
# in practice this is a check, not a fix.

# containers_subid_status - Print "ok", "missing" or "too-small".
containers_subid_status() {
    local user="${USER:-$(id -un)}"
    local subuid subgid

    subuid="$(awk -F: -v u="$user" '$1 == u { print $3; exit }' /etc/subuid 2>/dev/null || true)"
    subgid="$(awk -F: -v u="$user" '$1 == u { print $3; exit }' /etc/subgid 2>/dev/null || true)"

    if [[ -z "$subuid" || -z "$subgid" ]]; then
        echo "missing"
    elif [[ "$subuid" -lt "$CONTAINERS_MIN_SUBID" || "$subgid" -lt "$CONTAINERS_MIN_SUBID" ]]; then
        echo "too-small"
    else
        echo "ok"
    fi
}

# containers_subid_summary - Print a human-readable one-liner about subid state.
containers_subid_summary() {
    local user="${USER:-$(id -un)}"
    [[ -r /etc/subuid ]] || { echo "cannot read /etc/subuid"; return 0; }
    awk -F: -v u="$user" '$1 == u { printf "%s:%s:%s", $1, $2, $3; found=1 } END { if (!found) printf "no entry for %s", u }' /etc/subuid 2>/dev/null || echo "unknown"
}

# containers_report_subid - Explain the current subid state.
containers_report_subid() {
    case "$(containers_subid_status)" in
        ok)
            echo "  subuid/subgid: $(containers_subid_summary)"
            ;;
        missing)
            echo "  subuid/subgid: MISSING for ${USER:-$(id -un)}"
            echo "                 rootless containers will not work until this is allocated"
            ;;
        too-small)
            echo "  subuid/subgid: smaller than $CONTAINERS_MIN_SUBID"
            echo "                 rootless containers need at least $CONTAINERS_MIN_SUBID IDs"
            ;;
    esac
}

# containers_ensure_subid - Allocate a subordinate UID/GID range when absent.
# Deliberately a no-op when Fedora has already done this, so re-runs never
# touch /etc/subuid or /etc/subgid on a correctly provisioned machine.
containers_ensure_subid() {
    local status
    status="$(containers_subid_status)"

    if [[ "$status" == "ok" ]]; then
        echo "  subuid/subgid: already allocated, leaving alone"
        return 0
    fi

    echo "  subuid/subgid: $status — allocating 100000-165535"
    if ! sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${USER:-$(id -un)}"; then
        echo "Error: could not allocate subordinate UID/GID ranges." >&2
        echo "       Rootless containers require them. Allocate manually, e.g.:" >&2
        echo "         sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER" >&2
        return 1
    fi
    echo "  subuid/subgid: allocated"
}

# --- systemd user session ----------------------------------------------------

# containers_have_user_systemd - True when a systemd user session is usable.
containers_have_user_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user show-environment >/dev/null 2>&1
}

# --- Version reporting -------------------------------------------------------

# containers_version <backend> - Print a short version string, or "unknown".
containers_version() {
    case "${1:-}" in
        podman)
            podman --version 2>/dev/null | awk '{print $3}'
            ;;
        docker)
            docker version --format '{{.Client.Version}}' 2>/dev/null || true
            ;;
    esac
}
