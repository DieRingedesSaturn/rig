#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Security & Audit Library
# https://github.com/DieRingedesSaturn/rig
#
# Provides:
# - Anti-lockout verification (admin user, sudo rights, authorized_keys)
# - sshd_config hardening & syntax preflight validation (sshd -t)
# - Dual-layer listening ports audit (ss -lntup vs declared firewall policy)
#
# Usage:
#   source lib/os-detect.sh
#   source lib/security.sh
# =============================================================================

if [[ -n "${_LIB_SECURITY_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_LIB_SECURITY_LOADED=1

# Colors for terminal reports (if not already set)
GREEN="${GREEN:-\033[0;32m}"
RED="${RED:-\033[0;31m}"
YELLOW="${YELLOW:-\033[0;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
DIM="${DIM:-\033[2m}"
NC="${NC:-\033[0m}"

# security_verify_admin_user - Check if a non-root admin user is valid for login
# Arguments: username
# Returns: 0 if valid and has sudo + key, 1 otherwise
security_verify_admin_user() {
    local user="$1"

    if [[ -z "$user" || "$user" == "root" ]]; then
        return 1
    fi
    case "$user" in
        *[!A-Za-z0-9_.-]*|[0-9.-]*) return 1 ;;
    esac

    # 1. User exists
    if ! id "$user" >/dev/null 2>&1; then
        return 1
    fi

    # 2. Check login shell is valid (not nologin / false)
    local user_shell=""
    if command -v getent >/dev/null 2>&1; then
        user_shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7 || true)"
    fi
    if [[ -z "$user_shell" ]] && command -v dscl >/dev/null 2>&1; then
        user_shell="$(dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{print $2}' || true)"
    fi
    if [[ -z "$user_shell" && -f /etc/passwd ]]; then
        user_shell="$(awk -F: -v user="$user" '$1 == user { print $7; exit }' /etc/passwd 2>/dev/null || true)"
    fi
    if [[ "$user_shell" =~ (nologin|false)$ ]]; then
        return 1
    fi

    # 3. User has sudo/wheel/admin privileges
    local user_groups
    user_groups="$(id -Gn "$user" 2>/dev/null || true)"
    if ! echo "$user_groups" | grep -qwE '(sudo|wheel|admin)'; then
        return 1
    fi

    # 4. User has authorized_keys with at least one valid key
    local home_dir="" auth_keys ssh_dir
    if command -v getent >/dev/null 2>&1; then
        home_dir="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    fi
    if [[ -z "$home_dir" ]] && command -v dscl >/dev/null 2>&1; then
        home_dir="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi
    if [[ -z "$home_dir" && -f /etc/passwd ]]; then
        home_dir="$(awk -F: -v user="$user" '$1 == user { print $6; exit }' /etc/passwd 2>/dev/null || true)"
    fi
    [[ -n "$home_dir" ]] || return 1
    ssh_dir="$home_dir/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    if [[ ! -d "$ssh_dir" || ! -f "$auth_keys" || ! -s "$auth_keys" ]]; then
        return 1
    fi

    # 5. Check permissions for sshd StrictModes (directory <= 700, authorized_keys <= 644)
    if command -v stat >/dev/null 2>&1; then
        local ssh_perm
        ssh_perm="$(stat -c "%a" "$ssh_dir" 2>/dev/null || stat -f "%Lp" "$ssh_dir" 2>/dev/null || true)"
        if [[ -n "$ssh_perm" ]]; then
            local last_two="${ssh_perm: -2}"
            if [[ "$last_two" =~ [2367] ]]; then
                return 1
            fi
        fi
    fi

    # Ensure file contains actual public key patterns
    if ! grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-)' "$auth_keys" 2>/dev/null; then
        return 1
    fi

    # 6. Check sshd_config does not explicitly disable PubkeyAuthentication
    local pubkey_cfg
    pubkey_cfg="$(security_get_sshd_param PubkeyAuthentication "unknown")"
    pubkey_cfg="$(printf '%s' "$pubkey_cfg" | tr '[:upper:]' '[:lower:]')"
    if [[ "$pubkey_cfg" != "yes" ]]; then
        return 1
    fi

    return 0
}

# security_can_disable_root - Guard against accidental lockout
# Arguments: admin_user
# Returns: 0 if safe to disable root, 1 if unsafe
security_can_disable_root() {
    local admin_user="${1:-}"

    if [[ -z "$admin_user" ]]; then
        local current_user
        current_user="$(whoami)"
        if [[ "$current_user" != "root" ]]; then
            admin_user="$current_user"
        fi
    fi

    if security_verify_admin_user "$admin_user"; then
        return 0
    else
        return 1
    fi
}

