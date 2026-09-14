#!/usr/bin/env bash
set -euo pipefail

# Source library dependencies for multi-OS support
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

# =============================================================================
# Rig Component Uninstaller
# https://github.com/DieRingedesSaturn/rig
#
# Usage:
#   bash uninstall.sh docker                     # Uninstall single component
#   bash uninstall.sh node --force               # Force (ignore dependents)
#   bash uninstall.sh --all                      # Uninstall everything
#   bash uninstall.sh --all --yes                # Headless-safe (no TTY prompts)
#   bash uninstall.sh --components shell,tmux    # Uninstall specific components
#   bash uninstall.sh --list                     # List installed components
#   bash uninstall.sh docker --remove-docker-data  # Also remove Docker volumes
# =============================================================================

# --- [A] Constants -----------------------------------------------------------

FORCE=0
NON_INTERACTIVE=0
INTERACTIVE=0
VERBOSE=0
LOG_FILE=""
CURSOR_HIDDEN=0
ALL_EXPLICIT=0
YES_FLAG=0

# Pre-confirmation flags (collected before execution)
# Default to preserving data — require explicit flags to remove
DOCKER_REMOVE_DATA=0
SSH_REMOVE_KEYS=0
NODE_KEEP_VERSIONS=0

# --- [B] ANSI Colors ---------------------------------------------------------

