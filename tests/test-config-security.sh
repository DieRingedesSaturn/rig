#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Configuration writes are atomic, preserve unrelated and multi-line settings,
# and retain explicitly empty values.
CONFIG_FILE="$TEST_TMP/config"
cat > "$CONFIG_FILE" <<'EOF'
# user comment
RIG_COMPONENTS="
shell
tmux
"
RIG_PROFILE="desktop"
EOF

(
    export RIG_CONFIG_FILE="$CONFIG_FILE"
    source "$ROOT_DIR/lib/rig-config.sh"
    rig_config_set RIG_COMPONENTS "shell,security"
    rig_config_set RIG_PUBLIC_UDP ""
    [[ "$(rig_config_get RIG_COMPONENTS missing)" == "shell,security" ]]
    [[ "$(rig_config_get RIG_PUBLIC_UDP fallback)" == "" ]]
    [[ "$(rig_config_get RIG_PROFILE missing)" == "desktop" ]]
    ! rig_config_set NOT_A_RIG_KEY value >/dev/null 2>&1
) || fail "configuration get/set behavior"
grep -q '^# user comment$' "$CONFIG_FILE" || fail "config writer removed unrelated content"
[[ "$(grep -c '^RIG_COMPONENTS=' "$CONFIG_FILE")" -eq 1 ]] || fail "config writer left duplicate keys"

# Candidate sshd rendering places the managed global block first while keeping
# conditional Match settings byte-for-byte.
SSHD_INPUT="$TEST_TMP/sshd_config"
SSHD_OUTPUT="$TEST_TMP/sshd_candidate"
cat > "$SSHD_INPUT" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
port 22
PasswordAuthentication yes

Match User deploy
    PasswordAuthentication yes
    PermitRootLogin yes
EOF
(
    source "$ROOT_DIR/lib/security.sh"
    security_render_sshd_config "$SSHD_INPUT" "$SSHD_OUTPUT" 2222 no no yes
) || fail "sshd candidate rendering"
[[ "$(head -2 "$SSHD_OUTPUT" | tail -1)" == "Port 2222" ]] || fail "managed sshd block is not first"
[[ "$(grep -ci '^[[:space:]]*port[[:space:]]' "$SSHD_OUTPUT")" -eq 1 ]] || fail "old global SSH port survived"
grep -A2 '^Match User deploy$' "$SSHD_OUTPUT" | grep -q 'PasswordAuthentication yes' || fail "Match block was altered"
grep -A2 '^Match User deploy$' "$SSHD_OUTPUT" | grep -q 'PermitRootLogin yes' || fail "Match block was altered"

# Firewalld failures propagate, and Tailscale rules use a dedicated interface
# zone instead of an unsupported rich-rule interface selector.
FIREWALL_LOG="$TEST_TMP/firewall.log"
(
    source "$ROOT_DIR/lib/firewall.sh"
    sudo() {
        printf '%s\n' "$*" >> "$FIREWALL_LOG"
        [[ "$1" == "systemctl" ]] && return 1
        return 0
    }
    export -f sudo
    firewall_allow_port firewalld 22 tcp tailscale0
    firewall_remove_public_port firewalld 22 tcp
    if firewall_enable firewalld >/dev/null; then
        exit 1
    fi
) || fail "firewalld failure propagation"
grep -q -- '--zone=rig-tailscale --change-interface=tailscale0' "$FIREWALL_LOG" || fail "missing Tailscale interface restriction"
! grep -q 'in_interface' "$FIREWALL_LOG" || fail "unsupported firewalld interface matcher remains"
grep -q -- '--remove-port=22/tcp' "$FIREWALL_LOG" || fail "public SSH rule was not removed"

FIREWALL_ALLOWED="$(
    source "$ROOT_DIR/lib/firewall.sh"
    firewall-cmd() { :; }
    sudo() {
        case "$*" in
            'firewall-cmd --state') echo running ;;
            'firewall-cmd --list-ports') echo 80/tcp ;;
            'firewall-cmd --zone=rig-tailscale --list-interfaces') echo tailscale0 ;;
            'firewall-cmd --zone=rig-tailscale --list-ports') echo 22/tcp ;;
        esac
    }
    firewall_list_allowed firewalld
)"
[[ "$FIREWALL_ALLOWED" == "22/tcp@tailscale, 80/tcp" ]] || fail "restricted firewall rules were reported incorrectly"

# The documented `bash install.sh` form must use the current checkout rather
# than silently fetching the moving remote branch.
MOCK_BIN="$TEST_TMP/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "unexpected network access" >&2
exit 99
EOF
chmod +x "$MOCK_BIN/curl"
(
    cd "$ROOT_DIR"
    PATH="$MOCK_BIN:$PATH" bash install.sh --help >/dev/null
) || fail "bash install.sh did not use local libraries"

DRY_OUTPUT="$(HOME="$TEST_TMP/dry-home" bash "$ROOT_DIR/rig" apply --profile vps --dry-run)"
grep -q 'Profile:.*vps' <<< "$DRY_OUTPUT" || fail "apply did not resolve the VPS profile"
if command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    grep -q 'Container preference:.*podman.*already installed' <<< "$DRY_OUTPUT" || fail "dry run did not preserve installed Podman"
else
    grep -q 'Container preference:.*docker' <<< "$DRY_OUTPUT" || fail "VPS profile fallback did not select Docker"
