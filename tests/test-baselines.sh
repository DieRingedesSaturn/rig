#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=../lib/os-detect.sh
source "$ROOT_DIR/lib/os-detect.sh"
# shellcheck source=../lib/tmux.sh
source "$ROOT_DIR/lib/tmux.sh"
# shellcheck source=../lib/neovim.sh
source "$ROOT_DIR/lib/neovim.sh"
# shellcheck source=../lib/backup.sh
source "$ROOT_DIR/lib/backup.sh"

# --- rig_version_ge ----------------------------------------------------------

rig_version_ge 3.2 3.2   || fail "rig_version_ge 3.2 3.2"
! rig_version_ge 3.1 3.2 || fail "rig_version_ge 3.1 3.2 should be false"
rig_version_ge 3.10 3.9  || fail "rig_version_ge 3.10 3.9 (numeric, not lexical)"
rig_version_ge 0.10 0.9  || fail "rig_version_ge 0.10 0.9"
! rig_version_ge 0.9 0.10 || fail "rig_version_ge 0.9 0.10 should be false"
rig_version_ge 3 2.4     || fail "rig_version_ge 3 2.4 (missing minor)"

# --- version parsers ---------------------------------------------------------

[[ "$(tmux_parse_version 'tmux 3.2a')" == "3.2" ]]           || fail "tmux_parse_version 3.2a"
[[ "$(tmux_parse_version 'tmux next-3.6')" == "3.6" ]]       || fail "tmux_parse_version next-3.6"
[[ "$(tmux_parse_version 'tmux master')" == "99.0" ]]        || fail "tmux_parse_version master"
[[ "$(tmux_parse_version '')" == "0.0" ]]                    || fail "tmux_parse_version empty"
[[ "$(nvim_parse_version 'NVIM v0.10.4')" == "0.10" ]]       || fail "nvim_parse_version 0.10.4"
[[ "$(nvim_parse_version 'NVIM v0.12.0-dev-12+gabc')" == "0.12" ]] || fail "nvim_parse_version dev"
[[ "$(nvim_parse_version '')" == "0.0" ]]                    || fail "nvim_parse_version empty"

# --- tmux_baseline matrix ----------------------------------------------------

TMUX_VARIANTS=()
for ver in 2.7 3.1 3.2 3.4 3.7; do
    for clip in "" wl-copy xclip pbcopy; do
        f="$TEST_TMP/tmux-${ver}-${clip:-headless}.conf"
        tmux_baseline "$ver" "$clip" "/home/u/.tmux.conf" 1 100000 tmux-256color > "$f" \
            || fail "tmux_baseline $ver ${clip:-headless} returned non-zero"
        TMUX_VARIANTS+=("$f:$ver:$clip")

        [[ "$(sed -n '1p' "$f")" == "# Rig Tmux Baseline" ]] || fail "$f: bad first line"
        ! grep -q 'allow-passthrough' "$f"                       || fail "$f: allow-passthrough present"
        grep -qF 'set -sg escape-time 10' "$f"                   || fail "$f: escape-time"
        grep -qF 'set -g set-clipboard on' "$f"                  || fail "$f: set-clipboard"
        grep -qF 'set -g default-terminal "tmux-256color"' "$f"  || fail "$f: default-terminal"
        # Bindings must target copy-mode-vi, never the emacs 'copy-mode' table.
        ! grep -E -e '-T[[:space:]]*copy-mode[[:space:]]' "$f"   || fail "$f: copy-mode (emacs) binding"

        if rig_version_ge "$ver" 3.2; then
            grep -q 'terminal-features' "$f"   || fail "$f: terminal-features missing on >=3.2"
            ! grep -q 'terminal-overrides' "$f" || fail "$f: terminal-overrides on >=3.2"
        else
            ! grep -q 'terminal-features' "$f" || fail "$f: terminal-features on <3.2"
            ! grep -q 'copy-command' "$f"      || fail "$f: copy-command on <3.2"
        fi

        if [[ -z "$clip" ]]; then
            ! grep -q 'wl-copy\|xclip\|pbcopy\|copy-command' "$f" \
                || fail "$f: headless variant leaks a desktop clipboard"
        else
            cmd="$(tmux_clipboard_command "$clip")"
            grep -qF "$cmd" "$f" || fail "$f: missing $cmd"
            if rig_version_ge "$ver" 3.2; then
                grep -q 'copy-command' "$f" || fail "$f: copy-command missing on desktop >=3.2"
            fi
        fi
    done
done

# MOUSE=0 omits the mouse line entirely.
TMUX_NOMOUSE="$TEST_TMP/tmux-nomouse.conf"
tmux_baseline 3.4 "" "/home/u/.tmux.conf" 0 100000 tmux-256color > "$TMUX_NOMOUSE"
! grep -qF 'set -g mouse on' "$TMUX_NOMOUSE" || fail "MOUSE=0 still emits mouse on"
grep -qF 'bind -T copy-mode-vi y send -X copy-selection-and-cancel' "$TMUX_NOMOUSE" \
    || fail "headless y binding missing"

