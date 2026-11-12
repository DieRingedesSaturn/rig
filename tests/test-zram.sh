#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# zram/swap helper regression tests
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Redirect every managed path into the test tree.
export RIG_ZRAM_CONFIG_PATH="$TEST_TMP/zram-generator.conf"
export RIG_ZRAM_SYSCTL_PATH="$TEST_TMP/99-rig-zram.conf"
export RIG_SWAPFILE_PATH="$TEST_TMP/swapfile"
export RIG_FSTAB_PATH="$TEST_TMP/fstab"
export RIG_PROC_SWAPS="$TEST_TMP/proc_swaps"
export RIG_ZRAM_SYSFS="$TEST_TMP/zram0"
mkdir -p "$RIG_ZRAM_SYSFS"

# shellcheck source=lib/os-detect.sh
source "$ROOT_DIR/lib/os-detect.sh"
# shellcheck source=lib/zram.sh
source "$ROOT_DIR/lib/zram.sh"

# --- validation --------------------------------------------------------------
zram_size_is_valid auto || fail "auto size rejected"
zram_size_is_valid 512 || fail "numeric size rejected"
! zram_size_is_valid 0 || fail "zero size accepted"
! zram_size_is_valid nope || fail "text size accepted"
swapfile_size_is_valid 1024 || fail "swapfile size rejected"
! swapfile_size_is_valid 1 || fail "tiny swapfile accepted"
! zram_compression_is_valid brotli || fail "unknown compression accepted"

auto_size="$(zram_effective_size_mb auto)"
[[ "$auto_size" =~ ^[0-9]+$ ]] || fail "auto size is not numeric"
(( auto_size >= 16 && auto_size <= RIG_ZRAM_MAX_MB )) || fail "auto size out of range: $auto_size"
[[ "$(zram_effective_size_mb 512)" == "512" ]] || fail "explicit size not preserved"

# --- rendered config ---------------------------------------------------------
conf="$(zram_render_config 512 zstd)"
grep -qxF '# Managed by rig' <<< "$conf" || fail "config marker missing"
grep -qxF '[zram0]' <<< "$conf" || fail "zram0 section missing"
grep -qxF 'zram-size = 512' <<< "$conf" || fail "zram-size missing"
grep -qxF 'compression-algorithm = zstd' <<< "$conf" || fail "compression missing"
grep -qxF 'swap-priority = 100' <<< "$conf" || fail "swap priority missing"

printf '%s\n' "$conf" > "$RIG_ZRAM_CONFIG_PATH"
zram_config_is_managed || fail "managed config not detected"
printf '[zram0]\nzram-size = 1\n' > "$RIG_ZRAM_CONFIG_PATH"
! zram_config_is_managed || fail "unmanaged config treated as managed"

sysctl_conf="$(zram_render_sysctl)"
grep -qxF '# Managed by rig' <<< "$sysctl_conf" || fail "sysctl marker missing"
grep -qxF 'vm.swappiness = 100' <<< "$sysctl_conf" || fail "swappiness missing"
grep -qxF 'vm.page-cluster = 0' <<< "$sysctl_conf" || fail "page-cluster missing"

# --- fstab block -------------------------------------------------------------
cat > "$RIG_FSTAB_PATH" <<'EOF'
UUID=abc / ext4 defaults 0 1
# user comment
EOF
cp "$RIG_FSTAB_PATH" "$TEST_TMP/fstab.original"

rig_fstab_with_managed_block > "$TEST_TMP/fstab.managed"
[[ "$(grep -cxF "$RIG_FSTAB_MARKER" "$TEST_TMP/fstab.managed")" -eq 1 ]] || fail "swap marker count"
grep -qxF "$RIG_SWAPFILE_PATH none swap sw 0 0" "$TEST_TMP/fstab.managed" || fail "swap entry missing"
grep -qxF 'UUID=abc / ext4 defaults 0 1' "$TEST_TMP/fstab.managed" || fail "existing fstab entry lost"

cp "$TEST_TMP/fstab.managed" "$RIG_FSTAB_PATH"
rig_fstab_with_managed_block > "$TEST_TMP/fstab.managed2"
cmp -s "$TEST_TMP/fstab.managed" "$TEST_TMP/fstab.managed2" || fail "fstab block not idempotent"

rig_fstab_without_managed_block > "$TEST_TMP/fstab.restored"
cmp -s "$TEST_TMP/fstab.original" "$TEST_TMP/fstab.restored" || fail "fstab block removal changed other lines"

# A marker alone must not swallow the following user entry.
printf '%s\n/data / ext4 defaults 0 1\n' "$RIG_FSTAB_MARKER" > "$RIG_FSTAB_PATH"
rig_fstab_without_managed_block > "$TEST_TMP/fstab.stray"
grep -qxF '/data / ext4 defaults 0 1' "$TEST_TMP/fstab.stray" || fail "stray marker removed a user line"

# --- fstab/swap detection ----------------------------------------------------
printf 'UUID=abc / ext4 defaults 0 1\n' > "$RIG_FSTAB_PATH"
! swapfile_in_fstab || fail "absent swap entry reported"
! swapfile_fstab_managed || fail "absent managed block reported"

printf '%s none swap sw 0 0\n' "$RIG_SWAPFILE_PATH" > "$RIG_FSTAB_PATH"
swapfile_in_fstab || fail "unmanaged swap entry not found"
! swapfile_fstab_managed || fail "unmanaged swap entry reported managed"

