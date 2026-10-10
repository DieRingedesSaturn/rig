#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Neovim Baseline Generator & Official-Binary Installer
# https://github.com/DieRingedesSaturn/rig
#
# Builds the init.lua rig writes for a host. Everything is decided once, at
# setup time: the installed Neovim version and the clipboard helper this
# session calls for (lib/tools.sh) pick the emitted lines, so the generated
# file contains no runtime version or environment checks.
#
# Also installs the official static Neovim build for hosts whose distro
# package is older than the supported minimum.
#
# Must be sourced after lib/os-detect.sh.
#
# Exported functions:
#   nvim_parse_version         - "NVIM v0.10.4" → "0.10"
#   nvim_version               - installed nvim MAJOR.MINOR, or "0.0"
#   nvim_everforest_installed  - everforest under site/pack/*/start
#   nvim_is_static             - ~/.local/bin/nvim is the rig-managed build
#   nvim_static_install        - fetch official binary into ~/.local
#   nvim_baseline              - print the baseline init.lua to stdout
# =============================================================================

if [[ -n "${_LIB_NEOVIM_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_LIB_NEOVIM_LOADED=1

if [[ -z "${OS_FAMILY:-}" ]]; then
    echo "Error: lib/neovim.sh requires lib/os-detect.sh to be sourced first." >&2
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# nvim_parse_version RAW - First MAJOR.MINOR in `nvim --version` output.
# "NVIM v0.10.4" → 0.10, "NVIM v0.12.0-dev-12+gabc" → 0.12; none → 0.0.
nvim_parse_version() {
    local raw="$1"
    if [[ "$raw" =~ [0-9]+\.[0-9]+ ]]; then
        printf '%s\n' "${BASH_REMATCH[0]}"
    else
        printf '0.0\n'
    fi
}

# nvim_version - MAJOR.MINOR of the installed nvim, or "0.0" when absent.
nvim_version() {
    nvim_parse_version "$(nvim --version 2>/dev/null | head -1 || true)"
}

# nvim_everforest_installed - True when an everforest start plugin exists
# under the user's site/pack tree.
nvim_everforest_installed() {
    local dir
    for dir in "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/"*/start/everforest; do
        [[ -d "$dir" ]] && return 0
    done
    return 1
}

# nvim_is_static - True when ~/.local/bin/nvim is the rig-managed link into
# ~/.local/share/nvim-static/.
nvim_is_static() {
    local link="$HOME/.local/bin/nvim" target
    [[ -L "$link" ]] || return 1
    target="$(readlink "$link" 2>/dev/null)" || return 1
    [[ "$target" == "$HOME/.local/share/nvim-static/"* ]]
}

# nvim_static_install - Install the official Neovim binary release to
# ~/.local/share/nvim-static with a symlink at ~/.local/bin/nvim.
# Linux only; honours GH_PROXY like every other download in this project.
nvim_static_install() {
    is_macos && return 1

    local arch asset base tmp
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  asset="nvim-linux-x86_64" ;;
        aarch64|arm64) asset="nvim-linux-arm64" ;;
        *)
            echo "no official Neovim build for $arch" >&2
            return 1
            ;;
    esac

    base="https://github.com/neovim/neovim/releases/latest/download"
    [[ -n "${GH_PROXY:-}" ]] && base="${GH_PROXY%/}/${base}"

    tmp="$(mktemp -d)" || return 1
    if ! curl -fsSL --retry 2 "$base/$asset.tar.gz" -o "$tmp/nvim.tar.gz"; then
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "$tmp/nvim.tar.gz" -C "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    # Old glibc can leave a binary that downloads fine but cannot run.
    if ! "$tmp/$asset/bin/nvim" --version >/dev/null 2>&1; then
        echo "downloaded Neovim does not run on this system (glibc too old?)" >&2
        rm -rf "$tmp"
        return 1
    fi

    mkdir -p "$HOME/.local/share" "$HOME/.local/bin"
    # A leftover .new from an interrupted run would make mv nest inside it.
    rm -rf "$HOME/.local/share/nvim-static.new"
    if ! mv "$tmp/$asset" "$HOME/.local/share/nvim-static.new"; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$HOME/.local/share/nvim-static"
    if ! mv "$HOME/.local/share/nvim-static.new" "$HOME/.local/share/nvim-static"; then
        rm -rf "$tmp" "$HOME/.local/share/nvim-static.new"
        # The old tree is gone; our symlink would now dangle.
        if nvim_is_static; then
            rm -f "$HOME/.local/bin/nvim"
        fi
        return 1
    fi
    ln -sf "$HOME/.local/share/nvim-static/bin/nvim" "$HOME/.local/bin/nvim"

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) PATH="$HOME/.local/bin:$PATH" ;;
    esac
    hash -r

    echo "  Installed official Neovim to ~/.local/bin/nvim"
    rm -rf "$tmp"
    return 0
}