# --- tmux_baseline vs a live tmux --------------------------------------------

if command -v tmux >/dev/null 2>&1; then
    TMUX_LOCAL="$(tmux_version)"
    parsed=0
    for entry in "${TMUX_VARIANTS[@]}"; do
        f="${entry%%:*}"
        rest="${entry#*:}"
        ver="${rest%%:*}"
        rig_version_ge "$TMUX_LOCAL" "$ver" || continue
        # tmux <= 3.2 exits 0 even when source-file hit invalid options, so
        # assert on captured output, not the exit code.
        out="$(tmux -L "rigtest$$" -f /dev/null start-server \; source-file "$f" \; kill-server 2>&1 || true)"
        [[ -z "$out" ]] || fail "tmux $TMUX_LOCAL rejected $f: $out"
        parsed=$((parsed + 1))
    done
    echo "  live tmux: parsed $parsed variants with tmux $TMUX_LOCAL"
else
    echo "  live tmux: skipped (no tmux installed)"
fi

# --- tmux_config_advisories ---------------------------------------------------

ADV_CONF="$TEST_TMP/tmux-adv.conf"
cat > "$ADV_CONF" <<'EOF'
set -g allow-passthrough on
set -as terminal-features ",*:RGB"
# set -g extended-keys on
EOF

out="$(tmux_config_advisories "$ADV_CONF" 3.2)"
[[ "$out" == *'allow-passthrough needs tmux >= 3.3'* ]] || fail "advisory missed allow-passthrough"
[[ "$out" != *terminal-features* ]] || fail "advisory flagged a supported option"
[[ "$out" != *extended-keys* ]]     || fail "advisory scanned a commented line"
[[ "$out" == *'  [!] '* ]]          || fail "advisory lost its marker"

out="$(tmux_config_advisories "$ADV_CONF" 3.4)"
[[ -z "$out" ]] || fail "advisory noisy at tmux 3.4: $out"

ADV2="$TEST_TMP/tmux-emacs-copy.conf"
cat > "$ADV2" <<'EOF'
setw -g mode-keys vi
bind -T copy-mode MouseDragEnd1Pane send -X copy-pipe-and-cancel "wl-copy"
EOF
out="$(tmux_config_advisories "$ADV2" 3.4)"
[[ "$out" == *copy-mode-vi* ]] || fail "advisory missed dead emacs-table copy-pipe"

# --- nvim_baseline matrix ----------------------------------------------------

NVIM_VARIANTS=()
for ver in 0.9 0.10 0.12; do
    for clip in "" wl-copy pbcopy; do
        for ef in 0 1; do
            f="$TEST_TMP/nvim-${ver}-${clip:-headless}-ef${ef}.lua"
            nvim_baseline "$ver" "$clip" "$ef" > "$f" \
                || fail "nvim_baseline $ver ${clip:-headless} ef=$ef returned non-zero"
            NVIM_VARIANTS+=("$f:$ver:$clip:$ef")

            [[ "$(sed -n '1p' "$f")" == "-- Rig Neovim Baseline" ]] || fail "$f: bad first line"

            # The generated file must contain no runtime detection or the old
            # ANSI-palette machinery.
            for pat in "has('nvim-" SSH_CONNECTION SSH_TTY 'executable(' 'isdirectory(' \
                       NVIM_BACKGROUND "stdpath('state')" smartindent writebackup \
                       'vim.opt.hidden' 'syntax enable' 'filetype plugin' \
                       nvim_set_hl TextYankPost 'osc52.paste'; do
                ! grep -qF "$pat" "$f" || fail "$f: still contains '$pat'"
            done

            if [[ -n "$clip" ]]; then
                grep -qF "vim.opt.clipboard = 'unnamedplus'" "$f" || fail "$f: desktop clipboard missing"
                ! grep -q 'vim.g.clipboard' "$f"                  || fail "$f: desktop sets g.clipboard"
                if [[ "$ef" == "1" ]]; then
                    grep -q 'everforest' "$f"                        || fail "$f: everforest missing"
                    grep -qF 'vim.opt.termguicolors = true' "$f"     || fail "$f: termguicolors true missing"
                else
                    ! grep -q 'everforest' "$f"                      || fail "$f: ef=0 mentions everforest"
                    grep -qF 'vim.opt.termguicolors = false' "$f"    || fail "$f: termguicolors false missing"
                fi
            else
                grep -q 'vim.g.clipboard' "$f"   || fail "$f: headless lacks g.clipboard"
                ! grep -q 'everforest' "$f"      || fail "$f: headless mentions everforest"
                if rig_version_ge "$ver" 0.10; then
                    grep -q 'vim.ui.clipboard.osc52' "$f" || fail "$f: >=0.10 lacks osc52 module"
                else
                    grep -q 'chansend' "$f"                 || fail "$f: 0.9 lacks chansend fallback"
                    ! grep -q 'vim.ui.clipboard.osc52' "$f" || fail "$f: 0.9 uses osc52 module"
                fi
            fi
        done
    done
