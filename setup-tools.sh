#!/usr/bin/env bash
set -euo pipefail

# Source library dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/os-detect.sh
source "$SCRIPT_DIR/lib/os-detect.sh"
# shellcheck source=lib/pkg-maps.sh
source "$SCRIPT_DIR/lib/pkg-maps.sh"
# shellcheck source=lib/pkg-manager.sh
source "$SCRIPT_DIR/lib/pkg-manager.sh"
# shellcheck source=lib/rig-config.sh
source "$SCRIPT_DIR/lib/rig-config.sh"
# shellcheck source=lib/tools.sh
source "$SCRIPT_DIR/lib/tools.sh"

echo "=== Essential Tools Setup ==="

# [1/3] Install packages
echo "[1/3] Installing packages..."

# macOS: Install Xcode Command Line Tools first
if is_macos; then
    if ! xcode-select -p &>/dev/null; then
        echo "  Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        # Wait for installation (user must click through GUI)
        echo "  Note: Please complete Xcode CLI Tools installation if prompted."
    fi
fi

# Core tools (pkg_install auto-maps names per OS and skips unavailable ones).
# Install only missing capabilities, not merely missing package names: for
# example Fedora's wget2-wget already provides a valid `wget` command.
# fastfetch is intentionally NOT in this list: it is optional and absent from
# older Debian/Ubuntu repos, and one unresolvable name fails the whole batch.
TOOL_PACKAGES=(ripgrep jq fd bat tree shellcheck build-tools wget unzip)
MISSING_TOOL_PACKAGES=()
for tool_pkg in "${TOOL_PACKAGES[@]}"; do
    if tools_command_available "$tool_pkg"; then
        echo "  already available: $tool_pkg"
    else
        MISSING_TOOL_PACKAGES+=("$tool_pkg")
    fi
