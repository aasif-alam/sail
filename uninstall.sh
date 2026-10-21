#!/usr/bin/env bash
# Removes the sail command (does not uninstall brew packages).
set -euo pipefail
rm -rf "$HOME/.sail"
rm -f /usr/local/bin/sail "$HOME/.local/bin/sail"

# installer-created IINA CLI symlinks (only when they still point at IINA)
for link in /usr/local/bin/iina-cli "$HOME/.local/bin/iina-cli" \
            /usr/local/bin/iina "$HOME/.local/bin/iina"; do
    if [ -L "$link" ] && readlink "$link" | grep -q '/Applications/IINA.app/'; then
        rm -f "$link"
    fi
done

# remove the PATH line install.sh appended to ~/.zshrc (and its marker) —
# cat back into the file instead of mv'ing a temp over it so permissions stay.
# awk (not grep -v) exits 0 even when every line is removed, so a read error
# can never truncate the user's file.
if [ -f "$HOME/.zshrc" ]; then
    tmp="$HOME/.zshrc.sail.$$"
    marker="# sail: add ~/.local/bin to PATH (removed by uninstall.sh)"
    line="export PATH=\"\$HOME/.local/bin:\$PATH\""
    awk -v marker="$marker" -v line="$line" \
        '$0 != marker && $0 != line' "$HOME/.zshrc" > "$tmp"
    cat "$tmp" > "$HOME/.zshrc"
    rm -f "$tmp"
fi

BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [ -n "$BREW_PREFIX" ]; then
    rm -f "$BREW_PREFIX/share/zsh/site-functions/_sail"
    rm -f "$BREW_PREFIX/etc/bash_completion.d/sail"
fi

echo "sail removed. (Dependencies like fzf/webtorrent-cli/IINA were left installed —"
echo "remove them with: brew uninstall fzf webtorrent-cli && brew uninstall --cask iina)"