setup_colors() {
    if [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; then
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
        CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'
        DIM='\033[2m'; NC='\033[0m'
        HIDE_CURSOR='\033[?25l'; SHOW_CURSOR='\033[?25h'; CLEAR_LINE='\033[2K'
        SYM_CHECK="${GREEN}✔${NC}"; SYM_CROSS="${RED}✘${NC}"
        SYM_ARROW="${CYAN}▸${NC}"; SYM_DOT="${DIM}○${NC}"
        SYM_FILL="${GREEN}●${NC}"; SYM_WARN="${YELLOW}▲${NC}"
        SYM_PLAY="${CYAN}▶${NC}"
    else
        RED='' GREEN='' YELLOW='' CYAN='' WHITE=''
        BOLD='' DIM='' NC=''
        HIDE_CURSOR='' SHOW_CURSOR='' CLEAR_LINE=''
        SYM_CHECK='[ok]' SYM_CROSS='[fail]' SYM_ARROW='>' SYM_DOT='[ ]'
        SYM_FILL='[x]' SYM_WARN='[!]' SYM_PLAY='[>]'
    fi
}

# --- [C] Component Registry --------------------------------------------------

COMP_IDS=(shell tmux git tools neovim node uv containers tailscale ssh security)

COMP_NAMES=(
    "Shell Environment" "Tmux" "Git" "CLI Tools" "Neovim"
    "Node.js (nvm)" "uv + Python" "Containers" "Tailscale"
    "SSH" "Security Baseline"
)

COMP_DESCS=(
    "zsh + Starship, no Oh My Zsh"
    "tmux package (config preserved)"
    "git package (config preserved)"
    "rg, jq, fd, bat, tree, shellcheck, gh, build tools"
    "Neovim editor + config"
    "nvm + Node.js"
    "uv package manager + managed pythons"
    "Podman or Docker + images/volumes"
    "Tailscale VPN"
    "SSH keys + sshd config"
    "Restore sshd configuration and firewall notices"
)

# Reverse dependency map: which components depend on THIS one
COMP_DEPENDENTS=("" "" "" "" "" "" "" "" "" "10" "")

# Whether uninstall needs sudo (indexes: shell=0 tmux=1 git=2 tools=3 neovim=4
# node=5 uv=6 containers=7 tailscale=8 ssh=9 security=10)
# On macOS, brew operations do not require sudo
if is_macos; then
    COMP_NEEDS_SUDO=(1 0 0 0 0 0 0 0 0 1 1)
else
    COMP_NEEDS_SUDO=(1 1 0 1 0 0 0 1 1 1 1)
fi

# State arrays
COMP_INSTALLED=(0 0 0 0 0 0 0 0 0 0 0)
COMP_SELECTED=(0 0 0 0 0 0 0 0 0 0 0)
VISIBLE=()

# --- [D] Utility Functions ---------------------------------------------------

SUDO_KEEPALIVE_PID=""
SPINNER_PID=""

cleanup() {
    if [[ "${CURSOR_HIDDEN:-0}" -eq 1 ]]; then
        printf '\033[?25h' 2>/dev/null || true
    fi
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
    fi
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    return 0
}
trap cleanup EXIT INT TERM

start_spinner() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    [[ -z "$BOLD" ]] && frames=('-' '\' '|' '/')
    printf "${HIDE_CURSOR}" 2>/dev/null
    (
        local i=0
        while true; do
            printf "\r  ${CYAN}%s${NC} ${DIM}%s${NC}  " "${frames[$i]}" "$msg"
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf "\r${CLEAR_LINE}"
    printf "${SHOW_CURSOR}" 2>/dev/null
}

cache_sudo() {
    local needs_sudo=0
    for i in "${!COMP_SELECTED[@]}"; do
        if [[ "${COMP_SELECTED[$i]}" -eq 1 && "${COMP_NEEDS_SUDO[$i]}" -eq 1 ]]; then
            needs_sudo=1; break
        fi
    done
    if [[ $needs_sudo -eq 1 ]]; then
        printf "  ${DIM}Some components require sudo. Caching credentials...${NC}\n"
        sudo -v
        ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
    fi
}

print_banner() {
    printf "\n"
    printf "  ${CYAN}${BOLD}┌──────────────────────────────────────────┐${NC}\n"
    printf "  ${CYAN}${BOLD}│${NC}  ${BOLD}${WHITE}Rig Uninstaller${NC}                         ${CYAN}${BOLD}│${NC}\n"
    printf "  ${CYAN}${BOLD}│${NC}  ${DIM}github.com/DieRingedesSaturn/rig${NC}        ${CYAN}${BOLD}│${NC}\n"
    printf "  ${CYAN}${BOLD}└──────────────────────────────────────────┘${NC}\n"
    printf "\n"
}

hr() { printf "  ${DIM}──────────────────────────────────────────${NC}\n"; }

# Check if a TTY is truly available (not just that /dev/tty exists as a device node)
has_tty() { : < /dev/tty 2>/dev/null; }

# Back up before modifying or removing a user config file or directory.
backup_file() {
    local target="$1" backup
    [[ -e "$target" ]] || return 0
    backup="$(rig_user_backup "$target" uninstall)"
    echo "  Backup: $backup"
}

load_env() {
    if [[ -d "$HOME/.nvm" ]]; then
        export NVM_DIR="$HOME/.nvm"
        if [[ -f "$NVM_DIR/nvm.sh" ]]; then
            # shellcheck disable=SC1091
            . "$NVM_DIR/nvm.sh"
        fi
    fi
    if [[ -d "$HOME/.local/bin" ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    # Return 0 explicitly. This used to end on `[[ -d ... ]] && export ...`,
    # which returns 1 when ~/.local/bin does not exist — and under `set -e` that
    # aborted the whole script silently on any machine lacking that directory.
    return 0
}

show_help() {
    cat << 'HELP'
Usage: uninstall.sh [OPTIONS] [COMPONENT]

Rig uninstaller for individual or batch component removal.

Arguments:
  COMPONENT              Single component to uninstall:
                         shell,tmux,git,tools,neovim,node,uv,
                         containers,tailscale,ssh,security

Options:
  --all                  Uninstall all installed components
  --components LIST      Comma-separated component list (validated against known IDs)
  --force                Skip dependency checks and confirmations
  --yes                  Auto-confirm prompts (required for headless/no-TTY operation)
  --remove-docker-data   Remove Docker volumes and images at /var/lib/docker
  --remove-ssh-keys      Remove SSH keys in ~/.ssh/
  --keep-node-versions   Keep ~/.nvm (all Node versions + global npm packages)
  --list                 List installed components and exit
  -v, --verbose          Show raw command output
  -h, --help             Show this help

Data Safety:
  By default, destructive data (Docker volumes, SSH keys) is preserved during
  uninstall. Use the --remove-* flags above to opt in to data removal. The
  --force flag skips prompts but does NOT auto-remove data.

  When no TTY is available (e.g., CI/scripts), --yes is required to proceed.

Examples:
  bash uninstall.sh containers                     # Uninstall Containers (data preserved)
  bash uninstall.sh containers --remove-docker-data # Uninstall Containers + remove data
  bash uninstall.sh node --force                   # Force uninstall Node.js
  bash uninstall.sh --components containers,node   # Uninstall multiple
  bash uninstall.sh --all --yes                    # Uninstall everything (headless-safe)
  bash uninstall.sh --list                         # Show what's installed
HELP
}

# --- [E] Detection -----------------------------------------------------------

check_shell_installed() { command -v zsh &>/dev/null; }
check_tmux_installed() { command -v tmux &>/dev/null; }
check_git_installed() { command -v git &>/dev/null; }
check_tools_installed() { command -v rg &>/dev/null && command -v jq &>/dev/null; }
check_neovim_installed() { command -v nvim &>/dev/null; }
check_node_installed() { command -v nvm &>/dev/null || [[ -f "$HOME/.nvm/nvm.sh" ]]; }
check_uv_installed() { command -v uv &>/dev/null; }
check_containers_installed() { command -v podman &>/dev/null || command -v docker &>/dev/null; }
check_tailscale_installed() { command -v tailscale &>/dev/null; }
check_ssh_installed() { [[ -f /etc/ssh/sshd_config ]]; }
check_security_installed() {
    grep -q "# Rig Security Baseline" /etc/ssh/sshd_config 2>/dev/null || \
    [[ -f "$RIG_SYSTEM_BACKUP_DIR/etc__ssh__sshd_config.pre-rig" ]] || \
    ls /etc/ssh/sshd_config.rig.bak.* &>/dev/null || \
    [[ -f /etc/docker/daemon.json.rig-backup ]]
}

detect_installed() {
    local checks=(
        check_shell_installed
        check_tmux_installed
        check_git_installed
        check_tools_installed
        check_neovim_installed
        check_node_installed
        check_uv_installed
        check_containers_installed
        check_tailscale_installed
        check_ssh_installed
        check_security_installed
    )
    for i in "${!checks[@]}"; do
        if "${checks[$i]}"; then
            COMP_INSTALLED[$i]=1
        fi
    done
}

# --- [F] Pre-execution Confirmations ----------------------------------------

collect_confirmations() {
    # --force skips interactive prompts but does NOT auto-enable destructive data removal.
    # Use --remove-docker-data and --remove-ssh-keys explicitly.
    [[ "$FORCE" -eq 1 ]] && return 0
    has_tty || return 0

    local needs_confirm=0
    for i in "${!COMP_SELECTED[@]}"; do
        [[ "${COMP_SELECTED[$i]}" -eq 0 ]] && continue
        case "${COMP_IDS[$i]}" in containers|docker|ssh|node) needs_confirm=1 ;; esac
    done
    [[ $needs_confirm -eq 0 ]] && return 0

    printf "  ${BOLD}Data removal confirmations${NC}\n"
    hr

    for i in "${!COMP_SELECTED[@]}"; do
        [[ "${COMP_SELECTED[$i]}" -eq 0 ]] && continue
        case "${COMP_IDS[$i]}" in
            containers|docker)
                printf "\n  ${BOLD}${WHITE}Docker${NC}\n"
                printf "  ${YELLOW}Volumes and images at /var/lib/docker can be removed.${NC}\n"
                printf "  ${BOLD}Remove all Docker data?${NC} ${DIM}[y/N]${NC} "
                local ans; read -r ans </dev/tty
                [[ "$ans" =~ ^[Yy] ]] && DOCKER_REMOVE_DATA=1
                ;;
            ssh)
                printf "\n  ${BOLD}${WHITE}SSH${NC}\n"
                printf "  ${YELLOW}SSH keys in ~/.ssh/ can be removed.${NC}\n"
                printf "  ${BOLD}Remove SSH keys?${NC} ${DIM}[y/N]${NC} "
                local ans; read -r ans </dev/tty
                [[ "$ans" =~ ^[Yy] ]] && SSH_REMOVE_KEYS=1
                ;;
            node)
                printf "\n  ${BOLD}${WHITE}Node.js (nvm)${NC}\n"
                printf "  ${YELLOW}~/.nvm holds every nvm-managed Node version and all globally${NC}\n"
                printf "  ${YELLOW}installed npm packages. Removing it deletes all of them.${NC}\n"
                printf "  ${BOLD}Remove $HOME/.nvm?${NC} ${DIM}[y/N]${NC} "
                local ans; read -r ans </dev/tty
                # Declining is the safe direction: keep the data.
                [[ "$ans" =~ ^[Yy] ]] || NODE_KEEP_VERSIONS=1
                ;;
        esac
    done
    printf "\n"
}

