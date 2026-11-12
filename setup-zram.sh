#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Swap & zram Setup
# https://github.com/DieRingedesSaturn/rig
#
# Compressed zram swap through systemd-zram-generator, plus an optional
# disk-backed swapfile. Existing disk swap is never touched unless the user
# opts in, so it keeps acting as the fallback when zram fills up.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
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
# shellcheck source=lib/zram.sh
source "$SCRIPT_DIR/lib/zram.sh"

if [[ -t 1 || "${FORCE_COLOR:-}" == "1" ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; NC=''
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y|--non-interactive)
            export RIG_NON_INTERACTIVE=1
            shift
            ;;
        --help|-h)
            echo "Usage: setup-zram.sh [--yes|--non-interactive|--help]"
            echo "  Configures zram compressed swap and an optional swapfile."
            exit 0
            ;;
        *) shift ;;
    esac
done

echo "=== Swap & zram Setup ==="

if ! zram_supported; then
    echo "  zram requires Linux with systemd; skipping."
    exit 0
fi

ZRAM_ENABLE="$(rig_config_get RIG_ZRAM_ENABLE "yes")"
ZRAM_SIZE="$(rig_config_get RIG_ZRAM_SIZE "auto")"
ZRAM_COMPRESSION="$(rig_config_get RIG_ZRAM_COMPRESSION "zstd")"
SWAPFILE_ENABLE="$(rig_config_get RIG_SWAPFILE_ENABLE "no")"
SWAPFILE_SIZE="$(rig_config_get RIG_SWAPFILE_SIZE "1024")"

case "$ZRAM_ENABLE" in yes|no) ;; *) echo "Invalid RIG_ZRAM_ENABLE: $ZRAM_ENABLE" >&2; exit 1 ;; esac
case "$SWAPFILE_ENABLE" in yes|no) ;; *) echo "Invalid RIG_SWAPFILE_ENABLE: $SWAPFILE_ENABLE" >&2; exit 1 ;; esac
zram_size_is_valid "$ZRAM_SIZE" || { echo "Invalid RIG_ZRAM_SIZE: $ZRAM_SIZE (use auto or MiB)" >&2; exit 1; }
zram_compression_is_valid "$ZRAM_COMPRESSION" || { echo "Invalid RIG_ZRAM_COMPRESSION: $ZRAM_COMPRESSION" >&2; exit 1; }
swapfile_size_is_valid "$SWAPFILE_SIZE" || { echo "Invalid RIG_SWAPFILE_SIZE: $SWAPFILE_SIZE (MiB)" >&2; exit 1; }

# Interactive selection. Empty answer keeps the resolved value.
if rig_can_prompt && [[ "${RIG_NON_INTERACTIVE:-0}" -ne 1 ]]; then
    printf "\n=== Interactive Swap Configuration ===\n"
    printf "Press Enter to keep the current value.\n\n"

    read -rp "Enable zram compressed swap? [current: $ZRAM_ENABLE; yes/no]: " ans </dev/tty || ans=""
    case "$ans" in "" ) ;; yes|no) ZRAM_ENABLE="$ans" ;; *) echo "  Invalid value; keeping $ZRAM_ENABLE." ;; esac

    read -rp "zram size [current: $ZRAM_SIZE; auto or MiB]: " ans </dev/tty || ans=""
    if [[ -n "$ans" ]]; then
        if zram_size_is_valid "$ans"; then ZRAM_SIZE="$ans"; else echo "  Invalid size; keeping $ZRAM_SIZE."; fi
    fi

    read -rp "zram compression [current: $ZRAM_COMPRESSION; zstd/lz4/lzo-rle]: " ans </dev/tty || ans=""
    if [[ -n "$ans" ]]; then
        if zram_compression_is_valid "$ans"; then ZRAM_COMPRESSION="$ans"; else echo "  Invalid algorithm; keeping $ZRAM_COMPRESSION."; fi
    fi

    read -rp "Create a disk swapfile too? [current: $SWAPFILE_ENABLE; yes/no]: " ans </dev/tty || ans=""
    case "$ans" in "" ) ;; yes|no) SWAPFILE_ENABLE="$ans" ;; *) echo "  Invalid value; keeping $SWAPFILE_ENABLE." ;; esac

    if [[ "$SWAPFILE_ENABLE" == "yes" ]]; then
        read -rp "Swapfile size in MiB [current: $SWAPFILE_SIZE]: " ans </dev/tty || ans=""
        if [[ -n "$ans" ]]; then
            if swapfile_size_is_valid "$ans"; then SWAPFILE_SIZE="$ans"; else echo "  Invalid size; keeping $SWAPFILE_SIZE."; fi
        fi
    fi
    printf "\n"
fi

# install_root_file SRC DEST - atomically replace a root-owned config file.
install_root_file() {
    local src="$1" dest="$2"
    sudo install -m 0644 "$src" "$dest.rig-tmp" || return 1
    sudo mv -f "$dest.rig-tmp" "$dest"
}

