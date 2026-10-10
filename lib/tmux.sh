#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Tmux Baseline Generator
# https://github.com/DieRingedesSaturn/rig
#
# Builds the tmux.conf rig writes for a host. Everything is decided once, at
# setup time: the installed tmux version and the clipboard helper this session
# calls for (lib/tools.sh) pick the emitted lines, so the generated file
# contains no runtime version or environment checks.
#
# Must be sourced after lib/os-detect.sh.
#
# Exported functions:
#   tmux_parse_version       - "tmux 3.2a" → "3.2"
#   tmux_version             - installed tmux MAJOR.MINOR, or "0.0"
#   tmux_default_terminal    - terminfo-aware default-terminal value
#   tmux_clipboard_command   - abstract tool → command line for copy-pipe
#   tmux_baseline            - print the full baseline config to stdout
#   tmux_config_advisories   - warn about options the installed tmux rejects
# =============================================================================

if [[ -n "${_LIB_TMUX_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_LIB_TMUX_LOADED=1

if [[ -z "${OS_FAMILY:-}" ]]; then
    echo "Error: lib/tmux.sh requires lib/os-detect.sh to be sourced first." >&2
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# tmux_parse_version RAW - First MAJOR.MINOR in `tmux -V` output.
# "tmux 3.2a" → 3.2, "tmux next-3.6" → 3.6. A build reporting no number at
# all ("tmux master") is newer than any release → 99.0.
tmux_parse_version() {
    local raw="$1"
    if [[ "$raw" =~ [0-9]+\.[0-9]+ ]]; then
        printf '%s\n' "${BASH_REMATCH[0]}"
    elif [[ "$raw" == tmux\ * ]]; then
        printf '99.0\n'
    else
        printf '0.0\n'
    fi
}

# tmux_version - MAJOR.MINOR of the installed tmux, or "0.0" when absent.
tmux_version() {
    tmux_parse_version "$(tmux -V 2>/dev/null || true)"
}

# tmux_default_terminal - "tmux-256color" when the terminfo entry exists
# (modern ncurses ships it), otherwise the universally present
# "screen-256color".
tmux_default_terminal() {
    if command -v infocmp >/dev/null 2>&1 && infocmp tmux-256color >/dev/null 2>&1; then
        printf 'tmux-256color\n'
    else
        printf 'screen-256color\n'
    fi
}

# tmux_clipboard_command TOOL - Command line a copy-pipe binding should run.
# Empty when TOOL is empty or unknown (headless host).
tmux_clipboard_command() {
    case "$1" in
        pbcopy)  printf 'pbcopy\n' ;;
        wl-copy) printf 'wl-copy\n' ;;
        xclip)   printf 'xclip -selection clipboard\n' ;;
        *)       printf '\n' ;;
    esac
}