done

# --- nvim_baseline vs a live nvim ---------------------------------------------

if command -v nvim >/dev/null 2>&1 && rig_version_ge "$(nvim_version)" 0.9; then
    NVIM_LOCAL="$(nvim_version)"
    loaded=0
    checked_osc52=0
    for entry in "${NVIM_VARIANTS[@]}"; do
        f="${entry%%:*}"
        rest="${entry#*:}"
        ver="${rest%%:*}"
        rest="${rest#*:}"
        clip="${rest%%:*}"
        # Desktop variants need no versioned module; headless ones need the
        # tier they were generated for (0.9 chansend vs >=0.10 osc52 module).
        if [[ -n "$clip" ]]; then min="0.9"; else min="$ver"; fi
        rig_version_ge "$NVIM_LOCAL" "$min" || continue

        out="$(env XDG_CONFIG_HOME="$TEST_TMP/xdg-cfg" XDG_DATA_HOME="$TEST_TMP/xdg-data" \
                  XDG_STATE_HOME="$TEST_TMP/xdg-state" XDG_CACHE_HOME="$TEST_TMP/xdg-cache" \
                  nvim --headless -i NONE -u "$f" -c 'qa!' 2>&1)"
        [[ -z "$out" ]] || fail "nvim $NVIM_LOCAL rejected $f: $out"
        loaded=$((loaded + 1))

        if [[ -z "$clip" ]]; then
            errf="$TEST_TMP/nvim-stderr.$$.log"
            result="$(env XDG_CONFIG_HOME="$TEST_TMP/xdg-cfg" XDG_DATA_HOME="$TEST_TMP/xdg-data" \
                        XDG_STATE_HOME="$TEST_TMP/xdg-state" XDG_CACHE_HOME="$TEST_TMP/xdg-cache" \
                        nvim --headless -i NONE -u "$f" \
                        -c 'call setline(1,"rig")' -c 'normal! yy' \
                        -c 'lua local uv=vim.uv or vim.loop; local t=uv.hrtime(); local r=vim.fn.getreg("+"); io.stdout:write(("%s|%d\n"):format((r:gsub("\n","")), math.floor((uv.hrtime()-t)/1e6)))' \
                        -c 'qa!' 2>"$errf")"
            [[ "$result" =~ ^rig\|[0-9]+$ ]] || fail "headless yank/read broke on $f: $result"
            elapsed="${result##*|}"
            [[ "$elapsed" -lt 1000 ]] || fail "getreg + blocked ${elapsed}ms on $f"
            if [[ "$ver" == "0.9" ]]; then
                # base64("rig\n") starts with "cmln": the escape must be on stderr.
                grep -qF ']52;c;cmln' "$errf" || fail "0.9 OSC52 escape missing on stderr for $f"
                checked_osc52=$((checked_osc52 + 1))
            fi
        fi
    done
    echo "  live nvim: loaded $loaded variants with nvim $NVIM_LOCAL (0.9-tier OSC52 stderr checks: $checked_osc52)"
else
    echo "  live nvim: skipped (no nvim >= 0.9 installed)"
fi

# --- nvim_static_install with stubs -------------------------------------------

# aarch64 + GH_PROXY: the proxy prefix wraps the GitHub URL.
(
    HOME="$TEST_TMP/home-a64"
    mkdir -p "$HOME"
    is_macos() { return 1; }
    uname() { if [[ "${1:-}" == "-m" ]]; then echo aarch64; else command uname "$@"; fi; }
    GH_PROXY="https://proxy.example"
    CURL_LOG="$TEST_TMP/curl-a64.log"; : > "$CURL_LOG"
    curl() { printf '%s\n' "$*" >> "$CURL_LOG"; return 22; }
    if nvim_static_install >/dev/null 2>&1; then exit 1; fi
    grep -qF 'https://proxy.example/https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.tar.gz' "$CURL_LOG" || exit 1
    [[ ! -e "$HOME/.local/bin/nvim" ]] || exit 1
) || fail "nvim_static_install aarch64/GH_PROXY"

