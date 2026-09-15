#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./setup-ssh.sh                                    # ensure sshd installed
#   SSH_PORT=2222 ./setup-ssh.sh                      # change port
#   SSH_PUBKEY="ssh-ed25519 AAAA..." ./setup-ssh.sh   # add key + disable password auth
#   SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" ./setup-ssh.sh  # import private key
#
# Environment variables:
#   SSH_PORT        - custom SSH port (empty = don't change)
#   SSH_PUBKEY      - public key string. When set, adds key and disables password auth.
#   SSH_PRIVATE_KEY - private key content. When set, writes to ~/.ssh/ and derives public key.
#   SSH_PROXY_HOST  - local HTTP proxy host for GitHub *SSH transport*
#                     (default: 127.0.0.1)
#   SSH_PROXY_PORT  - local HTTP proxy port (e.g. 7890 for Clash). When set,
#                     ~/.ssh/config makes `git clone git@github.com:...` reach
#                     GitHub via ssh.github.com:443 wrapped in a corkscrew
#                     CONNECT tunnel — for networks that block outbound SSH:22.
#                     Unrelated to GH_PROXY (the script download mirror).

# --- Source multi-OS libraries ------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/security.sh
source "$SCRIPT_DIR/lib/security.sh"

SSH_PORT="${SSH_PORT:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}"
SSH_PROXY_HOST="${SSH_PROXY_HOST:-127.0.0.1}"
SSH_PROXY_PORT="${SSH_PROXY_PORT:-}"

# --- Ensure openssh-server is installed ---------------------------------------
if is_macos; then
    # macOS: SSH is built-in; Remote Login is managed via systemsetup
    true
else
    if ! pkg_check_installed openssh-server; then
        pkg_install openssh-server
    fi
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
CHANGED=0
SSHD_BACKUP_CREATED=0
SSHD_BACKUP_PATH=""

backup_sshd_config() {
    [[ "$SSHD_BACKUP_CREATED" -eq 0 ]] || return 0
    SSHD_BACKUP_PATH="$(rig_system_backup "$SSHD_CONFIG" setup-ssh)"
    echo "  Backup: $SSHD_BACKUP_PATH"
    SSHD_BACKUP_CREATED=1
}

# Helper: determine the correct sshd service name
_sshd_service_name() {
    if is_debian; then
        echo "ssh"
    else
        # RHEL, Fedora, Arch, and most others use "sshd"
        echo "sshd"
    fi
}

# Helper: start/restart sshd (macOS → systemsetup/launchctl, Linux → systemd → service → direct)
sshd_ctl() {
    local action="$1"
    if is_macos; then
        case "$action" in
            start)
                sudo systemsetup -setremotelogin on 2>/dev/null || \
                    sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
                ;;
            restart)
                sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
                sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
                ;;
        esac
    else
        local svc
        svc="$(_sshd_service_name)"
        if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
            sudo systemctl "$action" "$svc"
        elif command -v service &>/dev/null; then
            sudo service "$svc" "$action"
        else
            # No init system (containers, minimal images). Never `pkill sshd`
            # here: this script may be running inside the SSH session it would
            # kill. SIGHUP re-execs sshd and reloads its config while keeping
            # existing connections alive.
            case "$action" in
                start)
                    pgrep -x sshd &>/dev/null || sudo /usr/sbin/sshd
                    ;;
                restart|reload)
                    if pgrep -x sshd &>/dev/null; then
                        sudo pkill -HUP -x sshd 2>/dev/null || true
                    else
                        sudo /usr/sbin/sshd
                    fi
                    ;;
            esac
        fi
    fi
}

