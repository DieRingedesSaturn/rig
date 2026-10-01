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

# _security_perm_writeable - True when the mode's group/other digits grant write.
# sshd StrictModes rejects any key material reachable through such a path.
_security_perm_writeable() {
    local perm="$1"
    [[ -n "$perm" ]] || return 1
    local last_two="${perm: -2}"
    [[ "$last_two" =~ [2367] ]]
}

# _security_mode_of - Print numeric mode of a path (GNU and BSD stat).
_security_mode_of() {
    stat -c "%a" "$1" 2>/dev/null || stat -f "%Lp" "$1" 2>/dev/null || true
}

# _security_owner_of - Print owner name of a path (GNU and BSD stat).
_security_owner_of() {
    stat -c "%U" "$1" 2>/dev/null || stat -f "%Su" "$1" 2>/dev/null || true
}

# _security_user_in_list - Match a user against an sshd user-pattern list
# ("user" or "user@host" entries; * and ? globs apply like sshd's own matcher).
_security_user_in_list() {
    local user="$1" list="$2" context="${3:-}" mode="${4:-allow}" tok upat hostpat field
    local address="" hostname=""
    local -a fields=()
    IFS=',' read -r -a fields <<< "$context"
    for field in "${fields[@]+"${fields[@]}"}"; do
        case "$field" in addr=*) address="${field#addr=}" ;; host=*) hostname="${field#host=}" ;; esac
    done
    for tok in $list; do
        upat="${tok%%@*}"
        # Intentional glob: sshd user patterns allow * and ? wildcards.
        # shellcheck disable=SC2053
        [[ "$user" == $upat ]] || continue
        [[ "$tok" == *@* ]] || return 0
        hostpat="${tok#*@}"
        if [[ "$hostpat" == */* ]]; then
            if [[ -n "$address" ]] && command -v python3 >/dev/null 2>&1; then
                if python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' "$address" "$hostpat" 2>/dev/null; then
                    return 0
                fi
            elif [[ "$mode" == deny ]]; then
                # Unknown source constraints are not proof that login is safe.
                return 0
            fi
        elif [[ -n "$address$hostname" ]]; then
            # shellcheck disable=SC2053
            [[ "$address" == $hostpat || "$hostname" == $hostpat ]] && return 0
        elif [[ "$mode" == deny ]]; then
            return 0
        fi
    done
    return 1
}

# _security_group_in_list - True when any of the user's groups appears in list.
_security_group_in_list() {
    local groups="$1" list="$2" tok g
    for tok in $list; do
        for g in $groups; do
            # Intentional glob: sshd group patterns allow * and ? wildcards.
            # shellcheck disable=SC2053
            [[ "$g" == $tok ]] && return 0
        done
    done
    return 1
}

# _security_verify_fail - Report which anti-lockout check refused the user.
# Diagnostics go to stderr so callers can still use the function in tests and
# command substitution without swallowing the reason.
_security_verify_fail() {
    printf '  anti-lockout check failed: %s\n' "$1" >&2
    return 1
}

# security_verify_admin_user - Check if a non-root admin user is valid for login
# Arguments: username
# Returns: 0 if valid and has sudo + key, 1 otherwise
security_verify_admin_user() {
    local user="$1"
    local config_file="${2:-}" context="${3:-}"
    local _SECURITY_SSHD_OUTPUT

    if [[ -z "$user" || "$user" == "root" ]]; then
        _security_verify_fail "admin user is empty or root"
        return 1
    fi
    case "$user" in
        *[!A-Za-z0-9_.-]*|[0-9.-]*) _security_verify_fail "invalid username '$user'"; return 1 ;;
    esac

    # 1. User exists
    if ! id "$user" >/dev/null 2>&1; then
        _security_verify_fail "user '$user' does not exist"
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
        _security_verify_fail "user '$user' has non-login shell '$user_shell'"
        return 1
    fi

    # 3. User has sudo/wheel/admin privileges
    local user_groups
    user_groups="$(id -Gn "$user" 2>/dev/null || true)"
    if ! echo "$user_groups" | grep -qwE '(sudo|wheel|admin)'; then
        _security_verify_fail "user '$user' is not in sudo/wheel/admin (groups: ${user_groups:-none})"
        return 1
    fi

    # Group membership alone does not prove sudo works. Ask sudo even when
    # invoked by a normal user, using cached credentials or a visible prompt.
    if command -v sudo >/dev/null 2>&1; then
        if ! sudo -n -l -U "$user" >/dev/null 2>&1 && ! (
            [[ "${RIG_NO_SUDO_PROMPT:-0}" != 1 && "${RIG_NON_INTERACTIVE:-0}" != 1 ]] \
                && rig_can_prompt && sudo -l -U "$user" </dev/tty >/dev/null
        ); then
            _security_verify_fail "sudo -l reports no privileges for '$user' (sudoers does not grant sudo)"
            return 1
        fi
    else
        _security_verify_fail "sudo is unavailable; admin privileges cannot be verified"
        return 1
    fi

    # One resolved snapshot for all checks, including the candidate's Match
    # context. A failed query must never turn into permissive empty lists.
    if ! _SECURITY_SSHD_OUTPUT="$(security_sshd_effective "$config_file" "$context")"; then
        _security_verify_fail "cannot resolve effective sshd configuration"
        return 1
    fi

    # 4. Resolve the authorized-keys file sshd actually reads. The default is
    # ~/.ssh/authorized_keys, but AuthorizedKeysFile may relocate it (%u, %h
    # and %% tokens expand the same way sshd expands them).
    local home_dir="" ssh_dir
    if command -v getent >/dev/null 2>&1; then
        home_dir="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    fi
    if [[ -z "$home_dir" ]] && command -v dscl >/dev/null 2>&1; then
        home_dir="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi
    if [[ -z "$home_dir" && -f /etc/passwd ]]; then
        home_dir="$(awk -F: -v user="$user" '$1 == user { print $6; exit }' /etc/passwd 2>/dev/null || true)"
    fi
    if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
        _security_verify_fail "user '$user' has no home directory"
        return 1
    fi
    ssh_dir="$home_dir/.ssh"

    local auth_keys="" akf_list tok expanded
    akf_list="$(security_get_sshd_param AuthorizedKeysFile "")"
    [[ -z "$akf_list" ]] && akf_list=".ssh/authorized_keys .ssh/authorized_keys2"
    for tok in $akf_list; do
        expanded="${tok//%%/$'\001'}"
        expanded="${expanded//%u/$user}"
        expanded="${expanded//%h/$home_dir}"
        expanded="${expanded//$'\001'/%}"
        [[ "$expanded" != /* ]] && expanded="$home_dir/$expanded"
        if [[ -f "$expanded" && -s "$expanded" ]]; then
            auth_keys="$expanded"
            break
        fi
    done
    if [[ -z "$auth_keys" ]]; then
        _security_verify_fail "no non-empty authorized-keys file for '$user' (sshd AuthorizedKeysFile: $akf_list)"
        return 1
    fi

    # 5. StrictModes checks: the home dir, ~/.ssh (when in use) and the keys
    # file itself must not be writable by group/other, and the keys file must
    # be owned by the user (or root).
    if command -v stat >/dev/null 2>&1; then
        local perm
        perm="$(_security_mode_of "$home_dir")"
        if _security_perm_writeable "$perm"; then
            _security_verify_fail "home directory $home_dir is group/other-writable (mode $perm) — StrictModes would reject it"
            return 1
        fi
        if [[ -d "$ssh_dir" ]]; then
            perm="$(_security_mode_of "$ssh_dir")"
            if _security_perm_writeable "$perm"; then
                _security_verify_fail "$ssh_dir is group/other-writable (mode $perm) — StrictModes would reject it"
                return 1
            fi
        fi
        perm="$(_security_mode_of "$auth_keys")"
        if _security_perm_writeable "$perm"; then
            _security_verify_fail "$auth_keys is group/other-writable (mode $perm) — StrictModes would reject it"
            return 1
        fi
        local owner
        owner="$(_security_owner_of "$auth_keys")"
        if [[ -n "$owner" && "$owner" != "$user" && "$owner" != "root" ]]; then
            _security_verify_fail "$auth_keys is owned by '$owner', not '$user' or root"
            return 1
        fi
    fi

    # Ensure file contains actual public key patterns
    if ! ssh-keygen -l -f "$auth_keys" >/dev/null 2>&1; then
        _security_verify_fail "$auth_keys contains no recognizable public key"
        return 1
    fi

    # 6. Check sshd_config does not explicitly disable PubkeyAuthentication
    local pubkey_cfg
    pubkey_cfg="$(security_get_sshd_param PubkeyAuthentication "unknown")"
    pubkey_cfg="$(printf '%s' "$pubkey_cfg" | tr '[:upper:]' '[:lower:]')"
    if [[ "$pubkey_cfg" != "yes" ]]; then
        _security_verify_fail "effective PubkeyAuthentication is '$pubkey_cfg', not 'yes'"
        echo "  Locate the directive: sudo grep -rni pubkeyauthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/" >&2
        echo "  Safe path: set PubkeyAuthentication yes, reload sshd, verify a key" >&2
        echo "  login in a NEW session, then re-run hardening to disable password auth." >&2
        return 1
    fi

    local methods method key_only=0
    methods="$(security_get_sshd_param AuthenticationMethods unknown)"
    for method in $methods; do
        [[ "$method" == any || "$method" == publickey ]] && key_only=1
    done
    if [[ "$key_only" -ne 1 ]]; then
        _security_verify_fail "AuthenticationMethods '$methods' does not permit verified key-only login"
        return 1
    fi
    if [[ "$(security_get_sshd_param RefuseConnection no)" == yes ]]; then
        _security_verify_fail "sshd refuses connections for this admin context"
        return 1
    fi

    # 7. Allow/Deny user and group lists must not exclude the admin account.
    # These come from sshd -T, so unset directives simply yield empty strings.
    local allowusers denyusers allowgroups denygroups
    allowusers="$(security_get_sshd_param AllowUsers "")"
    denyusers="$(security_get_sshd_param DenyUsers "")"
    allowgroups="$(security_get_sshd_param AllowGroups "")"
    denygroups="$(security_get_sshd_param DenyGroups "")"
    if [[ -n "$denyusers" ]] && _security_user_in_list "$user" "$denyusers" "$context" deny; then
        _security_verify_fail "user '$user' matches DenyUsers ($denyusers)"
        return 1
    fi
    if [[ -n "$allowusers" ]] && ! _security_user_in_list "$user" "$allowusers" "$context" allow; then
        _security_verify_fail "user '$user' is not in AllowUsers ($allowusers)"
        return 1
    fi
    if [[ -n "$denygroups" ]] && _security_group_in_list "$user_groups" "$denygroups"; then
        _security_verify_fail "a group of '$user' matches DenyGroups ($denygroups)"
        return 1
    fi
    if [[ -n "$allowgroups" ]] && ! _security_group_in_list "$user_groups" "$allowgroups"; then
        _security_verify_fail "no group of '$user' is in AllowGroups ($allowgroups)"
        return 1
    fi

    # 8. A locked account ('!' shadow prefix) only blocks pubkey login when
    # sshd is not delegating account checks to PAM (UsePAM no).
    if command -v getent >/dev/null 2>&1; then
        local shadow_pw usepam
        shadow_pw="$(getent shadow "$user" 2>/dev/null | cut -d: -f2 || true)"
        if [[ "$shadow_pw" == '!'* ]]; then
            usepam="$(security_get_sshd_param UsePAM "unknown")"
            usepam="$(printf '%s' "$usepam" | tr '[:upper:]' '[:lower:]')"
            if [[ "$usepam" != "yes" ]]; then
                _security_verify_fail "account '$user' is locked (shadow '!') and UsePAM is not 'yes'"
                return 1
            fi
        fi
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
    # Debian-family sshd -t fails outright without the privilege-separation
    # directory, which does not exist on minimal/container installs.
    if [[ "$(uname -s 2>/dev/null)" == "Linux" && ! -d /run/sshd ]]; then
        sudo mkdir -p /run/sshd 2>/dev/null || true
    fi
    if command -v sshd >/dev/null 2>&1; then
        sudo sshd -t "${args[@]+"${args[@]}"}" 2>/dev/null
        return $?
    elif [[ -x /usr/sbin/sshd ]]; then
        sudo /usr/sbin/sshd -t "${args[@]+"${args[@]}"}" 2>/dev/null
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
                # The managed-block marker is a real comment; dedup it by its
                # text before classifying comment-vs-disabled-directive.
                bare = normalized
                sub(/^#[[:space:]]*/, "", bare)
                if (!in_match && bare == "rig security baseline") {
                    # The managed block ends with one separator blank line;
                    # remember to drop that too so re-rendering stays stable.
                    pending_blank = 1
                    next
                }
                check = normalized
                if (substr(check, 1, 1) == "#") {
                    if (substr(check, 2, 1) ~ /[a-z]/) {
                        # Stock "#Port 22"-style disabled directive: dedup it
                        # so the managed block above is the effective value.
                        sub(/^#/, "", check)
                    } else {
                        # A real comment ("# Port ...", "# note"): never a
                        # directive, always preserved.
                        check = "__comment__"
                    }
                }
                split(check, fields, /[[:space:]]+/)
                if (!in_match && fields[1] ~ /^(permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|port)$/) next
                if (pending_blank && normalized ~ /^[[:space:]]*$/) {
                    pending_blank = 0
                    next
                }
                pending_blank = 0
                print
            }
        ' "$input"
    } > "$output"
}

