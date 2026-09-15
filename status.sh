#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Rig Status — detect and report installation state of all components
#
# Usage:
#   bash status.sh          # Full status table
#   bash status.sh --json   # Machine-readable JSON output
#   bash status.sh --short  # One-line summary
# =============================================================================

# --- Load OS detection libraries ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"
# shellcheck source=lib/rig-config.sh
source "$SCRIPT_DIR/lib/rig-config.sh"
# shellcheck source=lib/containers.sh
source "$SCRIPT_DIR/lib/containers.sh"
# shellcheck source=lib/tools.sh
source "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=lib/firewall.sh
source "$SCRIPT_DIR/lib/firewall.sh"
# shellcheck source=lib/security.sh
source "$SCRIPT_DIR/lib/security.sh"

# A status report must never pop a sudo password prompt; degraded "unknown"
# values are preferable to an interactive prompt from a read-only command.
export RIG_NO_SUDO_PROMPT=1
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

# --- Options -----------------------------------------------------------------

OUTPUT_FORMAT="table"
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)               OUTPUT_FORMAT="json"; shift ;;
        --short)              OUTPUT_FORMAT="short"; shift ;;
        --security|security)  OUTPUT_FORMAT="security"; shift ;;
        --doctor|doctor)      OUTPUT_FORMAT="doctor"; shift ;;
        --help|-h)
            echo "Usage: status.sh [--json|--short|--security|--doctor|--help]"
            echo "  --json       Machine-readable JSON output"
            echo "  --short      One-line summary"
            echo "  --security   Security baseline & listening ports audit"
            echo "  --doctor     Full health and security diagnostic report"
            exit 0
            ;;
        *) shift ;;
    esac
done

# --- Colors & Symbols --------------------------------------------------------

