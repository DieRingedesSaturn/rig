#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# zram / swap configuration helpers
# https://github.com/DieRingedesSaturn/rig
#
# Shared by setup-zram.sh, status.sh and uninstall.sh. Every path is
# overridable so tests never touch (or depend on) the host's real files.
# =============================================================================

if [[ -n "${_LIB_ZRAM_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_LIB_ZRAM_LOADED=1

RIG_ZRAM_CONFIG_PATH="${RIG_ZRAM_CONFIG_PATH:-/etc/systemd/zram-generator.conf}"
RIG_ZRAM_UNIT="${RIG_ZRAM_UNIT:-systemd-zram-setup@zram0.service}"
RIG_ZRAM_SWAP_UNIT="${RIG_ZRAM_SWAP_UNIT:-dev-zram0.swap}"
RIG_ZRAM_DEVICE="${RIG_ZRAM_DEVICE:-/dev/zram0}"
RIG_ZRAM_SYSFS="${RIG_ZRAM_SYSFS:-/sys/block/zram0}"
RIG_ZRAM_SYSCTL_PATH="${RIG_ZRAM_SYSCTL_PATH:-/etc/sysctl.d/99-rig-zram.conf}"
RIG_SWAPFILE_PATH="${RIG_SWAPFILE_PATH:-/swapfile}"
RIG_FSTAB_PATH="${RIG_FSTAB_PATH:-/etc/fstab}"
RIG_PROC_SWAPS="${RIG_PROC_SWAPS:-/proc/swaps}"

# Shared marker for user-visible comments and managed-file detection.
RIG_ZRAM_MARKER="# Managed by rig"
RIG_FSTAB_MARKER="# rig-managed swap (do not edit)"
# auto sizing keeps zram useful without starving the page cache: RAM/3,
# capped at 1 GiB (matches the conservative Debian VPS baseline).
RIG_ZRAM_MAX_MB="${RIG_ZRAM_MAX_MB:-1024}"
RIG_ZRAM_SWAPPINESS="${RIG_ZRAM_SWAPPINESS:-100}"
RIG_ZRAM_PAGE_CLUSTER="${RIG_ZRAM_PAGE_CLUSTER:-0}"

# zram_pkg_name - Package that provides the systemd zram-generator.
zram_pkg_name() {
    case "${OS_FAMILY:-}" in
        debian)       printf '%s\n' "systemd-zram-generator" ;;
        fedora|rhel)  printf '%s\n' "zram-generator" ;;
        arch)         printf '%s\n' "zram-generator" ;;
        *)            printf '' ;;
    esac
}

# zram_supported - zram-generator is Linux/systemd only; macOS and unknown
# systems are skipped instead of failing the whole apply.
zram_supported() {
    [[ "${OS_FAMILY:-}" == "macos" || "${OS_FAMILY:-}" == "unknown" ]] && return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl show --property=Version >/dev/null 2>&1
}

# zram_generator_present - True when the systemd generator binary is installed.
zram_generator_present() {
    [[ -x /usr/lib/systemd/system-generators/zram-generator ]] \
        || [[ -x /lib/systemd/system-generators/zram-generator ]] \
        || [[ -x /usr/lib/systemd/system-generators/zram-generator-bin ]] \
        || [[ -x /lib/systemd/system-generators/zram-generator-bin ]]
}

zram_size_is_valid() {
    local size="${1:-}"
    [[ "$size" == "auto" ]] && return 0
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    size=$((10#$size))
    (( size >= 1 && size <= 1048576 ))
}

zram_compression_is_valid() {
    case "${1:-}" in
        zstd|lz4|lzo|lzo-rle|deflate|842) return 0 ;;
        *) return 1 ;;
    esac
}

