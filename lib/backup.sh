#!/usr/bin/env bash
set -euo pipefail

# Guard against double-sourcing
[[ -n "${_LIB_BACKUP_LOADED:-}" ]] && return 0 || _LIB_BACKUP_LOADED=1

# Keep every Rig-created backup in one user-owned data tree. Separating source
# classes makes restores obvious without scattering files beside live configs.
RIG_BACKUP_DIR="${RIG_BACKUP_DIR:-$HOME/.local/share/rig/backups}"
RIG_USER_BACKUP_DIR="${RIG_USER_BACKUP_DIR:-$RIG_BACKUP_DIR/user}"
RIG_SYSTEM_BACKUP_DIR="${RIG_SYSTEM_BACKUP_DIR:-$RIG_BACKUP_DIR/system}"

rig_backup_slug() {
    printf '%s' "$1" | sed 's#^/##; s#/#__#g; s#[^A-Za-z0-9_.-]#_#g'
}

rig_user_backup() {
    local target="$1" tag="${2:-backup}" slug stamp dest
    [[ -e "$target" ]] || return 1
    slug="$(rig_backup_slug "$target")"
    stamp="$(date +%Y%m%d%H%M%S)"
    mkdir -p "$RIG_USER_BACKUP_DIR"
    chmod 700 "$RIG_USER_BACKUP_DIR"
    dest="$RIG_USER_BACKUP_DIR/${slug}.${tag}.${stamp}"
    cp -a "$target" "$dest"
    printf '%s\n' "$dest"
}

rig_system_backup() {
    local target="$1" tag="${2:-backup}" slug stamp dest owner
    sudo test -e "$target" || return 1
    slug="$(rig_backup_slug "$target")"
    stamp="$(date +%Y%m%d%H%M%S)"
    dest="$RIG_SYSTEM_BACKUP_DIR/${slug}.${tag}.${stamp}"
    mkdir -p "$RIG_SYSTEM_BACKUP_DIR"
    chmod 700 "$RIG_BACKUP_DIR" "$RIG_SYSTEM_BACKUP_DIR"
    sudo cp -a "$target" "$dest"
    owner="$(id -u):$(id -g)"
    sudo chown -R "$owner" "$dest"
    printf '%s\n' "$dest"
}

rig_system_backup_once() {
    local target="$1" tag="${2:-pre-rig}" slug dest owner
    sudo test -e "$target" || return 1
    slug="$(rig_backup_slug "$target")"
    dest="$RIG_SYSTEM_BACKUP_DIR/${slug}.${tag}"
    mkdir -p "$RIG_SYSTEM_BACKUP_DIR"
    chmod 700 "$RIG_BACKUP_DIR" "$RIG_SYSTEM_BACKUP_DIR"
    if [[ ! -e "$dest" ]]; then
        sudo cp -a "$target" "$dest"
        owner="$(id -u):$(id -g)"
        sudo chown -R "$owner" "$dest"
    fi
    printf '%s\n' "$dest"
}

rig_system_backup_once_path() {
    local target="$1" tag="${2:-pre-rig}"
    printf '%s/%s.%s\n' "$RIG_SYSTEM_BACKUP_DIR" "$(rig_backup_slug "$target")" "$tag"
}

rig_system_latest_backup() {
    local target="$1" tag="${2:-backup}" slug candidate latest=""
    slug="$(rig_backup_slug "$target")"
    [[ -d "$RIG_SYSTEM_BACKUP_DIR" ]] || return 1
    # Shell glob order follows the timestamped filenames and is portable to
    # macOS, whose BSD find does not support GNU find's -maxdepth option.
    for candidate in "$RIG_SYSTEM_BACKUP_DIR/${slug}.${tag}."*; do
        [[ -f "$candidate" ]] && latest="$candidate"
    done
    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}
