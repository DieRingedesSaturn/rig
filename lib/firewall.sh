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

# All mutations share one mode for an apply. Never start a stopped daemon just
# to edit permanent configuration: prepare it with the offline client first.
firewall_prepare() {
    local backend="$1"
    FIREWALL_OFFLINE=0
    [[ "$backend" == firewalld ]] || return 0
    if ! sudo firewall-cmd --state >/dev/null 2>&1; then
        command -v firewall-offline-cmd >/dev/null 2>&1 || {
            echo "firewall-offline-cmd is required before starting firewalld" >&2
            return 1
        }
        FIREWALL_OFFLINE=1
    fi
}

_firewall_config_cmd() {
    if [[ "${FIREWALL_OFFLINE:-0}" -eq 1 ]]; then
        sudo firewall-offline-cmd "$@"
    else
        sudo firewall-cmd --permanent "$@"
    fi
}

firewall_validate_bindings() {
    local zone interfaces sources zones runtime_zones
    zones="$(_firewall_config_cmd --get-zones)" || return 1
    for zone in $zones; do
        case "$zone" in public|rig-tailscale|docker|libvirt) continue ;; esac
        interfaces="$(_firewall_config_cmd --zone="$zone" --list-interfaces)" || return 1
        sources="$(_firewall_config_cmd --zone="$zone" --list-sources)" || return 1
        if [[ -n "$interfaces$sources" ]]; then
            echo "Unmanaged firewalld zone '$zone' has interface/source bindings; configure their policy before applying Rig." >&2
            return 1
        fi
    done
    # Runtime-only bindings must not escape the same preflight.
    if [[ "${FIREWALL_OFFLINE:-0}" -eq 0 ]]; then
        runtime_zones="$(sudo firewall-cmd --get-zones)" || return 1
        for zone in $runtime_zones; do
            case "$zone" in public|rig-tailscale|docker|libvirt) continue ;; esac
            interfaces="$(sudo firewall-cmd --zone="$zone" --list-interfaces)" || return 1
            sources="$(sudo firewall-cmd --zone="$zone" --list-sources)" || return 1
            [[ -z "$interfaces$sources" ]] || {
                echo "Unmanaged runtime zone '$zone' has interface/source bindings" >&2
                return 1
            }
        done
    fi
}

# Snapshots are kept in the centralized user-owned backup tree. Capture both
# permanent and runtime firewalld settings: they need not be identical.
firewall_snapshot() {
    local backend="$1" dir="$2" active=0 enabled=0
    mkdir -p "$dir"
    chmod 700 "$dir"
    case "$backend" in
        ufw)
            if command -v ufw >/dev/null 2>&1; then
                local status
                status="$(sudo ufw status)" || return 1
                [[ "$status" != *'Status: active'* ]] || active=1
            fi
            _firewall_save_path /etc/ufw "$dir/ufw" || return 1
            _firewall_save_path /etc/default/ufw "$dir/ufw-default" || return 1
            ;;
        firewalld)
            sudo systemctl is-active --quiet firewalld && active=1
            sudo systemctl is-enabled --quiet firewalld && enabled=1
            _firewall_save_path /etc/firewalld "$dir/permanent" || return 1
            if [[ "$active" -eq 1 ]]; then
                # Export the runtime XML, then immediately restore the original
                # disk configuration without reloading the running daemon.
                local capture_rc=0
                sudo firewall-cmd --runtime-to-permanent >/dev/null || capture_rc=1
                if [[ "$capture_rc" -eq 0 ]]; then
                    _firewall_save_path /etc/firewalld "$dir/runtime" || capture_rc=1
                fi
                _firewall_restore_path "$dir/permanent" /etc/firewalld || return 1
                [[ "$capture_rc" -eq 0 ]] || return 1
            fi
            ;;
        *) return 1 ;;
    esac
    printf '%s\n%s\n%s\n' "$backend" "$active" "$enabled" > "$dir/state"
    sudo chown -R "$(id -u):$(id -g)" "$dir" || return 1
}

_firewall_save_path() {
    local path="$1" dest="$2"
    if sudo test -e "$path"; then
        sudo cp -a "$path" "$dest" || return 1
    else
        : > "$dest.absent"
    fi
}

_firewall_restore_path() {
    local source="$1" path="$2"
    # Only the known firewall config paths may be replaced by this helper.
    case "$path" in /etc/ufw|/etc/default/ufw|/etc/firewalld) ;; *) return 1 ;; esac
    if [[ ! -e "$source" && ! -f "$source.absent" ]]; then return 1; fi
    sudo rm -rf "$path" || return 1
    if [[ -e "$source" ]]; then sudo cp -a "$source" "$path" || return 1; fi
}