# --- [G] Uninstall Functions -------------------------------------------------

uninstall_shell() {
    echo "=== Uninstalling Shell Environment ==="

    # Packages this component installs. zsh itself is deliberately left alone:
    # it is the login shell, and pulling it out from under a live session is
    # never a safe cleanup.
    pkg_remove starship zsh-autosuggestions zsh-syntax-highlighting 2>/dev/null || true

    # Starship installed from upstream lives here instead of in the package DB.
    if [[ -x "$HOME/.local/bin/starship" ]]; then
        rm -f "$HOME/.local/bin/starship" "$HOME/.local/bin/starship.old"
        echo "  Removed $HOME/.local/bin/starship"
    fi

    # ~/.zshrc and ~/.config/starship.toml are the user's own files — this
    # component never created or edited them, so it must not remove them.
    if [[ -f "$HOME/.config/starship.toml" ]]; then
        echo "  Kept $HOME/.config/starship.toml (your configuration)"
    fi
    if [[ -f "$HOME/.zshrc" ]]; then
        echo "  Kept $HOME/.zshrc (your configuration)"
    fi

    # Oh My Zsh is left untouched: Rig does not manage or remove personal shell frameworks.
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        echo "  Kept $HOME/.oh-my-zsh (personal configuration preserved)"
    fi

    # The default shell is left as-is on purpose: this component never changed
    # it, and flipping someone's login shell is not a cleanup step.
    echo "  Left the default login shell unchanged."
}

uninstall_tmux() {
    echo "=== Uninstalling Tmux ==="

    if [[ -f "$HOME/.tmux.conf" ]]; then
        if head -1 "$HOME/.tmux.conf" 2>/dev/null | grep -qx '# Rig Tmux Baseline'; then
            backup_file "$HOME/.tmux.conf"
            rm -f "$HOME/.tmux.conf"
            echo "  $HOME/.tmux.conf backed up and removed."
        else
            echo "  Kept $HOME/.tmux.conf (not identified as a Rig-created file)"
        fi
    fi
    if [[ -d "$HOME/.tmux" ]]; then
        echo "  Kept $HOME/.tmux (plugins and user configurations preserved)"
    fi

    if command -v tmux &>/dev/null; then
        pkg_remove tmux 2>/dev/null || true
        echo "  tmux package removed."
    fi
}

uninstall_git() {
    echo "=== Uninstalling Git ==="
    echo "  Note: ~/.gitconfig will be preserved."

    if command -v git &>/dev/null; then
        pkg_remove git 2>/dev/null || true
        echo "  Git package removed."
    fi
}

uninstall_tools() {
    echo "=== Uninstalling CLI Tools ==="

    # Remove convenience symlinks (Debian-only; other platforms use native names)
    if is_debian; then
        rm -f "$HOME/.local/bin/bat" "$HOME/.local/bin/fd"
    fi

    # Remove gh CLI and its platform-specific repo config
    if command -v gh &>/dev/null; then
        if is_macos; then
            brew uninstall gh 2>/dev/null || true
        else
            pkg_remove gh 2>/dev/null || true
            # Clean up apt/yum repo sources (Linux only)
            sudo rm -f /etc/apt/sources.list.d/github-cli.list 2>/dev/null || true
            sudo rm -f /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
            sudo rm -f /etc/yum.repos.d/github-cli.repo 2>/dev/null || true
        fi
        echo "  GitHub CLI removed."
    fi

    # Remove packages (abstract names resolved by pkg_remove)
    pkg_remove ripgrep jq fd bat tree shellcheck build-tools wget unzip xclip fastfetch 2>/dev/null || true
    rm -f "$HOME/.local/bin/fastfetch"
    echo "  CLI tools removed."
}

uninstall_node() {
    echo "=== Uninstalling Node.js (nvm) ==="

    if [[ -d "$HOME/.nvm" ]]; then
        # Say what is about to be lost before losing it.
        local versions count=0
        versions="$(ls "$HOME/.nvm/versions/node" 2>/dev/null | tr '\n' ' ')"
        if [[ -d "$HOME/.nvm/versions/node" ]]; then
            count="$(find "$HOME/.nvm/versions/node" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
        fi
        echo "  nvm versions: ${versions:-none}"
        echo "  global npm packages live inside those versions and go with them."

        if [[ "$NODE_KEEP_VERSIONS" -eq 1 ]]; then
            echo "  Kept $HOME/.nvm (removal declined)."
        else
            rm -rf "$HOME/.nvm"
            echo "  Removed $HOME/.nvm ($count version(s))."
        fi
    else
        echo "  $HOME/.nvm not present."
    fi

    # rc files belong to the user — report the lines instead of editing them.
    local rc
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [[ -f "$rc" ]] || continue
        if grep -q '\.nvm' "$rc"; then
            echo "  $rc still loads nvm; this script does not edit it."
            echo "    Delete the nvm lines yourself once you no longer need nvm."
        fi
    done
}

uninstall_uv() {
    echo "=== Uninstalling uv ==="

    rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
    rm -rf "$HOME/.local/share/uv"
    rm -rf "$HOME/.cache/uv"
    echo "  uv and managed pythons removed."
}