# install_managed_file SRC DEST LABEL - write a root-owned file, backing up a
# differing existing file first. An identical file is left untouched.
install_managed_file() {
    local src="$1" dest="$2" label="$3" backup=""
    if [[ -e "$dest" ]]; then
        if cmp -s "$src" "$dest" 2>/dev/null; then
            return 0
        fi
        backup="$(rig_system_backup "$dest" zram)" || return 1
        echo "  Backup: $backup"
        if ! grep -qxF "$RIG_ZRAM_MARKER" "$dest" 2>/dev/null; then
            printf "  ${YELLOW}⚠${NC} Replacing unmanaged %s (backup kept).\n" "$label"
        fi
    fi
    install_root_file "$src" "$dest"
}

# --- [1/3] zram --------------------------------------------------------------
echo "[1/3] Configuring zram..."

ZRAM_EFFECTIVE_SIZE="$(zram_effective_size_mb "$ZRAM_SIZE")"
ZRAM_CONFIG_CHANGED=0

if [[ "$ZRAM_ENABLE" == "yes" ]]; then
    ZRAM_PKG="$(zram_pkg_name)"
    [[ -n "$ZRAM_PKG" ]] || { echo "ERROR: no zram-generator package for this platform" >&2; exit 1; }
    if ! zram_generator_present; then
        echo "  Installing $ZRAM_PKG..."
        pkg_install "$ZRAM_PKG" || { echo "ERROR: failed to install $ZRAM_PKG" >&2; exit 1; }
    fi
    if ! zram_generator_present; then
        echo "ERROR: zram-generator is still missing after installing $ZRAM_PKG" >&2
        exit 1
    fi

    ZRAM_TMP="$(mktemp)"
    zram_render_config "$ZRAM_EFFECTIVE_SIZE" "$ZRAM_COMPRESSION" > "$ZRAM_TMP"
    if [[ ! -f "$RIG_ZRAM_CONFIG_PATH" ]] || ! cmp -s "$ZRAM_TMP" "$RIG_ZRAM_CONFIG_PATH"; then
        ZRAM_CONFIG_CHANGED=1
    fi
    sudo mkdir -p "$(dirname "$RIG_ZRAM_CONFIG_PATH")"
    install_managed_file "$ZRAM_TMP" "$RIG_ZRAM_CONFIG_PATH" "$RIG_ZRAM_CONFIG_PATH"
    rm -f "$ZRAM_TMP"

    sudo systemctl daemon-reload \
        || { echo "ERROR: systemd daemon-reload failed" >&2; exit 1; }
    if [[ "$ZRAM_CONFIG_CHANGED" -eq 1 ]]; then
        # A changed size/algorithm needs a rebuild. The generated swap unit
        # must be stopped first: zramctl --reset fails on a device still used
        # as swap, which would leave the old size in place.
        if zram_is_active; then
            echo "  Rebuilding zram0 (active pages are swapped back into RAM)..."
            sudo systemctl stop "$RIG_ZRAM_SWAP_UNIT" 2>/dev/null || true
            sudo swapoff "$RIG_ZRAM_DEVICE" 2>/dev/null || true
        fi
        sudo systemctl restart "$RIG_ZRAM_UNIT" \
            || { echo "ERROR: $RIG_ZRAM_UNIT failed to start" >&2; sudo systemctl status "$RIG_ZRAM_UNIT" --no-pager 2>&1 | sed 's/^/    /' >&2 || true; exit 1; }
    else
        sudo systemctl start "$RIG_ZRAM_UNIT" 2>/dev/null || true
    fi
    sudo systemctl start "$RIG_ZRAM_SWAP_UNIT" 2>/dev/null || true

    if ! zram_is_active; then
        echo "ERROR: zram0 is not active after configuration" >&2
        sudo systemctl status "$RIG_ZRAM_UNIT" --no-pager 2>&1 | sed 's/^/    /' >&2 || true
        exit 1
    fi
    printf "  ${GREEN}✔${NC} zram0: %s MiB (%s)\n" "$(zram_active_size_mb)" "$ZRAM_COMPRESSION"
else
    echo "  zram disabled."
    if zram_config_is_managed; then
        sudo systemctl stop "$RIG_ZRAM_SWAP_UNIT" 2>/dev/null || true
        if zram_is_active; then
            sudo swapoff "$RIG_ZRAM_DEVICE" 2>/dev/null || true
        fi
        sudo systemctl stop "$RIG_ZRAM_UNIT" 2>/dev/null || true
        if zram_is_active; then
            if command -v zramctl >/dev/null 2>&1; then
                sudo zramctl --reset "$RIG_ZRAM_DEVICE" 2>/dev/null || true
            fi
        fi
        sudo rm -f "$RIG_ZRAM_CONFIG_PATH"
        sudo systemctl daemon-reload 2>/dev/null || true
        echo "  Removed rig zram configuration."
    elif [[ -e "$RIG_ZRAM_CONFIG_PATH" ]]; then
        echo "  Existing unmanaged $RIG_ZRAM_CONFIG_PATH left untouched."
    fi
fi

# --- [2/3] sysctl tuning -----------------------------------------------------
echo "[2/3] Tuning swap behavior..."

