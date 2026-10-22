#!/usr/bin/env bash
# sail installer — installs all dependencies and the sail command itself.
#
#   bash install.sh [--dry-run]
#
# --dry-run prints every change it would make (nothing is installed, no file
# is written). The one-line form forwards it too:
#   curl -fsSL .../install.sh | bash -s -- --dry-run
#
# SAIL_REF selects the branch or tag to fetch when piped (default main), and
# SAIL_TARBALL_SHA256 pins that download: when set, the archive's SHA-256 must
# match or the installer stops before running anything.
set -euo pipefail

# color only a real terminal (and honor NO_COLOR, https://no-color.org)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GRN=$'\e[1;32m'; RED=$'\e[1;31m'; RST=$'\e[0m'
else
    GRN=""; RED=""; RST=""
fi
say() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%sNote:%s %s\n' "$GRN" "$RST" "$*"; }
err() { printf '%sError:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            cat <<'EOF'
sail installer — installs Homebrew deps, the sail command, and completions.

Usage: bash install.sh [--dry-run]

  --dry-run   print every change without making it

Environment:
  SAIL_REF             branch or tag to fetch when piped (default: main)
  SAIL_TARBALL_SHA256  require this SHA-256 for the downloaded archive
EOF
            exit 0 ;;
        *) err "unknown option: $arg (try --help)" ;;
    esac
done

# ---- one-line install (curl | bash) ---------------------------------------
# Piping this file straight from GitHub runs it with no repo on disk
# (BASH_SOURCE is empty, so there is no bin/ or lib/ next to the script).
# Fetch a tarball into a temp dir and run the real installer from there — the
# tarball needs only curl + tar, both stock on macOS, so git isn't a
# prerequisite. A cloned checkout always has bin/sail beside this script, so
# this block only fires for the piped path.
SELF="${BASH_SOURCE[0]:-}"
SELF_DIR=""
if [ -n "$SELF" ]; then
    SELF_DIR="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)" \
        || SELF_DIR=""
fi
if [ -z "$SELF_DIR" ] || [ ! -f "$SELF_DIR/bin/sail" ]; then
    REF="${SAIL_REF:-main}"
    say "Fetching sail ($REF)…"
    TMP="$(mktemp -d)"
    TARBALL="$TMP/sail.tar.gz"
    curl -fsSL \
        "https://github.com/aasif-alam/sail/archive/refs/heads/$REF.tar.gz" \
        -o "$TARBALL" \
        || curl -fsSL \
            "https://github.com/aasif-alam/sail/archive/refs/tags/$REF.tar.gz" \
            -o "$TARBALL" \
        || err "could not download sail $REF — check SAIL_REF."

    if [ -n "${SAIL_TARBALL_SHA256:-}" ]; then
        ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
        [ "$ACTUAL" = "$SAIL_TARBALL_SHA256" ] \
            || err "checksum mismatch for sail $REF (got $ACTUAL)"
        say "Checksum verified."
    fi

    # read the real top-level directory instead of guessing how a branch or
    # tag is named; listing to a file avoids tar's SIGPIPE under pipefail
    tar -tzf "$TARBALL" > "$TMP/archive.list" 2>/dev/null \
        || err "downloaded archive is not a valid tarball."
    TOP="$(awk 'NR == 1 { sub(/\/.*/, ""); print; exit }' "$TMP/archive.list")"
    if [ -z "$TOP" ] || [ ! -f "$TMP/$TOP/install.sh" ]; then
        err "unexpected archive layout (no $TOP/install.sh)"
    fi
    tar -xzf "$TARBALL" -C "$TMP"
    ( trap 'rm -rf "$TMP"' EXIT; bash "$TMP/$TOP/install.sh" "$@" )
    exit $?
fi

cd "$SELF_DIR"

# a previous interrupted install must not be mistaken for a live one
if [ "$DRY_RUN" = 0 ]; then
    rm -rf "$HOME/.sail.new."* "$HOME/.sail.old."* 2>/dev/null || true
fi

# run a mutating command, or just report it in a dry run
do_step() {
    if [ "$DRY_RUN" = 1 ]; then
        say "[dry-run] would run: $*"
    else
        "$@"
    fi
}

install_formula() {  # $1 = brew formula
    if [ "$DRY_RUN" = 1 ]; then
        say "[dry-run] would install $1 (if missing)"
        return 0
    fi
    brew list "$1" >/dev/null 2>&1 || brew install "$1"
}

# ---- Homebrew ------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
        say "[dry-run] would install Homebrew"
    else
        say "Installing Homebrew (package manager)…"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # shellcheck disable=SC1091
        eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    fi
fi
if [ "$DRY_RUN" = 0 ]; then
    command -v brew >/dev/null 2>&1 || err "Homebrew install failed."
fi

# ---- Dependencies --------------------------------------------------------
# python3 comes with macOS via CommandLineTools; ensure it exists.
if ! command -v python3 >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
        say "[dry-run] would install python3"
    else
        say "Installing python3…"
        xcode-select --install 2>/dev/null || brew install python3
    fi
fi

say "Installing fzf (terminal selector)…"
install_formula fzf

say "Installing webtorrent-cli (torrent engine)…"
install_formula webtorrent-cli

# webtorrent-cli 6.x ships webtorrent 2.8.5, which crashes on every
# torrent add once its uint8-util dependency resolves to >=2.3 — repair
# right away (no-op when the install is healthy)
if [ "$DRY_RUN" = 0 ]; then
    bash lib/fix-webtorrent.sh