# tmux_baseline VERSION CLIPBOARD CONF_PATH [MOUSE=1] [HISTORY=100000] [DEFAULT_TERM]
# Print the recommended tmux.conf for this host. CLIPBOARD is
# pbcopy|wl-copy|xclip or empty for a headless host. DEFAULT_TERM empty means
# auto-detect via tmux_default_terminal.
tmux_baseline() {
    local version="$1" clipboard="$2" conf_path="$3"
    local mouse="${4:-1}" history="${5:-100000}" default_term="${6:-}"
    local tier cmd

    if rig_version_ge "$version" 3.2; then
        tier=">= 3.2"
    else
        tier="< 3.2"
    fi
    cmd="$(tmux_clipboard_command "$clipboard")"
    if [[ -z "$default_term" ]]; then
        default_term="$(tmux_default_terminal)"
    fi

    cat <<'EOF'
# Rig Tmux Baseline
EOF
    if [[ -n "$cmd" ]]; then
        printf '# Profile: tmux %s, clipboard: %s\n' "$tier" "$cmd"
    else
        printf '# Profile: tmux %s, clipboard: OSC 52 (headless)\n' "$tier"
    fi
    cat <<'EOF'
# extended-keys is left off on purpose: apps that do not negotiate CSI-u
# (e.g. nvim < 0.10) would receive raw sequences such as "^[[106;5u".

# ─── General ───
EOF
    printf 'set -g default-terminal "%s"\n' "$default_term"
    if rig_version_ge "$version" 3.2; then
        echo 'set -as terminal-features ",*:RGB"'
    else
        echo 'set -as terminal-overrides ",*:Tc"'
    fi
    cat <<'EOF'
set -g focus-events on
set -sg escape-time 10
EOF
    if [[ "$mouse" == "1" ]]; then
        echo 'set -g mouse on'
    fi
    printf 'set -g history-limit %s\n' "$history"
    cat <<'EOF'
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# ─── Key bindings ───
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi C-v send -X rectangle-toggle
EOF
    if [[ -z "$cmd" ]]; then
        echo 'bind -T copy-mode-vi y send -X copy-selection-and-cancel'
    elif rig_version_ge "$version" 3.2; then
        # copy-pipe with no argument uses the copy-command set below.
        echo 'bind -T copy-mode-vi y send -X copy-pipe-and-cancel'
    else
        printf 'bind -T copy-mode-vi y send -X copy-pipe-and-cancel "%s"\n' "$cmd"
    fi
    printf 'bind r source-file %s \\; display-message "tmux config reloaded"\n' "$conf_path"
    cat <<'EOF'
bind | split-window -h
bind - split-window -v

# ─── Status line ───
set -g status-interval 5
set -g status-left-length 40
set -g status-right-length 120
set -g status-left "#[bold][#S]"
set -g status-right "%Y-%m-%d %H:%M"

# ─── Clipboard ───
# set-clipboard on: copies also leave via OSC 52, and OSC 52 from programs
# inside tmux (e.g. Neovim on a headless host) is forwarded to the terminal.
set -g set-clipboard on
EOF
    if [[ -n "$cmd" ]]; then
        printf '# y, Enter and mouse-drag copies are piped to %s.\n' "$cmd"
        if rig_version_ge "$version" 3.2; then
            printf 'set -s copy-command "%s"\n' "$cmd"
        else
            printf 'bind -T copy-mode-vi Enter send -X copy-pipe-and-cancel "%s"\n' "$cmd"
            printf 'bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "%s"\n' "$cmd"
        fi
    fi
}

# tmux_config_advisories CONF VERSION - Warnings about an existing config that
# the installed tmux cannot honour. One "  [!] ..." line per finding; nothing
# when the file is fine. Comment lines are ignored.
tmux_config_advisories() {
    local conf="$1" version="$2"
    local active i
    [[ -f "$conf" ]] || return 0
    active="$(grep -vE '^[[:space:]]*#' "$conf" 2>/dev/null || true)"
    [[ -n "$active" ]] || return 0

    # Options that only exist above a given tmux release; older releases exit
    # with "invalid option" when they meet them. Keep name/minimum parallel —
    # bash 3.2 has no associative arrays.
    local names=(terminal-features copy-command extended-keys allow-passthrough extended-keys-format)
    local mins=(3.2 3.2 3.2 3.3 3.5)

    for ((i = 0; i < ${#names[@]}; i++)); do
        local name="${names[$i]}" min="${mins[$i]}"
        rig_version_ge "$version" "$min" && continue
        # Whole word: extended-keys must not match extended-keys-format.
        if printf '%s\n' "$active" | grep -E "(^|[[:space:]])${name}([[:space:]]|$)" >/dev/null 2>&1; then
            printf '  [!] %s needs tmux >= %s (this host has %s); tmux reports "invalid option" for it\n' \
                "$name" "$min" "$version"
        fi
    done

    # A copy-pipe binding in the emacs 'copy-mode' table is dead code when
    # mode-keys is vi — copy-mode-vi is the table copy mode actually uses.
    if printf '%s\n' "$active" | grep -E 'mode-keys[[:space:]]+vi([[:space:]]|$)' >/dev/null 2>&1 \
        && printf '%s\n' "$active" | grep -E -e '-T[[:space:]]*copy-mode[[:space:]]' | grep -q 'copy-pipe'; then
        printf '  [!] copy-pipe is bound in the emacs %s table but mode-keys is vi, so it never runs — bind it in %s (or use copy-command on tmux >= 3.2)\n' \
            "'copy-mode'" "'copy-mode-vi'"
    fi
}
