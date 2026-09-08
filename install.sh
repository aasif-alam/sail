#!/usr/bin/env bash
# sail installer — installs all dependencies and the sail command itself.
set -euo pipefail

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")"

# ---- Homebrew ------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    say "Installing Homebrew (package manager)…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # shellcheck disable=SC1091
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi
command -v brew >/dev/null 2>&1 || err "Homebrew install failed."

# ---- Dependencies --------------------------------------------------------
# python3 comes with macOS via CommandLineTools; ensure it exists.
if ! command -v python3 >/dev/null 2>&1; then
    say "Installing python3…"
    xcode-select --install 2>/dev/null || brew install python3
fi

say "Installing fzf (terminal selector)…"
brew list fzf >/dev/null 2>&1 || brew install fzf

say "Installing webtorrent-cli (torrent engine)…"
brew list webtorrent-cli >/dev/null 2>&1 || brew install webtorrent-cli

say "Installing media player (IINA)…"
# IINA is fine whether it was installed via brew or manually — only install
# the cask when the app is truly absent, since brew refuses to overwrite it.
if [ ! -x /Applications/IINA.app/Contents/MacOS/iina ] \
   && ! brew list --cask iina >/dev/null 2>&1; then
    brew install --cask iina || err "IINA install failed — install mpv manually: brew install mpv"
fi

# Put IINA's CLI on PATH so webtorrent can launch it for streaming
if [ -x /Applications/IINA.app/Contents/MacOS/iina ]; then
    LINK_DIR="/usr/local/bin"
    [ -w "$LINK_DIR" ] && ln -sf /Applications/IINA.app/Contents/MacOS/iina "$LINK_DIR/iina" 2>/dev/null \
        || { mkdir -p "$HOME/.local/bin" && ln -sf /Applications/IINA.app/Contents/MacOS/iina "$HOME/.local/bin/iina" 2>/dev/null; } || true
fi

# ---- Install the command -------------------------------------------------
BIN_DIR="/usr/local/bin"
if [ ! -w "$BIN_DIR" ]; then
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
           say "Added $BIN_DIR to PATH (restart your terminal or run: source ~/.zshrc)" ;;
    esac
fi

say "Installing sail…"
# the script resolves its lib/ relative to itself, so install the package to a
# stable home and symlink the command onto PATH.
PKG_HOME="$HOME/.sail"
rm -rf "$PKG_HOME"
mkdir -p "$PKG_HOME"
cp -R bin lib "$PKG_HOME/"
ln -sf "$PKG_HOME/bin/sail" "$BIN_DIR/sail"

mkdir -p "$HOME/Downloads/torrents"

# ---- Verify --------------------------------------------------------------
say "Verifying installation…"
for cmd in fzf webtorrent python3; do
    command -v "$cmd" >/dev/null 2>&1 || err "$cmd not found after install."
done
command -v iina >/dev/null 2>&1 || command -v mpv >/dev/null 2>&1 || \
    say "Note: iina/mpv not on PATH — IINA app is installed; streaming will still work."

printf '\n\033[1;32mDone!\033[0m Try it with:\n\n    sail ubuntu\n\n'
