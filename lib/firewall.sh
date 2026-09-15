#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Firewall Abstraction Library
# https://github.com/DieRingedesSaturn/rig
#
# Provides a unified interface across different Linux firewall backends
# (ufw for Debian/Ubuntu, firewalld for RHEL/Fedora/CentOS).
#
# Usage:
#   source lib/os-detect.sh
#   source lib/pkg-manager.sh
#   source lib/firewall.sh
# =============================================================================

if [[ -n "${_LIB_FIREWALL_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_LIB_FIREWALL_LOADED=1

# firewall_detect_backend - Detect installed firewall or determine default for distro
# Outputs: ufw, firewalld, or none
firewall_detect_backend() {
    local preferred="${1:-auto}"

    if [[ "$preferred" != "auto" && "$preferred" != "" ]]; then
        case "$preferred" in
            ufw|firewalld|none) echo "$preferred"; return 0 ;;
            *) echo "Error: unsupported firewall backend '$preferred'" >&2; return 1 ;;
        esac
    fi

    # Check already running or installed tools first
    if command -v ufw >/dev/null 2>&1; then
        echo "ufw"
        return 0
    elif command -v firewall-cmd >/dev/null 2>&1; then
        echo "firewalld"
        return 0
    fi

    # Distro defaults
    if command -v is_debian >/dev/null 2>&1 && is_debian; then
        echo "ufw"
    elif command -v is_rhel >/dev/null 2>&1 && (is_rhel || is_fedora); then
        echo "firewalld"
    elif command -v is_arch >/dev/null 2>&1 && is_arch; then
        echo "ufw"
    else
        echo "none"
    fi
}

# firewall_is_installed - Check if the backend CLI is installed
firewall_is_installed() {
    local backend="$1"
    case "$backend" in
        ufw) command -v ufw >/dev/null 2>&1 ;;
        firewalld) command -v firewall-cmd >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# firewall_ensure_installed - Install the required backend if missing
firewall_ensure_installed() {
    local backend="$1"
    if firewall_is_installed "$backend"; then
        return 0
    fi

    echo "  Installing firewall package for $backend..."
    case "$backend" in
        ufw)
            pkg_install ufw
            ;;
        firewalld)
            pkg_install firewalld
            ;;
        *)
            echo "Error: unsupported firewall backend '$backend'" >&2
            return 1
            ;;
    esac
}

# _firewall_ro_cmd - Run a read-only firewall query without ever prompting for
# a password: try unprivileged first (firewall-cmd queries work over D-Bus),
# then fall back to cached sudo credentials. An empty-but-successful answer is
# treated as unusable and retried via sudo -n.
_firewall_ro_cmd() {
    local out
    if out="$("$@" 2>/dev/null)" && [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    sudo -n "$@" 2>/dev/null
}

# firewall_is_active - Check if the firewall service is actively filtering.
# Read-only callers (status, audits) use sudo -n so they never block on a
# password prompt; an unreadable backend reports as inactive.
firewall_is_active() {
    local backend="$1"
    case "$backend" in
        ufw)
            if ! command -v ufw >/dev/null 2>&1; then
                return 1
            fi
            # ufw status requires root; there is no unprivileged path.
            if sudo -n ufw status 2>/dev/null | grep -qi "Status: active"; then
                return 0
            fi
            # Cached creds may be absent in read-only contexts (status.sh,
            # audits). The ufw service state is readable without privileges
            # and only stays active while filtering is enabled.
            if command -v systemctl >/dev/null 2>&1; then
                systemctl is-active --quiet ufw 2>/dev/null
                return
            fi
            return 1
            ;;
        firewalld)
            if ! command -v firewall-cmd >/dev/null 2>&1; then
                return 1
            fi
            _firewall_ro_cmd firewall-cmd --state | grep -qi "running"
            ;;
        *)
            return 1
            ;;
    esac
}

# firewall_set_defaults - Set default incoming/outgoing policies
# Arguments: backend, default_in (deny/allow), default_out (allow/deny)
firewall_set_defaults() {
    local backend="$1"
    local default_in="${2:-deny}"
    local default_out="${3:-allow}"

    case "$backend" in
        ufw)
            echo "  Setting UFW default policies (incoming: $default_in, outgoing: $default_out)..."
            sudo ufw default "$default_in" incoming >/dev/null || return 1
            sudo ufw default "$default_out" outgoing >/dev/null || return 1
            ;;
        firewalld)
            echo "  Setting firewalld default zone policy..."
            if [[ "$default_out" != "allow" ]]; then
                echo "Error: firewalld backend does not support RIG_FIREWALL_DEFAULT_OUT=$default_out" >&2
                return 1
            fi
            sudo firewall-cmd --set-default-zone=public >/dev/null || return 1
            if [[ "$default_in" == "deny" ]]; then
                sudo firewall-cmd --permanent --zone=public --set-target=DROP >/dev/null || return 1
                # A DROP target is silently bypassed by service entries shipped
                # in the stock public zone (ssh, cockpit, ...). Strip them so
                # only explicitly declared ports stay reachable. dhcpv6-client
                # is kept: removing it breaks DHCPv6 on networks that need it.
                local svc
                for svc in $(sudo firewall-cmd --permanent --zone=public --list-services 2>/dev/null); do
                    [[ "$svc" == "dhcpv6-client" ]] && continue
                    sudo firewall-cmd --permanent --zone=public --remove-service="$svc" >/dev/null || true
                done
            else
                sudo firewall-cmd --permanent --zone=public --set-target=default >/dev/null || return 1
            fi
            ;;
    esac
}

