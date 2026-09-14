#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Security Baseline & Hardening Module
# https://github.com/DieRingedesSaturn/rig
#
# Anti-lockout protection, SSH hardening, unified firewall, and port auditing.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"
# shellcheck source=lib/rig-config.sh
source "$SCRIPT_DIR/lib/rig-config.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/firewall.sh
source "$SCRIPT_DIR/lib/firewall.sh"
# shellcheck source=lib/security.sh
source "$SCRIPT_DIR/lib/security.sh"

# Parse command-line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y|--non-interactive)
            export RIG_NON_INTERACTIVE=1
            shift
            ;;
        --help|-h)
            echo "Usage: setup-security.sh [--yes|--non-interactive|--help]"
            echo "  Hardens SSH, configures firewall rules, and audits listening ports."
            exit 0
            ;;
        *) shift ;;
    esac
done

# Resolve Configuration
CURRENT_SSH_PORT="$(security_get_sshd_param Port 22)"
RIG_ADMIN_USER="$(rig_config_get RIG_ADMIN_USER "${SUDO_USER:-$(whoami)}")"
RIG_SSH_PORT="$(rig_config_get RIG_SSH_PORT "$CURRENT_SSH_PORT")"
RIG_SSH_ROOT_LOGIN="$(rig_config_get RIG_SSH_ROOT_LOGIN "no")"
RIG_SSH_PASSWORD_AUTH="$(rig_config_get RIG_SSH_PASSWORD_AUTH "no")"
RIG_SSH_PUBKEY_AUTH="$(rig_config_get RIG_SSH_PUBKEY_AUTH "yes")"
RIG_SSH_ACCESS="$(rig_config_get RIG_SSH_ACCESS "public")"

RIG_FIREWALL="$(rig_config_get RIG_FIREWALL "auto")"
RIG_FIREWALL_DEFAULT_IN="$(rig_config_get RIG_FIREWALL_DEFAULT_IN "deny")"
RIG_FIREWALL_DEFAULT_OUT="$(rig_config_get RIG_FIREWALL_DEFAULT_OUT "allow")"

RIG_PUBLIC_TCP="$(rig_config_get RIG_PUBLIC_TCP "$RIG_SSH_PORT")"
PREVIOUS_PUBLIC_TCP="$RIG_PUBLIC_TCP"
RIG_PUBLIC_UDP="$(rig_config_get RIG_PUBLIC_UDP "")"
RIG_CHECK_LISTENING_PORTS="$(rig_config_get RIG_CHECK_LISTENING_PORTS "yes")"
RIG_WARN_UNDECLARED_PORTS="$(rig_config_get RIG_WARN_UNDECLARED_PORTS "yes")"

csv_without_port() {
    local csv="$1" excluded="$2" item result=""
    local -a entries=()
    IFS=',' read -r -a entries <<< "$csv"
    for item in "${entries[@]}"; do
        item="$(printf '%s' "$item" | tr -d ' ')"
        [[ -z "$item" || "$item" == "$excluded" ]] && continue
        if [[ -n "$result" ]]; then result="$result,$item"; else result="$item"; fi
    done
    printf '%s\n' "$result"
}

csv_prepend_unique() {
    local first="$1" rest="$2"
    rest="$(csv_without_port "$rest" "$first")"
    if [[ -n "$rest" ]]; then printf '%s,%s\n' "$first" "$rest"; else printf '%s\n' "$first"; fi
}

csv_has_port() {
    local csv="$1" wanted="$2" item
    local -a entries=()
    IFS=',' read -r -a entries <<< "$csv"
    for item in "${entries[@]}"; do
        item="$(printf '%s' "$item" | tr -d ' ')"
        [[ "$item" == "$wanted" ]] && return 0
    done
    return 1
}