uninstall_containers() {
    local engine mode
    engine="$(containers_engine)"
    mode="$(containers_mode)"

    echo "=== Uninstalling Containers ($engine, $mode) ==="

    case "$engine" in
        podman)
            if is_macos; then
                brew uninstall podman 2>/dev/null || true
            else
                pkg_remove podman 2>/dev/null || true
            fi
            echo "  Podman package removed."

            # Podman is daemonless, so there is no service to stop. Images and
            # volumes are user data and are never removed by default.
            if [[ -d "$HOME/.local/share/containers" ]]; then
                echo "  Kept $HOME/.local/share/containers (images and volumes)"
            fi
            if [[ -f "$HOME/.config/containers/registries.conf" ]]; then
                echo "  Kept $HOME/.config/containers/registries.conf (your configuration)"
            fi
            ;;

        docker)
            if is_macos; then
                brew uninstall --cask docker 2>/dev/null || true
                if [[ "$DOCKER_REMOVE_DATA" -eq 1 ]]; then
                    backup_file "$HOME/.docker"
                    rm -rf "$HOME/.docker"
                    echo "  Docker Desktop data and config removed (backed up)."
                else
                    echo "  Kept $HOME/.docker (your configuration)"
                fi
                echo "  Docker Desktop removed."
                return 0
            fi

            if [[ "$mode" == "rootless" ]]; then
                # Rootless: the daemon is a user service, not a system one.
                systemctl --user disable --now docker 2>/dev/null || true
                if command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
                    dockerd-rootless-setuptool.sh uninstall 2>/dev/null || true
                fi
                echo "  Rootless service removed."

                if [[ "$DOCKER_REMOVE_DATA" -eq 1 ]]; then
                    rm -rf "$HOME/.local/share/docker"
                    echo "  Rootless Docker data removed."
                elif [[ -d "$HOME/.local/share/docker" ]]; then
                    echo "  Kept $HOME/.local/share/docker (images and volumes)"
                fi
                if [[ -f "$HOME/.config/docker/daemon.json" ]]; then
                    echo "  Kept $HOME/.config/docker/daemon.json (your configuration)"
                fi
            else
                sudo systemctl disable --now docker.socket docker.service 2>/dev/null || true
                sudo systemctl stop containerd 2>/dev/null || true
                echo "  System services stopped."

                if [[ "$DOCKER_REMOVE_DATA" -eq 1 ]]; then
                    sudo rm -rf /var/lib/docker /var/lib/containerd
                    echo "  Docker data removed."
                elif [[ -d /var/lib/docker ]]; then
                    echo "  Kept /var/lib/docker (images and volumes)"
                fi

                # Protect existing daemon.json: restore rig backup if present, otherwise preserve
                if [[ -f /etc/docker/daemon.json.rig-backup ]]; then
                    sudo cp /etc/docker/daemon.json.rig-backup /etc/docker/daemon.json
                    echo "  Restored original /etc/docker/daemon.json from backup."
                elif [[ "$DOCKER_REMOVE_DATA" -eq 1 ]]; then
                    sudo rm -f /etc/docker/daemon.json
                    echo "  System daemon.json removed."
                elif [[ -f /etc/docker/daemon.json ]]; then
                    echo "  Kept /etc/docker/daemon.json (your configuration)"
                fi
                sudo rm -rf /etc/systemd/system/docker.service.d 2>/dev/null || true
                echo "  System service configurations cleaned up."
            fi

            # Packages, in both modes.
            case "$PKG_MANAGER" in
                apt)
                    sudo apt-get remove -y \
                        docker-ce docker-ce-cli containerd.io \
                        docker-ce-rootless-extras \
                        docker-compose-plugin docker-buildx-plugin 2>/dev/null || true
                    sudo apt-get autoremove -y 2>/dev/null || true
                    ;;
                dnf)
                    sudo dnf remove -y \
                        docker-ce docker-ce-cli containerd.io \
                        docker-ce-rootless-extras \
                        docker-compose-plugin docker-buildx-plugin 2>/dev/null || true
                    ;;
                yum)
                    sudo yum remove -y \
                        docker-ce docker-ce-cli containerd.io \
                        docker-ce-rootless-extras \
                        docker-compose-plugin docker-buildx-plugin 2>/dev/null || true
                    ;;
                pacman)
                    sudo pacman -Rs --noconfirm docker docker-compose docker-buildx 2>/dev/null || true
                    ;;
            esac
            echo "  Packages removed."

            # Repo sources and the CLI context, both modes.
            sudo rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
            sudo rm -f /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            sudo rm -f /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true

            if [[ "$DOCKER_REMOVE_DATA" -eq 1 ]]; then
                backup_file "$HOME/.docker"
                rm -rf "$HOME/.docker"
                echo "  User CLI configuration removed (backed up)."
            elif [[ -d "$HOME/.docker" ]]; then
                echo "  Kept $HOME/.docker (CLI configuration)"
            fi
            ;;

        *)
            echo "  No container backend selected, nothing to do."
            ;;
    esac
}

uninstall_tailscale() {
    echo "=== Uninstalling Tailscale ==="

    # When SSH is restricted to tailscale0 the firewall rules survive this
    # uninstall — warn early that removing Tailscale could strand remote SSH.
    if [[ "$(rig_config_get RIG_SSH_ACCESS '' 2>/dev/null || true)" == "tailscale" ]]; then
        echo "  WARNING: SSH access is restricted to tailscale0 (RIG_SSH_ACCESS=tailscale)."
        echo "           Removing Tailscale may make this host unreachable over SSH."
        echo "           Re-run the security component with RIG_SSH_ACCESS=public first,"
        echo "           or remove the tailscale0 firewall rules manually."
    fi

    if is_macos; then
        # macOS: Tailscale is a cask or App Store app; CLI disconnect only
        tailscale logout 2>/dev/null || true
        brew uninstall --cask tailscale 2>/dev/null || true
        echo "  Tailscale removed."
    else
        # Linux: disconnect, stop systemd, remove package
        sudo tailscale down 2>/dev/null || true
        sudo systemctl stop tailscaled 2>/dev/null || true
        sudo systemctl disable tailscaled 2>/dev/null || true
        echo "  Disconnected and stopped."

        case "$PKG_MANAGER" in
            apt)
                sudo apt-get remove -y tailscale 2>/dev/null || true
                sudo apt-get autoremove -y 2>/dev/null || true
                ;;
            dnf)
                sudo dnf remove -y tailscale 2>/dev/null || true
                ;;
            yum)
                sudo yum remove -y tailscale 2>/dev/null || true
                ;;
            pacman)
                sudo pacman -Rs --noconfirm tailscale 2>/dev/null || true
                ;;
        esac
        sudo rm -rf /var/lib/tailscale
        sudo rm -f /etc/apt/sources.list.d/tailscale*.list 2>/dev/null || true
        sudo rm -f /etc/yum.repos.d/tailscale.repo 2>/dev/null || true
        echo "  Tailscale removed."
    fi
}

