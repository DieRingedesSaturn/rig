#!/usr/bin/env bash
set -euo pipefail

# Source library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"

# Usage:
#   ./setup-uv.sh
#   UV_PYTHON=3.12 ./setup-uv.sh

UV_PYTHON="${UV_PYTHON:-${1:-}}"

# Ensure dependencies
if ! command -v curl &>/dev/null; then
    pkg_install curl
fi

echo "=== uv Setup ==="

# Install uv
echo "[1/2] Installing uv..."
if command -v uv &>/dev/null; then
    echo "  uv already installed, upgrading..."
    uv self update || echo "  Warning: uv self update failed, continuing with existing version."
else
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# Load uv into current shell
export PATH="$HOME/.local/bin:$PATH"

# Ensure ~/.local/bin is in shell PATH for both zsh and bash. Never appended
# silently: with a usable /dev/tty the user is asked first (a backup is taken);
# without one the line is only printed.
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh" 2>/dev/null || true

_PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
_needy_rc=()
for _rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$_rc" ]] && ! grep -qF "$_PATH_LINE" "$_rc" 2>/dev/null && _needy_rc+=("$_rc")
done

if [[ "${#_needy_rc[@]}" -gt 0 ]]; then
    if rig_can_prompt 2>/dev/null; then
        printf "  ~/.local/bin is not on PATH in: %s. Append the export line? [y/N] " "${_needy_rc[*]}"
        read -r answer </dev/tty || answer="n"
        if [[ "$answer" == [yY]* ]]; then
            for _rc in "${_needy_rc[@]}"; do
                rig_user_backup "$_rc" "$(basename "$_rc")" >/dev/null 2>&1 || true
                printf '\n# uv / rig: ensure ~/.local/bin in PATH\n%s\n' "$_PATH_LINE" >>"$_rc"
                echo "  ✔ Added ~/.local/bin to PATH in $(basename "$_rc") (backup taken)."
            done
        else
            echo "  Kept as-is — uv/rig may not resolve until ~/.local/bin is on PATH."
        fi
    else
        echo "  ~/.local/bin is not on PATH in: ${_needy_rc[*]}; add this yourself:"
        echo "      $_PATH_LINE"
    fi
fi

# Install Python if requested
if [ -n "$UV_PYTHON" ]; then
    echo "[2/2] Installing Python ${UV_PYTHON}..."
    uv python install "$UV_PYTHON"
else
    echo "[2/2] Skipping Python install (set UV_PYTHON to install a version)."
fi

echo ""
echo "=== Done! ==="
echo "uv: $(uv --version)"
[ -n "$UV_PYTHON" ] && echo "Python: $(uv python find "$UV_PYTHON" 2>/dev/null || echo "$UV_PYTHON installed")"
echo "Run 'source ~/.zshrc' or open a new terminal to use uv."