# Interactive prompt if running in interactive terminal
if [[ -t 0 ]] && [[ "${RIG_NON_INTERACTIVE:-0}" -ne 1 ]]; then
    PUBLIC_TCP_EXTRAS="$(csv_without_port "$RIG_PUBLIC_TCP" "$RIG_SSH_PORT")"
    printf "\n=== Interactive Security Baseline Configuration ===\n"
    printf "Press Enter to keep the currently resolved value.\n\n"

    printf "SSH Access scope:\n"
    printf "  [1] Public / All interfaces\n"
    printf "  [2] Tailscale only (tailscale0 interface)\n"
    read -rp "Choice [1/2, current: $RIG_SSH_ACCESS]: " ans_access </dev/tty || ans_access=""
    case "$ans_access" in
        "") ;;
        1) RIG_SSH_ACCESS="public" ;;
        2) RIG_SSH_ACCESS="tailscale" ;;
        *) echo "  Invalid choice; keeping $RIG_SSH_ACCESS." ;;
    esac

    read -rp "PermitRootLogin [current: $RIG_SSH_ROOT_LOGIN; no/prohibit-password/yes]: " ans_root </dev/tty || ans_root=""
    case "$ans_root" in
        "") ;;
        no|prohibit-password|yes) RIG_SSH_ROOT_LOGIN="$ans_root" ;;
        *) echo "  Invalid value; keeping $RIG_SSH_ROOT_LOGIN." ;;
    esac

    read -rp "PasswordAuthentication [current: $RIG_SSH_PASSWORD_AUTH; yes/no]: " ans_pass </dev/tty || ans_pass=""
    case "$ans_pass" in
        "") ;;
        yes|no) RIG_SSH_PASSWORD_AUTH="$ans_pass" ;;
        *) echo "  Invalid value; keeping $RIG_SSH_PASSWORD_AUTH." ;;
    esac

    read -rp "SSH Port [default: $RIG_SSH_PORT]: " ans_port </dev/tty || ans_port=""
    if [[ -n "$ans_port" && "$ans_port" =~ ^[0-9]+$ ]]; then
        RIG_SSH_PORT="$ans_port"
    fi

    read -rp "Other public TCP ports [current: ${PUBLIC_TCP_EXTRAS:-none}; e.g. 80,443; 'none' clears]: " ans_tcp </dev/tty || ans_tcp=""
    case "$ans_tcp" in
        "") ;;
        none|None|NONE) PUBLIC_TCP_EXTRAS="" ;;
        *) PUBLIC_TCP_EXTRAS="$ans_tcp" ;;
    esac
    if [[ "$RIG_SSH_ACCESS" == "public" ]]; then
        RIG_PUBLIC_TCP="$(csv_prepend_unique "$RIG_SSH_PORT" "$PUBLIC_TCP_EXTRAS")"
    else
        RIG_PUBLIC_TCP="$PUBLIC_TCP_EXTRAS"
    fi
    printf "\n"
fi

case "$RIG_SSH_PORT" in
    ''|*[!0-9]*) echo "Invalid SSH port: $RIG_SSH_PORT" >&2; exit 1 ;;
esac
if [[ "$RIG_SSH_PORT" -lt 1 || "$RIG_SSH_PORT" -gt 65535 ]]; then
    echo "Invalid SSH port: $RIG_SSH_PORT" >&2
    exit 1
fi

case "$RIG_SSH_ACCESS" in public|tailscale) ;; *) echo "Invalid RIG_SSH_ACCESS: $RIG_SSH_ACCESS" >&2; exit 1 ;; esac
case "$RIG_SSH_ROOT_LOGIN" in no|prohibit-password|yes) ;; *) echo "Invalid RIG_SSH_ROOT_LOGIN: $RIG_SSH_ROOT_LOGIN" >&2; exit 1 ;; esac
case "$RIG_SSH_PASSWORD_AUTH" in yes|no) ;; *) echo "Invalid RIG_SSH_PASSWORD_AUTH: $RIG_SSH_PASSWORD_AUTH" >&2; exit 1 ;; esac
case "$RIG_SSH_PUBKEY_AUTH" in yes|no) ;; *) echo "Invalid RIG_SSH_PUBKEY_AUTH: $RIG_SSH_PUBKEY_AUTH" >&2; exit 1 ;; esac
case "$RIG_FIREWALL_DEFAULT_IN" in allow|deny) ;; *) echo "Invalid inbound firewall policy: $RIG_FIREWALL_DEFAULT_IN" >&2; exit 1 ;; esac
case "$RIG_FIREWALL_DEFAULT_OUT" in allow|deny) ;; *) echo "Invalid outbound firewall policy: $RIG_FIREWALL_DEFAULT_OUT" >&2; exit 1 ;; esac
case "$RIG_CHECK_LISTENING_PORTS" in yes|no) ;; *) echo "Invalid RIG_CHECK_LISTENING_PORTS: $RIG_CHECK_LISTENING_PORTS" >&2; exit 1 ;; esac
case "$RIG_WARN_UNDECLARED_PORTS" in yes|no) ;; *) echo "Invalid RIG_WARN_UNDECLARED_PORTS: $RIG_WARN_UNDECLARED_PORTS" >&2; exit 1 ;; esac

