#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Package Name Mapping Library
# https://github.com/DieRingedesSaturn/rig
#
# Maps abstract (generic) package names to distro-specific package names.
# Must be sourced after lib/os-detect.sh (needs OS_FAMILY).
#
# Usage:
#   source lib/os-detect.sh
#   source lib/pkg-maps.sh
#   resolved=$(pkg_map "build-tools")   # → "build-essential" on Debian
#   resolved=$(pkg_map "fd")            # → "fd-find" on Debian
#
# Exported functions:
#   pkg_map <abstract_name>  - Resolve one abstract name to distro-specific name
#   pkg_map_all <names...>   - Resolve multiple names, space-separated output
# =============================================================================

# Guard against double-sourcing
if [[ -n "${_PKG_MAPS_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
_PKG_MAPS_LOADED=1

# Require OS_FAMILY to be set
if [[ -z "${OS_FAMILY:-}" ]]; then
    echo "Error: lib/pkg-maps.sh requires lib/os-detect.sh to be sourced first." >&2
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# --- Mapping Tables ----------------------------------------------------------
#
# Each function maps an abstract name to a distro-specific name.
# Format: _pkg_map_<OS_FAMILY> <abstract_name>
# Returns the mapped name on stdout; empty string means "not available".

# pkg_map <abstract_name> - Resolve an abstract package name to the distro-specific name.
# Prints the resolved name to stdout. If no mapping exists, prints the original name unchanged.
#
# Examples:
#   pkg_map "build-tools"  → "build-essential" (Debian) / "base-devel" (Arch)
#   pkg_map "curl"         → "curl" (same everywhere)
pkg_map() {
    local name="$1"
    local mapped=""

    case "$OS_FAMILY" in
        debian) mapped=$(_pkg_map_debian "$name") ;;
        rhel)   mapped=$(_pkg_map_rhel "$name") ;;
        fedora) mapped=$(_pkg_map_fedora "$name") ;;
        arch)   mapped=$(_pkg_map_arch "$name") ;;
        macos)  mapped=$(_pkg_map_macos "$name") ;;
        *)      mapped="" ;;
    esac

    # Return the mapped value (may be empty for platform-unavailable packages)
    # Empty return means "skip this package on this platform"
    echo "$mapped"
}

# pkg_map_all <name1> [name2] ... - Resolve multiple abstract names.
# Prints all resolved names on one line, space-separated.
#
# Example:
#   pkg_map_all "fd" "bat" "ripgrep"  → "fd-find batcat ripgrep" (Debian)
pkg_map_all() {
    local result=()
    local name
    for name in "$@"; do
        result+=("$(pkg_map "$name")")
    done
    echo "${result[*]}"
}

# --- Debian / Ubuntu ---------------------------------------------------------

_pkg_map_debian() {
    local name="$1"
    case "$name" in
        build-tools)    echo "build-essential" ;;
        fd)             echo "fd-find" ;;
        bat)            echo "bat" ;;
        ripgrep)        echo "ripgrep" ;;
        tree)           echo "tree" ;;
        jq)             echo "jq" ;;
        wget)           echo "wget" ;;
        unzip)          echo "unzip" ;;
        curl)           echo "curl" ;;
        git)            echo "git" ;;
        vim)            echo "vim" ;;
        zsh)            echo "zsh" ;;
        shellcheck)     echo "shellcheck" ;;
        fastfetch)      echo "fastfetch" ;;
        xclip)         echo "xclip" ;;
        wl-clipboard)   echo "wl-clipboard" ;;
        python3)        echo "python3" ;;
        python3-pip)    echo "python3-pip" ;;
        starship)                echo "starship" ;;
        zsh-autosuggestions)     echo "zsh-autosuggestions" ;;
        zsh-syntax-highlighting) echo "zsh-syntax-highlighting" ;;
        *)              echo "$name" ;;
    esac
}

# --- RHEL / CentOS / Rocky / Alma -------------------------------------------