uninstall_ssh() {
    echo "=== Uninstalling SSH Configuration ==="

    # Remove SSH keys (conditional)
    if [[ "$SSH_REMOVE_KEYS" -eq 1 ]]; then
        for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
            if [[ -f "$key" ]]; then
                backup_file "$key"
                rm -f "$key" "${key}.pub"
                echo "  Removed $(basename "$key")."
            fi
        done
        if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
            backup_file "$HOME/.ssh/authorized_keys"
            rm -f "$HOME/.ssh/authorized_keys"
        fi
        echo "  SSH keys removed."
    else
        echo "  SSH keys preserved."
    fi

    # Remove GitHub SSH proxy config
    if [[ -f "$HOME/.ssh/config" ]] && grep -q "^Host github\.com" "$HOME/.ssh/config" 2>/dev/null; then
        backup_file "$HOME/.ssh/config"
        # Remove the github.com Host block using awk
        awk '
            /^Host github\.com/ { skip=1; next }
            /^Host / && skip { skip=0 }
            /^[^ \t]/ && !/^Host / && skip { skip=0 }
            !skip
        ' "$HOME/.ssh/config" > "$HOME/.ssh/config.tmp.$$"
        mv "$HOME/.ssh/config.tmp.$$" "$HOME/.ssh/config"
        chmod 600 "$HOME/.ssh/config"
        echo "  GitHub SSH proxy config removed."
    fi

    # Restore sshd_config from backup — but only if it passes sshd -t, since
    # restoring a broken file and restarting would take sshd down.
    local latest_backup=""
    latest_backup="$(rig_system_latest_backup /etc/ssh/sshd_config setup-ssh || true)"
    for f in /etc/ssh/sshd_config.bak.*; do
        [[ -z "$latest_backup" && -f "$f" ]] && latest_backup="$f"
    done
    if [[ -n "$latest_backup" ]]; then
        rig_system_backup /etc/ssh/sshd_config uninstall >/dev/null 2>&1 || true
        local sshd_bin=""
        if command -v sshd >/dev/null 2>&1; then sshd_bin="sshd"
        elif [[ -x /usr/sbin/sshd ]]; then sshd_bin="/usr/sbin/sshd"; fi
        # sshd -t needs the privilege-separation dir on Debian-family systems.
        [[ -d /run/sshd ]] || sudo mkdir -p /run/sshd 2>/dev/null || true
        if [[ -n "$sshd_bin" ]] && ! sudo "$sshd_bin" -t -f "$latest_backup" 2>/dev/null; then
            echo "  WARNING: backup $latest_backup failed 'sshd -t'; leaving current sshd_config." >&2
        else
            sudo cp "$latest_backup" /etc/ssh/sshd_config
            sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
            echo "  sshd_config restored from backup."
        fi
    fi
}

uninstall_neovim() {
    echo "=== Uninstalling Neovim ==="

    local nvim_conf="${XDG_CONFIG_HOME:-$HOME/.config}/nvim/init.lua"
    if [[ -f "$nvim_conf" ]]; then
        if grep -q "Rig Neovim Baseline\|Lightweight terminal-native Neovim configuration" "$nvim_conf" 2>/dev/null; then
            backup_file "$nvim_conf"
            rm -f "$nvim_conf"
            echo "  Config $nvim_conf backed up and removed."
        else
            echo "  Kept $nvim_conf (custom configuration not created by Rig)"
        fi
    fi

    if command -v nvim &>/dev/null; then
        pkg_remove neovim 2>/dev/null || true
        echo "  neovim package removed."
    fi
}

uninstall_security() {
    echo "=== Rolling Back Security Baseline ==="

    local sshd_cfg="/etc/ssh/sshd_config"
    local restored=0

    # Prefer the stable pre-Rig snapshot. For installations created before that
    # snapshot existed, the oldest timestamped backup is the pre-Rig state.
    local original_bak oldest_bak new_original_bak
    new_original_bak="$(rig_system_backup_once_path "$sshd_cfg" pre-rig)"
    original_bak="${sshd_cfg}.rig.original"
    oldest_bak=$(ls -tr "${sshd_cfg}.rig.bak."* 2>/dev/null | head -1 || true)
    if [[ -f "$new_original_bak" ]]; then
        sudo cp -p "$new_original_bak" "$sshd_cfg"
        mv "$new_original_bak" "${new_original_bak}.restored.$(date +%s)"
        echo "  Restored $sshd_cfg from the centralized pre-Rig snapshot."
        restored=1
    elif sudo test -f "$original_bak"; then
        sudo cp -p "$original_bak" "$sshd_cfg"
        sudo mv "$original_bak" "${original_bak}.restored.$(date +%s)"
        echo "  Restored $sshd_cfg from the pre-Rig snapshot."
        restored=1
    elif [[ -n "$oldest_bak" && -f "$oldest_bak" ]]; then
        sudo cp -p "$oldest_bak" "$sshd_cfg"
        echo "  Restored $sshd_cfg from $oldest_bak"
        restored=1
    elif [[ -f "$sshd_cfg" ]] && grep -q "# Rig Security Baseline" "$sshd_cfg"; then
        local tmp_cfg
        tmp_cfg="$(mktemp)"
        awk '
            /^# Rig Security Baseline$/ { skip=1; next }
            skip && /^[[:space:]]*$/ { skip=0; next }
            skip { next }
            { print }
        ' "$sshd_cfg" > "$tmp_cfg"
        sudo cp "$tmp_cfg" "$sshd_cfg"
        rm -f "$tmp_cfg"
        echo "  Removed Rig Security Baseline block from $sshd_cfg"
        restored=1
    fi

    if [[ $restored -eq 1 ]]; then
        if command -v sshd >/dev/null 2>&1 && sudo sshd -t 2>/dev/null; then
            if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
                if is_debian; then
                    sudo systemctl reload-or-restart ssh 2>/dev/null || true
                else
                    sudo systemctl reload-or-restart sshd 2>/dev/null || true
                fi
            elif command -v service >/dev/null 2>&1; then
                sudo service ssh reload 2>/dev/null || sudo service sshd reload 2>/dev/null || true
            fi
            echo "  sshd reloaded with restored configuration."
        fi
    fi

    echo "  Note: Firewall rules have been preserved. To reset, use 'sudo ufw reset' or firewall-cmd."
    echo "  Security baseline rollback complete."
}

# --- [H] Dispatcher & Dependency Checker ------------------------------------

run_uninstall() {
    local idx=$1
    case "${COMP_IDS[$idx]}" in
        shell)           uninstall_shell ;;
        tmux)            uninstall_tmux ;;
        git)             uninstall_git ;;
        tools)           uninstall_tools ;;
        neovim)          uninstall_neovim ;;
        node)            uninstall_node ;;
        uv)              uninstall_uv ;;
        containers)      uninstall_containers ;;
        tailscale)       uninstall_tailscale ;;
        ssh)             uninstall_ssh ;;
        security)        uninstall_security ;;
    esac
}