if [[ "$ZRAM_ENABLE" == "yes" ]]; then
    SYSCTL_TMP="$(mktemp)"
    zram_render_sysctl > "$SYSCTL_TMP"
    sudo mkdir -p "$(dirname "$RIG_ZRAM_SYSCTL_PATH")"
    install_managed_file "$SYSCTL_TMP" "$RIG_ZRAM_SYSCTL_PATH" "$RIG_ZRAM_SYSCTL_PATH"
    rm -f "$SYSCTL_TMP"
    sudo sysctl -q -p "$RIG_ZRAM_SYSCTL_PATH" \
        || { echo "ERROR: failed to apply $RIG_ZRAM_SYSCTL_PATH" >&2; exit 1; }
    printf "  ${GREEN}✔${NC} swappiness=%s, page-cluster=%s\n" "$RIG_ZRAM_SWAPPINESS" "$RIG_ZRAM_PAGE_CLUSTER"
elif zram_sysctl_is_managed; then
    sudo rm -f "$RIG_ZRAM_SYSCTL_PATH"
    sudo sysctl --system >/dev/null 2>&1 || true
    echo "  Removed rig zram sysctl tuning (reboot fully restores boot defaults)."
fi

# --- [3/3] swapfile ----------------------------------------------------------
echo "[3/3] Configuring swapfile..."

FSTAB_BACKUP=""
backup_fstab() {
    [[ -n "$FSTAB_BACKUP" ]] && return 0
    if [[ -e "$RIG_FSTAB_PATH" ]]; then
        FSTAB_BACKUP="$(rig_system_backup "$RIG_FSTAB_PATH" zram)" || return 1
        echo "  Backup: $FSTAB_BACKUP"
    fi
}

if [[ "$SWAPFILE_ENABLE" == "yes" ]]; then
    if swapfile_in_fstab && ! swapfile_fstab_managed; then
        printf "  ${YELLOW}⚠${NC} %s already has an fstab entry not managed by rig; leaving it untouched.\n" "$RIG_SWAPFILE_PATH"
    else
        if [[ ! -e "$RIG_SWAPFILE_PATH" ]]; then
            echo "  Creating $RIG_SWAPFILE_PATH ($SWAPFILE_SIZE MiB)..."
            if ! sudo fallocate -l "${SWAPFILE_SIZE}M" "$RIG_SWAPFILE_PATH" 2>/dev/null; then
                sudo dd if=/dev/zero of="$RIG_SWAPFILE_PATH" bs=1M count="$SWAPFILE_SIZE" 2>/dev/null
            fi
            sudo chmod 600 "$RIG_SWAPFILE_PATH"
            sudo mkswap "$RIG_SWAPFILE_PATH" >/dev/null
        fi

        if ! swapfile_fstab_managed; then
            FSTAB_TMP="$(mktemp)"
            rig_fstab_with_managed_block > "$FSTAB_TMP"
            backup_fstab
            install_root_file "$FSTAB_TMP" "$RIG_FSTAB_PATH"
            rm -f "$FSTAB_TMP"
        fi

        if ! swapfile_is_active; then
            if ! sudo swapon "$RIG_SWAPFILE_PATH"; then
                if [[ -n "$FSTAB_BACKUP" ]]; then
                    sudo cp "$FSTAB_BACKUP" "$RIG_FSTAB_PATH" || true
                fi
                echo "ERROR: could not activate $RIG_SWAPFILE_PATH (existing data was not reformatted)" >&2
                exit 1
            fi
        fi
        printf "  ${GREEN}✔${NC} swapfile active: %s\n" "$RIG_SWAPFILE_PATH"
    fi
else
    if swapfile_fstab_managed; then
        if swapfile_is_active; then
            sudo swapoff "$RIG_SWAPFILE_PATH" || { echo "ERROR: could not deactivate $RIG_SWAPFILE_PATH" >&2; exit 1; }
        fi
        FSTAB_TMP="$(mktemp)"
        rig_fstab_without_managed_block > "$FSTAB_TMP"
        backup_fstab
        install_root_file "$FSTAB_TMP" "$RIG_FSTAB_PATH"
        rm -f "$FSTAB_TMP"
        sudo rm -f "$RIG_SWAPFILE_PATH"
        echo "  Removed rig-managed swapfile $RIG_SWAPFILE_PATH."
    elif swapfile_in_fstab; then
        echo "  Existing unmanaged swap entry for $RIG_SWAPFILE_PATH left untouched."
    else
        echo "  No rig-managed swapfile; disk swap untouched."
    fi
fi

# Persist only after every requested step succeeded.
rig_config_set RIG_ZRAM_ENABLE "$ZRAM_ENABLE"
rig_config_set RIG_ZRAM_SIZE "$ZRAM_SIZE"
rig_config_set RIG_ZRAM_COMPRESSION "$ZRAM_COMPRESSION"
rig_config_set RIG_SWAPFILE_ENABLE "$SWAPFILE_ENABLE"
rig_config_set RIG_SWAPFILE_SIZE "$SWAPFILE_SIZE"

echo ""
printf "${GREEN}✔${NC} Swap & zram setup complete.\n"
