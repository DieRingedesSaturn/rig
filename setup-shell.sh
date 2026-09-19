#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Shell Environment Setup (lightweight)
# https://github.com/DieRingedesSaturn/rig
#
# zsh + Starship + autosuggestions + syntax-highlighting, taken from the distro
# package manager. No Oh My Zsh, no framework, no git clones, no curl|sh for
# anything the distro already packages.
#
# Non-negotiable contract — nothing is ever changed silently:
#
#   ~/.zshrc                  never edited by default; missing init lines are
#                             appended only after an explicit y/N confirmation
#                             plus a timestamped backup
#   ~/.config/starship.toml   created when absent; an existing file is only
#                             replaced after explicit interactive confirmation
#                             plus a timestamped backup
#   default login shell       reported, changed only after explicit y/N
#                             confirmation (chsh)
#
# Without a usable /dev/tty the script stays fully read-only and prints a
# checklist at the end instead of being done behind your back.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

ZSHRC="$HOME/.zshrc"
STARSHIP_TOML="$HOME/.config/starship.toml"
MISSING_ZSHRC=()
NOT_INSTALLED=()

echo "=== Shell Environment Setup (lightweight) ==="
echo "  platform: $OS_DISTRO ($OS_FAMILY, $PKG_MANAGER)"
echo ""

# --- [1/5] Packages ----------------------------------------------------------

echo "[1/5] Installing packages..."

if is_macos; then
    # zsh and curl ship with macOS; Homebrew is only used for what follows.
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is missing on macOS." >&2
        exit 1
    fi
    echo "  zsh + curl are built in on macOS"
else
    pkg_install zsh curl
fi

if ! command -v zsh >/dev/null 2>&1; then
    echo "Error: zsh is still not available after installation." >&2
    exit 1
fi
echo "  zsh: $(command -v zsh) ($(zsh --version 2>/dev/null | awk '{print $2}'))"

# Starship and the two plugins come from the distro when it packages them.
# A package that is missing is not fatal: Starship has an upstream installer
# (step 2) and the plugin report at the end says what to do.
for pkg in starship zsh-autosuggestions zsh-syntax-highlighting; do
    if [[ -z "$(pkg_map "$pkg")" ]]; then
        echo "  not packaged on $OS_FAMILY: $pkg"
    elif pkg_check_installed "$pkg"; then
        echo "  already installed: $pkg"
    elif pkg_install "$pkg" >/dev/null 2>&1; then
        echo "  installed: $pkg"
    else
        echo "  unavailable from $PKG_MANAGER: $pkg"
    fi
done

# --- [2/5] Starship ----------------------------------------------------------

echo ""
echo "[2/5] Ensuring Starship..."

if command -v starship >/dev/null 2>&1; then
    echo "  found: $(command -v starship)"
else
    # Not packaged — the upstream installer is the only route on old Debian
    # (https://starship.rs/guide). It pipes a remote script to sh, so ask first;
    # it lands in ~/.local/bin and needs no sudo.
    echo "  not packaged on $OS_DISTRO."
    ss_reply="n"
    if rig_can_prompt; then
        read -r -p "  Install via the upstream installer (https://starship.rs/install.sh → ~/.local/bin)? [y/N] " ss_reply </dev/tty || ss_reply="n"
    else
        echo "  Non-interactive: skipping. Manual: curl -sS https://starship.rs/install.sh | sh -s -- -y -b ~/.local/bin"
    fi
    if [[ "$ss_reply" =~ ^[Yy] ]]; then
        mkdir -p "$HOME/.local/bin"
        if curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" >/dev/null 2>&1 \
            && [[ -x "$HOME/.local/bin/starship" ]]; then
            echo "  installed: $HOME/.local/bin/starship"
            case ":$PATH:" in
                *":$HOME/.local/bin:"*) ;;
                *) echo "  NOTE: $HOME/.local/bin is not on your PATH — add it to your shell rc" ;;
            esac
        else
            echo "  WARNING: Starship could not be installed — see https://starship.rs" >&2
        fi
    fi
fi

# --- [3/5] Locate the zsh plugins -------------------------------------------

# Package managers disagree about where these land, so probe a candidate list
# instead of hardcoding one path per distro.

