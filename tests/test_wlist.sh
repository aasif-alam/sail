#!/usr/bin/env bash
# Unit tests for lib/wlist.sh — sail's watchlist storage.
#
# Pure bash, no network, no fzf: the fzf UI lives in bin/sail, everything
# testable here is the storage layer. SAIL_WLIST points every test at a
# throwaway file so the user's real watchlist is never touched.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib/wlist.sh
. lib/wlist.sh

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
export SAIL_WLIST="$W/wlist.tsv"

M1="magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&dn=one&tr=udp%3A%2F%2Fa"
M1B="magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&dn=one&tr=udp%3A%2F%2Fb"
M2="magnet:?xt=urn:btih:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB&dn=two"
M3="magnet:?xt=urn:btih:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC&dn=three"
F1="FETCH:https://1337x.to/torrent/123/some-release/"

nf() { wc -l < "$(wlist_file)" | tr -d ' '; }
last_title() { tail -1 "$(wlist_file)" | cut -f1; }

# 1. add creates the file and parent dirs, writes a 3-field TSV line
rc=0; wlist_add "One" "$M1" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(nf)" -eq 1 ] \
   && [ "$(awk -F'\t' '{print NF}' "$(wlist_file)")" = 3 ] \
   && [ "$(awk -F'\t' '{print $1}' "$(wlist_file)")" = "One" ] \
   && case "$(awk -F'\t' '{print $3}' "$(wlist_file)")" in
        ''|*[!0-9]*) false ;; *) true ;; esac; then
    ok "add: new entry with title, magnet, numeric epoch"
else
    fail "add: rc=$rc lines=$(nf)"
fi

# 2. same info hash via a different magnet (other trackers) dedups
rc=0; wlist_add "One" "$M1B" || rc=$?
if [ "$rc" -eq 1 ] && [ "$(nf)" -eq 1 ]; then
    ok "dedup by info hash: duplicate rejected (rc 1)"
else
    fail "dedup by info hash: rc=$rc lines=$(nf)"
fi

# 3. different hash -> new entry appended last (newest last in the file)
wlist_add "Two" "$M2"
if [ "$(nf)" -eq 2 ] && [ "$(last_title)" = "Two" ]; then
    ok "second entry appended last"
else
    fail "append: lines=$(nf) last=$(last_title)"
fi

# 4. re-adding an existing entry bumps it to newest without duplicating
sleep 1
rc=0; wlist_add "One (updated)" "$M1" || rc=$?
if [ "$rc" -eq 1 ] && [ "$(nf)" -eq 2 ] && [ "$(last_title)" = "One (updated)" ]; then
    ok "re-add: bumped to newest, title refreshed, no duplicate"
else
    fail "re-add: rc=$rc lines=$(nf) last=$(last_title)"
fi

# 5. FETCH: urls (scraped sources, no hash) dedup by exact string
wlist_add "Fetched" "$F1"
rc=0; wlist_add "Fetched" "$F1" || rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c "^Fetched" "$(wlist_file)")" -eq 1 ]; then
    ok "FETCH: url dedups verbatim"
else
    fail "FETCH dedup: rc=$rc"
fi

# 6. titles are sanitized: tabs/newlines collapse to spaces, edges trimmed
wlist_add "$(printf '  bad\ttitle\nname  ')" "$M3"
if [ "$(last_title)" = "bad title name" ]; then
    ok "title sanitized (tabs/newlines -> space, trimmed)"
else
    fail "sanitize: got [$(last_title)]"
fi

# 7. wlist_remove by magnet removes exactly that entry
before="$(nf)"
rc=0; wlist_remove "$M1" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(nf)" -eq $((before - 1)) ] \
   && ! grep -q "^One" "$(wlist_file)"; then
    ok "remove by magnet"
else
    fail "remove: rc=$rc before=$before after=$(nf)"
fi

# 8. removing a magnet that is not stored returns 1 and changes nothing
before_md5="$(md5 -q "$(wlist_file)")"
rc=0; wlist_remove "magnet:?xt=urn:btih:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD" || rc=$?
if [ "$rc" -eq 1 ] && [ "$(md5 -q "$(wlist_file)")" = "$before_md5" ]; then
    ok "remove of unknown magnet: rc 1, file untouched"
else
    fail "remove unknown: rc=$rc"
fi

# 9. empty title or empty magnet is rejected, file untouched
before_md5="$(md5 -q "$(wlist_file)")"
rc=0; wlist_add "" "$M2" || rc=$?
rc2=0; wlist_add "x" "" || rc2=$?
if [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ] \
   && [ "$(md5 -q "$(wlist_file)")" = "$before_md5" ]; then
    ok "empty title/magnet rejected (rc 2)"
else
    fail "empty args: rc=$rc rc2=$rc2"
fi

# 10. wlist_lookup returns title and magnet for a 1-based row id
printf 'T1\tmagnet:?xt=urn:btih:EE\nT2\tmagnet:?xt=urn:btih:FF\n' > "$W/rows.tsv"
if [ "$(wlist_lookup "$W/rows.tsv" 2)" = "$(printf 'T2\tmagnet:?xt=urn:btih:FF')" ]; then
    ok "wlist_lookup by row id"
else
    fail "wlist_lookup: got [$(wlist_lookup "$W/rows.tsv" 2)]"
fi
rc=0; wlist_lookup "$W/rows.tsv" 99 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "wlist_lookup bad id fails" || fail "wlist_lookup bad id"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