fi

say "Installing media player (IINA)…"
# IINA is fine whether it was installed via brew or manually — only install
# the cask when the app is truly absent, since brew refuses to overwrite it.
if [ ! -x /Applications/IINA.app/Contents/MacOS/iina ] \
   && ! { [ "$DRY_RUN" = 0 ] && brew list --cask iina >/dev/null 2>&1; }; then
    if [ "$DRY_RUN" = 1 ]; then
        say "[dry-run] would install IINA (if missing)"
    else
        brew install --cask iina \
            || err "IINA install failed — install mpv manually: brew install mpv"
    fi
fi

# Put IINA's CLI helper on PATH — bin/sail launches iina-cli (the plain
# iina binary does not accept --keep-running/--mpv-sub-files)
if [ -x /Applications/IINA.app/Contents/MacOS/iina-cli ]; then
    LINK_DIR="/usr/local/bin"
    if [ -w "$LINK_DIR" ]; then
        do_step ln -sf /Applications/IINA.app/Contents/MacOS/iina-cli "$LINK_DIR/iina-cli"
    else
        do_step mkdir -p "$HOME/.local/bin"
        do_step ln -sf /Applications/IINA.app/Contents/MacOS/iina-cli "$HOME/.local/bin/iina-cli"
    fi
fi

# ---- Install the command -------------------------------------------------
BIN_DIR="/usr/local/bin"
if [ ! -w "$BIN_DIR" ]; then
    BIN_DIR="$HOME/.local/bin"
    if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$BIN_DIR"
    fi
    # single-quoted below on purpose: $HOME/$PATH must stay literal so
    # they're re-evaluated by the shell at startup, not expanded once here
    # shellcheck disable=SC2016
    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            # append to the startup file the user's shell actually reads
            case "${SHELL:-}" in
                */bash) RC="$HOME/.bash_profile" ;;
                *)      RC="$HOME/.zshrc" ;;
            esac
            if [ "$DRY_RUN" = 1 ]; then
                say "[dry-run] would add $BIN_DIR to PATH in $RC"
            elif ! grep -qxF "$PATH_LINE" "$RC" 2>/dev/null; then
                {
                    echo '# sail: add ~/.local/bin to PATH (removed by uninstall.sh)'
                    echo "$PATH_LINE"
                } >> "$RC"
                say "Added $BIN_DIR to PATH (restart your terminal or run: source $RC)"
            fi
            ;;
    esac
fi

say "Installing sail…"
# the script resolves its lib/ relative to itself, so install the package to a
# stable home and symlink the command onto PATH. Build the new tree beside the
# old one and swap it in: an interrupted copy leaves the previous install
# working instead of a half-written ~/.sail.
PKG_HOME="$HOME/.sail"
STAGE="$HOME/.sail.new.$$"
if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] would install bin/ and lib/ to $PKG_HOME and link $BIN_DIR/sail"
else
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R bin lib "$STAGE/"
    chmod +x "$STAGE/bin/sail"
    OLD="$HOME/.sail.old.$$"
    rm -rf "$OLD"
    if [ -e "$PKG_HOME" ] && ! mv "$PKG_HOME" "$OLD"; then
        rm -rf "$STAGE"
        err "could not move the old install aside."
    fi
    if ! mv "$STAGE" "$PKG_HOME"; then
        if [ -e "$OLD" ]; then
            mv "$OLD" "$PKG_HOME" 2>/dev/null || true
        fi
        rm -rf "$STAGE"
        err "could not install to $PKG_HOME."
    fi
    rm -rf "$OLD"
    ln -sfn "$PKG_HOME/bin/sail" "$BIN_DIR/sail"
fi

do_step mkdir -p "$HOME/Downloads/torrents"

# ---- Shell completion (best-effort — skipped if the target dir is absent) --
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [ -n "$BREW_PREFIX" ] && [ -d "$BREW_PREFIX/share/zsh/site-functions" ]; then
    do_step cp completions/_sail "$BREW_PREFIX/share/zsh/site-functions/_sail"
    say "Installed zsh completion."
fi
if [ -n "$BREW_PREFIX" ] && [ -d "$BREW_PREFIX/etc/bash_completion.d" ]; then
    do_step cp completions/sail.bash "$BREW_PREFIX/etc/bash_completion.d/sail"
    say "Installed bash completion."
fi

# ---- Verify --------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
    printf '\n%sDry run complete.%s No changes were made.\n' "$GRN" "$RST"
    exit 0
fi

say "Verifying installation…"
for cmd in fzf webtorrent python3; do
    command -v "$cmd" >/dev/null 2>&1 || err "$cmd not found after install."
done
command -v iina-cli >/dev/null 2>&1 \
    || [ -x /Applications/IINA.app/Contents/MacOS/iina-cli ] \
    || command -v mpv >/dev/null 2>&1 \
    || warn "no iina-cli or mpv found — streaming needs one of them."

SAIL_VER="$("$BIN_DIR/sail" --version 2>/dev/null || true)"
case "$SAIL_VER" in
    sail\ [0-9]*) ;;
    *) err "installed command did not run (got: ${SAIL_VER:-nothing})" ;;
esac
say "Verified: $SAIL_VER"

printf '\n%sDone!%s Try it with:\n\n    sail ubuntu\n\n' "$GRN" "$RST"
