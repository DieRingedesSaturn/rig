#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Rig Config Import
# https://github.com/DieRingedesSaturn/rig
#
# Imports configuration exported by export-config.sh and reinstalls components.
#
# Usage:
#   bash import-config.sh ~/.rig/rig-config.json
#   bash import-config.sh --config ~/.rig/rig-config.json --secrets ~/.rig/secrets.env
#   bash import-config.sh --config config.json --yes       # Non-interactive
#
# The script reads the JSON config, optionally sources secrets.env for API keys,
# shows an installation plan, and runs install.sh with the correct components
# and environment variables.
# =============================================================================

# --- OS Detection ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source OS detection library if available
if [[ -f "$SCRIPT_DIR/lib/os-detect.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/os-detect.sh"
else
    # Minimal fallback
    is_debian() { [[ -f /etc/debian_version ]]; }
    is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
    PKG_MANAGER="apt"
    command -v dnf &>/dev/null && PKG_MANAGER="dnf"
    command -v brew &>/dev/null && PKG_MANAGER="brew"
fi

# --- Options -----------------------------------------------------------------

CONFIG_FILE=""
SECRETS_FILE=""
NON_INTERACTIVE=0
GH_PROXY="${GH_PROXY:-}"

# SECURITY WARNING — Supply-chain risk:
# When no local install.sh is found, this script downloads and executes remote
# shell scripts via `curl | bash`. The scripts are fetched from a GitHub branch
# (a moving target) and are NOT integrity-verified. If GH_PROXY is set, traffic
# is routed through a third-party proxy, adding MITM risk. Only use trusted
# HTTPS proxies. HTTP proxies are rejected.
# TODO: A future --verify flag may add SHA256 checksum verification.

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            if [[ $# -lt 2 ]]; then
                echo "error: --config requires an argument" >&2
                exit 1
            fi
            CONFIG_FILE="$2"; shift 2 ;;
        --secrets)
            if [[ $# -lt 2 ]]; then
                echo "error: --secrets requires an argument" >&2
                exit 1
            fi
            SECRETS_FILE="$2"; shift 2 ;;
        --yes|-y)       NON_INTERACTIVE=1; shift ;;
        --gh-proxy)
            if [[ $# -lt 2 ]]; then
                echo "error: --gh-proxy requires an argument" >&2
                exit 1
            fi
            GH_PROXY="$2"; shift 2 ;;
        --help|-h)
            cat <<'HELP'
Usage: import-config.sh [OPTIONS] [CONFIG_FILE]

Import a rig configuration and reinstall components.

Arguments:
  CONFIG_FILE              Path to rig-config.json (positional or via --config)

Options:
  --config FILE            Path to rig-config.json
  --secrets FILE           Path to secrets.env (default: same dir as config)
  --yes, -y                Non-interactive mode (skip confirmation)
  --gh-proxy URL           GitHub proxy URL (must use https://)
  -h, --help               Show this help

Security:
  If no local install.sh is found, scripts are downloaded from GitHub via
  curl | bash. Scripts are fetched from a branch (not pinned) and are not
  integrity-verified. Only use trusted HTTPS proxies with --gh-proxy.

Examples:
  import-config.sh ~/.rig/rig-config.json
  import-config.sh --config config.json --secrets secrets.env
  import-config.sh --config config.json --yes
HELP
            exit 0
            ;;
        -*)
            printf "Unknown option: %s\n" "$1" >&2
            exit 1
            ;;
        *)
            # Positional argument: config file
            [[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="$1"
            shift
            ;;
    esac
done

# --- Colors ------------------------------------------------------------------

setup_colors() {
    if [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
        SYM_CHECK="${GREEN}✔${NC}"
    else
        RED='' GREEN='' CYAN=''
        BOLD='' DIM='' NC=''
        SYM_CHECK='[ok]'
    fi
}

setup_colors

# --- Validation --------------------------------------------------------------

if [[ -z "$CONFIG_FILE" ]]; then
    printf "${RED}error:${NC} No config file specified.\n" >&2
    printf "Usage: import-config.sh <rig-config.json>\n" >&2
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    printf "${RED}error:${NC} Config file not found: %s\n" "$CONFIG_FILE" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    install_cmd="sudo apt install jq"
    if is_macos; then
        install_cmd="brew install jq"
    elif [[ "${PKG_MANAGER:-apt}" == "dnf" ]]; then
        install_cmd="sudo dnf install jq"
    elif [[ "${PKG_MANAGER:-apt}" == "yum" ]]; then
        install_cmd="sudo yum install jq"
    elif [[ "${PKG_MANAGER:-apt}" == "pacman" ]]; then
        install_cmd="sudo pacman -S jq"
    fi
    printf "${RED}error:${NC} jq is required but not found. Install with: %s\n" "$install_cmd" >&2
    exit 1
fi

# Validate JSON structure
if ! jq -e '.components' "$CONFIG_FILE" &>/dev/null; then
    printf "${RED}error:${NC} Invalid config: missing 'components' field in %s\n" "$CONFIG_FILE" >&2
    exit 1
fi

# Validate components is an array
if ! jq -e '.components | type == "array"' "$CONFIG_FILE" &>/dev/null; then
    printf "${RED}error:${NC} Invalid config: 'components' must be an array in %s\n" "$CONFIG_FILE" >&2
    exit 1
fi

# Validate components array is not empty
comp_count=$(jq -r '.components | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
if [[ "$comp_count" -eq 0 ]]; then
    printf "${RED}error:${NC} Invalid config: 'components' array is empty in %s\n" "$CONFIG_FILE" >&2
    exit 1
fi

# Define supported component IDs (must match install.sh)
SUPPORTED_COMPONENTS=(
    "shell" "tmux" "git" "tools"
    "neovim" "node" "uv" "containers" "tailscale" "ssh" "security"
)

# Validate each component ID
while IFS= read -r comp; do
    [[ -z "$comp" ]] && continue
    comp_valid=0
    for supported in "${SUPPORTED_COMPONENTS[@]}"; do
        if [[ "$comp" == "$supported" ]]; then
            comp_valid=1
            break
        fi
    done
    if [[ $comp_valid -eq 0 ]]; then
        printf "${RED}error:${NC} Unknown component ID: '%s' in %s\n" "$comp" "$CONFIG_FILE" >&2
        printf "  Supported components: %s\n" "${SUPPORTED_COMPONENTS[*]}" >&2
        exit 1
    fi
done < <(jq -r '.components[]' "$CONFIG_FILE" 2>/dev/null)

# --- Auto-detect secrets.env ------------------------------------------------

if [[ -z "$SECRETS_FILE" ]]; then
    local_secrets="$(dirname "$CONFIG_FILE")/secrets.env"
    [[ -f "$local_secrets" ]] && SECRETS_FILE="$local_secrets"
fi

# --- Parse Config ------------------------------------------------------------

COMPONENTS=$(jq -r '.components[]' "$CONFIG_FILE" 2>/dev/null)
COMP_LIST=$(echo "$COMPONENTS" | paste -sd, -)

# Extract non-sensitive config
GIT_USER_NAME=$(jq -r '.config.git.user_name // empty' "$CONFIG_FILE" 2>/dev/null || true)
GIT_USER_EMAIL=$(jq -r '.config.git.user_email // empty' "$CONFIG_FILE" 2>/dev/null || true)

# Extract container & system & security baseline config
RIG_CONTAINER_ENGINE=$(jq -r '.config.containers.engine // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_CONTAINER_MODE=$(jq -r '.config.containers.mode // .config.system.container_mode // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_PROFILE=$(jq -r '.config.system.profile // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_FIREWALL=$(jq -r '.config.system.firewall // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_FIREWALL_DEFAULT_IN=$(jq -r '.config.system.firewall_default_in // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_FIREWALL_DEFAULT_OUT=$(jq -r '.config.system.firewall_default_out // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_PUBLIC_TCP=$(jq -r '.config.system.public_tcp // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_PUBLIC_UDP=$(jq -r '.config.system.public_udp // empty' "$CONFIG_FILE" 2>/dev/null || true)
HAS_RIG_PUBLIC_TCP=$(jq -r 'if .config.system | has("public_tcp") then 1 else 0 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
HAS_RIG_PUBLIC_UDP=$(jq -r 'if .config.system | has("public_udp") then 1 else 0 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
RIG_SSH_PORT=$(jq -r '.config.system.ssh_port // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_SSH_ROOT_LOGIN=$(jq -r '.config.system.ssh_root_login // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_SSH_PASSWORD_AUTH=$(jq -r '.config.system.ssh_password_auth // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_SSH_PUBKEY_AUTH=$(jq -r '.config.system.ssh_pubkey_auth // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_SSH_ACCESS=$(jq -r '.config.system.ssh_access // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_ADMIN_USER=$(jq -r '.config.system.admin_user // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_CHECK_LISTENING_PORTS=$(jq -r '.config.system.check_listening_ports // empty' "$CONFIG_FILE" 2>/dev/null || true)
RIG_WARN_UNDECLARED_PORTS=$(jq -r '.config.system.warn_undeclared_ports // empty' "$CONFIG_FILE" 2>/dev/null || true)

# --- Load Secrets ------------------------------------------------------------

TAILSCALE_AUTH_KEY=""

if [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]]; then
    # Source secrets safely — only known variable names
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Trim whitespace
        key=$(echo "$key" | tr -d '[:space:]')
        case "$key" in
            TAILSCALE_AUTH_KEY) TAILSCALE_AUTH_KEY="$value" ;;
        esac
    done < "$SECRETS_FILE"
fi

# --- Show Plan ---------------------------------------------------------------

printf "\n"
printf "  ${CYAN}${BOLD}┌──────────────────────────────────────────┐${NC}\n"
printf "  ${CYAN}${BOLD}│${NC}  ${BOLD}${CYAN}Rig Config Import${NC}                        ${CYAN}${BOLD}│${NC}\n"
printf "  ${CYAN}${BOLD}└──────────────────────────────────────────┘${NC}\n"
printf "\n"

printf "  ${BOLD}Config:${NC}  %s\n" "$CONFIG_FILE"
if [[ -n "$SECRETS_FILE" ]]; then
    printf "  ${BOLD}Secrets:${NC} %s\n" "$SECRETS_FILE"
else
    printf "  ${BOLD}Secrets:${NC} ${DIM}none${NC}\n"
fi
printf "\n"

printf "  ${BOLD}Components to install:${NC}\n"
while IFS= read -r comp; do
    [[ -z "$comp" ]] && continue
    printf "    ${CYAN}•${NC} %s\n" "$comp"
done <<< "$COMPONENTS"
printf "\n"

# Show detected API keys (masked)
has_secrets=0
if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
    printf "  ${BOLD}Tailscale:${NC}   auth key ${GREEN}detected${NC}\n"
    has_secrets=1
fi
if [[ $has_secrets -eq 0 && -n "$SECRETS_FILE" ]]; then
    printf "  ${DIM}No API keys found in secrets file.${NC}\n"
fi
printf "\n"

# --- Confirm -----------------------------------------------------------------

if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
    if [[ -e /dev/tty ]]; then
        printf "  ${BOLD}Proceed with import?${NC} ${DIM}[Y/n]${NC} "
        read -r confirm </dev/tty
        if [[ "$confirm" =~ ^[Nn] ]]; then
            printf "\n  ${DIM}Aborted.${NC}\n\n"
            exit 0
        fi
    else
        printf "${RED}error:${NC} No terminal available. Use --yes for non-interactive mode.\n" >&2
        exit 1
    fi
    printf "\n"
fi

# --- Persist Rig Config ------------------------------------------------------

# Persist before changing unrelated user state. This also makes imported
# values available to future `rig` commands, not only this installer process.
if [[ -f "$SCRIPT_DIR/lib/rig-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/rig-config.sh"
    rig_config_set RIG_COMPONENTS "$COMP_LIST"
    [[ -n "$RIG_PROFILE" ]] && rig_config_set RIG_PROFILE "$RIG_PROFILE"
    [[ -n "$RIG_CONTAINER_ENGINE" ]] && rig_config_set RIG_CONTAINER_ENGINE "$RIG_CONTAINER_ENGINE"
    [[ -n "$RIG_CONTAINER_MODE" ]] && rig_config_set RIG_CONTAINER_MODE "$RIG_CONTAINER_MODE"
    [[ -n "$RIG_FIREWALL" ]] && rig_config_set RIG_FIREWALL "$RIG_FIREWALL"
    [[ -n "$RIG_FIREWALL_DEFAULT_IN" ]] && rig_config_set RIG_FIREWALL_DEFAULT_IN "$RIG_FIREWALL_DEFAULT_IN"
    [[ -n "$RIG_FIREWALL_DEFAULT_OUT" ]] && rig_config_set RIG_FIREWALL_DEFAULT_OUT "$RIG_FIREWALL_DEFAULT_OUT"
    [[ "$HAS_RIG_PUBLIC_TCP" -eq 1 ]] && rig_config_set RIG_PUBLIC_TCP "$RIG_PUBLIC_TCP"
    [[ "$HAS_RIG_PUBLIC_UDP" -eq 1 ]] && rig_config_set RIG_PUBLIC_UDP "$RIG_PUBLIC_UDP"
    [[ -n "$RIG_SSH_PORT" ]] && rig_config_set RIG_SSH_PORT "$RIG_SSH_PORT"
    [[ -n "$RIG_SSH_ROOT_LOGIN" ]] && rig_config_set RIG_SSH_ROOT_LOGIN "$RIG_SSH_ROOT_LOGIN"
    [[ -n "$RIG_SSH_PASSWORD_AUTH" ]] && rig_config_set RIG_SSH_PASSWORD_AUTH "$RIG_SSH_PASSWORD_AUTH"
    [[ -n "$RIG_SSH_PUBKEY_AUTH" ]] && rig_config_set RIG_SSH_PUBKEY_AUTH "$RIG_SSH_PUBKEY_AUTH"
    [[ -n "$RIG_SSH_ACCESS" ]] && rig_config_set RIG_SSH_ACCESS "$RIG_SSH_ACCESS"
    [[ -n "$RIG_ADMIN_USER" ]] && rig_config_set RIG_ADMIN_USER "$RIG_ADMIN_USER"
    [[ -n "$RIG_CHECK_LISTENING_PORTS" ]] && rig_config_set RIG_CHECK_LISTENING_PORTS "$RIG_CHECK_LISTENING_PORTS"
    [[ -n "$RIG_WARN_UNDECLARED_PORTS" ]] && rig_config_set RIG_WARN_UNDECLARED_PORTS "$RIG_WARN_UNDECLARED_PORTS"
fi

# --- Apply Git Config --------------------------------------------------------

if [[ -n "$GIT_USER_NAME" || -n "$GIT_USER_EMAIL" ]]; then
    printf "  ${DIM}Applying git config...${NC}\n"
    [[ -n "$GIT_USER_NAME" ]]  && git config --global user.name "$GIT_USER_NAME"
    [[ -n "$GIT_USER_EMAIL" ]] && git config --global user.email "$GIT_USER_EMAIL"
    printf "  ${SYM_CHECK} ${GREEN}Git config applied${NC}\n\n"
fi

# --- Run Install -------------------------------------------------------------

printf "  ${DIM}Running install.sh --components %s ...${NC}\n\n" "$COMP_LIST"

# Validate GH_PROXY before building URL
if [[ -n "$GH_PROXY" ]] && [[ "$GH_PROXY" != https://* ]]; then
    printf "${RED}error:${NC} GH_PROXY must use https:// (got: %s). HTTP proxies are rejected to prevent MITM attacks.\n" "$GH_PROXY" >&2
    exit 1
fi

# Build install.sh URL
_RAW="raw.githubusercontent.com"
REPO="DieRingedesSaturn/rig"
BRANCH="master"
BASE_URL="https://${_RAW}/${REPO}/${BRANCH}"

install_url="${BASE_URL}/install.sh"
if [[ -n "$GH_PROXY" ]]; then
    install_url="${GH_PROXY%/}/${BASE_URL}/install.sh"
fi

# Export env vars for install.sh
export GH_PROXY
export TAILSCALE_AUTH_KEY
[[ -n "$RIG_PROFILE" ]] && export RIG_PROFILE
[[ -n "$RIG_CONTAINER_ENGINE" ]] && export RIG_CONTAINER_ENGINE
[[ -n "$RIG_CONTAINER_MODE" ]] && export RIG_CONTAINER_MODE
[[ -n "$RIG_FIREWALL" ]] && export RIG_FIREWALL
[[ -n "$RIG_FIREWALL_DEFAULT_IN" ]] && export RIG_FIREWALL_DEFAULT_IN
[[ -n "$RIG_FIREWALL_DEFAULT_OUT" ]] && export RIG_FIREWALL_DEFAULT_OUT
[[ "$HAS_RIG_PUBLIC_TCP" -eq 1 ]] && export RIG_PUBLIC_TCP
[[ "$HAS_RIG_PUBLIC_UDP" -eq 1 ]] && export RIG_PUBLIC_UDP
[[ -n "$RIG_SSH_PORT" ]] && export RIG_SSH_PORT
[[ -n "$RIG_SSH_ROOT_LOGIN" ]] && export RIG_SSH_ROOT_LOGIN
[[ -n "$RIG_SSH_PASSWORD_AUTH" ]] && export RIG_SSH_PASSWORD_AUTH
[[ -n "$RIG_SSH_PUBKEY_AUTH" ]] && export RIG_SSH_PUBKEY_AUTH
[[ -n "$RIG_SSH_ACCESS" ]] && export RIG_SSH_ACCESS
[[ -n "$RIG_ADMIN_USER" ]] && export RIG_ADMIN_USER
[[ -n "$RIG_CHECK_LISTENING_PORTS" ]] && export RIG_CHECK_LISTENING_PORTS
[[ -n "$RIG_WARN_UNDECLARED_PORTS" ]] && export RIG_WARN_UNDECLARED_PORTS

# If running from local repo, use local install.sh
if [[ -f "$SCRIPT_DIR/install.sh" ]]; then
    exec bash "$SCRIPT_DIR/install.sh" --components "$COMP_LIST"
else
    exec bash <(curl -fsSL "$install_url") --components "$COMP_LIST"
fi
