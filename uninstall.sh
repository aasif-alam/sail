#!/usr/bin/env bash
# Removes the sail command (does not uninstall brew packages).
set -euo pipefail
rm -rf "$HOME/.sail"
rm -f /usr/local/bin/sail "$HOME/.local/bin/sail"
echo "sail removed. (Dependencies like fzf/webtorrent-cli/IINA were left installed —"
echo "remove them with: brew uninstall fzf webtorrent-cli && brew uninstall --cask iina)"