_pkg_map_rhel() {
    local name="$1"
    case "$name" in
        build-tools)    echo "@development-tools" ;;
        fd)             echo "fd-find" ;;
        bat)            echo "bat" ;;
        ripgrep)        echo "ripgrep" ;;
        tree)           echo "tree" ;;
        jq)             echo "jq" ;;
        wget)           echo "wget" ;;
        unzip)          echo "unzip" ;;
        curl)           echo "curl" ;;
        git)            echo "git" ;;
        vim)            echo "vim-enhanced" ;;
        zsh)            echo "zsh" ;;
        shellcheck)     echo "ShellCheck" ;;
        fastfetch)      echo "fastfetch" ;;
        xclip)         echo "xclip" ;;
        wl-clipboard)   echo "wl-clipboard" ;;
        python3)        echo "python3" ;;
        python3-pip)    echo "python3-pip" ;;
        starship)                echo "starship" ;;
        zsh-autosuggestions)     echo "zsh-autosuggestions" ;;
        zsh-syntax-highlighting) echo "zsh-syntax-highlighting" ;;
        *)              echo "$name" ;;
    esac
}

# --- Fedora ------------------------------------------------------------------

_pkg_map_fedora() {
    local name="$1"
    case "$name" in
        build-tools)    echo "@development-tools" ;;
        fd)             echo "fd-find" ;;
        bat)            echo "bat" ;;
        ripgrep)        echo "ripgrep" ;;
        tree)           echo "tree" ;;
        jq)             echo "jq" ;;
        wget)           echo "wget" ;;
        unzip)          echo "unzip" ;;
        curl)           echo "curl" ;;
        git)            echo "git" ;;
        vim)            echo "vim-enhanced" ;;
        zsh)            echo "zsh" ;;
        shellcheck)     echo "ShellCheck" ;;
        fastfetch)      echo "fastfetch" ;;
        xclip)         echo "xclip" ;;
        wl-clipboard)   echo "wl-clipboard" ;;
        python3)        echo "python3" ;;
        python3-pip)    echo "python3-pip" ;;
        starship)                echo "starship" ;;
        zsh-autosuggestions)     echo "zsh-autosuggestions" ;;
        zsh-syntax-highlighting) echo "zsh-syntax-highlighting" ;;
        *)              echo "$name" ;;
    esac
}

# --- Arch / Manjaro ----------------------------------------------------------

_pkg_map_arch() {
    local name="$1"
    case "$name" in
        build-tools)    echo "base-devel" ;;
        fd)             echo "fd" ;;
        bat)            echo "bat" ;;
        ripgrep)        echo "ripgrep" ;;
        tree)           echo "tree" ;;
        jq)             echo "jq" ;;
        wget)           echo "wget" ;;
        unzip)          echo "unzip" ;;
        curl)           echo "curl" ;;
        git)            echo "git" ;;
        vim)            echo "vim" ;;
        zsh)            echo "zsh" ;;
        shellcheck)     echo "shellcheck" ;;
        fastfetch)      echo "fastfetch" ;;
        xclip)         echo "xclip" ;;
        wl-clipboard)   echo "wl-clipboard" ;;
        python3)        echo "python" ;;
        python3-pip)    echo "python-pip" ;;
        starship)                echo "starship" ;;
        zsh-autosuggestions)     echo "zsh-autosuggestions" ;;
        zsh-syntax-highlighting) echo "zsh-syntax-highlighting" ;;
        *)              echo "$name" ;;
    esac
}

# --- macOS (Homebrew) --------------------------------------------------------

_pkg_map_macos() {
    local name="$1"
    case "$name" in
        build-tools)    echo "" ;;  # Xcode CLI tools handled in setup scripts
        fd)             echo "fd" ;;
        bat)            echo "bat" ;;
        ripgrep)        echo "ripgrep" ;;
        tree)           echo "tree" ;;
        jq)             echo "jq" ;;
        wget)           echo "wget" ;;
        unzip)          echo "" ;;  # built-in on macOS
        curl)           echo "" ;;  # built-in on macOS
        git)            echo "git" ;;
        vim)            echo "vim" ;;
        zsh)            echo "" ;;  # built-in on macOS
        shellcheck)     echo "shellcheck" ;;
        fastfetch)      echo "fastfetch" ;;
        xclip)         echo "" ;;  # not applicable on macOS (pbcopy is built in)
        wl-clipboard)   echo "" ;;  # not applicable on macOS (pbcopy is built in)
        python3)        echo "python@3" ;;
        python3-pip)    echo "" ;;  # included with python@3 on brew
        starship)                echo "starship" ;;
        zsh-autosuggestions)     echo "zsh-autosuggestions" ;;
        zsh-syntax-highlighting) echo "zsh-syntax-highlighting" ;;
        *)              echo "$name" ;;
    esac
}
