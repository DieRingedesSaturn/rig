#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Neovim Setup (modern lightweight terminal configuration)
# https://github.com/DieRingedesSaturn/rig
#
# Installs Neovim (ensuring >= 0.9), sets default system editor, configures
# alias vim=nvim, and writes a dependency-free, high-performance init.lua.
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
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

NVIM_CONFIG_DIR="$HOME/.config/nvim"
NVIM_INIT_LUA="$NVIM_CONFIG_DIR/init.lua"

echo "=== Neovim Environment Setup ==="
echo "  platform: $OS_DISTRO ($OS_FAMILY, $PKG_MANAGER)"
echo ""

# --- [1/4] Install Neovim ----------------------------------------------------
echo "[1/4] Ensuring Neovim (>= 0.9)..."

_nvim_version_ok() {
    if ! command -v nvim >/dev/null 2>&1; then
        return 1
    fi
    local raw_ver major minor
    raw_ver="$(nvim --version 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/^v//' || echo "0.0")"
    major="$(echo "$raw_ver" | cut -d. -f1)"
    minor="$(echo "$raw_ver" | cut -d. -f2)"

    if [[ "$major" -gt 0 ]] || [[ "$minor" -ge 9 ]]; then
        return 0
    else
        return 1
    fi
}

if ! _nvim_version_ok; then
    echo "  Installing Neovim via package manager..."
    if ! pkg_check_installed neovim; then
        pkg_install neovim || true
    fi
fi