plugin_candidates() {
    local name="$1" file="$2"
    case "$OS_FAMILY" in
        macos)
            echo "/opt/homebrew/share/${name}/${file}"  # Apple Silicon
            echo "/usr/local/share/${name}/${file}"     # Intel
            ;;
        arch)
            echo "/usr/share/zsh/plugins/${name}/${file}"
            echo "/usr/share/${name}/${file}"
            ;;
        *)
            echo "/usr/share/${name}/${file}"
            echo "/usr/local/share/${name}/${file}"
            ;;
    esac
}

find_plugin() {
    local name="$1" file="$2" candidate
    while IFS= read -r candidate; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done < <(plugin_candidates "$name" "$file")
    return 1
}

echo ""
echo "[3/5] Locating zsh plugins..."
AUTOSUGGEST_FILE="$(find_plugin zsh-autosuggestions zsh-autosuggestions.zsh || true)"
SYNTAX_FILE="$(find_plugin zsh-syntax-highlighting zsh-syntax-highlighting.zsh || true)"

if [[ -n "$AUTOSUGGEST_FILE" ]]; then
    echo "  zsh-autosuggestions:     $AUTOSUGGEST_FILE"
else
    echo "  zsh-autosuggestions:     not found"
fi
if [[ -n "$SYNTAX_FILE" ]]; then
    echo "  zsh-syntax-highlighting: $SYNTAX_FILE"
else
    echo "  zsh-syntax-highlighting: not found"
fi

# --- [4/5] Starship configuration -------------------------------------------

# Created when absent. An existing config is yours — it is only replaced after
# an explicit interactive choice (keep/overwrite/append), with a backup first.

echo ""
echo "[4/5] Starship configuration..."
TMP_STARSHIP="$(mktemp)"
cat > "$TMP_STARSHIP" <<'EOF'
# Starship configuration — reference: https://starship.rs/config/

format = """
$hostname$directory$git_branch$git_status$python$conda$nodejs$time
$character"""

[hostname]
ssh_only = true
format = "[ssh:$hostname]($style) "
style = "bold dimmed red"

[directory]
truncation_length = 3
truncate_to_repo = true
style = "bold cyan"
read_only = " 🔒"

[time]
disabled = false
time_format = "%R"
format = "[\\[$time\\]]($style) "
style = "bright-black"

[python]
disabled = false
format = "[$symbol$version( \\($virtualenv\\))]($style) "
symbol = "🐍 "
style = "bold yellow"

[conda]
disabled = false
format = "[$symbol$environment]($style) "
symbol = "📦 "
style = "bold green"

[nodejs]
disabled = false
format = "[$symbol($version )]($style)"
symbol = "⬢ "
style = "bold green"
EOF

if [[ -f "$STARSHIP_TOML" ]]; then
    rig_offer_config_baseline "$STARSHIP_TOML" "$TMP_STARSHIP" starship
else
    mkdir -p "$(dirname "$STARSHIP_TOML")"
    cat "$TMP_STARSHIP" > "$STARSHIP_TOML"
    echo "  created default $STARSHIP_TOML"
fi
rm -f "$TMP_STARSHIP"

# --- [5/5] Read-only check of your shell configuration ----------------------

echo ""
echo "[5/5] Checking your shell configuration (read-only)..."

# Read-only inspection helpers for $ZSHRC. Comment lines are ignored so a
# commented-out entry is never mistaken for an active one.
rc_lines() {
    grep -n "$1" "$ZSHRC" 2>/dev/null | grep -v ':[[:space:]]*#' || true
}
rc_has()  { [[ -f "$ZSHRC" ]] && [[ -n "$(rc_lines "$1")" ]]; }
rc_line() { rc_lines "$1" | head -1 | cut -d: -f1; }

check_plugin() {
    local name="$1" file="$2"
    if [[ -z "$file" ]]; then
        echo "  [$name] not found on disk — install package '$name' for $OS_DISTRO"
        NOT_INSTALLED+=("$name")
    elif rc_has "$name"; then
        echo "  [$name] installed and loaded by .zshrc"
    else
        echo "  [$name] installed at $file but NOT loaded by .zshrc"
        MISSING_ZSHRC+=("source $file")
    fi
    return 0
}

check_plugin zsh-autosuggestions "$AUTOSUGGEST_FILE"
check_plugin zsh-syntax-highlighting "$SYNTAX_FILE"