check_dependents() {
    local idx=$1
    local deps="${COMP_DEPENDENTS[$idx]}"
    [[ -z "$deps" ]] && return 0

    local blocked=()
    for dep_idx in $deps; do
        # Only block if dependent is installed AND not also selected for removal
        if [[ "${COMP_INSTALLED[$dep_idx]}" -eq 1 && "${COMP_SELECTED[$dep_idx]}" -eq 0 ]]; then
            blocked+=("${COMP_NAMES[$dep_idx]}")
        fi
    done

    if [[ ${#blocked[@]} -gt 0 ]]; then
        printf "  ${SYM_WARN} ${YELLOW}%s${NC} is required by: ${BOLD}%s${NC}\n" \
            "${COMP_NAMES[$idx]}" "$(IFS=', '; echo "${blocked[*]}")"
        if [[ "$FORCE" -eq 1 ]]; then
            printf "  ${DIM}Forcing uninstall (--force)${NC}\n"
            return 0
        fi
        printf "  ${DIM}Use --force to override${NC}\n"
        return 1
    fi
    return 0
}

# --- [I] TUI Menu -----------------------------------------------------------

read_key() {
    local key=""
    IFS= read -rsn1 key 2>/dev/null </dev/tty || true
    if [[ "$key" == $'\x1b' ]]; then
        local seq
        IFS= read -rsn2 -t 0.1 seq 2>/dev/null </dev/tty
        case "$seq" in
            '[A') echo "UP" ;; '[B') echo "DOWN" ;; *) echo "ESC" ;;
        esac
    elif [[ "$key" == "" ]]; then echo "ENTER"
    elif [[ "$key" == " " ]]; then echo "SPACE"
    elif [[ "$key" == "a" || "$key" == "A" ]]; then echo "A"
    elif [[ "$key" == "q" || "$key" == "Q" ]]; then echo "Q"
    else echo "$key"
    fi
}

render_menu() {
    local cursor_pos=$1
    local total=${#VISIBLE[@]}
    local selected_count=0
    for vi in "${!VISIBLE[@]}"; do
        local ci="${VISIBLE[$vi]}"
        [[ "${COMP_SELECTED[$ci]}" -eq 1 ]] && ((selected_count++))
    done

    printf "\033[%dA" "$((total + 4))"
    printf "${CLEAR_LINE}\n"
    printf "${CLEAR_LINE}  ${DIM}↑↓${NC} navigate  ${DIM}space${NC} toggle  ${DIM}a${NC} all  ${DIM}enter${NC} confirm  ${DIM}q${NC} quit\n"

    for vi in $(seq 0 $((total - 1))); do
        local ci="${VISIBLE[$vi]}"
        printf "${CLEAR_LINE}"
        [[ $vi -eq $cursor_pos ]] && printf "  ${SYM_ARROW} " || printf "    "
        [[ "${COMP_SELECTED[$ci]}" -eq 1 ]] && printf "${SYM_FILL} " || printf "${SYM_DOT} "
        if [[ $vi -eq $cursor_pos ]]; then
            printf "${BOLD}${WHITE}%-22s${NC} " "${COMP_NAMES[$ci]}"
        else
            printf "${BOLD}%-22s${NC} " "${COMP_NAMES[$ci]}"
        fi
        printf "${DIM}%-34s${NC}" "${COMP_DESCS[$ci]}"
        [[ "${COMP_NEEDS_SUDO[$ci]}" -eq 1 ]] && printf " ${DIM}[${NC} ${YELLOW}sudo${NC} ${DIM}]${NC}"
        printf "\n"
    done

    printf "${CLEAR_LINE}\n"
    if [[ $selected_count -gt 0 ]]; then
        printf "${CLEAR_LINE}  ${RED}${BOLD}%d${NC}${DIM} component(s) selected for removal${NC}\n" "$selected_count"
    else
        printf "${CLEAR_LINE}  ${DIM}No components selected${NC}\n"
    fi
}

show_checkbox_menu() {
    local cursor=0 total=${#VISIBLE[@]}
    printf "${HIDE_CURSOR}"; CURSOR_HIDDEN=1

    for ((i = 0; i < total + 4; i++)); do printf "\n"; done
    render_menu $cursor

    while true; do
        local key; key=$(read_key)
        case "$key" in
            UP)    ((cursor > 0)) && ((cursor--)) ;;
            DOWN)  ((cursor < total - 1)) && ((cursor++)) ;;
            SPACE)
                local ci="${VISIBLE[$cursor]}"
                COMP_SELECTED[$ci]=$(( 1 - COMP_SELECTED[$ci] ))
                ;;
            A)
                local any=0
                for vi in "${!VISIBLE[@]}"; do
                    [[ "${COMP_SELECTED[${VISIBLE[$vi]}]}" -eq 1 ]] && any=1 && break
                done
                for vi in "${!VISIBLE[@]}"; do COMP_SELECTED[${VISIBLE[$vi]}]=$((1 - any)); done
                ;;
            ENTER) break ;;
            Q)
                printf "${SHOW_CURSOR}"; CURSOR_HIDDEN=0
                printf "\n  ${DIM}Aborted.${NC}\n\n"; exit 0
                ;;
        esac
        render_menu $cursor
    done
    printf "${SHOW_CURSOR}"; CURSOR_HIDDEN=0
}

# --- [J] Execution Engine ----------------------------------------------------