setup_colors() {
    if [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        CYAN='\033[0;36m'
        WHITE='\033[1;37m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
    else
        RED='' GREEN='' YELLOW='' CYAN='' WHITE=''
        BOLD='' DIM='' NC=''
    fi
}

setup_colors

# Status symbols
sym_installed="${GREEN}✔${NC}"
sym_partial="${YELLOW}◐${NC}"
sym_missing="${RED}✘${NC}"

# --- Helper Functions --------------------------------------------------------

# Resolve a command, checking common PATH additions
resolve_cmd() {
    local cmd="$1"
    command -v "$cmd" 2>/dev/null && return 0
    # Check common non-default paths
    local extra_paths=(
        "$HOME/.local/bin"
        "$HOME/.nvm/versions/node"/*/bin
        "/usr/local/bin"
        "$HOME/.cargo/bin"
    )
    for p in "${extra_paths[@]}"; do
        [[ -x "$p/$cmd" ]] && echo "$p/$cmd" && return 0
    done
    return 1
}

# Get version from a command, return "N/A" on failure
get_version() {
    local output
    output=$("$@" 2>/dev/null) && echo "$output" | head -1 || echo "N/A"
}

# JSON-escape a string value
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# --- Detection Functions -----------------------------------------------------
# Each function prints: status|version|config_status
#   status:        installed / partial / not_installed
#   version:       version string or "N/A"
#   config_status: configured / install-only / not-configured

detect_shell() {
    local status="not_installed" version="N/A" config="not-configured"

    local zsh_path
    if zsh_path=$(resolve_cmd zsh); then
        version=$("$zsh_path" --version 2>/dev/null | head -1 | sed 's/zsh //' | awk '{print $1}' || echo "N/A")
        status="installed"
        config="install-only"

        # zsh as the login shell
        local current_shell
        current_shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "$SHELL")
        local is_default=0
        [[ "$current_shell" == *zsh* ]] && is_default=1

        # Starship
        local has_starship=0
        resolve_cmd starship >/dev/null && has_starship=1

        # This component never edits ~/.zshrc, so "configured" means the rc file
        # actually loads what we installed. Comment lines are ignored so a
        # commented-out entry is not mistaken for an active one.
        local zshrc="$HOME/.zshrc"
        local rc_ok=1
        if [[ -f "$zshrc" ]]; then
            local pattern
            for pattern in 'zsh-autosuggestions' 'zsh-syntax-highlighting' 'starship init'; do
                grep -n "$pattern" "$zshrc" 2>/dev/null | grep -qv ':[[:space:]]*#' || rc_ok=0
            done
        else
            rc_ok=0
        fi

        if [[ $is_default -eq 1 && $has_starship -eq 1 && $rc_ok -eq 1 ]]; then
            config="configured"
        elif [[ $has_starship -eq 1 || $rc_ok -eq 1 ]]; then
            status="partial"
            config="install-only"
        fi
    fi

    echo "${status}|${version}|${config}"
}

detect_tmux() {
    local status="not_installed" version="N/A" config="not-configured"

    local tmux_path
    if tmux_path=$(resolve_cmd tmux); then
        version=$("$tmux_path" -V 2>/dev/null | head -1 | sed 's/tmux //' || echo "N/A")
        status="installed"
        config="install-only"

        # This component installs no plugins; "configured" means a config file
        # exists and carries the settings the generated template provides.
        local conf="" candidate
        for candidate in "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" "$HOME/.tmux.conf"; do
            if [[ -f "$candidate" ]]; then
                conf="$candidate"
                break
            fi
        done

        if [[ -n "$conf" ]]; then
            # Comment lines are ignored so a commented-out entry is not counted.
            local rc_lines wanted missing=0
            for wanted in 'extended-keys' 'mouse' 'history-limit'; do
                rc_lines="$(grep -n "$wanted" "$conf" 2>/dev/null | grep -v ':[[:space:]]*#' || true)"
                [[ -n "$rc_lines" ]] || missing=1
            done
            if [[ $missing -eq 0 ]]; then
                config="configured"
            else
                status="partial"
            fi
        fi
    fi

    echo "${status}|${version}|${config}"
}

detect_git() {
    local status="not_installed" version="N/A" config="not-configured"

    local git_path
    if git_path=$(resolve_cmd git); then
        version=$("$git_path" --version 2>/dev/null | head -1 | sed 's/git version //' || echo "N/A")
        status="installed"
        config="install-only"

        local has_name has_email
        has_name=$(git config --global user.name 2>/dev/null || true)
        has_email=$(git config --global user.email 2>/dev/null || true)

        if [[ -n "$has_name" && -n "$has_email" ]]; then
            config="configured"
        elif [[ -n "$has_name" || -n "$has_email" ]]; then
            status="partial"
            config="install-only"
        fi
    fi

    echo "${status}|${version}|${config}"
}

detect_tools() {
    local status="not_installed" version="N/A" config="not-configured"

    # Essential tools installed by setup-tools.sh.
    # The clipboard helper is session-dependent, so only the applicable one is
    # expected — expecting xclip on a Wayland box would report a permanent
    # false gap on a correctly provisioned machine.
    local tools=(rg jq fd bat tree shellcheck gh wget unzip fastfetch)
    local clipboard_tool
    clipboard_tool="$(tools_clipboard_tool)"
    [[ -n "$clipboard_tool" ]] && tools+=("$clipboard_tool")
    local found=0
    local total=${#tools[@]}
    local missing_tools=()

    for tool in "${tools[@]}"; do
        # Handle Debian renames: fd-find→fdfind, bat→batcat
        if resolve_cmd "$tool" >/dev/null 2>&1; then
            found=$((found + 1))
        elif is_debian && [[ "$tool" == "fd" ]] && resolve_cmd fdfind >/dev/null 2>&1; then
            found=$((found + 1))
        elif is_debian && [[ "$tool" == "bat" ]] && resolve_cmd batcat >/dev/null 2>&1; then
            found=$((found + 1))
        else
            missing_tools+=("$tool")
        fi
    done

    if [[ $found -eq $total ]]; then
        status="installed"
        config="configured"
        version="${found}/${total} tools"
    elif [[ $found -gt 0 ]]; then
        status="partial"
        config="install-only"
        version="${found}/${total} tools"
    else
        version="0/${total} tools"
    fi

    echo "${status}|${version}|${config}"
}

detect_node() {
    local status="not_installed" version="N/A" config="not-configured"

    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"

    # System Node first, because loading nvm.sh puts the nvm version in front of
    # it on PATH. A distro package with the same major version as the nvm one is
    # exactly the case that goes unnoticed, and a machine can have both.
    local system_node="" system_version=""
    local candidate
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        case "$candidate" in
            "$nvm_dir"/*) continue ;;
        esac
        system_node="$candidate"
        break
    done < <(type -a -p node 2>/dev/null || true)

    if [[ -n "$system_node" ]]; then
        system_version="$("$system_node" --version 2>/dev/null | sed 's/^v//' || true)"
    fi

    # nvm-managed version, if nvm has one active.
    local has_nvm=0 nvm_version=""
    if [[ -f "$nvm_dir/nvm.sh" ]]; then
        has_nvm=1
        export NVM_DIR="$nvm_dir"
        # shellcheck disable=SC1091
        . "$nvm_dir/nvm.sh" >/dev/null 2>&1 || true
        local current
        current="$(nvm current 2>/dev/null || true)"
        case "$current" in
            ''|none|system) ;;
            *) nvm_version="${current#v}" ;;
        esac
    fi

    # Report both when both exist — "two Node 24s" is worth seeing.
    if [[ -n "$nvm_version" && -n "$system_version" ]]; then
        version="${nvm_version} + system ${system_version}"
    elif [[ -n "$nvm_version" ]]; then
        version="${nvm_version}"
    elif [[ -n "$system_version" ]]; then
        version="${system_version} (system)"
    fi

    if [[ $has_nvm -eq 1 && -n "$nvm_version" ]]; then
        status="installed"
        config="configured"
    elif [[ $has_nvm -eq 1 || -n "$system_version" ]]; then
        # nvm present without an active version, or only a distro Node: usable,
        # but not the nvm-managed setup this component provides.
        status="partial"
        config="install-only"
        if [[ "$version" == "N/A" ]]; then
            version="nvm only"
        fi
    fi

    echo "${status}|${version}|${config}"
}

detect_uv() {
    local status="not_installed" version="N/A" config="not-configured"

    # Add common uv location to search
    export PATH="$HOME/.local/bin:$PATH"

    local uv_path
    if uv_path=$(resolve_cmd uv); then
        version=$("$uv_path" --version 2>/dev/null | head -1 | sed 's/^uv //' || echo "N/A")
        status="installed"
        config="configured"
    fi

    echo "${status}|${version}|${config}"
}

detect_podman() {
    local status="not_installed" version="N/A" config="not-configured"

    local podman_path
    if podman_path=$(resolve_cmd podman); then
        local ver rootless
        ver=$("$podman_path" --version 2>/dev/null | awk '{print $3}' || true)
        version="Podman ${ver:-?}"

        # Podman reports its own privilege state, so this is authoritative
        # rather than inferred from group membership.
        rootless=$("$podman_path" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)
        case "$rootless" in
            true)
                version="${version} (rootless)"
                status="installed"
                config="configured"
                ;;
            false)
                version="${version} (rootful)"
                status="installed"
                config="configured"
                ;;
            *)
                # Binary present but `podman info` failed — usually a broken
                # subuid/subgid allocation.
                status="partial"
                config="install-only"
                ;;
        esac
    fi

    echo "${status}|${version}|${config}"
}

detect_docker() {
    local status="not_installed" version="N/A" config="not-configured"

    local docker_path
    if docker_path=$(resolve_cmd docker); then
        local ver
        ver=$("$docker_path" version --format '{{.Client.Version}}' 2>/dev/null || true)
        version="Docker ${ver:-?}"
        status="installed"

        if "$docker_path" info 2>/dev/null | grep -qi rootless; then
            version="${version} (rootless)"
            config="configured"
        elif "$docker_path" info >/dev/null 2>&1; then
            version="${version} (rootful)"
            config="configured"
        else
            # Client is here but nothing answers on the socket.
            status="partial"
            config="daemon-unavailable"
        fi
    fi

    echo "${status}|${version}|${config}"
}

# Containers is one component with two interchangeable backends, so exactly one
# of them is reported — whichever the configuration selects. Showing both would
# mean a permanent red mark for the one you deliberately did not install.
detect_containers() {
    case "$(containers_engine)" in
        podman) detect_podman ;;
        docker) detect_docker ;;
        *)      echo "not_installed|N/A|not-configured" ;;
    esac
}

detect_tailscale() {
    local status="not_installed" version="N/A" config="not-configured"

    local tailscale_path
    if tailscale_path=$(resolve_cmd tailscale); then
        version=$("$tailscale_path" version 2>/dev/null | head -1 || echo "N/A")
        status="installed"
        config="install-only"

        # Check if connected to a tailnet. `tailscale status --json` pretty-
        # prints with a space after the colon, so a tight `"BackendState":"`
        # match never fires; jq first, space-tolerant grep as fallback.
        local ts_status
        ts_status=$(tailscale status --json 2>/dev/null || echo "{}")
        local backend_state
        if command -v jq >/dev/null 2>&1; then
            backend_state=$(printf '%s' "$ts_status" | jq -r '.BackendState // ""' 2>/dev/null || true)
        else
            backend_state=$(printf '%s' "$ts_status" | grep -o '"BackendState": *"[^"]*"' 2>/dev/null | cut -d'"' -f4 || true)
        fi

        if [[ "$backend_state" == "Running" ]]; then
            config="configured"
        elif [[ "$backend_state" == "NeedsLogin" || "$backend_state" == "Stopped" ]]; then
            status="partial"
        fi
    fi

    echo "${status}|${version}|${config}"
}

detect_ssh() {
    local status="not_installed" version="N/A" config="not-configured"

    # The component manages the OpenSSH *server*: an ssh client alone does not
    # count. sshd usually lives in /usr/sbin, outside a minimal PATH.
    local sshd_found=0
    if is_macos; then
        sshd_found=1
    elif resolve_cmd sshd >/dev/null 2>&1 \
        || [[ -x /usr/sbin/sshd || -x /usr/libexec/sshd || -x /usr/lib/ssh/sshd ]]; then
        sshd_found=1
    fi

    if [[ $sshd_found -eq 1 ]]; then
        # Version comes from the client binary — same OpenSSH package family.
        local ssh_path
        if ssh_path=$(resolve_cmd ssh); then
            version=$("$ssh_path" -V 2>&1 | head -1 | sed 's/,.*//' | sed 's/OpenSSH_//' || echo "N/A")
        fi
        status="installed"
        config="install-only"

        # Check for SSH keys
        local has_keys=0
        for keyfile in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
            [[ -f "$keyfile" ]] && has_keys=1 && break
        done

        # Check authorized_keys
        local has_authkeys=0
        [[ -f "$HOME/.ssh/authorized_keys" && -s "$HOME/.ssh/authorized_keys" ]] && has_authkeys=1

        # Check if sshd is running (platform-specific)
        local sshd_running=0
        if is_macos; then
            # On macOS, check Remote Login via System Preferences (launchd).
            # sudo -n: a read-only status report must never prompt.
            if sudo -n launchctl list 2>/dev/null | grep -q "com.openssh.sshd" 2>/dev/null; then
                sshd_running=1
            fi
        else
            # On Linux, check for sshd process
            pgrep -x sshd &>/dev/null && sshd_running=1
        fi

        # This component manages the sshd *server*: "configured" means sshd is
        # running and at least one key path exists — authorized_keys alone is a
        # fully valid server setup; a local private key is not required.
        if [[ $sshd_running -eq 1 && ( $has_keys -eq 1 || $has_authkeys -eq 1 ) ]]; then
            config="configured"
        elif [[ $has_keys -eq 1 || $has_authkeys -eq 1 || $sshd_running -eq 1 ]]; then
            status="partial"
            config="install-only"
        fi
    fi

    echo "${status}|${version}|${config}"
}

detect_security() {
    local status="not_installed"
    local version="N/A"
    local config="not-configured"

    local fw_backend fw_active=0
    fw_backend="$(firewall_detect_backend auto)"
    if [[ "$fw_backend" != "none" ]] && firewall_is_active "$fw_backend"; then
        fw_active=1
    fi

    local root_login pw_auth
    root_login="$(security_get_sshd_param PermitRootLogin "unknown")"
    pw_auth="$(security_get_sshd_param PasswordAuthentication "unknown")"

    # "Configured" means a hardening policy was applied, not the strictest
    # possible one: firewall up plus at least one of root-login or password
    # auth disabled is an applied baseline. Fully permissive SSH with an
    # active firewall still reports partial.
    if [[ $fw_active -eq 1 && ( "$root_login" == "no" || "$pw_auth" == "no" ) ]]; then
        status="installed"
        config="configured"
        if [[ "$root_login" == "no" && "$pw_auth" == "no" ]]; then
            version="${fw_backend} + key-only"
        else
            version="${fw_backend} + hardened"
        fi
    elif [[ $fw_active -eq 1 || "$root_login" == "no" || "$pw_auth" == "no" ]]; then
        status="partial"
        config="install-only"
        version="${fw_backend:-audit}"
    fi

    echo "${status}|${version}|${config}"
}

detect_neovim() {
    local status="not_installed" version="N/A" config="not-configured"

    local nvim_path
    if nvim_path=$(resolve_cmd nvim); then
        status="installed"
        version=$("$nvim_path" --version 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "installed")
        if [[ -f "$HOME/.config/nvim/init.lua" ]]; then
            config="configured"
        else
            config="install-only"
            status="partial"
        fi
    fi

    echo "${status}|${version}|${config}"
}

# --- Output Formatters -------------------------------------------------------

# Component registry (parallel to install.sh)
COMP_IDS=(shell tmux git tools neovim node uv containers tailscale ssh security)
COMP_NAMES=(
    "Shell Environment"
    "Tmux"
    "Git"
    "Essential Tools"
    "Neovim"
    "Node.js (nvm)"
    "uv + Python"
    "Containers"
    "Tailscale"
    "SSH"
    "Security Baseline"
)
COMP_DETECT=(
    detect_shell
    detect_tmux
    detect_git
    detect_tools
    detect_neovim
    detect_node
    detect_uv
    detect_containers
    detect_tailscale
    detect_ssh
    detect_security
)

# Run all detections and store results
declare -a RESULTS=()
run_detections() {
    for detect_fn in "${COMP_DETECT[@]}"; do
        RESULTS+=("$($detect_fn)")
    done
}

print_table() {
    local total=${#COMP_IDS[@]}
    local installed=0
    local partial=0
    local missing=0

    printf "\n"
    printf "  ${CYAN}${BOLD}┌──────────────────────────────────────────────────────────────────┐${NC}\n"
    printf "  ${CYAN}${BOLD}│${NC}  ${BOLD}${WHITE}Rig Status${NC}                                                      ${CYAN}${BOLD}│${NC}\n"
    printf "  ${CYAN}${BOLD}└──────────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"

    # Header
    printf "  ${DIM}%-4s %-24s %-24s %-16s${NC}\\n" "" "Component" "Version" "Config"
    printf "  ${DIM}──── ──────────────────────── ──────────────────────── ────────────────${NC}\\n"

    for i in $(seq 0 $((total - 1))); do
        local result="${RESULTS[$i]}"
        local comp_status comp_version comp_config
        IFS='|' read -r comp_status comp_version comp_config <<< "$result"

        # Pick symbol
        local sym
        case "$comp_status" in
            installed)     sym="$sym_installed"; installed=$((installed + 1)) ;;
            partial)       sym="$sym_partial";   partial=$((partial + 1)) ;;
            not_installed) sym="$sym_missing";   missing=$((missing + 1)) ;;
            *)             sym="$sym_missing";   missing=$((missing + 1)) ;;
        esac

        # Pad plain text first, then wrap with colors (ANSI escapes break printf width)
        local ver_padded config_padded
        printf -v ver_padded "%-24s" "$comp_version"
        printf -v config_padded "%-16s" "$comp_config"

        # Apply color to the padded strings
        if [[ "$comp_version" == "N/A" ]]; then
            ver_padded="${DIM}${ver_padded}${NC}"
        else
            ver_padded="${WHITE}${ver_padded}${NC}"
        fi
        case "$comp_config" in
            configured)     config_padded="${GREEN}${config_padded}${NC}" ;;
            install-only)   config_padded="${YELLOW}${config_padded}${NC}" ;;
            not-configured) config_padded="${DIM}${config_padded}${NC}" ;;
            *)              config_padded="${DIM}${config_padded}${NC}" ;;
        esac

        printf "  %b     %-24s %b %b\n" "$sym" "${COMP_NAMES[$i]}" "$ver_padded" "$config_padded"
    done

    # Summary
    printf "\n"
    printf "  ${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "  ${GREEN}${BOLD}%d${NC}${DIM} installed${NC}" "$installed"
    [[ $partial -gt 0 ]] && printf "  ${YELLOW}${BOLD}%d${NC}${DIM} partial${NC}" "$partial"
    [[ $missing -gt 0 ]] && printf "  ${RED}${BOLD}%d${NC}${DIM} missing${NC}" "$missing"
    printf "\n\n"
}