# security_sshd_context USER PORT - Use the current SSH connection when known.
# An explicit context is useful when applying a policy from a local console.
security_sshd_context() {
    local user="$1" port="$2" client client_port server server_port
    if [[ -n "${RIG_SSH_TEST_CONTEXT:-}" ]]; then
        printf 'user=%s,%s\n' "$user" "$RIG_SSH_TEST_CONTEXT"
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r client client_port server server_port <<< "$SSH_CONNECTION"
        printf 'user=%s,host=%s,addr=%s,laddr=%s,lport=%s\n' "$user" "$client" "$client" "$server" "$port"
    else
        printf 'user=%s,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=%s\n' "$user" "$port"
    fi
}

# Resolve the whole configuration, with optional candidate file and Match context.
security_sshd_effective() {
    local config_file="${1:-}" context="${2:-}" sshd_bin="" output
    local -a args=(-T)
    [[ -z "$config_file" ]] || args+=(-f "$config_file")
    [[ -z "$context" ]] || args+=(-C "$context")
    if command -v sshd >/dev/null 2>&1; then sshd_bin=sshd
    elif [[ -x /usr/sbin/sshd ]]; then sshd_bin=/usr/sbin/sshd
    else return 1; fi
    if output="$("$sshd_bin" "${args[@]}" 2>/dev/null)" && [[ -n "$output" ]]; then
        printf '%s\n' "$output"; return 0
    fi
    if output="$(sudo -n "$sshd_bin" "${args[@]}" 2>/dev/null)" && [[ -n "$output" ]]; then
        printf '%s\n' "$output"; return 0
    fi
    if [[ "${RIG_NO_SUDO_PROMPT:-0}" != 1 ]] && rig_can_prompt 2>/dev/null; then
        if output="$(sudo "$sshd_bin" "${args[@]}" </dev/tty)" && [[ -n "$output" ]]; then
            printf '%s\n' "$output"; return 0
        fi
    fi
    return 1
}

