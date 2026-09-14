#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Rig Config Export
# https://github.com/DieRingedesSaturn/rig
#
# Exports installed component configuration to JSON + optional secrets.env.
#
# Usage:
#   bash export-config.sh                     # Export to ~/.rig/
#   bash export-config.sh --output-dir /tmp   # Custom output directory
#   bash export-config.sh --no-secrets        # Skip sensitive data
#   bash export-config.sh --json              # Print JSON to stdout only
#
# Output files:
#   rig-config.json   - Non-sensitive configuration (safe to share)
#   secrets.env       - API keys and tokens (chmod 600, gitignored)
#   .gitignore        - Auto-generated to protect secrets.env
# =============================================================================

# --- OS Detection ------------------------------------------------------------

# Source OS detection library if available
if [[ -f "${BASH_SOURCE[0]%/*}/lib/os-detect.sh" ]]; then
    # shellcheck disable=SC1091
    source "${BASH_SOURCE[0]%/*}/lib/os-detect.sh"
else
    # Minimal fallback
    is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
fi

if [[ -f "${BASH_SOURCE[0]%/*}/lib/rig-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "${BASH_SOURCE[0]%/*}/lib/rig-config.sh"
fi
if [[ -f "${BASH_SOURCE[0]%/*}/lib/backup.sh" ]]; then
    # shellcheck disable=SC1091
    source "${BASH_SOURCE[0]%/*}/lib/backup.sh"
fi

# --- Options -----------------------------------------------------------------

OUTPUT_DIR="$HOME/.rig"
EXPORT_SECRETS=1
JSON_ONLY=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
        --no-secrets)  EXPORT_SECRETS=0; shift ;;
        --json)        JSON_ONLY=1; shift ;;
        --help|-h)
            echo "Usage: export-config.sh [--output-dir DIR] [--no-secrets] [--json] [--help]"
            echo "  --output-dir DIR  Output directory (default: ~/.rig)"
            echo "  --no-secrets      Skip exporting API keys and tokens"
            echo "  --json            Print JSON to stdout only (no files written)"
            echo ""
            echo "Exported data:"
            echo "  rig-config.json   - Component list and user/email (imported by rig)"
            echo "  secrets.env       - API keys/tokens (imported by rig)"
            echo ""
            echo "Informational only (not imported):"
            echo "  - Node versions (detected at import time)"
            echo "  - Container engine and registry mirrors (requires manual setup)"
            echo "  - Model preferences (preserved if already configured)"
            exit 0
            ;;
        *) shift ;;
    esac
done

# --- Colors ------------------------------------------------------------------

setup_colors() {
    if [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
        SYM_CHECK="${GREEN}✔${NC}"
        SYM_WARN="${YELLOW}▲${NC}"
        SYM_CROSS="${RED}✘${NC}"
    else
        RED='' GREEN='' YELLOW='' CYAN=''
        BOLD='' DIM='' NC=''
        SYM_CHECK='[ok]' SYM_WARN='[!]' SYM_CROSS='[fail]'
    fi
}

[[ "$JSON_ONLY" -eq 0 ]] && setup_colors

# --- Helpers -----------------------------------------------------------------

# JSON-escape a string value
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Print a JSON key-value pair (string)
json_kv() {
    printf '    "%s": "%s"' "$1" "$(json_escape "$2")"
}

# Load nvm if available
load_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [[ -f "$NVM_DIR/nvm.sh" ]]; then
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh" 2>/dev/null
    fi
    # Returning 0 on purpose: a missing nvm is normal, and a bare `[[ ]] && cmd`
    # as the last statement makes the function return 1, which under `set -e`
    # aborts the caller depending on how it was invoked.
    return 0
}

# --- Detect Installed Components ---------------------------------------------

detect_installed() {
    local components=()

    # Shell
    command -v zsh &>/dev/null && components+=("shell")

    # Tmux
    command -v tmux &>/dev/null && components+=("tmux")

    # Git
    command -v git &>/dev/null && components+=("git")

    # Essential Tools
    local tools_found=0
    for t in rg jq fd bat gh; do
        command -v "$t" &>/dev/null && tools_found=$((tools_found + 1))
        [[ "$t" == "fd" ]] && command -v fdfind &>/dev/null && tools_found=$((tools_found + 1))
        [[ "$t" == "bat" ]] && command -v batcat &>/dev/null && tools_found=$((tools_found + 1))
    done
    [[ $tools_found -gt 0 ]] && components+=("tools")

    # Node
    load_nvm
    command -v node &>/dev/null && components+=("node")

    # uv
    command -v uv &>/dev/null || [[ -x "$HOME/.local/bin/uv" ]] && components+=("uv")

    # Neovim
    command -v nvim &>/dev/null && components+=("neovim")

    # Containers — one component with two interchangeable backends, so report
    # whichever backend this machine actually has.
    if command -v podman &>/dev/null; then
        components+=("containers")
    elif command -v docker &>/dev/null; then
        components+=("containers")
    fi

    # Tailscale
    command -v tailscale &>/dev/null && components+=("tailscale")

    # SSH
    command -v ssh &>/dev/null && [[ -d "$HOME/.ssh" ]] && components+=("ssh")

    # Security Baseline
    if [[ -f /etc/ssh/sshd_config ]] && grep -q "# Rig Security Baseline" /etc/ssh/sshd_config 2>/dev/null; then
        components+=("security")
    elif [[ -f "${RIG_SYSTEM_BACKUP_DIR:-$HOME/.local/share/rig/backups/system}/etc__ssh__sshd_config.pre-rig" ]]; then
        components+=("security")
    elif ls /etc/ssh/sshd_config.rig.bak.* &>/dev/null; then
        components+=("security")
    fi

    printf '%s\n' "${components[@]}"
}

# --- Extract Non-Sensitive Config --------------------------------------------

extract_config() {
    local json="{\n"
    json+='  "_comment": "Non-sensitive config exported by Rig. Node versions, container engine/mirrors, and model fields are informational only and not imported.",\n'
    json+='  "rig_version": "0.1.0",\n'
    json+="  \"exported_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\n"

    # Installed components list
    local comps
    comps=$(detect_installed)
    json+='  "components": ['
    local first=1
    while IFS= read -r comp; do
        [[ -z "$comp" ]] && continue
        [[ $first -eq 0 ]] && json+=', '
        json+="\"$comp\""
        first=0
    done <<< "$comps"
    json+="],\n"

    # Config section
    json+='  "config": {\n'

    # Git
    local git_name git_email
    git_name=$(git config --global user.name 2>/dev/null || true)
    git_email=$(git config --global user.email 2>/dev/null || true)
    json+='    "git": {\n'
    json+="$(json_kv "user_name" "${git_name}")"
    json+=',\n'
    json+="$(json_kv "user_email" "${git_email}")"
    json+='\n    },\n'

    # Node (informational only)
    local node_version="N/A"
    command -v node &>/dev/null && node_version=$(node --version 2>/dev/null | sed 's/^v//')
    json+='    "node": {\n'
    json+="$(json_kv "version" "$node_version")"
    json+='\n    },\n'

    # Containers (informational only). The backend and mode come from the rig
    # config, and each backend keeps its registry mirrors in a different place:
    # rootless Docker and Podman are user-level, rootful Docker is system-level.
    local engine="" mirrors=""
    if command -v rig_config_get >/dev/null 2>&1; then
        engine="$(rig_config_get RIG_CONTAINER_ENGINE "")"
    fi
    if [[ -z "$engine" ]]; then
        if command -v podman &>/dev/null; then
            engine="podman"
        elif command -v docker &>/dev/null; then
            engine="docker"
        fi
    fi

    if [[ "$engine" == "podman" && -f "$HOME/.config/containers/registries.conf" ]]; then
        mirrors=$(grep -o 'location[[:space:]]*=[[:space:]]*"[^"]*"' "$HOME/.config/containers/registries.conf" 2>/dev/null | tail -1 || true)
    elif [[ -f "$HOME/.config/docker/daemon.json" ]]; then
        mirrors=$(grep -o '"registry-mirrors"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$HOME/.config/docker/daemon.json" 2>/dev/null || true)
    elif [[ -f /etc/docker/daemon.json ]]; then
        mirrors=$(grep -o '"registry-mirrors"[[:space:]]*:[[:space:]]*\[[^]]*\]' /etc/docker/daemon.json 2>/dev/null || true)
    fi

    local container_mode="${RIG_CONTAINER_MODE:-rootless}"
    if command -v rig_config_get >/dev/null 2>&1; then
        container_mode="$(rig_config_get RIG_CONTAINER_MODE "$container_mode")"
    fi

    json+='    "containers": {\n'
    json+="$(json_kv "engine" "$engine")"
    json+=',\n'
    json+="$(json_kv "mode" "$container_mode")"
    json+=',\n'
    if [[ -n "$mirrors" ]]; then
        json+="    $mirrors"
    else
        json+='    "registry-mirrors": []'
    fi
    json+='\n    },\n'

    # System & Security baseline
    local rig_profile firewall public_tcp public_udp ssh_port
    local ssh_root_login ssh_password_auth ssh_pubkey_auth ssh_access admin_user
    local fw_default_in fw_default_out check_listening_ports warn_undeclared_ports

    rig_profile="${RIG_PROFILE:-}"
    firewall="${RIG_FIREWALL:-auto}"
    public_tcp="${RIG_PUBLIC_TCP:-22}"
    public_udp="${RIG_PUBLIC_UDP:-}"
    ssh_port="${RIG_SSH_PORT:-22}"
    ssh_root_login="${RIG_SSH_ROOT_LOGIN:-no}"
    ssh_password_auth="${RIG_SSH_PASSWORD_AUTH:-no}"
    ssh_pubkey_auth="${RIG_SSH_PUBKEY_AUTH:-yes}"
    ssh_access="${RIG_SSH_ACCESS:-public}"
    admin_user="${RIG_ADMIN_USER:-$USER}"
    fw_default_in="${RIG_FIREWALL_DEFAULT_IN:-deny}"
    fw_default_out="${RIG_FIREWALL_DEFAULT_OUT:-allow}"
    check_listening_ports="${RIG_CHECK_LISTENING_PORTS:-yes}"
    warn_undeclared_ports="${RIG_WARN_UNDECLARED_PORTS:-yes}"

    if command -v rig_config_get >/dev/null 2>&1; then
        rig_profile="$(rig_config_get RIG_PROFILE "$rig_profile")"
        firewall="$(rig_config_get RIG_FIREWALL "$firewall")"
        public_tcp="$(rig_config_get RIG_PUBLIC_TCP "$public_tcp")"
        public_udp="$(rig_config_get RIG_PUBLIC_UDP "$public_udp")"
        ssh_port="$(rig_config_get RIG_SSH_PORT "$ssh_port")"
        ssh_root_login="$(rig_config_get RIG_SSH_ROOT_LOGIN "$ssh_root_login")"
        ssh_password_auth="$(rig_config_get RIG_SSH_PASSWORD_AUTH "$ssh_password_auth")"
        ssh_pubkey_auth="$(rig_config_get RIG_SSH_PUBKEY_AUTH "$ssh_pubkey_auth")"
        ssh_access="$(rig_config_get RIG_SSH_ACCESS "$ssh_access")"
        admin_user="$(rig_config_get RIG_ADMIN_USER "$admin_user")"
        fw_default_in="$(rig_config_get RIG_FIREWALL_DEFAULT_IN "$fw_default_in")"
        fw_default_out="$(rig_config_get RIG_FIREWALL_DEFAULT_OUT "$fw_default_out")"
        check_listening_ports="$(rig_config_get RIG_CHECK_LISTENING_PORTS "$check_listening_ports")"
        warn_undeclared_ports="$(rig_config_get RIG_WARN_UNDECLARED_PORTS "$warn_undeclared_ports")"
    fi

    json+='    "system": {\n'
    json+="$(json_kv "profile" "$rig_profile")"
    json+=',\n'
    json+="$(json_kv "container_mode" "$container_mode")"
    json+=',\n'
    json+="$(json_kv "firewall" "$firewall")"
    json+=',\n'
    json+="$(json_kv "firewall_default_in" "$fw_default_in")"
    json+=',\n'
    json+="$(json_kv "firewall_default_out" "$fw_default_out")"
    json+=',\n'
    json+="$(json_kv "public_tcp" "$public_tcp")"
    json+=',\n'
    json+="$(json_kv "public_udp" "$public_udp")"
    json+=',\n'
    json+="$(json_kv "ssh_port" "$ssh_port")"
    json+=',\n'
    json+="$(json_kv "ssh_root_login" "$ssh_root_login")"
    json+=',\n'
    json+="$(json_kv "ssh_password_auth" "$ssh_password_auth")"
    json+=',\n'
    json+="$(json_kv "ssh_pubkey_auth" "$ssh_pubkey_auth")"
    json+=',\n'
    json+="$(json_kv "ssh_access" "$ssh_access")"
    json+=',\n'
    json+="$(json_kv "admin_user" "$admin_user")"
    json+=',\n'
    json+="$(json_kv "check_listening_ports" "$check_listening_ports")"
    json+=',\n'
    json+="$(json_kv "warn_undeclared_ports" "$warn_undeclared_ports")"
    json+='\n    }\n'

    json+='  }\n'
    json+='}'

    printf '%b' "$json"
}

# --- Extract Secrets ---------------------------------------------------------

extract_secrets() {
    local secrets=""

    # Tailscale auth key (if stored)
    if [[ -f "$HOME/.config/tailscale/auth_key" ]]; then
        local ts_key
        ts_key=$(cat "$HOME/.config/tailscale/auth_key" 2>/dev/null || true)
        [[ -n "$ts_key" ]] && secrets+="TAILSCALE_AUTH_KEY=${ts_key}\n"
    fi

    printf '%b' "$secrets"
}

# --- Main --------------------------------------------------------------------

main() {
    local config_json
    config_json=$(extract_config)

    # JSON-only mode: print and exit
    if [[ "$JSON_ONLY" -eq 1 ]]; then
        printf '%s\n' "$config_json"
        exit 0
    fi

    # Banner
    printf "\n"
    printf "  ${CYAN}${BOLD}┌──────────────────────────────────────────┐${NC}\n"
    printf "  ${CYAN}${BOLD}│${NC}  ${BOLD}${CYAN}Rig Config Export${NC}                        ${CYAN}${BOLD}│${NC}\n"
    printf "  ${CYAN}${BOLD}└──────────────────────────────────────────┘${NC}\n"
    printf "\n"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Write config JSON
    local config_file="$OUTPUT_DIR/rig-config.json"
    printf '%s\n' "$config_json" > "$config_file"
    printf "  ${SYM_CHECK} ${GREEN}Config written to ${CYAN}%s${NC}\n" "$config_file"

    # Write secrets
    if [[ "$EXPORT_SECRETS" -eq 1 ]]; then
        local secrets
        secrets=$(extract_secrets)
        if [[ -n "$secrets" ]]; then
            local secrets_file="$OUTPUT_DIR/secrets.env"
            # Pre-create the file with restrictive permissions (mode 600) before
            # writing any secrets. This closes the TOCTOU window where the file
            # could be world-readable under a permissive umask.
            install -m 600 /dev/null "$secrets_file"
            printf "# Rig secrets — exported %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$secrets_file"
            printf "# WARNING: This file contains sensitive API keys. Do NOT commit to git.\n\n" >> "$secrets_file"
            printf '%b' "$secrets" >> "$secrets_file"
            printf "  ${SYM_CHECK} ${GREEN}Secrets written to ${CYAN}%s${NC} ${DIM}(chmod 600)${NC}\n" "$secrets_file"

            # Auto-generate .gitignore (preserve existing rules)
            local gitignore="$OUTPUT_DIR/.gitignore"
            if [[ ! -f "$gitignore" ]]; then
                printf 'secrets.env\n*.env\n' > "$gitignore"
                printf "  ${SYM_CHECK} ${GREEN}Created ${CYAN}%s${NC}\n" "$gitignore"
            elif ! grep -qF 'secrets.env' "$gitignore" 2>/dev/null; then
                printf 'secrets.env\n' >> "$gitignore"
                printf "  ${SYM_CHECK} ${GREEN}Updated ${CYAN}%s${NC}\n" "$gitignore"
            fi

            printf "\n"
            printf "  ${SYM_WARN} ${YELLOW}${BOLD}secrets.env contains sensitive API keys.${NC}\n"
            printf "  ${DIM}Do not commit this file to version control.${NC}\n"
        else
            printf "  ${DIM}No secrets found to export.${NC}\n"
        fi
    else
        printf "  ${DIM}Secrets export skipped (--no-secrets).${NC}\n"
    fi

    printf "\n"
    printf "  ${DIM}To import on another machine:${NC}\n"
    printf "  ${CYAN}rig import %s${NC}\n" "$config_file"
    printf "\n"
}

main