# nvim_baseline VERSION CLIPBOARD EVERFOREST - Print the recommended init.lua
# for this host. CLIPBOARD is pbcopy|wl-copy|xclip for a desktop session or
# empty for a headless host. EVERFOREST=1 only counts on a desktop.
nvim_baseline() {
    local version="$1" clipboard="$2" everforest="${3:-0}"
    local desktop=0 tier="0.9"

    [[ -n "$clipboard" ]] && desktop=1
    rig_version_ge "$version" 0.10 && tier=">= 0.10"

    cat <<'EOF'
-- Rig Neovim Baseline
EOF
    if [[ "$desktop" == "1" ]]; then
        if [[ "$everforest" == "1" ]]; then
            printf -- '-- Profile: desktop, clipboard: %s, colors: everforest\n' "$clipboard"
        else
            printf -- '-- Profile: desktop, clipboard: %s, colors: terminal palette\n' "$clipboard"
        fi
    elif [[ "$tier" == ">= 0.10" ]]; then
        printf -- '-- Profile: headless, clipboard: OSC 52 copy-only (nvim >= 0.10), colors: terminal palette\n'
    else
        printf -- '-- Profile: headless, clipboard: OSC 52 copy-only (nvim 0.9), colors: terminal palette\n'
    fi
    cat <<'EOF'
-- Generated by rig setup-neovim for this host; re-run it after moving the
-- file to another machine or upgrading Neovim across 0.10.

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.opt.number = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4
vim.opt.expandtab = true
vim.opt.scrolloff = 4
vim.opt.sidescrolloff = 4
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.undofile = true

vim.keymap.set('n', '<F2>', function()
  vim.opt.number = not vim.opt.number:get()
end)

-- Leave mouse selection and copy-on-select to the terminal emulator.
vim.opt.mouse = ''

EOF

    if [[ "$desktop" == "1" && "$everforest" == "1" ]]; then
        cat <<'EOF'
-- Everforest was found under site/pack when this file was generated.
vim.opt.termguicolors = true
pcall(vim.cmd.colorscheme, 'everforest')
EOF
    else
        cat <<'EOF'
-- Built-in colorscheme on the terminal's 16-colour palette, so it follows
-- the terminal's own light/dark theme.
vim.opt.termguicolors = false
EOF
    fi

    echo
    if [[ "$desktop" == "1" ]]; then
        cat <<'EOF'
-- Yank and put through the system clipboard; Neovim picks pbcopy, wl-copy
-- or xclip on its own.
vim.opt.clipboard = 'unnamedplus'
EOF
    elif [[ "$tier" == ">= 0.10" ]]; then
        cat <<'EOF'
-- Headless host: yanks reach the local clipboard through OSC 52 (inside tmux
-- this needs `set -g set-clipboard on`). Puts return the last yank instead of
-- asking the terminal, which blocks or prompts on every `p`.
local osc52 = require('vim.ui.clipboard.osc52')
local last = { { '' }, 'v' }
local function copy(reg)
  local send = osc52.copy(reg)
  return function(lines, regtype)
    last = { lines, regtype }
    send(lines)
  end
end
local function paste()
  return last
end
vim.g.clipboard = {
  name = 'OSC 52 (copy only)',
  copy = { ['+'] = copy('+'), ['*'] = copy('*') },
  paste = { ['+'] = paste, ['*'] = paste },
}
vim.opt.clipboard = 'unnamedplus'
EOF
    else
        cat <<'EOF'
-- Headless host: yanks reach the local clipboard through OSC 52 (inside tmux
-- this needs `set -g set-clipboard on`). Puts return the last yank instead of
-- asking the terminal. Neovim 0.9 has no OSC 52 module, so the escape is
-- built with base64(1) and written to stderr, which is the terminal.
local last = { { '' }, 'v' }
local function copy(lines, regtype)
  last = { lines, regtype }
  local b64 = vim.fn.system({ 'base64' }, table.concat(lines, '\n')):gsub('%s', '')
  vim.fn.chansend(vim.v.stderr, '\27]52;c;' .. b64 .. '\7')
end
local function paste()
  return last
end
vim.g.clipboard = {
  name = 'OSC 52 (copy only)',
  copy = { ['+'] = copy, ['*'] = copy },
  paste = { ['+'] = paste, ['*'] = paste },
}
vim.opt.clipboard = 'unnamedplus'
EOF
    fi
}