printf '%s\n%s none swap sw 0 0\n' "$RIG_FSTAB_MARKER" "$RIG_SWAPFILE_PATH" > "$RIG_FSTAB_PATH"
swapfile_fstab_managed || fail "managed swap block not detected"

printf 'Filename Type Size Used Priority\n/dev/zram0 partition 1 0 100\n%s file 2 0 -2\n' "$RIG_SWAPFILE_PATH" > "$RIG_PROC_SWAPS"
zram_is_active || fail "active zram0 not detected"
swapfile_is_active || fail "active swapfile not detected"

printf 'Filename Type Size Used Priority\n' > "$RIG_PROC_SWAPS"
! zram_is_active || fail "inactive zram0 reported active"
! swapfile_is_active || fail "inactive swapfile reported active"

printf '536870912\n' > "$RIG_ZRAM_SYSFS/disksize"
[[ "$(zram_active_size_mb)" == "512" ]] || fail "sysfs size conversion"
rm -f "$RIG_ZRAM_SYSFS/disksize"
! zram_active_size_mb || fail "missing sysfs size reported a value"

# --- platform mapping --------------------------------------------------------
( export OS_FAMILY=debian; [[ "$(zram_pkg_name)" == "systemd-zram-generator" ]] ) \
    || fail "Debian package mapping"
( export OS_FAMILY=fedora; [[ "$(zram_pkg_name)" == "zram-generator" ]] ) \
    || fail "Fedora package mapping"
( export OS_FAMILY=arch; [[ "$(zram_pkg_name)" == "zram-generator" ]] ) \
    || fail "Arch package mapping"
( export OS_FAMILY=macos; [[ -z "$(zram_pkg_name)" ]] ) \
    || fail "macOS should have no zram package"
! ( export OS_FAMILY=macos; zram_supported ) || fail "macOS should be unsupported"

# A stray marker cannot claim a nonadjacent user swap entry.
printf '%s\n/data / ext4 defaults 0 1\n%s none swap sw 0 0\n' "$RIG_FSTAB_MARKER" "$RIG_SWAPFILE_PATH" > "$RIG_FSTAB_PATH"
! swapfile_fstab_managed || fail "stray marker claimed unrelated swapfile"
rig_fstab_without_managed_block > "$TEST_TMP/stripped"
grep -qxF "$RIG_SWAPFILE_PATH none swap sw 0 0" "$TEST_TMP/stripped" || fail "user swap entry removed"
printf '%s\n%s /data ext4 defaults 0 1\n' "$RIG_FSTAB_MARKER" "$RIG_SWAPFILE_PATH" > "$RIG_FSTAB_PATH"
! swapfile_fstab_managed || fail "non-swap entry claimed as managed"

# Noninteractive applies preserve both kinds of unmanaged config. Managed
# files and absent files remain eligible for normal idempotent updates.
printf 'custom config\n' > "$RIG_ZRAM_CONFIG_PATH"
cp "$RIG_ZRAM_CONFIG_PATH" "$TEST_TMP/custom.original"
( export RIG_NON_INTERACTIVE=1; ! zram_confirm_config_replacement "$RIG_ZRAM_CONFIG_PATH" ) || fail "--yes accepted unmanaged config"
cmp -s "$RIG_ZRAM_CONFIG_PATH" "$TEST_TMP/custom.original" || fail "guard changed config"
zram_confirm_config_replacement "$TEST_TMP/absent" || fail "absent config rejected"
printf '%s\n' "$RIG_ZRAM_MARKER" > "$RIG_ZRAM_SYSCTL_PATH"
zram_confirm_config_replacement "$RIG_ZRAM_SYSCTL_PATH" || fail "managed config rejected"

# Exercise the real setup entry point, stopping before packages or sudo.
if ! is_macos; then
    mkdir -p "$TEST_TMP/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/bin/systemctl"
    printf '#!/bin/sh\necho unexpected mutation >> "$RIG_TEST_MUTATIONS"\nexit 1\n' > "$TEST_TMP/bin/sudo"
    chmod +x "$TEST_TMP/bin/systemctl" "$TEST_TMP/bin/sudo"
    export RIG_TEST_MUTATIONS="$TEST_TMP/mutations"
    for destination in "$RIG_ZRAM_CONFIG_PATH" "$RIG_ZRAM_SYSCTL_PATH"; do
        printf '%s\n' "$RIG_ZRAM_MARKER" > "$RIG_ZRAM_CONFIG_PATH"
        printf '%s\n' "$RIG_ZRAM_MARKER" > "$RIG_ZRAM_SYSCTL_PATH"
        printf 'custom config\n' > "$destination"
        if PATH="$TEST_TMP/bin:$PATH" RIG_CONFIG_FILE="$TEST_TMP/rig-config" RIG_ZRAM_ENABLE=yes \
            bash "$ROOT_DIR/setup-zram.sh" --yes > "$TEST_TMP/setup.log" 2>&1; then
            fail "setup accepted unmanaged $destination"
        fi
        grep -q 'Preserved unmanaged' "$TEST_TMP/setup.log" || fail "setup failed before checking config"
        cmp -s "$destination" "$TEST_TMP/custom.original" || fail "setup replaced unmanaged config"
        [[ ! -f "$RIG_TEST_MUTATIONS" ]] || fail "setup mutated system before config decision"
        [[ ! -f "$TEST_TMP/rig-config" ]] || fail "refused setup persisted policy"
    done
fi

echo "zram regression tests passed"
