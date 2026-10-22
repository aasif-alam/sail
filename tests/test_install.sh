#!/usr/bin/env bash
# Tests for install.sh that don't touch the machine: argument handling and a
# full --dry-run. The dry run must describe the install (deps, package swap,
# PATH) without creating or modifying anything.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# --- help and bad options --------------------------------------------------
RC=0
bash install.sh --help > "$W/help" 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && grep -q -- '--dry-run' "$W/help"; then
    ok "--help exits 0 and documents --dry-run"
else
    fail "--help: rc=$RC"
fi
RC=0
bash install.sh --nonsense > "$W/bad" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
    ok "unknown option exits non-zero"
else
    fail "unknown option exited 0"
fi

# --- a dry run changes nothing --------------------------------------------
mkdir -p "$W/home" "$W/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$W/fakebin/brew"
chmod +x "$W/fakebin/brew"
printf 'export KEEP=1\n' > "$W/home/.zshrc"
cp "$W/home/.zshrc" "$W/zshrc.before"

RC=0
HOME="$W/home" PATH="$W/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash install.sh --dry-run > "$W/dry" 2>&1 || RC=$?

if [ "$RC" -eq 0 ] && grep -q 'Dry run complete' "$W/dry"; then
    ok "dry run exits 0"
else
    fail "dry run: rc=$RC out=[$(tr '\n' ' ' < "$W/dry")]"
fi
if grep -q 'would install fzf' "$W/dry" \
   && grep -q 'would install webtorrent-cli' "$W/dry" \
   && grep -q 'would install bin/ and lib/' "$W/dry"; then
    ok "dry run reports the dependency and package steps"
else
    fail "dry run plan is incomplete: $(tr '\n' ' ' < "$W/dry")"
fi
if [ ! -e "$W/home/.sail" ] && [ ! -e "$W/home/.local/bin/sail" ] \
   && [ ! -e "$W/home/Downloads/torrents" ]; then
    ok "dry run installed nothing"
else
    fail "dry run created files"
fi
if cmp -s "$W/home/.zshrc" "$W/zshrc.before"; then
    ok "dry run left the startup file alone"
else
    fail "dry run modified ~/.zshrc"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