run_component_uninstall() {
    local idx=$1 step=$2 total=$3
    local comp_log="${LOG_FILE}.${COMP_IDS[$idx]}"

    load_env

    if [[ "$VERBOSE" -eq 1 ]]; then
        printf "\n"
        printf "  ${BOLD}${CYAN}[%d/%d]${NC} ${BOLD}${WHITE}%s${NC}\n" "$step" "$total" "${COMP_NAMES[$idx]}"
        printf "  ${CYAN}────────────────────────────────────────${NC}\n"
        if run_uninstall "$idx" 2>&1 | tee "$comp_log"; then
            printf "  ${CYAN}────────────────────────────────────────${NC}\n"
            printf "  ${SYM_CHECK} ${GREEN}%s${NC}\n" "${COMP_NAMES[$idx]}"
            return 0
        else
            printf "  ${CYAN}────────────────────────────────────────${NC}\n"
            printf "  ${SYM_CROSS} ${RED}%s${NC}\n" "${COMP_NAMES[$idx]}"
            return 1
        fi
    else
        start_spinner "Uninstalling ${COMP_NAMES[$idx]}..."
        run_uninstall "$idx" > "$comp_log" 2>&1
        local result=$?
        stop_spinner

        if [[ $result -eq 0 ]]; then
            printf "  ${SYM_CHECK} ${BOLD}${CYAN}[%d/%d]${NC} %s\n" "$step" "$total" "${COMP_NAMES[$idx]}"
            return 0
        else
            printf "  ${SYM_CROSS} ${BOLD}${CYAN}[%d/%d]${NC} ${RED}%s${NC}\n" "$step" "$total" "${COMP_NAMES[$idx]}"
            printf "  ${DIM}── last 15 lines ──${NC}\n"
            tail -n 15 "$comp_log" 2>/dev/null | sed 's/^/    /'
            printf "  ${DIM}── full log: %s ──${NC}\n" "$comp_log"
            return 1
        fi
    fi
}

run_all_selected() {
    local ordered=("$@")
    local total=${#ordered[@]} step=0 succeeded=0 failed=0
    local failed_names=() succeeded_names=()

    printf "\n"
    for idx in "${ordered[@]}"; do
        step=$((step + 1))
        if run_component_uninstall "$idx" "$step" "$total"; then
            succeeded=$((succeeded + 1)); succeeded_names+=("${COMP_NAMES[$idx]}")
        else
            failed=$((failed + 1)); failed_names+=("${COMP_NAMES[$idx]}")
        fi
    done

    # Summary
    printf "\n"
    printf "  ${BOLD}${CYAN}┌──────────────────────────────────────────┐${NC}\n"
    printf "  ${BOLD}${CYAN}│${NC}  ${BOLD}${WHITE}Uninstall Summary${NC}                       ${BOLD}${CYAN}│${NC}\n"
    printf "  ${BOLD}${CYAN}└──────────────────────────────────────────┘${NC}\n"
    printf "\n"

    for name in "${succeeded_names[@]}"; do printf "  ${SYM_CHECK} %s\n" "$name"; done
    for name in "${failed_names[@]}"; do printf "  ${SYM_CROSS} %s\n" "$name"; done

    printf "\n  ${DIM}Result: ${GREEN}${BOLD}%d removed${NC}" "$succeeded"
    [[ $failed -gt 0 ]] && printf " ${DIM}/${NC} ${RED}${BOLD}%d failed${NC}" "$failed"
    printf "\n"

    [[ $failed -gt 0 ]] && printf "\n  ${DIM}Logs: ${NC}${CYAN}${LOG_FILE}.*${NC}\n"
    printf "\n"
    return "$failed"
}

# --- [K] Argument Parser -----------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                ALL_EXPLICIT=1; NON_INTERACTIVE=1; shift ;;
            --components)
                [[ $# -lt 2 ]] && { printf "${RED}Error: --components requires an argument${NC}\n"; exit 1; }
                IFS=',' read -ra REQUESTED <<< "$2"
                local unknown_ids=()
                for req in "${REQUESTED[@]}"; do
                    req=$(echo "$req" | tr -d ' ')
                    [[ -z "$req" ]] && continue
                    local found=0
                    for i in "${!COMP_IDS[@]}"; do
                        if [[ "${COMP_IDS[$i]}" == "$req" ]]; then
                            COMP_SELECTED[$i]=1; found=1; break
                        fi
                    done
                    if [[ $found -eq 0 ]]; then
                        unknown_ids+=("$req")
                    fi
                done
                if [[ ${#unknown_ids[@]} -gt 0 ]]; then
                    printf "${RED}Error: Unknown component ID(s): %s${NC}\n" "$(IFS=', '; echo "${unknown_ids[*]}")"
                    printf "Valid IDs: %s\n" "${COMP_IDS[*]}"
                    exit 1
                fi
                # Verify at least one component was selected
                local any_set=0
                for s in "${COMP_SELECTED[@]}"; do [[ "$s" -eq 1 ]] && any_set=1 && break; done
                if [[ $any_set -eq 0 ]]; then
                    printf "${RED}Error: --components list is empty after parsing${NC}\n"
                    printf "Valid IDs: %s\n" "${COMP_IDS[*]}"
                    exit 1
                fi
                NON_INTERACTIVE=1; shift 2 ;;
            --force)
                FORCE=1; shift ;;
            --yes)
                YES_FLAG=1; shift ;;
            --remove-docker-data)
                DOCKER_REMOVE_DATA=1; shift ;;
            --remove-ssh-keys)
                SSH_REMOVE_KEYS=1; shift ;;
            --keep-node-versions)
                NODE_KEEP_VERSIONS=1; shift ;;
            --list)
                setup_colors; load_env; detect_installed
                printf "\n  ${BOLD}Installed components:${NC}\n"; hr
                local count=0
                for i in "${!COMP_IDS[@]}"; do
                    if [[ "${COMP_INSTALLED[$i]}" -eq 1 ]]; then
                        printf "  ${SYM_CHECK} %-22s ${DIM}%s${NC}\n" "${COMP_NAMES[$i]}" "${COMP_DESCS[$i]}"
                        count=$((count + 1))
                    fi
                done
                [[ $count -eq 0 ]] && printf "  ${DIM}No rig components detected.${NC}\n"
                hr; printf "  ${DIM}Total: %d component(s)${NC}\n\n" "$count"
                exit 0 ;;
            --verbose|-v)
                VERBOSE=1; shift ;;
            --help|-h)
                show_help; exit 0 ;;
            -*)
                printf "${RED}Unknown option: %s${NC}\n" "$1"
                show_help; exit 1 ;;
            *)
                # Positional argument: component name
                local found=0
                for i in "${!COMP_IDS[@]}"; do
                    [[ "${COMP_IDS[$i]}" == "$1" ]] && { COMP_SELECTED[$i]=1; found=1; }
                done
                if [[ $found -eq 0 ]]; then
                    printf "${RED}Unknown component: %s${NC}\n" "$1"
                    printf "Valid: %s\n" "${COMP_IDS[*]}"
                    exit 1
                fi
                NON_INTERACTIVE=1; shift ;;
        esac
    done
}

# --- [L] Main ----------------------------------------------------------------