validate_port_list() {
    local csv="$1" label="$2" item
    local -a items=()
    IFS=',' read -r -a items <<< "$csv"
    for item in "${items[@]}"; do
        item="$(printf '%s' "$item" | tr -d ' ')"
        [[ -z "$item" ]] && continue
        case "$item" in *[!0-9]*) echo "Invalid port in $label: $item" >&2; return 1 ;; esac
        if [[ "$item" -lt 1 || "$item" -gt 65535 ]]; then
            echo "Invalid port in $label: $item" >&2
            return 1
        fi
    done
}
validate_port_list "$RIG_PUBLIC_TCP" RIG_PUBLIC_TCP
validate_port_list "$RIG_PUBLIC_UDP" RIG_PUBLIC_UDP

echo "=== System Security & Baseline Hardening ==="

# --- [1/5] Anti-lockout Protection Check -------------------------------------
echo "[1/5] Verifying anti-lockout safety constraints..."

LOCKOUT_RISK=0
if [[ "$RIG_SSH_ROOT_LOGIN" == "no" || "$RIG_SSH_PASSWORD_AUTH" == "no" ]]; then
    LOCKOUT_RISK=1
fi

if [[ $LOCKOUT_RISK -eq 1 ]]; then
    if [[ "$RIG_ADMIN_USER" == "root" ]]; then
        echo "  ${RED}Error: Cannot harden SSH when RIG_ADMIN_USER is root!${NC}" >&2
        echo "  You must designate a non-root admin user with sudo privileges and an SSH key." >&2
        exit 1
    fi

    if ! security_verify_admin_user "$RIG_ADMIN_USER"; then
        echo "  ${RED}FATAL: Anti-lockout guard blocked hardening!${NC}" >&2
        echo "  User '$RIG_ADMIN_USER' either does not exist, lacks sudo privileges, or" >&2
        echo "  has no valid SSH public keys in ~/.ssh/authorized_keys." >&2
        echo "  Refusing to disable root SSH login or password authentication." >&2
        exit 1
    fi
    echo "  ${GREEN}✔ Anti-lockout check passed:${NC} Admin user '$RIG_ADMIN_USER' verified (sudo + SSH key active)."
else
    echo "  Anti-lockout check skipped (root/password login not being disabled)."
fi

# Build and validate the complete candidate before touching the firewall or
# active sshd configuration. Match blocks are preserved verbatim.
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CANDIDATE=""
if [[ -f "$SSHD_CONFIG" ]]; then
    SSHD_CANDIDATE="$(mktemp)"
    trap '[[ -n "${SSHD_CANDIDATE:-}" ]] && rm -f "$SSHD_CANDIDATE"' EXIT
    security_render_sshd_config "$SSHD_CONFIG" "$SSHD_CANDIDATE" \
        "$RIG_SSH_PORT" "$RIG_SSH_ROOT_LOGIN" \
        "$RIG_SSH_PASSWORD_AUTH" "$RIG_SSH_PUBKEY_AUTH"
    if ! security_test_sshd_config "$SSHD_CANDIDATE"; then
        echo "  ${RED}ERROR: candidate sshd configuration failed preflight; no system changes were made.${NC}" >&2
        exit 1
    fi
    echo "  ${GREEN}✔ Candidate sshd configuration passed syntax preflight.${NC}"
fi

# --- [2/5] Firewall Provisioning ---------------------------------------------
echo ""
echo "[2/5] Configuring firewall..."

if [[ "$RIG_SSH_ACCESS" == "tailscale" ]]; then
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
        echo "  ${GREEN}✔ Tailscale is active.${NC}"
    else
        echo "  ${RED}ERROR: Tailscale is not running or not connected!${NC}" >&2
        echo "  Restricting SSH to tailscale0 while Tailscale is inactive would lock you out." >&2
        echo "  Please start Tailscale ('tailscale up') or change RIG_SSH_ACCESS to 'public' first.${NC}" >&2
        exit 1
    fi
fi

FW_BACKEND="$(firewall_detect_backend "$RIG_FIREWALL")"
if [[ "$FW_BACKEND" == "none" ]]; then
    if [[ "$RIG_SSH_ACCESS" == "tailscale" ]]; then
        echo "  ${RED}ERROR: Tailscale-only SSH requires a supported firewall backend.${NC}" >&2
        exit 1
    fi
    echo "  No supported firewall engine for this system, skipping."