# Apply "Key value" directives to the *global* section of sshd_config through a
# preflighted candidate file. Directives are emitted before any Match block, so
# they can never land in match context, and every duplicate in the global
# section is removed (first value wins). The result is checked with sshd -t
# before it is installed; a failed check leaves the live config untouched.
_sshd_apply_directives() {
    local candidate keyline key keys_re=""
    candidate="$(mktemp)"
    for keyline in "$@"; do
        key="${keyline%% *}"
        keys_re="${keys_re}${keys_re:+|}$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    done
    {
        for keyline in "$@"; do
            printf '%s\n' "$keyline"
        done
        awk -v keys_re="$keys_re" '
            BEGIN { in_match = 0 }
            {
                norm = tolower($0)
                sub(/^[[:space:]]*/, "", norm)
                if (norm ~ /^match[[:space:]]/) in_match = 1
                check = norm
                if (substr(check, 1, 1) == "#") {
                    if (substr(check, 2, 1) ~ /[a-z]/) sub(/^#/, "", check)
                    else check = "__comment__"
                }
                split(check, f, /[[:space:]]+/)
                if (!in_match && keys_re != "" && f[1] ~ ("^(" keys_re ")$")) next
                print
            }
        ' "$SSHD_CONFIG"
    } > "$candidate"

    if ! security_test_sshd_config "$candidate"; then
        rm -f "$candidate"
        echo "  ERROR: resulting sshd_config failed 'sshd -t'; existing config kept." >&2
        return 1
    fi
    backup_sshd_config
    sudo cp "$candidate" "$SSHD_CONFIG"
    rm -f "$candidate"
    CHANGED=1
}

echo "=== SSH Setup ==="

# [1/6] Ensure sshd is running
echo "[1/6] Ensuring sshd is running..."
if is_macos; then
    if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
        echo "  Remote Login (sshd) already enabled."
    else
        sshd_ctl start
        echo "  Remote Login (sshd) enabled."
    fi
elif pgrep -x sshd &>/dev/null; then
    echo "  sshd already running."
else
    sshd_ctl start
    echo "  sshd started."
fi

# [2/6] Import private key
echo "[2/6] Importing private key..."
if [ -n "$SSH_PRIVATE_KEY" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Detect key type from content
    KEY_FILE="$HOME/.ssh/id_ed25519"
    if echo "$SSH_PRIVATE_KEY" | grep -q "RSA"; then
        KEY_FILE="$HOME/.ssh/id_rsa"
    elif echo "$SSH_PRIVATE_KEY" | grep -q "ECDSA"; then
        KEY_FILE="$HOME/.ssh/id_ecdsa"
    fi

    if [ -f "$KEY_FILE" ]; then
        echo "  $KEY_FILE already exists, skipping."
    else
        echo "$SSH_PRIVATE_KEY" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        echo "  Private key written to $KEY_FILE"
    fi

    # Derive public key
    PUB_FILE="${KEY_FILE}.pub"
    if [ ! -f "$PUB_FILE" ]; then
        ssh-keygen -y -f "$KEY_FILE" > "$PUB_FILE"
        chmod 644 "$PUB_FILE"
        echo "  Public key derived to $PUB_FILE"
    fi
else
    echo "  Skipped (SSH_PRIVATE_KEY not set)."
fi

# [3/6] Configure port
echo "[3/6] Configuring port..."
if [ -n "$SSH_PORT" ]; then
    if [ ! -f "$SSHD_CONFIG" ]; then
        echo "  $SSHD_CONFIG not found, skipping port change."
    elif [[ "$(security_get_sshd_param Port "")" == "$SSH_PORT" ]]; then
        echo "  Port already set to $SSH_PORT."
    else
        if _sshd_apply_directives "Port $SSH_PORT"; then
            echo "  Port set to $SSH_PORT."
        fi
    fi
else
    echo "  Skipped (SSH_PORT not set)."
fi

# [4/6] Add public key to authorized_keys
echo "[4/6] Configuring authorized keys..."
if [ -n "$SSH_PUBKEY" ]; then
    AUTH_KEYS="$HOME/.ssh/authorized_keys"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    if grep -qF "$SSH_PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
        echo "  Public key already in authorized_keys."
    else
        echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
        echo "  Public key added to authorized_keys."
    fi
else
    echo "  Skipped (SSH_PUBKEY not set)."
fi

# [5/6] Configure public key authentication
echo "[5/6] Ensuring public key authentication is enabled..."
if [ -n "$SSH_PUBKEY" ]; then
    if [ -f "$SSHD_CONFIG" ]; then
        cur_pubkey="$(security_get_sshd_param PubkeyAuthentication "")"
        cur_pubkey="$(printf '%s' "$cur_pubkey" | tr '[:upper:]' '[:lower:]')"
        if [[ "$cur_pubkey" == "yes" ]]; then
            echo "  Public key authentication already enabled."
        elif _sshd_apply_directives "PubkeyAuthentication yes"; then
            echo "  Public key authentication enabled."
        else
            echo "  WARNING: could not enable PubkeyAuthentication; existing config kept." >&2
        fi
        echo "  (Note: Root login and password authentication hardening are safely managed by the security module)"
    fi
else
    echo "  Skipped (no public key provided)."
fi

# [6/6] Configure GitHub SSH-over-proxy (git's SSH transport via local HTTP proxy)
echo "[6/6] Configuring GitHub SSH transport proxy..."
if [ -n "$SSH_PROXY_PORT" ]; then
    # Ensure corkscrew is installed
    if ! command -v corkscrew &>/dev/null; then
        pkg_install corkscrew
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    SSH_CONFIG="$HOME/.ssh/config"
    touch "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"

    # Check if github.com Host block already exists
    if grep -q "^Host github.com" "$SSH_CONFIG" 2>/dev/null; then
        echo "  GitHub SSH config already exists in $SSH_CONFIG, skipping."
    else
        cat >> "$SSH_CONFIG" <<EOF

Host github.com
    Hostname ssh.github.com
    Port 443
    User git
    ProxyCommand corkscrew $SSH_PROXY_HOST $SSH_PROXY_PORT %h %p
EOF
        echo "  GitHub SSH transport proxy configured: git@github.com goes via ssh.github.com:443 through corkscrew at $SSH_PROXY_HOST:$SSH_PROXY_PORT."
    fi
else
    echo "  Skipped (SSH_PROXY_PORT not set — git@github.com will use a direct SSH:22 connection)."
fi

# Restart sshd if config changed; roll back if the service fails to come up.
if [ "$CHANGED" -eq 1 ]; then
    echo ""
    echo "Restarting sshd..."
    if sshd_ctl restart; then
        echo "  sshd restarted."
    else
        echo "  ERROR: sshd failed to restart; restoring previous configuration." >&2
        if [[ -n "$SSHD_BACKUP_PATH" ]]; then
            sudo cp "$SSHD_BACKUP_PATH" "$SSHD_CONFIG" 2>/dev/null || true
            sshd_ctl restart || true
            echo "  Restored $SSHD_CONFIG from backup." >&2
        fi
        exit 1
    fi
fi

echo ""
echo "=== Done! ==="
echo "SSH: $(ssh -V 2>&1)"
[ -n "$SSH_PORT" ] && echo "Port: $SSH_PORT" || echo "Port: (default)"
[ -n "$SSH_PUBKEY" ] && echo "Authorized Key: added" || echo "Authorized Key: (unchanged)"
[ -n "$SSH_PRIVATE_KEY" ] && echo "Identity: imported" || echo "Identity: (unchanged)"
[ -n "$SSH_PROXY_PORT" ] && echo "GitHub SSH: via $SSH_PROXY_HOST:$SSH_PROXY_PORT" || echo "GitHub SSH: (unchanged)"