main() {
    setup_colors
    parse_args "$@"
    load_env

    # Determine interactive mode
    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        if has_tty; then
            INTERACTIVE=1
        else
            echo "Error: No terminal available. Specify a component or use --all."
            echo "  When running without a TTY, --yes is required to confirm."
            echo "  Example: bash uninstall.sh docker --yes"
            echo "  Example: bash uninstall.sh --all --yes"
            exit 1
        fi
    fi

    # In non-interactive mode without a TTY, require --yes to proceed
    if [[ "$NON_INTERACTIVE" -eq 1 && "$YES_FLAG" -eq 0 && "$FORCE" -eq 0 ]] && ! has_tty; then
        echo "Error: No terminal available and --yes not specified."
        echo "  Refusing to proceed without explicit confirmation."
        echo "  Add --yes to confirm, or run interactively with a TTY."
        exit 1
    fi

    # Create secure log file in user's cache directory
    local log_dir="$HOME/.cache/rig"
    mkdir -p "$log_dir"
    chmod 700 "$log_dir"
    LOG_FILE=$(mktemp "$log_dir/uninstall-XXXXXX")
    chmod 600 "$LOG_FILE"

    print_banner
    detect_installed

    local installed_count=0
    for v in "${COMP_INSTALLED[@]}"; do [[ "$v" -eq 1 ]] && installed_count=$((installed_count + 1)); done

    if [[ $installed_count -eq 0 ]]; then
        printf "  ${DIM}No rig components detected.${NC}\n\n"
        exit 0
    fi

    printf "  ${DIM}Found ${BOLD}%d${NC}${DIM} installed component(s)${NC}\n" "$installed_count"

    # Build visible mapping (only installed components)
    VISIBLE=()
    for i in "${!COMP_IDS[@]}"; do
        [[ "${COMP_INSTALLED[$i]}" -eq 1 ]] && VISIBLE+=("$i")
    done

    if [[ "$INTERACTIVE" -eq 1 ]]; then
        show_checkbox_menu
    else
        # Check if specific components were selected
        local has_explicit=0
        for s in "${COMP_SELECTED[@]}"; do [[ "$s" -eq 1 ]] && has_explicit=1 && break; done

        if [[ $has_explicit -eq 0 && "$ALL_EXPLICIT" -eq 1 ]]; then
            # --all was explicitly passed: select all installed
            for i in "${!COMP_INSTALLED[@]}"; do COMP_SELECTED[$i]=${COMP_INSTALLED[$i]}; done
        elif [[ $has_explicit -eq 0 && "$ALL_EXPLICIT" -eq 0 ]]; then
            # No components selected and --all not passed — error out
            printf "  ${RED}Error: No components specified.${NC}\n"
            printf "  ${DIM}Use --all to uninstall everything, or specify components.${NC}\n"
            printf "  ${DIM}Example: bash uninstall.sh --components docker,node${NC}\n\n"
            exit 1
        else
            # Warn about non-installed selections
            for i in "${!COMP_SELECTED[@]}"; do
                if [[ "${COMP_SELECTED[$i]}" -eq 1 && "${COMP_INSTALLED[$i]}" -eq 0 ]]; then
                    printf "  ${SYM_WARN} ${YELLOW}%s${NC} ${DIM}is not installed, skipping${NC}\n" "${COMP_NAMES[$i]}"
                    COMP_SELECTED[$i]=0
                fi
            done
        fi
    fi

    # Check at least one selected
    local any_selected=0
    for s in "${COMP_SELECTED[@]}"; do [[ "$s" -eq 1 ]] && any_selected=1 && break; done
    if [[ "$any_selected" -eq 0 ]]; then
        printf "  ${DIM}No components selected. Exiting.${NC}\n\n"
        exit 0
    fi

    # Build ordered list (reverse order: dependents before dependencies)
    local ordered=()
    for (( i=${#COMP_SELECTED[@]}-1; i>=0; i-- )); do
        [[ "${COMP_SELECTED[$i]}" -eq 1 ]] && ordered+=("$i")
    done

    # Check dependencies
    local blocked=0
    for idx in "${ordered[@]}"; do
        check_dependents "$idx" || ((blocked++))
    done
    if [[ $blocked -gt 0 && "$FORCE" -eq 0 ]]; then
        printf "\n  ${RED}${BOLD}Uninstall blocked.${NC} ${DIM}Resolve dependencies or use --force.${NC}\n\n"
        exit 1
    fi

    # Show plan
    printf "\n  ${BOLD}${SYM_PLAY} Uninstall plan${NC}\n"
    hr
    local step=0
    for idx in "${ordered[@]}"; do
        step=$((step + 1))
        local suffix=""
        [[ "${COMP_NEEDS_SUDO[$idx]}" -eq 1 ]] && suffix=" ${YELLOW}sudo${NC}"
        printf "  ${CYAN}%2d${NC} ${DIM}│${NC} %-24s${DIM}%s${NC}%b\n" \
            "$step" "${COMP_NAMES[$idx]}" "${COMP_DESCS[$idx]}" "$suffix"
    done
    hr
    printf "  ${DIM}Total: ${BOLD}%d${NC}${DIM} component(s) to remove${NC}\n\n" "${#ordered[@]}"

    # Confirm
    if [[ "$FORCE" -eq 0 && "$YES_FLAG" -eq 0 ]] && has_tty; then
        printf "  ${RED}${BOLD}⚠ This action cannot be fully undone.${NC}\n"
        printf "  ${BOLD}Proceed with uninstall?${NC} ${DIM}[y/N]${NC} "
        local confirm_ans
        read -r confirm_ans </dev/tty
        if [[ ! "$confirm_ans" =~ ^[Yy] ]]; then
            printf "\n  ${DIM}Aborted.${NC}\n\n"
            exit 0
        fi
        printf "\n"
    fi

    # Collect data-removal confirmations for docker/ssh
    collect_confirmations

    # Pre-cache sudo
    cache_sudo

    # Execute
    run_all_selected "${ordered[@]}"
    local result=$?

    printf "  ${DIM}Run ${CYAN}exec \$SHELL${NC} ${DIM}to reload your shell.${NC}\n"

    if [[ $result -eq 0 ]]; then
        printf "  ${SYM_CHECK} ${GREEN}${BOLD}All done!${NC}\n\n"
    else
        printf "  ${SYM_WARN} ${YELLOW}${BOLD}Some components failed. See logs above.${NC}\n\n"
    fi

    exit "$result"
}

main "$@"