if rc_has 'starship init'; then
    echo "  [starship] initialized in .zshrc"
    # A wired-up line can still be dead code: flag an earlier return/exit and
    # a binary whose init script fails to render (e.g. wrong arch, broken).
    if command -v starship >/dev/null 2>&1 && ! starship init zsh >/dev/null 2>&1; then
        echo "  ⚠ 'starship init zsh' fails to run — the binary may be broken"
    fi
    awk -v s="$(rc_line 'starship init')" \
        'NR < s && /^[[:space:]]*(return|exit)[[:space:]]/ {printf "  ⚠ line %d runs before starship init and may skip it: %s\n", NR, $0}' \
        "$ZSHRC"
else
    echo "  [starship] init line NOT present in .zshrc"
    MISSING_ZSHRC+=('eval "$(starship init zsh)"')
fi

# A promptinit theme (`prompt adam1` ships in Debian's newuser .zshrc)
# registers a precmd hook that rewrites PROMPT every draw and wins over
# starship — appending 'prompt off' does NOT help, because its cleanup also
# removes starship's hook. The theme line itself must be commented out.
# Stored as "lineno:content"; handled in the report section.
ZSHRC_PROMPT_CONFLICT=""
if rc_has 'starship init'; then
    ZSHRC_PROMPT_CONFLICT="$(rc_lines 'prompt' \
        | grep -E ':[[:space:]]*prompt[[:space:]]+[a-zA-Z]' \
        | grep -vE ':[[:space:]]*prompt[[:space:]]+(off|-[a-zA-Z]+)([[:space:]]|$)' \
        | head -1 || true)"
fi

# Advisory: upstream requires zsh-syntax-highlighting to be sourced last,
# because it wraps the ZLE line editor. Anything sourcing after it can end up
# bypassing the highlighting widget.
if [[ -n "$SYNTAX_FILE" && -f "$ZSHRC" ]]; then
    syntax_line="$(rc_line 'zsh-syntax-highlighting')"
    if [[ -n "$syntax_line" ]]; then
        later="$(awk -v s="$syntax_line" 'NR > s && (/zsh-autosuggestions/ || /starship init/)' "$ZSHRC" | wc -l | tr -d ' ')"
        if [[ "$later" -gt 0 ]]; then
            echo ""
            echo "  note: zsh-syntax-highlighting is sourced at line $syntax_line, but"
            echo "        $later later line(s) load autosuggestions/starship after it."
            echo "        Upstream recommends it be sourced last. Optional to change."
        fi
    fi
fi

# Force the emacs line-editing keymap unless the user already picked one:
# zsh switches ZLE to vi mode whenever EDITOR/VISUAL contains "vi" (nvim
# counts), which silently breaks Ctrl+A/Ctrl+E readline bindings.
if ! grep -q 'bindkey -[ev]' "$ZSHRC" 2>/dev/null; then
    MISSING_ZSHRC+=('bindkey -e  # emacs keymap: EDITOR may contain "vi" (nvim)')
fi

# Pasting a command block that contains '# comments' fails on a stock zsh:
# without interactive_comments the '#' is parsed as a command/word.
if ! grep -q 'interactive_comments\|interactivecomments' "$ZSHRC" 2>/dev/null; then
    MISSING_ZSHRC+=('setopt interactive_comments  # allow # comments when pasting commands')
fi

# Basic color support: the distro .bashrc in /etc/skel sets these, but a zsh
# user switching shells loses ls/grep colors entirely. BSD/macOS ls has no
# --color; it uses CLICOLOR + -G instead.
if ! grep -qE 'color=auto|CLICOLOR' "$ZSHRC" 2>/dev/null; then
    if is_macos; then
        MISSING_ZSHRC+=('export CLICOLOR=1')
        MISSING_ZSHRC+=("alias ls='ls -G'")
    else
        MISSING_ZSHRC+=('eval "$(dircolors -b 2>/dev/null)"')
        MISSING_ZSHRC+=("alias ls='ls --color=auto'")
        MISSING_ZSHRC+=("alias ll='ls -alF'")
        MISSING_ZSHRC+=("alias la='ls -A'")
        MISSING_ZSHRC+=("alias grep='grep --color=auto'")
    fi
fi

# --- Report ------------------------------------------------------------------