fi
grep -q 'Dry run complete' <<< "$DRY_OUTPUT" || fail "dry run did not stop before execution"

# Auto mode treats the two engines as alternatives: an installed Podman wins
# over the VPS preference for Docker. Explicit configuration is tested by the
# same resolver precedence in lib/rig-config.sh.
(
    export RIG_CONTAINER_ENGINE=auto RIG_PROFILE=vps
    source "$ROOT_DIR/lib/os-detect.sh"
    source "$ROOT_DIR/lib/pkg-maps.sh"
    source "$ROOT_DIR/lib/pkg-manager.sh"
    source "$ROOT_DIR/lib/rig-config.sh"
    source "$ROOT_DIR/lib/containers.sh"
    command() {
        if [[ "${1:-}" == "-v" && "${2:-}" == "podman" ]]; then return 0; fi
        if [[ "${1:-}" == "-v" && "${2:-}" == "docker" ]]; then return 1; fi
        builtin command "$@"
    }
    [[ "$(containers_engine)" == "podman" ]]
    [[ "$(containers_engine_source)" == "installed" ]]
) || fail "installed Podman did not suppress Docker selection"

grep -q 'rig_config_get RIG_PUBLIC_TCP "$RIG_SSH_PORT"' "$ROOT_DIR/setup-security.sh" || \
    fail "security baseline still has implicit web-port defaults"
! grep -q 'RIG_PUBLIC_TCP "22,80,443"' "$ROOT_DIR/setup-security.sh" || \
    fail "security baseline still opens 80/443 by default"

# Backups are centralized below the user's Rig data directory, including
# copies of privileged source files. Mock sudo keeps this test unprivileged.
BACKUP_SOURCE="$TEST_TMP/system-config"
printf 'original\n' > "$BACKUP_SOURCE"
(
    export HOME="$TEST_TMP/backup-home"
    source "$ROOT_DIR/lib/backup.sh"
    sudo() { "$@"; }
    export -f sudo
    user_backup="$(rig_user_backup "$CONFIG_FILE" test)"
    system_backup="$(rig_system_backup "$BACKUP_SOURCE" test)"
    [[ "$user_backup" == "$HOME/.local/share/rig/backups/user/"* ]]
    [[ "$system_backup" == "$HOME/.local/share/rig/backups/system/"* ]]
    [[ -f "$user_backup" && -f "$system_backup" ]]
) || fail "centralized backup layout"

# Package/provider detection is capability based: a compatible wget command
# means the installer must not insist on a package literally named `wget`.
cat > "$MOCK_BIN/wget" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/wget"
(
    export PATH="$MOCK_BIN:$PATH"
    source "$ROOT_DIR/lib/os-detect.sh"
    source "$ROOT_DIR/lib/tools.sh"
    tools_command_available wget
) || fail "wget capability detection"

# Exercise the real import path with a stub installer. This catches missing
# configuration-library APIs without installing packages or touching host Git.
IMPORT_CASE="$TEST_TMP/import-case"
mkdir -p "$IMPORT_CASE/lib" "$TEST_TMP/home"
cp "$ROOT_DIR/import-config.sh" "$IMPORT_CASE/import-config.sh"
cp "$ROOT_DIR/lib/os-detect.sh" "$ROOT_DIR/lib/rig-config.sh" "$IMPORT_CASE/lib/"
cat > "$IMPORT_CASE/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$HOME/install-args"
printf '%s' "${RIG_PUBLIC_TCP-unset}" > "$HOME/imported-public-tcp"
EOF
cat > "$IMPORT_CASE/rig-config.json" <<'EOF'
{
  "components": ["shell"],
  "config": {
    "git": {"user_name": "Rig Test", "user_email": "rig@example.invalid"},
    "containers": {"engine": "auto", "mode": "rootless"},
    "system": {
      "profile": "minimal",
      "public_tcp": "",
      "public_udp": "",
      "warn_undeclared_ports": "no"
    }
  }
}
EOF
HOME="$TEST_TMP/home" RIG_CONFIG_FILE="$TEST_TMP/home/rig.conf" \
    bash "$IMPORT_CASE/import-config.sh" "$IMPORT_CASE/rig-config.json" --yes >/dev/null
grep -q '^RIG_PROFILE="minimal"$' "$TEST_TMP/home/rig.conf" || fail "import did not persist profile"
grep -q '^RIG_COMPONENTS="shell"$' "$TEST_TMP/home/rig.conf" || fail "import did not persist components"
grep -q '^RIG_PUBLIC_TCP=""$' "$TEST_TMP/home/rig.conf" || fail "import did not persist an empty public list"
[[ "$(cat "$TEST_TMP/home/imported-public-tcp")" == "" ]] || fail "empty imported list was not exported"
grep -q '^--components shell$' "$TEST_TMP/home/install-args" || fail "import did not invoke installer correctly"

echo "config/security regression tests passed"