# security_test_sshd_config - Run syntax check on sshd config
# Returns: 0 on success, 1 on failure
security_test_sshd_config() {
    local config_file="${1:-}"
    local -a args=()
    [[ -n "$config_file" ]] && args=(-f "$config_file")
    if command -v sshd >/dev/null 2>&1; then
        sudo sshd -t "${args[@]}" 2>/dev/null
        return $?
    elif [[ -x /usr/sbin/sshd ]]; then
        sudo /usr/sbin/sshd -t "${args[@]}" 2>/dev/null
        return $?
    fi
    echo "sshd executable not found; configuration cannot be validated" >&2
    return 1
}

# security_render_sshd_config INPUT OUTPUT PORT ROOT PASSWORD PUBKEY
# Render a candidate configuration without modifying Match blocks. OpenSSH uses
# the first value it encounters, so the managed global block is placed before
# Include directives and existing global copies of these settings are removed.
security_render_sshd_config() {
    local input="$1" output="$2" port="$3" root_login="$4"
    local password_auth="$5" pubkey_auth="$6"

    {
        echo "# Rig Security Baseline"
        echo "Port $port"
        echo "PermitRootLogin $root_login"
        echo "PasswordAuthentication $password_auth"
        echo "PubkeyAuthentication $pubkey_auth"
        echo "KbdInteractiveAuthentication no"
        echo ""
        awk '
            BEGIN { in_match = 0 }
            {
                normalized = tolower($0)
                sub(/^[[:space:]]*/, "", normalized)
                if (normalized ~ /^match[[:space:]]/) in_match = 1
                check = normalized
                sub(/^#[[:space:]]*/, "", check)
                if (!in_match && check == "rig security baseline") next
                split(check, fields, /[[:space:]]+/)
                if (!in_match && fields[1] ~ /^(permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|port)$/) next
                print
            }
        ' "$input"
    } > "$output"
}

# security_get_sshd_param - Retrieve effective parameter from sshd configuration
# Arguments: param_name, default_value
security_get_sshd_param() {
    local param="$1"
    local default_val="${2:-unknown}"

    # 1. Prefer sshd -T for fully resolved runtime configuration
    local sshd_bin=""
    if command -v sshd >/dev/null 2>&1; then
        sshd_bin="sshd"
    elif [[ -x /usr/sbin/sshd ]]; then
        sshd_bin="/usr/sbin/sshd"
    fi

    if [[ -n "$sshd_bin" ]]; then
        local t_val=""
        t_val="$("$sshd_bin" -T 2>/dev/null | grep -i "^${param} " | head -1 | awk '{print $2}' || true)"
        if [[ -z "$t_val" ]] && sudo -n true 2>/dev/null; then
            t_val="$(sudo "$sshd_bin" -T 2>/dev/null | grep -i "^${param} " | head -1 | awk '{print $2}' || true)"
        fi
        if [[ -n "$t_val" ]]; then
            echo "$t_val"
            return 0
        fi
    fi

    # Do not guess from files: Include placement, lexical glob order, and Match
    # contexts make a simple grep materially different from effective config.
    echo "$default_val"
}

# security_audit_listening_ports - Audit open ports against declared policy and active firewall
# Arguments: allowed_tcp_csv, allowed_udp_csv
security_audit_listening_ports() {
    local allowed_tcp_csv="${1:-}"
    local allowed_udp_csv="${2:-}"
    local warn_undeclared="${3:-${RIG_WARN_UNDECLARED_PORTS:-yes}}"
    local ssh_access="${4:-${RIG_SSH_ACCESS:-public}}"
    local ssh_port="${5:-${RIG_SSH_PORT:-22}}"

    # Load firewall helper if needed
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! command -v firewall_is_active >/dev/null 2>&1; then
        if [[ -f "$lib_dir/firewall.sh" ]]; then
            # shellcheck source=lib/firewall.sh
            source "$lib_dir/firewall.sh" 2>/dev/null || true
        fi
    fi

    local fw_backend="none" fw_active=0 allowed_fw_str=""
    if command -v firewall_detect_backend >/dev/null 2>&1; then
        fw_backend="$(firewall_detect_backend "auto")"
        if [[ "$fw_backend" != "none" ]] && firewall_is_active "$fw_backend"; then
            fw_active=1
            allowed_fw_str="$(firewall_list_allowed "$fw_backend")"
        fi
    fi

    # Convert CSV to arrays
    local -a allowed_tcp=()
    local -a allowed_udp=()
    local item

    IFS=',' read -r -a raw_tcp <<< "$allowed_tcp_csv"
    for item in "${raw_tcp[@]}"; do
        item="$(echo "$item" | tr -d ' ')"
        [[ -n "$item" ]] && allowed_tcp+=("$item")
    done

    IFS=',' read -r -a raw_udp <<< "$allowed_udp_csv"
    for item in "${raw_udp[@]}"; do
        item="$(echo "$item" | tr -d ' ')"
        [[ -n "$item" ]] && allowed_udp+=("$item")
    done

    if ! command -v ss >/dev/null 2>&1; then
        echo "ss command not available, skipping port audit."
        return 0
    fi

    printf "  ${DIM}%-5s %-7s %-16s %-16s %-24s${NC}\n" "Proto" "Port" "Bind Address" "Process" "Policy & Firewall Status"
    printf "  ${DIM}───── ─────── ──────────────── ──────────────── ────────────────────────${NC}\n"

    local -a warnings=()

    # Capture listening sockets from `ss -lntup`
    while read -r proto state recvq sendq local_addr peer_addr proc; do
        [[ "$proto" =~ ^(tcp|udp)$ ]] || continue
        [[ "$state" == "LISTEN" || "$proto" == "udp" ]] || continue

        local bind_ip port
        if [[ "$local_addr" =~ \[?([0-9a-fA-F:\.]+)\]?:([0-9]+)$ ]]; then
            bind_ip="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        else
            continue
        fi

        local proc_name="unknown"
        if [[ "$proc" =~ users:\(\(\"([^\"]+)\" ]]; then
            proc_name="${BASH_REMATCH[1]}"
        fi

        # Determine Policy & Firewall Status
        local status_str is_internal=0 is_declared=0

        if [[ "$bind_ip" == "127.0.0.1" || "$bind_ip" == "::1" || "$bind_ip" == "localhost" ]]; then
            is_internal=1
        fi

        if [[ $is_internal -eq 1 ]]; then
            status_str="${GREEN}✔ Internal only${NC}"
        else
            if [[ "$proto" == "tcp" ]]; then
                for p in "${allowed_tcp[@]}"; do
                    if [[ "$p" == "$port" ]]; then
                        is_declared=1; break
                    fi
                done
            elif [[ "$proto" == "udp" ]]; then
                for p in "${allowed_udp[@]}"; do
                    if [[ "$p" == "$port" ]]; then
                        is_declared=1; break
                    fi
                done
            fi

            # A Tailscale-only SSH listener is declared by the SSH access
            # policy itself and does not belong in RIG_PUBLIC_TCP.
            if [[ "$ssh_access" == "tailscale" && "$proto" == "tcp" && "$port" == "$ssh_port" ]]; then
                is_declared=1
            fi

            if [[ $is_declared -eq 1 ]]; then
                if [[ $fw_active -eq 1 ]]; then
                    if [[ ", $allowed_fw_str, " == *", ${port}/${proto}, "* ]]; then
                        status_str="${GREEN}✔ Allowed (public)${NC}"
                    elif [[ "$ssh_access" == "tailscale" && "$proto" == "tcp" && "$port" == "$ssh_port" && ", $allowed_fw_str, " == *", ${port}/${proto}@tailscale, "* ]]; then
                        status_str="${GREEN}✔ Allowed (Tailscale only)${NC}"
                    else
                        status_str="${YELLOW}◐ Declared (FW blocked)${NC}"
                        local proto_label
                        proto_label="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
                        warnings+=("Port $port/$proto is declared in RIG_PUBLIC_${proto_label} but NOT found in active $fw_backend rules!")
                    fi
                else
                    status_str="${YELLOW}⚠ WARN: FW down${NC}"
                    warnings+=("Port $port/$proto ($proc_name) exposed publicly while firewall ($fw_backend) is inactive!")
                fi
            else
                if [[ "$warn_undeclared" == "yes" ]]; then
                    local proto_label
                    proto_label="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
                    status_str="${RED}⚠ WARN: Undeclared${NC}"
                    warnings+=("Port $port/$proto ($proc_name) bound to $bind_ip without declaration in RIG_PUBLIC_${proto_label}!")
                else
                    status_str="${DIM}Undeclared (warning disabled)${NC}"
                fi
            fi
        fi

        printf "  %-5s %-7s %-16s %-16s %b\n" "$proto" "$port" "$bind_ip" "$proc_name" "$status_str"

    done < <(sudo ss -lntup 2>/dev/null | tail -n +2 || true)

    if [[ ${#warnings[@]} -gt 0 ]]; then
        printf "\n  ${YELLOW}${BOLD}Security Warnings:${NC}\n"
        for w in "${warnings[@]}"; do
            printf "  ${YELLOW}[!] $w${NC}\n"
        done
        printf "  ${DIM}Hint: Private container services should explicitly bind to 127.0.0.1 (e.g., 127.0.0.1:port:port).${NC}\n"
    fi
}