# firewall_allow_port - Open a port for incoming traffic
# Arguments: backend, port, proto (tcp/udp), interface (optional)
firewall_allow_port() {
    local backend="$1"
    local port="$2"
    local proto="${3:-tcp}"
    local iface="${4:-}"

    [[ -z "$port" ]] && return 0

    case "$backend" in
        ufw)
            if [[ -n "$iface" ]]; then
                sudo ufw allow in on "$iface" to any port "$port" proto "$proto" >/dev/null || return 1
            else
                sudo ufw allow "${port}/${proto}" >/dev/null || return 1
            fi
            ;;
        firewalld)
            if [[ -n "$iface" ]]; then
                if [[ "$iface" != "tailscale0" ]]; then
                    echo "Error: unsupported restricted firewalld interface '$iface'" >&2
                    return 1
                fi
                # Move tailscale0 into a dedicated deny-by-default zone so only
                # explicitly allowed services are reachable over that interface.
                if ! sudo firewall-cmd --permanent --get-zones 2>/dev/null | tr ' ' '\n' | grep -qx 'rig-tailscale'; then
                    sudo firewall-cmd --permanent --new-zone=rig-tailscale >/dev/null || return 1
                    sudo firewall-cmd --reload >/dev/null || return 1
                fi
                sudo firewall-cmd --permanent --zone=rig-tailscale --set-target=DROP >/dev/null || return 1
                sudo firewall-cmd --permanent --zone=rig-tailscale --change-interface=tailscale0 >/dev/null || return 1
                sudo firewall-cmd --permanent --zone=rig-tailscale --add-port="${port}/${proto}" >/dev/null || return 1
            else
                sudo firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null || return 1
            fi
            ;;
    esac
}

# firewall_remove_public_port - Remove a broad allow rule while preserving
# interface/source-restricted rules for the same port.
firewall_remove_public_port() {
    local backend="$1"
    local port="$2"
    local proto="${3:-tcp}"

    case "$backend" in
        ufw)
            if sudo ufw status 2>/dev/null | awk -v rule="${port}/${proto}" '$1 == rule && $2 == "ALLOW" { found=1 } END { exit !found }'; then
                sudo ufw --force delete allow "${port}/${proto}" >/dev/null || return 1
            fi
            ;;
        firewalld)
            if sudo firewall-cmd --permanent --zone=public --query-port="${port}/${proto}" >/dev/null 2>&1; then
                sudo firewall-cmd --permanent --zone=public --remove-port="${port}/${proto}" >/dev/null || return 1
            fi
            ;;
        *)
            echo "Error: unsupported firewall backend '$backend'" >&2
            return 1
            ;;
    esac
}

# firewall_enable - Enable and activate firewall
firewall_enable() {
    local backend="$1"
    case "$backend" in
        ufw)
            echo "  Activating UFW..."
            sudo ufw --force enable >/dev/null || return 1
            ;;
        firewalld)
            echo "  Activating firewalld..."
            sudo systemctl enable --now firewalld >/dev/null || return 1
            sudo firewall-cmd --reload >/dev/null || return 1
            ;;
    esac
}

# firewall_reload - Reload firewall configuration
firewall_reload() {
    local backend="$1"
    case "$backend" in
        ufw)
            sudo ufw reload >/dev/null || return 1
            ;;
        firewalld)
            sudo firewall-cmd --reload >/dev/null || return 1
            ;;
    esac
}

# firewall_list_allowed - Return comma-separated list of allowed ports
# Outputs: formatted string e.g. "22/tcp, 80/tcp, 443/tcp"
firewall_list_allowed() {
    local backend="$1"
    local allowed=()

    if ! firewall_is_active "$backend"; then
        echo "(inactive)"
        return 0
    fi

    case "$backend" in
        ufw)
            # Parse `ufw status` output: "22/tcp ALLOW Anywhere"
            while read -r line; do
                local port_proto
                port_proto="$(echo "$line" | awk '{print $1}')"
                if [[ "$port_proto" =~ ^[0-9]+/(tcp|udp)$ ]]; then
                    if echo "$line" | grep -qE '[[:space:]]on[[:space:]]+tailscale0[[:space:]]'; then
                        allowed+=("${port_proto}@tailscale")
                    else
                        allowed+=("$port_proto")
                    fi
                fi
            done < <(sudo -n ufw status 2>/dev/null | grep -E "ALLOW" || true)
            ;;
        firewalld)
            local raw_ports
            raw_ports="$(_firewall_ro_cmd firewall-cmd --list-ports || true)"
            for p in $raw_ports; do
                allowed+=("$p")
            done
            # Service entries open ports too (stock "ssh" → 22/tcp); expand
            # them so the audit sees what is actually reachable.
            local svc svc_ports
            for svc in $(_firewall_ro_cmd firewall-cmd --list-services || true); do
                svc_ports="$(_firewall_ro_cmd firewall-cmd --service="$svc" --get-ports || true)"
                for p in $svc_ports; do
                    [[ "$p" =~ ^[0-9]+/(tcp|udp)$ ]] && allowed+=("$p")
                done
            done
            local tailscale_ports tailscale_ifaces
            tailscale_ifaces="$(_firewall_ro_cmd firewall-cmd --zone=rig-tailscale --list-interfaces || true)"
            if printf '%s\n' "$tailscale_ifaces" | tr ' ' '\n' | grep -qx 'tailscale0'; then
                tailscale_ports="$(_firewall_ro_cmd firewall-cmd --zone=rig-tailscale --list-ports || true)"
                for p in $tailscale_ports; do
                    allowed+=("${p}@tailscale")
                done
            fi
            ;;
    esac

    # Deduplicate and format
    if [[ ${#allowed[@]} -eq 0 ]]; then
        echo "none"
    else
        # Remove duplicates
        printf "%s\n" "${allowed[@]}" | sort -u | paste -sd ',' - | sed 's/,/, /g'
    fi
}
