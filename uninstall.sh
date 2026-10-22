#!/usr/bin/env bash
# Removes the sail command. Dependencies (fzf, webtorrent-cli, IINA) are left
# installed; so are your settings unless --purge is passed.
#
#   bash uninstall.sh [--purge]
set -euo pipefail

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            cat <<'EOF'
sail uninstaller

Usage: bash uninstall.sh [--purge]

  --purge   also remove ~/.config/sail (your sources and watchlist)
EOF
            exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$arg" >&2; exit 1 ;;
    esac
done

# remove the PATH line install.sh appended (and its marker) from whichever
# startup file it chose. cat back into the file instead of mv'ing a temp over
# it so permissions stay. awk (not grep -v) exits 0 even when every line is
# removed, so a read error can never truncate the user's file.
strip_path_block() {
    local file="$1" tmp marker line
    [ -f "$file" ] || return 0
    tmp="$file.sail.$$"
    marker="# sail: add ~/.local/bin to PATH (removed by uninstall.sh)"
    # shellcheck disable=SC2016  # written as a literal for the shell to expand later
    line='export PATH="$HOME/.local/bin:$PATH"'
    awk -v marker="$marker" -v line="$line" \
        '$0 != marker && $0 != line' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# the package, plus stages from an interrupted install/upgrade
rm -rf "$HOME/.sail" "$HOME/.sail.new."* "$HOME/.sail.old."*
rm -f /usr/local/bin/sail "$HOME/.local/bin/sail"

# installer-created IINA CLI symlinks (only when they still point at IINA)
for link in /usr/local/bin/iina-cli "$HOME/.local/bin/iina-cli" \
            /usr/local/bin/iina "$HOME/.local/bin/iina"; do
    if [ -L "$link" ] && readlink "$link" | grep -q '/Applications/IINA.app/'; then
        rm -f "$link"
    fi
done

strip_path_block "$HOME/.zshrc"
strip_path_block "$HOME/.bash_profile"

BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [ -n "$BREW_PREFIX" ]; then
    rm -f "$BREW_PREFIX/share/zsh/site-functions/_sail"
    rm -f "$BREW_PREFIX/etc/bash_completion.d/sail"
fi

if [ "$PURGE" = 1 ]; then
    rm -rf "$HOME/.config/sail"
    printf 'sail and its settings removed.\n'
else
    printf 'sail removed. Settings kept in %s/.config/sail (pass --purge to remove them).\n' "$HOME"
fi
printf 'Dependencies like fzf/webtorrent-cli/IINA were left installed —\n'
printf 'remove them with: brew uninstall fzf webtorrent-cli && brew uninstall --cask iina\n'
