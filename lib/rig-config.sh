#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Rig Configuration File Library
# https://github.com/DieRingedesSaturn/rig
#
# Reads ~/.config/rig/config — a small shell-syntax settings file:
#
#   RIG_PROFILE="desktop"
#   RIG_CONTAINER_ENGINE="auto"
#   RIG_CONTAINER_MODE="rootless"
#   RIG_CLIPBOARD_TOOL="auto"
#   RIG_COMPONENTS="
#   shell
#   tmux
#   containers
#   "
#
# The file is PARSED, never sourced, so a malformed line can not execute
# anything or clobber the caller's shell.
#
# Precedence for every key (highest first):
#   1. environment variable of the same name   (RIG_CONTAINER_ENGINE=docker rig install)
#   2. the config file
#   3. the caller's default
#
# Exported functions:
#   rig_config_file            - Print the config file path in use
#   rig_config_get KEY [DEF]   - Resolve one key to stdout
#   rig_config_set KEY VALUE   - Atomically persist one known key
#   rig_config_list KEY [DEF]  - Resolve a list key to space-separated stdout
#   rig_config_show            - Human-readable dump of every known key
# =============================================================================

# Guard against double-sourcing
if [[ -n "${_RIG_CONFIG_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_RIG_CONFIG_LOADED=1

# Keys this library understands. Anything else in the file is ignored.
RIG_CONFIG_KEYS=(
    RIG_PROFILE
    RIG_CONTAINER_ENGINE
    RIG_CONTAINER_MODE
    RIG_COMPONENTS
    RIG_CLIPBOARD_TOOL
    RIG_ADMIN_USER
    RIG_SSH_PORT
    RIG_SSH_ROOT_LOGIN
    RIG_SSH_PASSWORD_AUTH
    RIG_SSH_PUBKEY_AUTH
    RIG_SSH_ACCESS
    RIG_FIREWALL
    RIG_FIREWALL_DEFAULT_IN
    RIG_FIREWALL_DEFAULT_OUT
    RIG_PUBLIC_TCP
    RIG_PUBLIC_UDP
    RIG_CHECK_LISTENING_PORTS
    RIG_WARN_UNDECLARED_PORTS
)

# rig_config_file - Print the path of the config file in use.
rig_config_file() {
    printf '%s\n' "${RIG_CONFIG_FILE:-$HOME/.config/rig/config}"
}

rig_config_key_is_known() {
    local wanted="$1" key
    for key in "${RIG_CONFIG_KEYS[@]}"; do
        [[ "$key" == "$wanted" ]] && return 0
    done
    return 1
}

# rig_config_get <KEY> [default] - Resolve one key to stdout.
rig_config_get() {
    local key="$1"
    local default="${2:-}"

    if ! rig_config_key_is_known "$key"; then
        printf 'rig: unknown configuration key: %s\n' "$key" >&2
        return 1
    fi

    # 1. environment override. An explicitly empty value is meaningful for
    # list settings such as RIG_PUBLIC_UDP, so test existence, not content.
    if declare -p "$key" >/dev/null 2>&1; then
        printf '%s\n' "${!key}"
        return 0
    fi

    # 2. config file
    local file
    file="$(rig_config_file)"
    if [[ ! -f "$file" ]]; then
        printf '%s\n' "$default"
        return 0
    fi

    # Extract the raw text after `KEY=`, tolerating a value that spans several
    # lines inside a quoted string. Comments and blank lines are skipped, and
    # only the last assignment wins (matching shell semantics).
    if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
        printf '%s\n' "$default"
        return 0
    fi

    local raw
    raw="$(awk -v key="$key" '
        # Count occurrences of a character in a string.
        function countch(s, ch,   n, i) {
            n = 0
            for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
            return n
        }
        BEGIN { dq = sprintf("%c", 34); sq = sprintf("%c", 39) }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $0 !~ ("^[[:space:]]*" key "[[:space:]]*=") { next }
        {
            line = $0
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
            # An odd number of quotes means the value continues on later lines,
            # which is how a multi-line RIG_COMPONENTS="..." block is written.
            if (countch(line, dq) % 2 == 1) {
                buf = line
                while ((getline more) > 0) {
                    buf = buf "\n" more
                    if (countch(buf, dq) % 2 == 0) break
                }
                line = buf
            } else if (countch(line, sq) % 2 == 1) {
                buf = line
                while ((getline more) > 0) {
                    buf = buf "\n" more
                    if (countch(buf, sq) % 2 == 0) break
                }
                line = buf
            }
            val = line
        }
        END { print val }
    ' "$file" 2>/dev/null || true)"

    # Strip one layer of surrounding quotes and trailing whitespace.
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw%\"}"; raw="${raw#\"}"
    raw="${raw%\'}"; raw="${raw#\'}"

    printf '%s\n' "$raw"
}

# rig_config_set <KEY> <VALUE> - Atomically persist one known key.
# The config parser deliberately does not evaluate shell syntax, so values are
# restricted to one line and stored as a simple double-quoted assignment.
rig_config_set() {
    local key="$1"
    local value="${2-}"
    local file dir tmp

    if ! rig_config_key_is_known "$key"; then
        printf 'rig: refusing to write unknown configuration key: %s\n' "$key" >&2
        return 1
    fi
    case "$value" in
        *$'\n'*|*$'\r'*|*'"'*)
            printf 'rig: configuration value for %s contains unsupported characters\n' "$key" >&2
            return 1
            ;;
    esac

    file="$(rig_config_file)"
    dir="$(dirname "$file")"
    mkdir -p "$dir"
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    chmod 600 "$tmp"

    if [[ -f "$file" ]]; then
        awk -v key="$key" '
            function countch(s, ch, n, i) {
                n = 0
                for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
                return n
            }
            BEGIN { dq = sprintf("%c", 34); sq = sprintf("%c", 39); skip = 0; quote = "" }
            skip {
                if (countch($0, quote) % 2 == 1) { skip = 0; quote = "" }
                next
            }
            $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
                line = $0
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
                if (countch(line, dq) % 2 == 1) { skip = 1; quote = dq }
                else if (countch(line, sq) % 2 == 1) { skip = 1; quote = sq }
                next
            }
            { print }
        ' "$file" > "$tmp"
    fi

    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
}

# rig_config_list <KEY> [default] - Resolve a list key to a space-separated line.
# Newlines and commas are treated as separators, so both of these work:
#   RIG_COMPONENTS="shell tmux git"
#   RIG_COMPONENTS="
#   shell
#   tmux
#   "
rig_config_list() {
    local raw
    raw="$(rig_config_get "$1" "${2:-}")"
    printf '%s\n' "$raw" | tr ',\n\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# rig_config_show - Print every known key and its resolved value.
# Lists are printed space-separated on one line.
rig_config_show() {
    local file key
    file="$(rig_config_file)"
    printf 'config file: %s' "$file"
    if [[ -f "$file" ]]; then
        printf ' (present)\n'
    else
        printf ' (absent — using defaults)\n'
    fi
    for key in "${RIG_CONFIG_KEYS[@]}"; do
        printf '  %-22s = %s\n' "$key" "$(rig_config_get "$key" '')"
    done
}
