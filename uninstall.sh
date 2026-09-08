#!/usr/bin/env bash
# Removes the sail command (does not uninstall brew packages).
set -euo pipefail
rm -rf "$HOME/.sail"
rm -f /usr/local/bin/sail "$HOME/.local/bin/sail"

BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [ -n "$BREW_PREFIX" ]; then
    rm -f "$BREW_PREFIX/share/zsh/site-functions/_sail"
    rm -f "$BREW_PREFIX/etc/bash_completion.d/sail"
fi

echo "sail removed. (Dependencies like fzf/webtorrent-cli/IINA were left installed —"
echo "remove them with: brew uninstall fzf webtorrent-cli && brew uninstall --cask iina)"