print_json() {
    local total=${#COMP_IDS[@]}

    printf '{\n  "components": [\n'
    for i in $(seq 0 $((total - 1))); do
        local result="${RESULTS[$i]}"
        local comp_status comp_version comp_config
        IFS='|' read -r comp_status comp_version comp_config <<< "$result"

        printf '    {\n'
        printf '      "id": "%s",\n' "$(json_escape "${COMP_IDS[$i]}")"
        printf '      "name": "%s",\n' "$(json_escape "${COMP_NAMES[$i]}")"
        printf '      "status": "%s",\n' "$(json_escape "$comp_status")"
        printf '      "version": "%s",\n' "$(json_escape "$comp_version")"
        printf '      "config": "%s"\n' "$(json_escape "$comp_config")"
        if [[ $i -lt $((total - 1)) ]]; then
            printf '    },\n'
        else
            printf '    }\n'
        fi
    done

    # Summary counts
    local installed=0 partial_count=0 missing=0
    for result in "${RESULTS[@]}"; do
        local s
        s=$(echo "$result" | cut -d'|' -f1)
        case "$s" in
            installed)     installed=$((installed + 1)) ;;
            partial)       partial_count=$((partial_count + 1)) ;;
            not_installed) missing=$((missing + 1)) ;;
        esac
    done

    printf '  ],\n'
    printf '  "summary": {\n'
    printf '    "installed": %d,\n' "$installed"
    printf '    "partial": %d,\n' "$partial_count"
    printf '    "missing": %d,\n' "$missing"
    printf '    "total": %d\n' "$total"
    printf '  }\n'
    printf '}\n'
}

