#!/usr/bin/env bash
# CLI contract tests: help/version exit statuses, empty-query handling, and
# path expansion. These paths never touch the network.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

run() {  # run sail, capture stdout+stderr and exit status
    local rc=0
    "$@" >"$W/out" 2>"$W/err" || rc=$?
    printf '%s' "$rc"
}

# --- 1. -h is a successful request for help -------------------------------
RC="$(run bash bin/sail -h)"
if [ "$RC" -eq 0 ] \
   && grep -q 'sail <query>' "$W/out" \
   && grep -q 'sail -h' "$W/out"; then
    ok "-h prints usage and exits 0"
else
    fail "-h: rc=$RC out=[$(tr '\n' ' ' < "$W/out")]"
fi

# --- 2. no query / blank query / unknown flag are usage errors -------------
RC="$(run bash bin/sail)"
[ "$RC" -eq 1 ] && ok "no arguments: exit 1" || fail "no arguments: rc=$RC"
RC="$(run bash bin/sail "")"
[ "$RC" -eq 1 ] && ok "empty query: exit 1" || fail "empty query: rc=$RC"
RC="$(run bash bin/sail -d "")"
[ "$RC" -eq 1 ] && ok "empty -d query: exit 1" || fail "empty -d query: rc=$RC"
RC="$(run bash bin/sail -x)"
[ "$RC" -eq 1 ] && ok "unknown flag: exit 1" || fail "unknown flag: rc=$RC"

# --- 3. --version still exits 0 -------------------------------------------
RC="$(run bash bin/sail --version)"
if [ "$RC" -eq 0 ] && grep -Eq '^sail [0-9]+\.[0-9]+\.[0-9]+$' "$W/out"; then
    ok "--version prints the version and exits 0"
else
    fail "--version: rc=$RC out=[$(cat "$W/out")]"
fi

# --- 4. an empty watchlist is a clean no-op (and SAIL_WLIST is honored) -----
RC="$(run env SAIL_WLIST="$W/none.tsv" bash bin/sail wlist)"
if [ "$RC" -eq 0 ] && grep -q 'watchlist is empty' "$W/out"; then
    ok "empty watchlist exits 0"
else
    fail "empty watchlist: rc=$RC out=[$(cat "$W/out")]"
fi

# --- 5. ~ in path overrides expands to $HOME ------------------------------
awk '/^expand_tilde\(\) \{/ { copy = 1 } copy { print } copy && /^\}/ { exit }' \
    bin/sail > "$W/expand.sh"
# shellcheck disable=SC1090
. "$W/expand.sh"
if [ "$(expand_tilde '~/Videos')" = "$HOME/Videos" ] \
   && [ "$(expand_tilde '~')" = "$HOME" ] \
   && [ "$(expand_tilde '/tmp/x')" = "/tmp/x" ]; then
    ok "expand_tilde handles ~, ~/path, and plain paths"
else
    fail "expand_tilde: [$(expand_tilde '~/Videos')] [$(expand_tilde '~')]"
fi

# wlist storage uses the same expansion
if [ "$(SAIL_WLIST='~/sail-test.tsv' bash -c '. lib/wlist.sh; wlist_file')" \
     = "$HOME/sail-test.tsv" ]; then
    ok "wlist_file expands a leading ~"
else
    fail "wlist_file did not expand ~"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
