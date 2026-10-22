#!/usr/bin/env bash
# wtdir.sh — shared filesystem helpers for finding the webtorrent module.
#
# Sourced by bin/sail, lib/fix-webtorrent.sh, and the tests, so the walk-up
# discovery lives in exactly one place. bash-3.2 safe; no arrays.

# Resolve a path to its symlink target without relying on `readlink -f`
# (GNU-only; macOS grew it in 12.3). A bare command name is looked up on
# PATH first, so this works for both `sail` and `webtorrent`.
sail_resolve_path() {
    local p="${1:-}" d
    [ -n "$p" ] || return 1
    case "$p" in
        */*) ;;
        *) p="$(command -v "$p" 2>/dev/null || true)" || return 1
           [ -n "$p" ] || return 1 ;;
    esac
    while [ -L "$p" ]; do
        d="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)" || return 1
        p="$(readlink "$p")" || return 1
        case "$p" in
            /*) ;;
            *) p="$d/$p" ;;
        esac
    done
    d="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)" || return 1
    printf '%s/%s' "$d" "$(basename "$p")"
}

# print the path to webtorrent's module directory, or nothing.
# Walks up from the real webtorrent binary because Homebrew vendors the
# node_modules tree beside it.
find_webtorrent_module() {
    local bin real d
    bin="$(command -v webtorrent 2>/dev/null || true)"
    [ -n "$bin" ] || return 0
    real="$(sail_resolve_path "$bin" 2>/dev/null || printf '%s' "$bin")"
    d="$(dirname "$real")"
    while [ "$d" != "/" ] && [ "$d" != "." ]; do
        # npm layouts seen in the wild: a package-local node_modules, a
        # Homebrew libexec/lib/node_modules tree, or a global npm root
        for candidate in "$d/node_modules/webtorrent" \
                         "$d/lib/node_modules/webtorrent" \
                         "$d/../lib/node_modules/webtorrent"; do
            if [ -f "$candidate/index.js" ]; then
                printf '%s' "$candidate"
                return 0
            fi
        done
        d="$(dirname "$d")"
    done
}
