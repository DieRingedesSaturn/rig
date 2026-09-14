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

# rig_config_diff OLD NEW - Show a colorized unified diff of two config files.
rig_config_diff() {
    local old_file="$1" new_file="$2"
    echo ""
    echo "─── Configuration Diff (- existing / + recommended) ───"
    if command -v git >/dev/null 2>&1; then
        git diff --no-index --color=always "$old_file" "$new_file" || true
    elif diff --help 2>&1 | grep -q -- '--color'; then
        diff -u --color=always "$old_file" "$new_file" || true
    else
        diff -u "$old_file" "$new_file" || true
    fi
    echo "───────────────────────────────────────────────────────"
}

# rig_offer_config_baseline TARGET BASELINE_FILE TAG
# Shared "existing config vs recommended baseline" decision flow: when TARGET
# differs, show the diff and — whenever a controlling terminal exists (this
# also works under `curl | bash` via /dev/tty) — offer keep / overwrite /
# append / diff. Overwrite and append take a timestamped backup first.
# Non-interactive runs and "keep" leave TARGET untouched.
rig_offer_config_baseline() {
    local target="$1" baseline="$2" tag="${3:-config}" choice backup
    [[ -f "$target" && -f "$baseline" ]] || return 0
    if cmp -s "$target" "$baseline"; then
        echo "  ✔ $target already matches the recommended baseline."
        return 0
    fi

    echo ""
    echo "  Notice: $target differs from the recommended baseline."
    rig_config_diff "$target" "$baseline"

    if ! rig_can_prompt; then
        echo "  Non-interactive terminal: keeping existing $target untouched (default)."
        return 0
    fi

    echo ""
    echo "How would you like to handle your existing $target?"
    echo "  [k] Keep existing configuration unchanged (default / safe)"
    echo "  [o] Overwrite with recommended baseline (creates a Rig backup)"
    echo "  [a] Append recommended baseline settings to end of file"
    echo "  [d] Show diff again"
    while true; do
        read -r -p "Choice [K/o/a/d]: " choice </dev/tty || choice="k"
        choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
        case "$choice" in
            o|overwrite)
                backup="$(rig_user_backup "$target" "$tag")"
                cat "$baseline" > "$target"
                echo "  ✔ Backed up existing config to: $backup"
                echo "  ✔ Overwrote $target with recommended baseline."
                return 0
                ;;
            a|append)
                backup="$(rig_user_backup "$target" "$tag")"
                {
                    echo ""
                    echo "# --- Appended by rig on $(date '+%Y-%m-%d %H:%M:%S') ---"
                    cat "$baseline"
                } >> "$target"
                echo "  ✔ Backed up existing config to: $backup"
                echo "  ✔ Appended baseline settings to $target."
                return 0
                ;;
            d|diff)
                rig_config_diff "$target" "$baseline"
                ;;
            ""|k|keep)
                echo "  Keeping existing $target untouched."
                return 0
                ;;
            *)
                echo "  Invalid choice: please enter k, o, a, or d."
                ;;
        esac
    done
}
