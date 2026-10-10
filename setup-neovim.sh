#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Neovim Setup (modern lightweight terminal configuration)
# https://github.com/DieRingedesSaturn/rig
#
# Installs Neovim (ensuring >= 0.9, falling back to the official binary
# release when the distro package is too old), sets default system editor,
# configures alias vim=nvim, and writes a dependency-free init.lua decided
# for this machine (desktop clipboard helper vs headless OSC 52).
#
# Non-negotiable contract:
#   ~/.config/nvim/init.lua   created when absent; an existing file is only
#                             replaced after explicit interactive confirmation
#                             plus a timestamped backup (never silently)
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
# shellcheck source=lib/tools.sh
source "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=lib/neovim.sh
source "$SCRIPT_DIR/lib/neovim.sh"

NVIM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
NVIM_INIT_LUA="$NVIM_CONFIG_DIR/init.lua"
NVIM_INIT_VIM="$NVIM_CONFIG_DIR/init.vim"
NVIM_STATIC_USED=0

echo "=== Neovim Environment Setup ==="
echo "  platform: $OS_DISTRO ($OS_FAMILY, $PKG_MANAGER)"
echo ""

# --- [1/4] Install Neovim ----------------------------------------------------
echo "[1/4] Ensuring Neovim (>= 0.9)..."

# A rig-managed static build may already exist but be invisible when
# ~/.local/bin is not on PATH yet — prefer it over downloading again.
if nvim_is_static && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    PATH="$HOME/.local/bin:$PATH"
    hash -r
fi

_nvim_ok() {
    command -v nvim >/dev/null 2>&1 && rig_version_ge "$(nvim_version)" 0.9
}

if ! _nvim_ok; then
    echo "  Installing Neovim via package manager..."
    if ! pkg_check_installed neovim; then
        pkg_install neovim || true
    fi
fi

# Fallback: when the distro package is missing or older than 0.9, install the
# official binary release (Linux only — macOS has no official tarball here).
if ! _nvim_ok && ! is_macos; then
    echo "  Distro Neovim is missing or < 0.9. Fetching the official release..."
    if nvim_static_install; then
        NVIM_STATIC_USED=1
    else
        echo "  official build could not be installed (see above)"
    fi
fi

if ! _nvim_ok; then
    {
        echo "  Error: Neovim >= 0.9 is required; found: $(command -v nvim 2>/dev/null || echo none) $(nvim_version)"
        echo "  Hint: install it manually from https://github.com/neovim/neovim/releases"
        echo "        (set GH_PROXY to an https:// mirror prefix if GitHub is unreachable)"
    } >&2
    exit 1
fi

NVIM_BIN="$(command -v nvim)"
echo "  Neovim active: $NVIM_BIN ($(nvim --version | head -1))"

if [[ "$NVIM_STATIC_USED" == "1" ]] && type -ap nvim 2>/dev/null | grep -vF "$NVIM_BIN" | grep -q .; then
    echo "  note: another nvim exists on PATH — ~/.local/bin must precede it for the new build to win"
    echo "        (rig setup-shell already adds ~/.local/bin to ~/.zshrc)"
fi

# --- [2/4] Set Default Editor & sudoedit -------------------------------------
echo ""
echo "[2/4] Configuring default editor (EDITOR, VISUAL, SUDO_EDITOR)..."

# System-level update-alternatives is a Debian-family mechanism; only when
# the binary is system-wide and sudo is passwordless.
if is_debian && [[ "$NVIM_BIN" != "$HOME"* ]] && command -v update-alternatives >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo update-alternatives --install /usr/bin/editor editor "$NVIM_BIN" 60 2>/dev/null || true
    sudo update-alternatives --set editor "$NVIM_BIN" 2>/dev/null || true
    sudo update-alternatives --install /usr/bin/vi vi "$NVIM_BIN" 60 2>/dev/null || true
    echo "  System-level alternatives set to $NVIM_BIN (editor, vi)"
fi