firewall_restore() {
    local backend="$1" dir="$2" saved active enabled failed=0
    [[ -f "$dir/state" ]] || return 1
    { read -r saved; read -r active; read -r enabled; } < "$dir/state"
    [[ "$saved" == "$backend" && "$active" =~ ^[01]$ && "$enabled" =~ ^[01]$ ]] || return 1
    case "$backend" in
        ufw)
            _firewall_restore_path "$dir/ufw" /etc/ufw || return 1
            _firewall_restore_path "$dir/ufw-default" /etc/default/ufw || return 1
            if [[ "$active" -eq 1 ]]; then
                sudo ufw --force enable || failed=1
                sudo ufw reload || failed=1
            elif command -v ufw >/dev/null 2>&1; then
                sudo ufw --force disable || failed=1
            fi
            ;;
        firewalld)
            if [[ "$active" -eq 1 ]]; then
                _firewall_restore_path "$dir/runtime" /etc/firewalld || return 1
                sudo systemctl start firewalld || failed=1
                sudo firewall-cmd --reload || failed=1
                # Leave the original permanent settings on disk, retaining the
                # restored runtime settings until the next user-requested reload.
                _firewall_restore_path "$dir/permanent" /etc/firewalld || failed=1
            else
                sudo systemctl stop firewalld || failed=1
                _firewall_restore_path "$dir/permanent" /etc/firewalld || failed=1
            fi
            if [[ "$enabled" -eq 1 ]]; then sudo systemctl enable firewalld || failed=1
            else sudo systemctl disable firewalld || failed=1; fi
            ;;
        *) return 1 ;;
    esac
    [[ "$failed" -eq 0 ]]
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
            if [[ "${FIREWALL_OFFLINE:-0}" -eq 1 ]]; then
                sudo firewall-offline-cmd --set-default-zone=public >/dev/null || return 1
            else
                # Switch only after prepared public rules are loaded by reload.
                FIREWALL_DEFAULT_PENDING=public
            fi
            if [[ "$default_in" == "deny" ]]; then
                _firewall_config_cmd --zone=public --set-target=DROP >/dev/null || return 1
                # A DROP target is silently bypassed by service entries shipped
                # in the stock public zone (ssh, cockpit, ...). Strip them so
                # only explicitly declared ports stay reachable. dhcpv6-client
                # is kept: removing it breaks DHCPv6 on networks that need it.
                local svc services
                services="$(_firewall_config_cmd --zone=public --list-services)" || return 1
                for svc in $services; do
                    [[ "$svc" == "dhcpv6-client" ]] && continue
                    _firewall_config_cmd --zone=public --remove-service="$svc" >/dev/null || return 1
                done
            else
                _firewall_config_cmd --zone=public --set-target=ACCEPT >/dev/null || return 1
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
                local zones
                zones="$(_firewall_config_cmd --get-zones)" || return 1
                if ! printf '%s\n' "$zones" | tr ' ' '\n' | grep -qx 'rig-tailscale'; then
                    _firewall_config_cmd --new-zone=rig-tailscale >/dev/null || return 1
                fi
                _firewall_config_cmd --zone=rig-tailscale --set-target=DROP >/dev/null || return 1
                _firewall_config_cmd --zone=rig-tailscale --change-interface=tailscale0 >/dev/null || return 1
                _firewall_config_cmd --zone=rig-tailscale --add-port="${port}/${proto}" >/dev/null || return 1
            else
                _firewall_config_cmd --zone=public --add-port="${port}/${proto}" >/dev/null || return 1
            fi
            ;;
    esac
}

# firewall_remove_public_port - Remove a broad allow rule while preserving
# interface/source-restricted rules for the same port.
firewall_remove_public_port() {
    local backend="$1"
    local port="$2"
    local proto="${3:-tcp}" status rc

    case "$backend" in
        ufw)
            status="$(sudo ufw status)" || return 1
            if printf '%s\n' "$status" | awk -v rule="${port}/${proto}" '
                $1 == rule && (($2 == "ALLOW" && $3 == "Anywhere") || ($2 == "(v6)" && $3 == "ALLOW" && $4 == "Anywhere")) { found=1 }
                END { exit !found }
            '; then
                sudo ufw --force delete allow "${port}/${proto}" >/dev/null || return 1
            fi
            ;;
        firewalld)
            if _firewall_config_cmd --zone=public --query-port="${port}/${proto}" >/dev/null 2>&1; then
                _firewall_config_cmd --zone=public --remove-port="${port}/${proto}" >/dev/null || return 1
            else
                rc=$?
                [[ "$rc" -eq 1 ]] || return "$rc"
            fi
            ;;
        *)
            echo "Error: unsupported firewall backend '$backend'" >&2
            return 1
            ;;
    esac
}

# firewall_enable - Enable and activate firewall
firewall_remove_interface_port() {
    local backend="$1" port="$2" proto="$3" iface="$4" rc status
    case "$backend" in
        ufw)
            status="$(sudo ufw status)" || return 1
            if printf '%s\n' "$status" | awk -v port="$port/$proto" -v iface="$iface" '
                $1 == port && $2 == "on" && $3 == iface && /ALLOW/ { found=1 }
                END { exit !found }
            '; then
                sudo ufw --force delete allow in on "$iface" to any port "$port" proto "$proto" >/dev/null || return 1
            fi
            ;;
        firewalld)
            if _firewall_config_cmd --zone=rig-tailscale --query-port="$port/$proto" >/dev/null 2>&1; then
                _firewall_config_cmd --zone=rig-tailscale --remove-port="$port/$proto" >/dev/null
            else
                rc=$?
                [[ "$rc" -eq 1 ]] || return "$rc"
            fi
            ;;
        *) return 1 ;;
    esac
}

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
            FIREWALL_OFFLINE=0
            if [[ -n "${FIREWALL_DEFAULT_PENDING:-}" ]]; then
                sudo firewall-cmd --set-default-zone="$FIREWALL_DEFAULT_PENDING" >/dev/null || return 1
                FIREWALL_DEFAULT_PENDING=""
            fi
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
            if [[ -n "${FIREWALL_DEFAULT_PENDING:-}" ]]; then
                sudo firewall-cmd --set-default-zone="$FIREWALL_DEFAULT_PENDING" >/dev/null || return 1
                FIREWALL_DEFAULT_PENDING=""
            fi
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