# x86_64 + empty GH_PROXY: plain GitHub URL.
(
    HOME="$TEST_TMP/home-x64"
    mkdir -p "$HOME"
    is_macos() { return 1; }
    uname() { if [[ "${1:-}" == "-m" ]]; then echo x86_64; else command uname "$@"; fi; }
    GH_PROXY=""
    CURL_LOG="$TEST_TMP/curl-x64.log"; : > "$CURL_LOG"
    curl() { printf '%s\n' "$*" >> "$CURL_LOG"; return 22; }
    if nvim_static_install >/dev/null 2>&1; then exit 1; fi
    grep -qF 'https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz' "$CURL_LOG" || exit 1
    [[ ! -e "$HOME/.local/bin/nvim" ]] || exit 1
) || fail "nvim_static_install x86_64 URL"

# Unsupported arch: fails before ever calling curl.
(
    HOME="$TEST_TMP/home-rv"
    mkdir -p "$HOME"
    is_macos() { return 1; }
    uname() { if [[ "${1:-}" == "-m" ]]; then echo riscv64; else command uname "$@"; fi; }
    CURL_LOG="$TEST_TMP/curl-rv.log"; : > "$CURL_LOG"
    curl() { printf '%s\n' "$*" >> "$CURL_LOG"; return 0; }
    if nvim_static_install >/dev/null 2>&1; then exit 1; fi
    [[ ! -s "$CURL_LOG" ]] || exit 1
) || fail "nvim_static_install riscv64 called curl"

# Success path: stub curl serves a fabricated release tarball; a stale .new
# directory from an interrupted run must be cleared, not nested into.
(
    HOME="$TEST_TMP/home-ok"
    mkdir -p "$HOME/.local/share/nvim-static.new/stale"
    is_macos() { return 1; }
    uname() { if [[ "${1:-}" == "-m" ]]; then echo x86_64; else command uname "$@"; fi; }
    GH_PROXY=""
    fake="$TEST_TMP/fake-release"; mkdir -p "$fake/nvim-linux-x86_64/bin"
    printf '#!/bin/sh\necho "NVIM v0.12.0"\n' > "$fake/nvim-linux-x86_64/bin/nvim"
    chmod +x "$fake/nvim-linux-x86_64/bin/nvim"
    tar -czf "$TEST_TMP/fake.tar.gz" -C "$fake" nvim-linux-x86_64
    curl() { local out="" prev="" a; for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done; cp "$TEST_TMP/fake.tar.gz" "$out"; }
    nvim_static_install >/dev/null 2>&1 || exit 1
    nvim_is_static || exit 1
    [[ -x "$HOME/.local/share/nvim-static/bin/nvim" ]] || exit 1
    [[ ! -e "$HOME/.local/share/nvim-static.new" ]] || exit 1
    [[ "$("$HOME/.local/bin/nvim" --version)" == "NVIM v0.12.0" ]] || exit 1
) || fail "nvim_static_install success path"

# --- rig_offer_config_baseline append gating -----------------------------------

# Without --allow-append: 'a' is rejected, 'k' keeps, target untouched.
(
    HOME="$TEST_TMP/home-offer"
    mkdir -p "$HOME"
    # Backup dirs resolve at source time from the real HOME; redirect them.
    export RIG_BACKUP_DIR="$TEST_TMP/backups1"
    export RIG_USER_BACKUP_DIR="$TEST_TMP/backups1/user"
    rig_can_prompt() { return 0; }
    target="$TEST_TMP/target.conf"
    baseline="$TEST_TMP/baseline.conf"
    printf 'old\n' > "$target"
    printf 'new baseline\n' > "$baseline"
    printf 'a\nk\n' > "$TEST_TMP/answers"
    export RIG_PROMPT_TTY="$TEST_TMP/answers"
    out="$(rig_offer_config_baseline "$target" "$baseline" tmux 2>&1)"
    [[ "$out" == *"Invalid choice"* ]] || { echo "$out" >&2; exit 1; }
    [[ "$(cat "$target")" == "old" ]] || exit 1
) || fail "rig_offer_config_baseline without --allow-append"

# With --allow-append: 'a' appends and leaves a backup under the user tree.
(
    HOME="$TEST_TMP/home-offer2"
    mkdir -p "$HOME"
    export RIG_BACKUP_DIR="$HOME/.local/share/rig/backups"
    export RIG_USER_BACKUP_DIR="$HOME/.local/share/rig/backups/user"
    rig_can_prompt() { return 0; }
    target="$TEST_TMP/target2.conf"
    baseline="$TEST_TMP/baseline2.conf"
    printf 'old\n' > "$target"
    printf 'new baseline\n' > "$baseline"
    printf 'a\n' > "$TEST_TMP/answers2"
    export RIG_PROMPT_TTY="$TEST_TMP/answers2"
    rig_offer_config_baseline "$target" "$baseline" tmux --allow-append >/dev/null 2>&1 || exit 1
    tail -1 "$target" | grep -qF 'new baseline' || exit 1
    ls "$HOME/.local/share/rig/backups/user/" 2>/dev/null | grep -q . || exit 1
) || fail "rig_offer_config_baseline --allow-append"

echo "baseline tests passed"