# Same contract as everywhere else: rc files are only appended to after an
# explicit yes plus a backup; without a usable /dev/tty the lines are printed.
_editor_block=$'export EDITOR="nvim"\nexport VISUAL="nvim"\nexport SUDO_EDITOR="nvim"\nalias vim="nvim"'

_needy_rc=()
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc" ]] || continue
    if grep -q 'EDITOR="nvim"' "$rc" 2>/dev/null; then
        echo "  $rc already configures nvim as default editor."
    else
        _needy_rc+=("$rc")
    fi
done

if [[ "${#_needy_rc[@]}" -gt 0 ]]; then
    if rig_can_prompt; then
        printf "  Export nvim as default editor in: %s? [y/N] " "${_needy_rc[*]}"
        read -r answer </dev/tty || answer="n"
        if [[ "$answer" == [yY]* ]]; then
            for rc in "${_needy_rc[@]}"; do
                rig_user_backup "$rc" "$(basename "$rc")" >/dev/null 2>&1 || true
                printf '\n# Added by rig setup-neovim\n%s\n' "$_editor_block" >>"$rc"
                echo "  ✔ Appended editor exports to $rc (backup taken)."
            done
        else
            echo "  Kept as-is."
        fi
    else
        for rc in "${_needy_rc[@]}"; do
            echo "  Note: $rc does not export EDITOR=\"nvim\". You can add:"
            printf '%s\n' "$_editor_block" | sed 's/^/      /'
        done
    fi
fi

# --- [3/4] Neovim Configuration (init.lua) -----------------------------------
echo ""
echo "[3/4] Neovim configuration..."

CLIP="$(tools_clipboard_tool)"
EVERFOREST=0
if [[ -n "$CLIP" ]] && nvim_everforest_installed; then
    EVERFOREST=1
fi

TMP_INIT_LUA="$(mktemp)"
nvim_baseline "$(nvim_version)" "$CLIP" "$EVERFOREST" > "$TMP_INIT_LUA"
PROFILE_LINE="$(sed -n '2p' "$TMP_INIT_LUA")"

if [[ -f "$NVIM_INIT_LUA" ]]; then
    rig_offer_config_baseline "$NVIM_INIT_LUA" "$TMP_INIT_LUA" neovim
elif [[ -f "$NVIM_INIT_VIM" ]]; then
    # With both files present Neovim loads only init.lua and reports E5422, so
    # writing init.lua next to the user's init.vim would silently disable it.
    echo "  found $NVIM_INIT_VIM — with an init.lua beside it Neovim would load only init.lua (E5422)"
    echo "  and silently ignore your init.vim, so no baseline was written."
    echo "  Move init.vim aside and re-run this script to get the baseline."
else
    mkdir -p "$NVIM_CONFIG_DIR"
    cat "$TMP_INIT_LUA" > "$NVIM_INIT_LUA"
    echo "  created $NVIM_INIT_LUA"
    echo "  $PROFILE_LINE"
fi
rm -f "$TMP_INIT_LUA"

# On a headless host the baseline copies out through OSC 52. Inside tmux that
# escape is only forwarded when set-clipboard is on — which setup-tmux.sh's
# baseline writes. Warn when the tmux config on this host does not enable it.
if [[ -z "$CLIP" ]] && command -v tmux >/dev/null 2>&1; then
    _tmux_conf=""
    for candidate in "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" "$HOME/.tmux.conf"; do
        if [[ -f "$candidate" ]]; then
            _tmux_conf="$candidate"
            break
        fi
    done
    if [[ -z "$_tmux_conf" ]] \
        || ! grep -vE '^[[:space:]]*#' "$_tmux_conf" | grep -qE 'set-clipboard[[:space:]]+on([[:space:]]|$)'; then
        echo "  note: inside tmux, yanks reach the local clipboard only with"
        echo "        'set -g set-clipboard on' — rig setup-tmux writes it."
    fi
fi

# --- [4/4] Summary -----------------------------------------------------------
echo ""
echo "=== Done ==="
echo "nvim: $(command -v nvim) ($(nvim --version | head -1))"
echo "config: $NVIM_INIT_LUA"
echo "  $PROFILE_LINE"
