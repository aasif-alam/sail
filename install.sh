#!/usr/bin/env bash
# sail installer — installs all dependencies and the sail command itself.
set -euo pipefail

# color only a real terminal (and honor NO_COLOR, https://no-color.org)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GRN=$'\e[1;32m'; RED=$'\e[1;31m'; RST=$'\e[0m'
else
    GRN=""; RED=""; RST=""
fi
say() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
err() { printf '%sError:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---- one-line install (curl | bash) ---------------------------------------
# Piping this file straight from GitHub runs it with no repo on disk ($0 is
# "bash", so there is no bin/ or lib/ next to the script). Fetch a tarball of
# main into a temp dir and re-run the real installer from there — the tarball
# needs only curl + tar, both stock on macOS, so git isn't a prerequisite.
# A cloned checkout always has bin/sail beside this script, so this block
# only ever fires for the piped path.
if [ ! -f "$(dirname "$0")/bin/sail" ]; then
    say "Fetching the sail repository…"
    TMP="$(mktemp -d)"
    curl -fsSL https://github.com/aasif-alam/sail/archive/refs/heads/main.tar.gz \
        | tar -xz -C "$TMP"
    exec bash "$TMP"/sail-main/install.sh
fi

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

# webtorrent-cli 6.x ships webtorrent 2.8.5, which crashes on every
# torrent add once its uint8-util dependency resolves to >=2.3 — repair
# right away (no-op when the install is healthy)
bash lib/fix-webtorrent.sh

say "Installing media player (IINA)…"
# IINA is fine whether it was installed via brew or manually — only install
# the cask when the app is truly absent, since brew refuses to overwrite it.
if [ ! -x /Applications/IINA.app/Contents/MacOS/iina ] \
   && ! brew list --cask iina >/dev/null 2>&1; then
    brew install --cask iina || err "IINA install failed — install mpv manually: brew install mpv"
fi

# Put IINA's CLI helper on PATH — bin/sail launches iina-cli (the plain
# iina binary does not accept --keep-running/--mpv-sub-files)
if [ -x /Applications/IINA.app/Contents/MacOS/iina-cli ]; then
    LINK_DIR="/usr/local/bin"
    [ -w "$LINK_DIR" ] && ln -sf /Applications/IINA.app/Contents/MacOS/iina-cli "$LINK_DIR/iina-cli" 2>/dev/null \
        || { mkdir -p "$HOME/.local/bin" && ln -sf /Applications/IINA.app/Contents/MacOS/iina-cli "$HOME/.local/bin/iina-cli" 2>/dev/null; } || true
fi

# ---- Install the command -------------------------------------------------
BIN_DIR="/usr/local/bin"
if [ ! -w "$BIN_DIR" ]; then
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    # single-quoted below on purpose: $HOME/$PATH must stay literal so
    # they're re-evaluated by zsh at shell startup, not expanded once here
    # shellcheck disable=SC2016
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) if ! grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc" 2>/dev/null; then
               {
                   echo '# sail: add ~/.local/bin to PATH (removed by uninstall.sh)'
                   echo 'export PATH="$HOME/.local/bin:$PATH"'
               } >> "$HOME/.zshrc"
           fi
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

# ---- Shell completion (best-effort — skipped if the target dir is absent) --
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [ -n "$BREW_PREFIX" ] && [ -d "$BREW_PREFIX/share/zsh/site-functions" ]; then
    cp completions/_sail "$BREW_PREFIX/share/zsh/site-functions/_sail" 2>/dev/null \
        && say "Installed zsh completion."
fi
if [ -n "$BREW_PREFIX" ] && [ -d "$BREW_PREFIX/etc/bash_completion.d" ]; then
    cp completions/sail.bash "$BREW_PREFIX/etc/bash_completion.d/sail" 2>/dev/null \
        && say "Installed bash completion."
fi

# ---- Verify --------------------------------------------------------------
say "Verifying installation…"
for cmd in fzf webtorrent python3; do
    command -v "$cmd" >/dev/null 2>&1 || err "$cmd not found after install."
done
command -v iina-cli >/dev/null 2>&1 \
    || [ -x /Applications/IINA.app/Contents/MacOS/iina-cli ] \
    || command -v mpv >/dev/null 2>&1 \
    || say "Note: no iina-cli or mpv found — streaming needs one of them."

printf '\n%sDone!%s Try it with:\n\n    sail ubuntu\n\n' "$GRN" "$RST"