done
if [[ ${#MISSING_TOOL_PACKAGES[@]} -gt 0 ]]; then
    pkg_install "${MISSING_TOOL_PACKAGES[@]}"
fi

# Clipboard helper — which one is correct depends on the session, not on taste:
#   macOS          -> pbcopy, already part of the OS
#   Wayland        -> wl-clipboard (wl-copy / wl-paste)
#   X11            -> xclip
#   headless / VPS -> neither; there is no display server to talk to
# Override with RIG_CLIPBOARD_TOOL=auto|pbcopy|wl-copy|xclip|none
CLIPBOARD_PKG="$(tools_clipboard_package)"
if [[ -n "$CLIPBOARD_PKG" ]]; then
    echo "  clipboard helper: $CLIPBOARD_PKG ($(tools_clipboard_origin))"
    pkg_install "$CLIPBOARD_PKG"
else
    echo "  clipboard helper: none needed ($(tools_clipboard_origin))"
fi

# [2/4] Install GitHub CLI
echo "[2/4] Installing GitHub CLI..."
if command -v gh &>/dev/null; then
    echo "  gh already installed, skipping."
elif is_macos; then
    brew install gh
elif is_debian; then
    sudo mkdir -p -m 755 /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
elif is_fedora || is_rhel; then
    sudo dnf install -y 'dnf-command(config-manager)' 2>/dev/null || true
    # dnf5 (Fedora 41+) uses different syntax than dnf4
    sudo dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null || \
        sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null || true
    sudo dnf install -y gh
elif is_arch; then
    sudo pacman -S --needed --noconfirm github-cli
else
    echo "  Warning: Unsupported OS for GitHub CLI. Attempting install via conda-forge..."
    echo "  Please install gh manually: https://github.com/cli/cli#installation"
fi

# [3/4] Ensure fastfetch is installed (optional; not every distro packages it)
echo "[3/4] Checking fastfetch..."
if ! command -v fastfetch &>/dev/null; then
    # Native repos cover Arch/Fedora/Alpine/openSUSE/Void and Debian 13+/
    # Ubuntu 25.04+. Installed alone so a missing name cannot fail the batch.
    pkg_install fastfetch 2>/dev/null || true
fi

ff_works() {
    command -v fastfetch &>/dev/null && fastfetch --version &>/dev/null \
        || { [[ -x "$HOME/.local/bin/fastfetch" ]] && "$HOME/.local/bin/fastfetch" --version &>/dev/null; }
}

if ! ff_works; then
    # Upstream releases ship .deb/.rpm/.tar.gz per arch, plus "-polyfilled"
    # builds for old glibc and a musl build for Alpine-style systems.
    ff_arch="$(uname -m)"
    [[ "$ff_arch" == "x86_64" ]] && ff_arch="amd64"
    if is_macos; then
        ff_os="macos"
    elif ldd --version 2>&1 | grep -qi musl; then
        ff_os="musl"
    else
        ff_os="linux"
    fi
    ff_base="https://github.com/fastfetch-cli/fastfetch/releases/latest/download"
    [[ -n "${GH_PROXY:-}" ]] && ff_base="${GH_PROXY%/}/${ff_base}"

    echo "  fastfetch is not in $OS_DISTRO's package repositories."
    ff_reply="n"
    if rig_can_prompt; then
        read -r -p "  Install from the upstream GitHub release (.deb/.rpm via sudo, else tarball into ~/.local/bin)? [y/N] " ff_reply </dev/tty || ff_reply="n"
    else
        echo "  Non-interactive: skipping. Manual assets: $ff_base/fastfetch-${ff_os}-${ff_arch}.{deb,rpm,tar.gz}"
    fi

    if [[ "$ff_reply" =~ ^[Yy] ]]; then
        ff_tmp="$(mktemp -d)"
        ff_ours=""
        for ff_variant in "" "-polyfilled"; do
            ff_asset="fastfetch-${ff_os}-${ff_arch}${ff_variant}"
            if is_debian; then
                if curl -fsSL --retry 2 "$ff_base/${ff_asset}.deb" -o "$ff_tmp/ff.deb" 2>/dev/null \
                    && { sudo dpkg -i "$ff_tmp/ff.deb" 2>/dev/null \
                        || sudo apt-get install -f -y 2>/dev/null; }; then
                    echo "  installed via ${ff_asset}.deb"
                fi
            elif command -v dnf &>/dev/null; then
                if curl -fsSL --retry 2 "$ff_base/${ff_asset}.rpm" -o "$ff_tmp/ff.rpm" 2>/dev/null \
                    && sudo dnf install -y "$ff_tmp/ff.rpm" 2>/dev/null; then
                    echo "  installed via ${ff_asset}.rpm"
                fi
            elif command -v zypper &>/dev/null; then
                if curl -fsSL --retry 2 "$ff_base/${ff_asset}.rpm" -o "$ff_tmp/ff.rpm" 2>/dev/null \
                    && sudo zypper --non-interactive install "$ff_tmp/ff.rpm" 2>/dev/null; then
                    echo "  installed via ${ff_asset}.rpm"
                fi
            fi
            # Rootless fallback: tarball → ~/.local/bin (no sudo needed)
            if ! ff_works \
                && curl -fsSL --retry 2 "$ff_base/${ff_asset}.tar.gz" -o "$ff_tmp/ff.tar.gz" 2>/dev/null; then
                tar -xzf "$ff_tmp/ff.tar.gz" -C "$ff_tmp" 2>/dev/null || true
                ff_bin="$(find "$ff_tmp" -type f -name fastfetch | head -1)"
                if [[ -n "$ff_bin" ]]; then
                    mkdir -p "$HOME/.local/bin"
                    cp "$ff_bin" "$HOME/.local/bin/fastfetch" && chmod +x "$HOME/.local/bin/fastfetch"
                    ff_ours=1
                    echo "  installed via ${ff_asset}.tar.gz → ~/.local/bin"
                fi
            fi
            if ff_works; then break; fi
            # Our tarball binary fails to run (old glibc) → retry polyfilled
            if [[ -n "$ff_ours" ]]; then rm -f "$HOME/.local/bin/fastfetch"; fi
        done
        rm -rf "$ff_tmp"
    else
        echo "  Skipped."
    fi
fi

if ff_works; then
    echo "  fastfetch $(fastfetch --version 2>/dev/null | awk '{print $2}' || "$HOME/.local/bin/fastfetch" --version 2>/dev/null | awk '{print $2}' || true) installed."
else
    echo "  fastfetch unavailable for $OS_DISTRO — skipping (it is optional)."
fi

# [4/4] Create convenience symlinks (Debian renames fd-find→fdfind, bat→batcat)
echo "[4/4] Creating symlinks..."
if is_debian; then
    mkdir -p "$HOME/.local/bin"
    if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
        ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
        echo "  Created bat → batcat symlink."
    else
        echo "  bat symlink not needed."
    fi
    if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
        echo "  Created fd → fdfind symlink."
    else
        echo "  fd symlink not needed."
    fi
else
    echo "  Symlinks not needed on ${OS_DISTRO}."
fi

echo ""
echo "=== Done! Essential tools installed. ==="