echo ""
if [[ "${#MISSING_ZSHRC[@]}" -eq 0 && "${#NOT_INSTALLED[@]}" -eq 0 ]]; then
    echo "  ✔ Everything is already wired up in $ZSHRC — nothing to add."
else
    if [[ "${#NOT_INSTALLED[@]}" -gt 0 ]]; then
        echo "  Not installed on this machine: ${NOT_INSTALLED[*]}"
        echo "  Your $ZSHRC may already reference them — those lines fail until installed."
    fi
    if [[ "${#MISSING_ZSHRC[@]}" -gt 0 ]]; then
        if rig_can_prompt; then
            echo "  $ZSHRC is missing the lines below:"
            for line in "${MISSING_ZSHRC[@]}"; do
                echo "      $line"
            done
            printf "  Append them to %s? [y/N] " "$ZSHRC"
            read -r answer </dev/tty || answer="n"
            if [[ "$answer" == [yY]* ]]; then
                if [[ -f "$ZSHRC" ]]; then
                    rig_user_backup "$ZSHRC" zshrc >/dev/null 2>&1 || true
                fi
                # zsh-syntax-highlighting must be sourced last — it wraps ZLE
                # widgets and later loads can bypass it.
                {
                    echo ""
                    echo "# Added by rig setup-shell"
                    for line in "${MISSING_ZSHRC[@]}"; do
                        [[ "$line" == *zsh-syntax-highlighting* ]] || echo "$line"
                    done
                    for line in "${MISSING_ZSHRC[@]}"; do
                        [[ "$line" == *zsh-syntax-highlighting* ]] && echo "$line"
                    done
                } >>"$ZSHRC"
                echo "  ✔ Appended to $ZSHRC (backup taken if the file existed)."
            else
                echo "  Kept as-is. Add them yourself if you change your mind."
            fi
        else
            echo "  Add these lines to $ZSHRC yourself; this script does not edit it:"
            for line in "${MISSING_ZSHRC[@]}"; do
                echo "      $line"
            done
        fi
    fi
fi

if [[ -n "$ZSHRC_PROMPT_CONFLICT" ]]; then
    cln="${ZSHRC_PROMPT_CONFLICT%%:*}"
    cline="${ZSHRC_PROMPT_CONFLICT#*:}"
    echo ""
    printf "  ⚠ line %s of %s loads a zsh prompt theme that overrides starship:\n" "$cln" "$ZSHRC"
    echo "      $cline"
    if rig_can_prompt; then
        printf "  Comment it out so starship takes over? [y/N] "
        read -r answer </dev/tty || answer="n"
        if [[ "$answer" == [yY]* ]]; then
            rig_user_backup "$ZSHRC" zshrc >/dev/null 2>&1 || true
            sed -i "${cln}s/^[[:space:]]*/# rig-disabled: /" "$ZSHRC"
            echo "  ✔ Commented out (backup taken). Takes effect in a new zsh."
        else
            echo "  Kept — the prompt theme will keep hiding starship."
        fi
    else
        echo "    Comment out that line to let starship render."
    fi
fi

echo ""
current_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || true)"
[[ -z "$current_shell" ]] && current_shell="${SHELL:-unknown}"
if [[ "$current_shell" == *zsh ]]; then
    echo "  ✔ default login shell: $current_shell"
else
    zsh_path="$(command -v zsh || true)"
    if [[ -n "$zsh_path" ]] && rig_can_prompt; then
        printf "  Default login shell is %s. Change it to %s? [y/N] " "$current_shell" "$zsh_path"
        read -r answer </dev/tty || answer="n"
        if [[ "$answer" == [yY]* ]]; then
            if sudo -n chsh -s "$zsh_path" "$USER" 2>/dev/null || chsh -s "$zsh_path" </dev/tty 2>/dev/null; then
                echo "  ✔ Login shell changed to $zsh_path (applies on next login)."
            else
                echo "  ✘ chsh failed — run it yourself: chsh -s $zsh_path"
            fi
        else
            echo "  Kept $current_shell. To change later: chsh -s $zsh_path"
        fi
    else
        echo "  ✘ default login shell: $current_shell (not zsh)"
        echo "    Not changed automatically — run this yourself:"
        echo "        chsh -s $zsh_path"
    fi
fi

echo ""
echo "=== Done ==="