print_short() {
    local installed=0 partial_count=0 missing=0

    for result in "${RESULTS[@]}"; do
        local s
        s=$(echo "$result" | cut -d'|' -f1)
        case "$s" in
            installed)     installed=$((installed + 1)) ;;
            partial)       partial_count=$((partial_count + 1)) ;;
            not_installed) missing=$((missing + 1)) ;;
        esac
    done

    local total=${#COMP_IDS[@]}
    printf "rig: %d/%d installed" "$installed" "$total"
    [[ $partial_count -gt 0 ]] && printf ", %d partial" "$partial_count"
    [[ $missing -gt 0 ]] && printf ", %d missing" "$missing"
    printf "\n"
}

print_security_report() {
    setup_colors
    local fw_backend fw_active=0
    fw_backend="$(firewall_detect_backend auto)"
    if [[ "$fw_backend" != "none" ]] && firewall_is_active "$fw_backend"; then
        fw_active=1
    fi

    local root_login pw_auth pubkey_auth
    root_login="$(security_get_sshd_param PermitRootLogin "unknown")"
    pw_auth="$(security_get_sshd_param PasswordAuthentication "unknown")"
    pubkey_auth="$(security_get_sshd_param PubkeyAuthentication "unknown")"

    local admin_user
    admin_user="$(rig_config_get RIG_ADMIN_USER "${SUDO_USER:-$(whoami)}")"

    printf "\n  ${BOLD}${WHITE}Security Baseline${NC}\n"
    printf "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"

    # Admin user
    if security_verify_admin_user "$admin_user"; then
        printf "  ${GREEN}✔${NC} %-22s %s\n" "Admin user" "$admin_user (sudo active)"
    else
        printf "  ${YELLOW}⚠${NC} %-22s %s\n" "Admin user" "$admin_user (unverified or lacks key)"
    fi

    # SSH root login
    if [[ "$root_login" == "no" ]]; then
        printf "  ${GREEN}✔${NC} %-22s %s\n" "SSH root login" "disabled (PermitRootLogin no)"
    else
        printf "  ${YELLOW}⚠${NC} %-22s %s\n" "SSH root login" "enabled ($root_login)"
    fi

    # SSH password auth
    if [[ "$pw_auth" == "no" ]]; then
        printf "  ${GREEN}✔${NC} %-22s %s\n" "SSH password auth" "disabled"
    else
        printf "  ${YELLOW}⚠${NC} %-22s %s\n" "SSH password auth" "enabled ($pw_auth)"
    fi

    # SSH public key
    if [[ "$pubkey_auth" == "yes" || "$pubkey_auth" == "unknown" ]]; then
        printf "  ${GREEN}✔${NC} %-22s %s\n" "SSH public key" "enabled"
    else
        printf "  ${RED}✘${NC} %-22s %s\n" "SSH public key" "disabled"
    fi

    # Firewall
    if [[ $fw_active -eq 1 ]]; then
        printf "  ${GREEN}✔${NC} %-22s %s\n" "Firewall" "$fw_backend (active)"
        printf "  ${GREEN}✔${NC} %-22s %s\n" "Allowed rules" "$(firewall_list_allowed "$fw_backend")"
    else
        printf "  ${RED}✘${NC} %-22s %s\n" "Firewall" "inactive / not running"
    fi

    # Tailscale
    if command -v tailscale >/dev/null 2>&1; then
        local ts_ip
        ts_ip="$(tailscale ip -4 2>/dev/null || echo "inactive")"
        if [[ "$ts_ip" != "inactive" ]]; then
            printf "  ${GREEN}✔${NC} %-22s %s\n" "Tailscale" "active ($ts_ip)"
        else
            printf "  ${DIM}○${NC} %-22s %s\n" "Tailscale" "installed (not connected)"
        fi
    fi

    printf "\n  ${BOLD}${WHITE}Listening Ports Audit${NC}\n"
    printf "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"
    local tcp_allow udp_allow warn_undeclared ssh_access ssh_port
    ssh_port="$(rig_config_get RIG_SSH_PORT "22")"
    tcp_allow="$(rig_config_get RIG_PUBLIC_TCP "$ssh_port")"
    udp_allow="$(rig_config_get RIG_PUBLIC_UDP "")"
    warn_undeclared="$(rig_config_get RIG_WARN_UNDECLARED_PORTS "yes")"
    ssh_access="$(rig_config_get RIG_SSH_ACCESS "public")"
    security_audit_listening_ports "$tcp_allow" "$udp_allow" "$warn_undeclared" "$ssh_access" "$ssh_port"
    printf "\n"
}

# --- Main --------------------------------------------------------------------

main() {
    case "$OUTPUT_FORMAT" in
        security)
            print_security_report
            ;;
        doctor)
            run_detections
            print_table
            print_security_report
            ;;
        json)
            run_detections
            print_json
            ;;
        short)
            run_detections
            print_short
            ;;
        table)
            run_detections
            print_table
            ;;
    esac
}

main
