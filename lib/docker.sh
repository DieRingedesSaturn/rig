#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Containers — Docker backend
# https://github.com/DieRingedesSaturn/rig
#
# Two quite different installations live behind the same `docker` command:
#
#   rootless   the daemon runs as your user under systemd --user
#              socket   /run/user/$UID/docker.sock
#              state    ~/.local/share/docker
#              config   ~/.config/docker/daemon.json
#              service  systemctl --user
#
#   rootful    the classic system-wide daemon
#              socket   /var/run/docker.sock
#              state    /var/lib/docker
#              config   /etc/docker/daemon.json
#              service  systemctl (system)
#
# They are not interchangeable, and the config files are different files in
# different places, which is why this module keeps them apart.
#
# Must be sourced after lib/containers.sh.
#
# Exported functions:
#   setup_docker_rootless   - Install Docker as a user-level service
#   setup_docker_rootful    - Install the classic system-wide daemon
# =============================================================================

if [[ -n "${_CONTAINERS_DOCKER_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_CONTAINERS_DOCKER_LOADED=1

if ! declare -f containers_engine >/dev/null 2>&1; then
    echo "Error: lib/docker.sh requires lib/containers.sh to be sourced first." >&2
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# Registry mirrors (comma separated) and log rotation.
DOCKER_MIRROR="${DOCKER_MIRROR:-${RIG_REGISTRY_MIRRORS:-}}"
DOCKER_LOG_SIZE="${DOCKER_LOG_SIZE:-20m}"
DOCKER_LOG_FILES="${DOCKER_LOG_FILES:-3}"

# --- Shared ------------------------------------------------------------------

# _docker_install_engine - Install the Docker Engine packages.
# Uses the upstream convenience script, which sets up the distro repository and
# installs docker-ce, the CLI, containerd, buildx and the compose plugin.
_docker_install_engine() {
    if command -v docker >/dev/null 2>&1; then
        echo "  already installed: $(command -v docker)"
        return 0
    fi
    echo "  installing Docker Engine via get.docker.com..."
    curl -fsSL https://get.docker.com | sudo sh
    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: docker is still not available after installation." >&2
        exit 1
    fi
    echo "  installed: $(command -v docker)"
}

# _docker_install_rootless_extras - Ensure dockerd-rootless-setuptool.sh exists.
_docker_install_rootless_extras() {
    if command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
        return 0
    fi
    echo "  installing docker-ce-rootless-extras..."
    pkg_install docker-ce-rootless-extras || true
    if ! command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
        # Some distros ship it outside PATH.
        local candidate
        for candidate in /usr/bin/dockerd-rootless-setuptool.sh \
                         /usr/local/bin/dockerd-rootless-setuptool.sh; do
            [[ -x "$candidate" ]] && return 0
        done
        echo "Error: dockerd-rootless-setuptool.sh not found." >&2
        echo "       Install the 'docker-ce-rootless-extras' package and re-run." >&2
        return 1
    fi
    return 0
}

# _docker_write_daemon_json <path> <use-sudo:0|1> - Merge our settings in.
# Preserves keys this script does not manage by merging with python3 when it is
# available. Address pools are rootful-only: rootless uses slirp4netns and has
# no bridge to allocate from.
_docker_write_daemon_json() {
    local path="$1" use_sudo="$2" with_pools="$3"

    # A helper rather than an array: expanding an empty array under `set -u`
    # is an unbound-variable error on bash 3.2, which macOS still ships.
    if [[ "$use_sudo" == "1" ]]; then
        run_root() { sudo "$@"; }
    else
        run_root() { "$@"; }
    fi

    run_root mkdir -p "$(dirname "$path")"

    local existing=""
    if [[ -f "$path" ]]; then
        existing="$(run_root cat "$path" 2>/dev/null || true)"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        if [[ -n "$existing" ]]; then
            echo "  python3 not found — keeping existing $path untouched"
            return 0
        fi
        {
            echo '{'
            if [[ -n "$DOCKER_MIRROR" ]]; then
                local first=1 m
                printf '  "registry-mirrors": ['
                IFS=',' read -ra _m <<< "$DOCKER_MIRROR"
                for m in "${_m[@]}"; do
                    m="$(echo "$m" | tr -d '[:space:]')"
                    [[ -n "$m" ]] || continue
                    [[ $first -eq 0 ]] && printf ','
                    printf '"%s"' "$m"
                    first=0
                done
                printf '],\n'
                unset _m
            fi
            printf '  "log-driver": "json-file",\n'
            printf '  "log-opts": { "max-size": "%s", "max-file": "%s" }\n' "$DOCKER_LOG_SIZE" "$DOCKER_LOG_FILES"
            echo '}'
        } | run_root tee "$path" >/dev/null
        echo "  wrote $path"
        return 0
    fi

    printf '%s' "$existing" | run_root python3 -c '
import json, os, sys

path         = sys.argv[1]
mirrors_raw  = sys.argv[2]
log_size     = sys.argv[3]
log_files    = sys.argv[4]
with_pools   = sys.argv[5] == "1"

raw = sys.stdin.read().strip()
data = {}
if raw:
    try:
        data = json.loads(raw)
    except ValueError:
        print("  warning: existing daemon.json is not valid JSON — starting fresh")
        data = {}

if mirrors_raw.strip():
    data["registry-mirrors"] = [m.strip() for m in mirrors_raw.split(",") if m.strip()]

data["log-driver"] = "json-file"
data["log-opts"] = {"max-size": log_size, "max-file": log_files}

if with_pools:
    data.setdefault("default-address-pools", [
        {"base": "172.17.0.0/12", "size": 24},
        {"base": "192.168.0.0/16", "size": 24},
    ])
else:
    # Not meaningful under rootless (no bridge; slirp4netns handles networking).
    data.pop("default-address-pools", None)

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$path" "$DOCKER_MIRROR" "$DOCKER_LOG_SIZE" "$DOCKER_LOG_FILES" "$with_pools"

    echo "  wrote $path (existing keys preserved)"
}

# --- Rootless ----------------------------------------------------------------

# setup_docker_rootless - Install Docker as a user-level service.
setup_docker_rootless() {
    echo "[docker] Installing Docker in rootless mode..."

    if is_macos; then
        echo "  Docker on macOS runs through Docker Desktop, which has no rootless"
        echo "  mode. Use the Podman backend instead, or pick rootful mode."
        return 1
    fi

    if ! containers_have_user_systemd; then
        echo "Error: rootless Docker needs a working systemd --user session." >&2
        echo "       No user session was detected for ${USER:-$(id -un)}." >&2
        return 1
    fi

    # 1. Prerequisites. newuidmap/newgidmap come from uidmap on Debian/RHEL and
    #    from shadow-utils on Fedora/Arch (always present there).
    echo ""
    echo "[docker] Prerequisites"
    if is_debian || is_rhel; then
        pkg_install uidmap
    else
        echo "  newuidmap/newgidmap come from shadow-utils on $OS_DISTRO"
    fi
    if ! command -v newuidmap >/dev/null 2>&1; then
        echo "Error: newuidmap is missing — rootless Docker cannot work." >&2
        return 1
    fi
    echo "  newuidmap: $(command -v newuidmap)"

    # 2. Subordinate UID/GID. Docker requires at least 65536 IDs.
    echo ""
    echo "[docker] Subordinate UID/GID"
    containers_report_subid
    containers_ensure_subid

    # 3. Engine packages. Note the system daemon is NOT enabled; the whole point
    #    of rootless is the per-user daemon installed in step 4.
    echo ""
    echo "[docker] Engine packages"
    _docker_install_engine
    _docker_install_rootless_extras

    # 4. Stop the system daemon if a previous rootful install enabled it, so the
    #    CLI does not silently talk to the wrong socket.
    if systemctl is-enabled docker.service >/dev/null 2>&1 \
        || systemctl is-active docker.service >/dev/null 2>&1; then
        echo ""
        echo "[docker] Disabling the system-wide daemon (rootless replaces it)"
        sudo systemctl disable --now docker.service docker.socket 2>/dev/null || true
    fi

    # 5. Install the per-user service.
    echo ""
    echo "[docker] Per-user service"
    if systemctl --user list-unit-files docker.service >/dev/null 2>&1 \
        && systemctl --user is-enabled docker.service >/dev/null 2>&1; then
        echo "  already installed, skipping dockerd-rootless-setuptool"
    else
        dockerd-rootless-setuptool.sh install
    fi

    systemctl --user enable --now docker

    # 6. Linger keeps the user service alive without an interactive login, which
    #    is what makes rootless containers survive a reboot on a headless VPS.
    echo ""
    echo "[docker] Enabling linger so the service survives logout/reboot"
    if loginctl show-user "${USER:-$(id -un)}" 2>/dev/null | grep -q 'Linger=yes'; then
        echo "  linger already enabled"
    else
        sudo loginctl enable-linger "${USER:-$(id -un)}"
        echo "  linger enabled"
    fi

    # 7. Make the CLI default to the rootless context.
    echo ""
    echo "[docker] Selecting the rootless context"
    docker context use rootless 2>/dev/null || true
    echo "  context: $(docker context show 2>/dev/null || echo unknown)"

    # 8. Config. Rootless reads ~/.config/docker/daemon.json, never /etc/docker.
    echo ""
    echo "[docker] Daemon configuration (rootless)"
    _docker_write_daemon_json "$HOME/.config/docker/daemon.json" 0 0

    # 9. Verify.
    echo ""
    echo "[docker] Verifying"
    if docker info >/dev/null 2>&1; then
        if docker info 2>/dev/null | grep -qi rootless; then
            echo "  running rootless — $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
        else
            echo "  daemon reachable (rootless marker not reported)"
        fi
    else
        echo "  warning: 'docker info' failed. Check the service with:"
        echo "      systemctl --user status docker"
        echo "      journalctl --user -u docker -n 50"
    fi
}

# --- Rootful -----------------------------------------------------------------

# setup_docker_rootful - Install the classic system-wide daemon.
setup_docker_rootful() {
    echo "[docker] Installing Docker in rootful mode..."

    if is_macos; then
        echo "  macOS uses Docker Desktop; daemon.json is managed in its settings."
        echo "  Install it with: brew install --cask docker"
        return 0
    fi

    echo ""
    echo "[docker] Engine packages"
    _docker_install_engine

    echo ""
    echo "[docker] Compose plugin"
    if docker compose version >/dev/null 2>&1; then
        echo "  already available"
    else
        pkg_install docker-compose-plugin || true
        if docker compose version >/dev/null 2>&1; then
            echo "  installed"
        else
            echo "  warning: 'docker compose' still unavailable"
        fi
    fi

    echo ""
    echo "[docker] Adding ${USER:-$(id -un)} to the docker group"
    if id -nG "${USER:-$(id -un)}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "  already a member"
    else
        sudo usermod -aG docker "${USER:-$(id -un)}"
        echo "  added — log out and back in for it to take effect"
    fi

    echo ""
    echo "[docker] Daemon configuration (rootful, /etc/docker/daemon.json)"
    _docker_write_daemon_json "/etc/docker/daemon.json" 1 1

    echo ""
    echo "[docker] Enabling the system service"
    sudo systemctl enable --now docker 2>/dev/null || true
    if docker info >/dev/null 2>&1; then
        echo "  daemon reachable — $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
    else
        echo "  warning: 'docker info' failed. Check: systemctl status docker"
    fi
}