else
    if [[ "$FW_BACKEND" == "firewalld" && "$RIG_FIREWALL_DEFAULT_OUT" != "allow" ]]; then
        echo "  ${RED}ERROR: firewalld cannot enforce RIG_FIREWALL_DEFAULT_OUT=$RIG_FIREWALL_DEFAULT_OUT.${NC}" >&2
        exit 1
    fi
    echo "  Firewall backend: $FW_BACKEND"
    firewall_ensure_installed "$FW_BACKEND"
    # firewall-cmd cannot write permanent rules until the daemon is running.
    if [[ "$FW_BACKEND" == "firewalld" ]]; then
        firewall_enable "$FW_BACKEND"
    fi

    # Always ensure SSH port is opened first to prevent lockout
    if [[ "$RIG_SSH_ACCESS" == "tailscale" ]]; then
        echo "  Restricting SSH port $RIG_SSH_PORT to Tailscale interface (tailscale0)..."
        firewall_allow_port "$FW_BACKEND" "$RIG_SSH_PORT" "tcp" "tailscale0"
    else
        echo "  Allowing public SSH port $RIG_SSH_PORT/tcp..."
        firewall_allow_port "$FW_BACKEND" "$RIG_SSH_PORT" "tcp"
    fi

    # Allow declared public TCP ports (skip SSH port if restricted to Tailscale)
    IFS=',' read -r -a tcp_ports <<< "$RIG_PUBLIC_TCP"
    for p in "${tcp_ports[@]}"; do
        p="$(echo "$p" | tr -d ' ')"
        [[ -z "$p" ]] && continue
        if [[ "$RIG_SSH_ACCESS" == "tailscale" && "$p" == "$RIG_SSH_PORT" ]]; then
            echo "  Skipping public rule for SSH port $p (restricted to Tailscale)."
            continue
        fi
        firewall_allow_port "$FW_BACKEND" "$p" "tcp"
    done

    # Allow declared public UDP ports
    IFS=',' read -r -a udp_ports <<< "$RIG_PUBLIC_UDP"
    for p in "${udp_ports[@]}"; do
        p="$(echo "$p" | tr -d ' ')"
        [[ -z "$p" ]] && continue
        firewall_allow_port "$FW_BACKEND" "$p" "udp"
    done

    # Set default policies and activate
    firewall_set_defaults "$FW_BACKEND" "$RIG_FIREWALL_DEFAULT_IN" "$RIG_FIREWALL_DEFAULT_OUT"
    if [[ "$FW_BACKEND" == "ufw" ]]; then
        firewall_enable "$FW_BACKEND"
    else
        firewall_reload "$FW_BACKEND"
    fi
    echo "  ${GREEN}✔ Firewall configured and enabled.${NC}"
fi

# --- [3/5] SSH Hardening & sshd -t Preflight --------------------------------
echo ""
echo "[3/5] Hardening OpenSSH server..."

if [[ -f "$SSHD_CONFIG" ]]; then
    ORIGINAL_CONFIG="$(rig_system_backup_once "$SSHD_CONFIG" pre-rig)"
    BACKUP_CONFIG="$(rig_system_backup "$SSHD_CONFIG" security)"
    echo "  Backup: $BACKUP_CONFIG"
    sudo cp "$SSHD_CANDIDATE" "$SSHD_CONFIG"

    # Re-check the installed file, then reload with rollback on any failure.
    if security_test_sshd_config; then
        echo "  ${GREEN}✔ sshd -t syntax preflight passed.${NC}"
        # Reload sshd safely with rollback on failure
        reload_ok=1
        if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
            if is_debian; then
                sudo systemctl reload-or-restart ssh 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || reload_ok=0
            else
                sudo systemctl reload-or-restart sshd 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || reload_ok=0
            fi
        elif command -v service >/dev/null 2>&1; then
            if is_debian; then
                sudo service ssh reload 2>/dev/null || sudo service ssh restart 2>/dev/null || reload_ok=0
            else
                sudo service sshd reload 2>/dev/null || sudo service sshd restart 2>/dev/null || reload_ok=0
            fi
        elif is_macos; then
            echo "  macOS detected: sshd configuration updated."
        fi

        if [[ $reload_ok -eq 1 ]]; then
            echo "  ${GREEN}✔ sshd reloaded with hardened policies.${NC}"
        else
            echo "  ${RED}ERROR: sshd reload/restart failed! Rolling back sshd_config...${NC}" >&2
            sudo cp "$BACKUP_CONFIG" "$SSHD_CONFIG"
            if command -v systemctl >/dev/null 2>&1; then
                sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
            fi
            echo "  Rolled back to previous working configuration." >&2
            exit 1
        fi
    else
        echo "  ${RED}ERROR: sshd -t test failed! Rolling back sshd_config...${NC}" >&2
        sudo cp "$BACKUP_CONFIG" "$SSHD_CONFIG"
        echo "  Rolled back to previous working configuration. Service was not restarted." >&2
        exit 1
    fi
