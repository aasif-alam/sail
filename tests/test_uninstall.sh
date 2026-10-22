#!/usr/bin/env bash
# Regression tests for uninstall.sh's cleanup.
#
# The installer used to create an `iina` symlink (sail now calls iina-cli) and
# append a PATH line to ~/.zshrc that uninstall never removed. Run a copy of
# the script with its two system bin paths redirected into a temp dir so the
# real machine is never touched.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/home/.sail" "$W/bin" "$W/home/.sail.new.1234" "$W/home/.sail.old.1234" \
         "$W/home/.config/sail"
printf 'installed\n' > "$W/home/.sail/marker"
printf 'sail\n' > "$W/bin/sail"
printf 'tpb\n' > "$W/home/.config/sail/sources.conf"
ln -s /Applications/IINA.app/Contents/MacOS/iina-cli "$W/bin/iina-cli"
ln -s /somewhere/else "$W/bin/keep-me"
cat > "$W/home/.zshrc" <<'EOF'
export EDITOR=vim
# sail: add ~/.local/bin to PATH (removed by uninstall.sh)
export PATH="$HOME/.local/bin:$PATH"
export KEEP=1
EOF
cat > "$W/home/.bash_profile" <<'EOF'
export KEEP_BASH=1
# sail: add ~/.local/bin to PATH (removed by uninstall.sh)
export PATH="$HOME/.local/bin:$PATH"
EOF

# redirect both hardcoded /usr/local/bin references into the temp bin dir
sed "s#/usr/local/bin#$W/bin#g" uninstall.sh > "$W/uninstall.sh"

# fake brew so the real Homebrew prefix is never touched
mkdir -p "$W/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$W/fakebin/brew"
chmod +x "$W/fakebin/brew"

HOME="$W/home" PATH="$W/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$W/uninstall.sh" >/dev/null 2>&1 || true

if [ ! -e "$W/bin/sail" ] && [ ! -e "$W/home/.sail" ]; then
    ok "removes the command and ~/.sail"
else
    fail "command or ~/.sail left behind"
fi

if [ ! -e "$W/home/.sail.new.1234" ] && [ ! -e "$W/home/.sail.old.1234" ]; then
    ok "removes interrupted-install staging directories"
else
    fail "install staging directory left behind"
fi

if [ -e "$W/home/.config/sail" ]; then
    ok "settings survive a normal uninstall"
else
    fail "normal uninstall removed the settings"
fi

if [ ! -e "$W/bin/iina-cli" ]; then
    ok "removes the installer's iina-cli symlink"
else
    fail "iina-cli symlink left behind"
fi

if [ -L "$W/bin/keep-me" ]; then
    ok "leaves unrelated symlinks alone"
else
    fail "unrelated symlink was removed"
fi

# shellcheck disable=SC2016  # matching the literal line the installer wrote
if grep -q 'EDITOR=vim' "$W/home/.zshrc" \
   && grep -q 'KEEP=1' "$W/home/.zshrc" \
   && ! grep -q 'sail: add ~/.local/bin' "$W/home/.zshrc" \
   && ! grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$W/home/.zshrc"; then
    ok "removes its PATH block, keeps the rest of ~/.zshrc"
else
    fail "$HOME/.zshrc cleanup left: [$(tr '\n' '|' < "$W/home/.zshrc")]"
fi

# shellcheck disable=SC2016  # matching the literal line the installer wrote
if grep -q 'KEEP_BASH=1' "$W/home/.bash_profile" \
   && ! grep -q 'sail: add' "$W/home/.bash_profile" \
   && ! grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$W/home/.bash_profile"; then
    ok "removes its PATH block from ~/.bash_profile too"
else
    fail "$HOME/.bash_profile cleanup left: [$(tr '\n' '|' < "$W/home/.bash_profile")]"
fi

# --- --purge also removes settings -----------------------------------------
mkdir -p "$W/home2/.config/sail"
printf 'nyaa\n' > "$W/home2/.config/sail/sources.conf"
HOME="$W/home2" PATH="$W/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$W/uninstall.sh" --purge >/dev/null 2>&1 || true
if [ ! -e "$W/home2/.config/sail" ]; then
    ok "--purge removes ~/.config/sail"
else
    fail "--purge left the config behind"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