# Scalar directives yield one value; list directives retain ALL rows and values.
security_get_sshd_param() {
    local param="$1" default_val="${2-unknown}" output value
    if [[ -n "${_SECURITY_SSHD_OUTPUT:-}" ]]; then
        output="$_SECURITY_SSHD_OUTPUT"
    elif ! output="$(security_sshd_effective "${3:-}" "${4:-}")"; then
        printf '%s\n' "$default_val"; return 0
    fi
    value="$(printf '%s\n' "$output" | awk -v key="$param" '
        tolower($1) == tolower(key) {
            $1=""; sub(/^[[:space:]]+/, "")
            if (found++) printf " "
            printf "%s", $0
        }
        END { if (found) printf "\n" }
    ')"
    printf '%s\n' "${value:-$default_val}"
}

# Confirm the new port belongs to an SSH listener before withdrawing old rules.
security_verify_sshd_listener() {
    local port="$1" sockets
    if command -v ss >/dev/null 2>&1; then
        sockets="$(sudo ss -H -lntp)" || return 1
        printf '%s\n' "$sockets" | awk -v port="$port" '
            $4 ~ (":" port "$") && /users:.*"sshd"/ { found=1 }
            END { exit !found }
        '
    elif command -v lsof >/dev/null 2>&1; then
        sudo lsof -nP -iTCP:"$port" -sTCP:LISTEN | awk '
            $1 == "sshd" || $1 == "launchd" { found=1 }
            END { exit !found }
        '
    else
        echo "Cannot verify the new SSH listener: ss/lsof is unavailable" >&2
        return 1
    fi
}