swapfile_size_is_valid() {
    local size="${1:-}"
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    size=$((10#$size))
    (( size >= 16 && size <= 1048576 ))
}

# zram_auto_size_mb - RAM/3 MiB, capped at RIG_ZRAM_MAX_MB.
zram_auto_size_mb() {
    local ram_mb size
    ram_mb="$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || true)"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=2048
    size=$((ram_mb / 3))
    (( size > RIG_ZRAM_MAX_MB )) && size=$RIG_ZRAM_MAX_MB
    (( size < 16 )) && size=16
    printf '%s\n' "$size"
}

# zram_effective_size_mb VALUE - Resolve auto or a literal MiB value.
zram_effective_size_mb() {
    if [[ "${1:-auto}" == "auto" ]]; then
        zram_auto_size_mb
    else
        printf '%s\n' "$((10#${1}))"
    fi
}

zram_render_config() {
    local size="$1" compression="$2"
    printf '%s\n' "$RIG_ZRAM_MARKER"
    printf '# rig zram: compressed swap device zram0\n'
    printf '[zram0]\n'
    printf 'zram-size = %s\n' "$size"
    printf 'compression-algorithm = %s\n' "$compression"
    printf 'swap-priority = 100\n'
}

zram_render_sysctl() {
    printf '%s\n' "$RIG_ZRAM_MARKER"
    printf '# rig zram tuning: prefer compressed swap, read back one page\n'
    printf 'vm.swappiness = %s\n' "$RIG_ZRAM_SWAPPINESS"
    printf 'vm.page-cluster = %s\n' "$RIG_ZRAM_PAGE_CLUSTER"
}

zram_config_is_managed() {
    [[ -f "$RIG_ZRAM_CONFIG_PATH" ]] \
        && grep -qxF "$RIG_ZRAM_MARKER" "$RIG_ZRAM_CONFIG_PATH" 2>/dev/null
}

zram_sysctl_is_managed() {
    [[ -f "$RIG_ZRAM_SYSCTL_PATH" ]] \
        && grep -qxF "$RIG_ZRAM_MARKER" "$RIG_ZRAM_SYSCTL_PATH" 2>/dev/null
}

# _zram_swap_names - Active swap entries from /proc/swaps (one per line).
_zram_swap_names() {
    awk 'NR > 1 { print $1 }' "$RIG_PROC_SWAPS" 2>/dev/null || true
}

zram_is_active() {
    _zram_swap_names | grep -qxF "$RIG_ZRAM_DEVICE"
}

swapfile_is_active() {
    _zram_swap_names | grep -qxF "$RIG_SWAPFILE_PATH"
}

# zram_active_size_mb - Actual device size in MiB (0 when the device is absent).
zram_active_size_mb() {
    local bytes
    [[ -r "$RIG_ZRAM_SYSFS/disksize" ]] || return 1
    bytes="$(cat "$RIG_ZRAM_SYSFS/disksize" 2>/dev/null || true)"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$((bytes / 1024 / 1024))"
}

# swapfile_in_fstab - Path has any fstab entry, managed or not.
swapfile_in_fstab() {
    [[ -f "$RIG_FSTAB_PATH" ]] || return 1
    awk -v p="$RIG_SWAPFILE_PATH" '
        !/^[[:space:]]*#/ && $1 == p { found = 1 }
        END { exit !found }
    ' "$RIG_FSTAB_PATH"
}

# swapfile_fstab_managed - The path is in rig's marked fstab block.
swapfile_fstab_managed() {
    [[ -f "$RIG_FSTAB_PATH" ]] || return 1
    awk -v marker="$RIG_FSTAB_MARKER" -v path="$RIG_SWAPFILE_PATH" '
        pending && $1 == path && $2 == "none" && $3 == "swap" { found = 1 }
        { pending = ($0 == marker) }
        END { exit !found }
    ' "$RIG_FSTAB_PATH"
}

# Check all config destinations before setup changes the system.
zram_confirm_config_replacement() {
    local path="$1" answer=""
    [[ -e "$path" ]] || return 0
    grep -qxF "$RIG_ZRAM_MARKER" "$path" 2>/dev/null && return 0
    if [[ "${RIG_NON_INTERACTIVE:-0}" != 1 ]] && rig_can_prompt; then
        printf 'Replace unmanaged %s (backup will be kept)? [y/N]: ' "$path" >&2
        read -r answer </dev/tty || answer=""
        case "$answer" in y|Y|yes|YES) return 0 ;; esac
    fi
    printf 'Preserved unmanaged %s; zram setup stopped before applying changes.\n' "$path" >&2
    return 1
}

# rig_fstab_without_managed_block - Strip rig's two-line swap block, keeping
# every user entry byte-for-byte. The block is marker + entry, so a stray
# marker alone cannot delete the following user line.
rig_fstab_without_managed_block() {
    [[ -f "$RIG_FSTAB_PATH" ]] || return 0
    awk -v marker="$RIG_FSTAB_MARKER" -v path="$RIG_SWAPFILE_PATH" '
        $0 == marker { pending = 1; next }
        pending && $1 == path && $2 == "none" && $3 == "swap" { pending = 0; next }
        pending { pending = 0 }
        { print }
    ' "$RIG_FSTAB_PATH"
}

rig_fstab_with_managed_block() {
    rig_fstab_without_managed_block
    printf '%s\n' "$RIG_FSTAB_MARKER"
    printf '%s none swap sw 0 0\n' "$RIG_SWAPFILE_PATH"
}