else
    echo "  /etc/ssh/sshd_config not found, skipping sshd hardening."
fi

# Reconcile rules that were previously declared by Rig but the user removed in
# this run. Do this only after the SSH candidate has been applied successfully.
if [[ "$FW_BACKEND" != "none" ]]; then
    IFS=',' read -r -a previous_tcp_ports <<< "$PREVIOUS_PUBLIC_TCP"
    for p in "${previous_tcp_ports[@]}"; do
        p="$(printf '%s' "$p" | tr -d ' ')"
        [[ -z "$p" ]] && continue
        if ! csv_has_port "$RIG_PUBLIC_TCP" "$p"; then
            echo "  Removing no-longer-declared public rule $p/tcp..."
            firewall_remove_public_port "$FW_BACKEND" "$p" tcp
        fi
    done
    if [[ "$RIG_SSH_ACCESS" == "tailscale" ]]; then
        echo "  Ensuring SSH has no broad public allow rule..."
        firewall_remove_public_port "$FW_BACKEND" "$RIG_SSH_PORT" tcp
        if [[ "$CURRENT_SSH_PORT" != "$RIG_SSH_PORT" ]]; then
            firewall_remove_public_port "$FW_BACKEND" "$CURRENT_SSH_PORT" tcp
        fi
    fi
    firewall_reload "$FW_BACKEND"
fi

# --- [4/5] Tailscale Integration Check ---------------------------------------
echo ""
echo "[4/5] Checking Tailscale status..."
if command -v tailscale >/dev/null 2>&1; then
    TS_IP="$(tailscale ip -4 2>/dev/null || echo "not connected")"
    echo "  Tailscale IPv4: $TS_IP"
else
    echo "  Tailscale not installed (optional)."
fi

# --- [5/5] Listening Ports Audit ---------------------------------------------
echo ""
echo "[5/5] Auditing listening ports against policy..."
if [[ "$RIG_CHECK_LISTENING_PORTS" == "yes" ]]; then
    security_audit_listening_ports "$RIG_PUBLIC_TCP" "$RIG_PUBLIC_UDP" "$RIG_WARN_UNDECLARED_PORTS" "$RIG_SSH_ACCESS" "$RIG_SSH_PORT"
fi

# Record only a fully applied policy. Failed preflight/firewall/reload paths exit
# before this point and therefore cannot persist a misleading desired state.
rig_config_set RIG_ADMIN_USER "$RIG_ADMIN_USER"
rig_config_set RIG_SSH_PORT "$RIG_SSH_PORT"
rig_config_set RIG_SSH_ROOT_LOGIN "$RIG_SSH_ROOT_LOGIN"
rig_config_set RIG_SSH_PASSWORD_AUTH "$RIG_SSH_PASSWORD_AUTH"
rig_config_set RIG_SSH_PUBKEY_AUTH "$RIG_SSH_PUBKEY_AUTH"
rig_config_set RIG_SSH_ACCESS "$RIG_SSH_ACCESS"
rig_config_set RIG_FIREWALL "$RIG_FIREWALL"
rig_config_set RIG_FIREWALL_DEFAULT_IN "$RIG_FIREWALL_DEFAULT_IN"
rig_config_set RIG_FIREWALL_DEFAULT_OUT "$RIG_FIREWALL_DEFAULT_OUT"
rig_config_set RIG_PUBLIC_TCP "$RIG_PUBLIC_TCP"
rig_config_set RIG_PUBLIC_UDP "$RIG_PUBLIC_UDP"
rig_config_set RIG_CHECK_LISTENING_PORTS "$RIG_CHECK_LISTENING_PORTS"
rig_config_set RIG_WARN_UNDECLARED_PORTS "$RIG_WARN_UNDECLARED_PORTS"
echo "  Saved security choices in $(rig_config_file)."

echo ""
echo "=== Security Hardening Complete ==="