security_sshd_is_running() {
    local svc=sshd
    is_debian && svc=ssh
    if command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then
        systemctl is-active --quiet "$svc"
    else
        pgrep -x sshd >/dev/null 2>&1
    fi
}

security_stop_sshd() {
    local svc=sshd
    is_debian && svc=ssh
    if command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then
        sudo systemctl stop "$svc"
    elif is_macos; then
        sudo launchctl bootout system/com.openssh.sshd
    elif command -v service >/dev/null 2>&1; then
        sudo service "$svc" stop
    else
        sudo pkill -TERM -x sshd
    fi
}

# Shared apply/rollback service operation; failures remain visible to the caller.
security_reload_sshd() {
    local svc=sshd
    is_debian && svc=ssh
    if command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then
        sudo systemctl reload-or-restart "$svc" || sudo systemctl restart "$svc"
    elif is_macos; then
        sudo launchctl kickstart -k system/com.openssh.sshd
    elif command -v service >/dev/null 2>&1; then
        sudo service "$svc" reload || sudo service "$svc" restart
    else
        sudo pkill -HUP -x sshd
    fi
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
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
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
    for item in "${raw_tcp[@]+"${raw_tcp[@]}"}"; do
        item="$(echo "$item" | tr -d ' ')"
        [[ -n "$item" ]] && allowed_tcp+=("$item")
    done

    IFS=',' read -r -a raw_udp <<< "$allowed_udp_csv"
    for item in "${raw_udp[@]+"${raw_udp[@]}"}"; do
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
        # Accept bracketed IPv6 and %-zone suffixes (127.0.0.53%lo, fe80::1%eth0)
        if [[ "$local_addr" =~ \[?([*0-9a-fA-F:%\.A-Za-z]+)\]?:([0-9]+)$ ]]; then
            bind_ip="${BASH_REMATCH[1]}"
            bind_ip="${bind_ip%%%*}"
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

        # Anything bound to loopback or a link-local address cannot be reached
        # from the public network: all of 127.0.0.0/8, ::1, fe80::/10, 169.254/16.
        case "$bind_ip" in
            127.*|::1|localhost|fe80::*|169.254.*) is_internal=1 ;;
        esac

        if [[ $is_internal -eq 1 ]]; then
            status_str="${GREEN}✔ Internal only${NC}"
        else
            if [[ "$proto" == "tcp" ]]; then
                for p in "${allowed_tcp[@]+"${allowed_tcp[@]}"}"; do
                    if [[ "$p" == "$port" ]]; then
                        is_declared=1; break
                    fi
                done
            elif [[ "$proto" == "udp" ]]; then
                for p in "${allowed_udp[@]+"${allowed_udp[@]}"}"; do
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
                    status_str="${YELLOW}⚠ WARN: FW inactive?${NC}"
                    warnings+=("Port $port/$proto ($proc_name) exposed publicly while firewall ($fw_backend) is inactive or unreadable!")
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

    # `sudo -n` keeps this read-only audit from prompting for a password; the
    # unprivileged fallback still lists sockets (process names stay "unknown").
    done < <({ sudo -n ss -lntup 2>/dev/null || ss -lntu 2>/dev/null; } | tail -n +2 || true)

    if [[ ${#warnings[@]} -gt 0 ]]; then
        printf "\n  ${YELLOW}${BOLD}Security Warnings:${NC}\n"
        for w in "${warnings[@]+"${warnings[@]}"}"; do
            printf "  ${YELLOW}[!] $w${NC}\n"
        done
        printf "  ${DIM}Hint: Private container services should explicitly bind to 127.0.0.1 (e.g., 127.0.0.1:port:port).${NC}\n"
    fi
}