# Fallback: if distro repo has outdated Neovim (< 0.9) or failed, download official static binary
if ! _nvim_version_ok; then
    echo "  Distro neovim is missing or < 0.9. Fetching official release..."
    mkdir -p "$HOME/.local/bin"
    if [[ "$(uname -m)" == "x86_64" ]] && ! is_macos; then
        NVIM_TAR_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
        TMP_DIR="$(mktemp -d)"
        if curl -fsSL "$NVIM_TAR_URL" -o "$TMP_DIR/nvim.tar.gz"; then
            tar -xzf "$TMP_DIR/nvim.tar.gz" -C "$TMP_DIR"
            mkdir -p "$HOME/.local/share/nvim-static"
            cp -rf "$TMP_DIR"/nvim-linux-x86_64/* "$HOME/.local/share/nvim-static/"
            ln -sf "$HOME/.local/share/nvim-static/bin/nvim" "$HOME/.local/bin/nvim"
            echo "  Installed official Neovim to $HOME/.local/bin/nvim"
        fi
        rm -rf "$TMP_DIR"
    fi
fi

if command -v nvim >/dev/null 2>&1; then
    NVIM_BIN="$(command -v nvim)"
    echo "  Neovim active: $NVIM_BIN ($(nvim --version | head -1))"
else
    echo "  Error: Neovim installation failed." >&2
    exit 1
fi

# --- [2/4] Set Default Editor & sudoedit -------------------------------------
echo ""
echo "[2/4] Configuring default editor (EDITOR, VISUAL, SUDO_EDITOR)..."

# System-level update-alternatives if available and binary is system-wide
if [[ "$NVIM_BIN" != "$HOME"* ]] && command -v update-alternatives >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo update-alternatives --install /usr/bin/editor editor "$NVIM_BIN" 60 2>/dev/null || true
    sudo update-alternatives --set editor "$NVIM_BIN" 2>/dev/null || true
    sudo update-alternatives --install /usr/bin/vi vi "$NVIM_BIN" 60 2>/dev/null || true
    echo "  System-level alternatives set to $NVIM_BIN (editor, vi)"
fi

# Read-only check for user rc files
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc" ]] || continue
    if ! grep -q 'EDITOR="nvim"' "$rc" 2>/dev/null; then
        echo "  Note: $rc does not export EDITOR=\"nvim\". You can add:"
        echo "      export EDITOR=\"nvim\""
        echo "      export VISUAL=\"nvim\""
        echo "      export SUDO_EDITOR=\"nvim\""
        echo "      alias vim=\"nvim\""
    else
        echo "  $rc already configures nvim as default editor."
    fi
done

# --- [3/4] Neovim Configuration (init.lua) -----------------------------------
echo ""
echo "[3/4] Neovim configuration..."

TMP_INIT_LUA="$(mktemp)"
cat > "$TMP_INIT_LUA" <<'EOF'
-- Rig Neovim Baseline
-- Lightweight terminal-native Neovim configuration.

-- Leader key
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Basic editing
vim.opt.number = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4
vim.opt.expandtab = true
vim.opt.autoindent = true
vim.opt.smartindent = true

vim.opt.scrolloff = 4
vim.opt.sidescrolloff = 4
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.hidden = true

vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.incsearch = true
vim.opt.hlsearch = true

vim.opt.undofile = true
vim.opt.backup = false
vim.opt.writebackup = false

vim.keymap.set('n', '<F2>', function()
  vim.opt.number = not vim.opt.number:get()
end)

-- Keep syntax and filetype behavior explicit and independent of plugins.
vim.cmd('syntax enable')
vim.cmd('filetype plugin indent on')

-- Use the full Everforest plugin locally, but keep VPS sessions dependency-free.
local is_remote = vim.env.SSH_CONNECTION ~= nil or vim.env.SSH_TTY ~= nil
local plugin_dir = vim.fn.stdpath('data') .. '/site/pack/plugins/start/everforest'
local use_everforest = not is_remote and vim.fn.isdirectory(plugin_dir) == 1

if use_everforest then
  vim.opt.termguicolors = true
  local background_file = vim.fn.stdpath('state') .. '/background'
  local background = vim.env.NVIM_BACKGROUND
  if vim.fn.filereadable(background_file) == 1 then
    background = vim.fn.readfile(background_file)[1]
  end
  if background == 'dark' or background == 'light' then
    vim.o.background = background
  end
  local ok = pcall(vim.cmd, 'colorscheme everforest')
  if not ok then
    use_everforest = false
    vim.opt.termguicolors = false
  end
end

if not use_everforest then
  -- Use the terminal's ANSI palette instead of a Neovim theme plugin.
  vim.opt.termguicolors = false

  local hl = vim.api.nvim_set_hl

  hl(0, 'Normal', {})
  hl(0, 'NormalFloat', {})
  hl(0, 'SignColumn', {})
  hl(0, 'EndOfBuffer', { ctermfg = 8 })

  local ansi = {
    fg = 7,
    grey = 8,
    red = 1,
    orange = 3,
    yellow = 11,
    green = 2,
    aqua = 6,
    blue = 4,
    purple = 5,
  }

  local function set_role(group, role, attrs)
    local spec = {}
    if attrs then
      for key, value in pairs(attrs) do
        spec[key] = value
      end
    end
    spec.ctermfg = ansi[role]
    hl(0, group, spec)
  end

  local function link_groups(groups)
    for group, target in pairs(groups) do
      hl(0, group, { link = target })
    end
  end

  set_role('Fg', 'fg')
  set_role('Grey', 'grey')
  set_role('Red', 'red')
  set_role('Orange', 'orange')
  set_role('Yellow', 'yellow')
  set_role('Green', 'green')
  set_role('Aqua', 'aqua')
  set_role('Blue', 'blue')
  set_role('Purple', 'purple')
  set_role('RedItalic', 'red', { italic = true, cterm = { italic = true } })
  set_role('OrangeItalic', 'orange', { italic = true, cterm = { italic = true } })
  set_role('YellowItalic', 'yellow', { italic = true, cterm = { italic = true } })
  set_role('PurpleItalic', 'purple', { italic = true, cterm = { italic = true } })

  set_role('Comment', 'grey', { italic = true, cterm = { italic = true } })
  link_groups({ SpecialComment = 'Comment' })

  link_groups({
    Boolean = 'Purple',
    Number = 'Purple',
    Float = 'Purple',
    PreProc = 'Purple',
    PreCondit = 'Purple',
    Include = 'Purple',
    Define = 'Purple',
    Conditional = 'Red',
    Repeat = 'Red',
    Keyword = 'Red',
    Typedef = 'Red',
    Exception = 'Red',
    Statement = 'Red',
    Error = 'Red',
    StorageClass = 'Orange',
    Tag = 'Orange',
    Label = 'Orange',
    Structure = 'Orange',
    Operator = 'Orange',
    Special = 'Yellow',
    SpecialChar = 'Yellow',
    Type = 'Yellow',
    Function = 'Green',
    String = 'Green',
    Character = 'Green',
    Constant = 'Aqua',
    Macro = 'Aqua',
    Identifier = 'Blue',
    Delimiter = 'Fg',
    Ignore = 'Grey',
  })
  set_role('Title', 'orange', { bold = true, cterm = { bold = true } })
  set_role('Error', 'red', { bold = true, cterm = { bold = true } })
  hl(0, 'Todo', { ctermfg = ansi.fg, ctermbg = ansi.blue, bold = true, cterm = { bold = true } })
  hl(0, 'Underlined', { underline = true, cterm = { underline = true } })

  set_role('ErrorMsg', 'red', { bold = true, cterm = { bold = true } })
  set_role('WarningMsg', 'yellow', { bold = true, cterm = { bold = true } })
  set_role('InfoMsg', 'blue')
  set_role('Question', 'yellow')
  set_role('Directory', 'green')
  set_role('Search', 'green', { bold = true, cterm = { bold = true } })
  set_role('IncSearch', 'red', { bold = true, cterm = { bold = true } })
  set_role('DiagnosticError', 'red')
  set_role('DiagnosticWarn', 'yellow')
  set_role('DiagnosticInfo', 'blue')
  set_role('DiagnosticHint', 'purple')
  set_role('DiagnosticOk', 'green')
end

-- Clipboard:
-- When running in a local GUI/Wayland session with wl-copy, sync with system clipboard.
-- In SSH or headless environments, use OSC 52 to pass yanks back to the local terminal.
if not is_remote and vim.fn.executable('wl-copy') == 1 then
  vim.opt.clipboard:append('unnamedplus')
else
  vim.g.clipboard = 'osc52'
  vim.keymap.set('x', 'y', '"+y')
end

-- Let Ghostty/Konsole own mouse selection and copy-on-select.
vim.opt.mouse = ''
EOF

if [[ -f "$NVIM_INIT_LUA" ]]; then
    rig_offer_config_baseline "$NVIM_INIT_LUA" "$TMP_INIT_LUA" neovim
else
    mkdir -p "$NVIM_CONFIG_DIR"
    cat "$TMP_INIT_LUA" > "$NVIM_INIT_LUA"
    echo "  created modern $NVIM_INIT_LUA (Everforest ANSI palette + OSC 52 clipboard)"
fi
rm -f "$TMP_INIT_LUA"

# --- [4/4] Summary -----------------------------------------------------------
echo ""
echo "=== Done ==="
echo "nvim: $(command -v nvim) ($(nvim --version | head -1))"
echo "config: $NVIM_INIT_LUA"
