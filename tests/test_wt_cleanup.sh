#!/usr/bin/env bash
# Regression tests for wt.js's unselected-file cleanup.
#
# A download run removes fragments of unselected files so the folder holds
# only what was picked. It used to do that for every unselected path, even
# ones that were already on disk from an earlier download — data loss.
# cleanupUnselected must now leave pre-existing paths alone while still
# removing fragments created by this run.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

command -v node >/dev/null 2>&1 || { echo "node not found — skipping"; exit 0; }

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# requiring the module must not run main() (main would call usage() and exit 3)
rc=0
node -e "require('./lib/wt.js')" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "requiring wt.js does not execute the CLI"
else
    fail "require ran the CLI (rc=$rc)"
fi

OUT="$W/downloads"
mkdir -p "$OUT/Season 1" "$OUT/Empty Pre"
printf 'earlier download\n' > "$OUT/Season 1/preexisting.bin"
printf 'selected this run\n' > "$OUT/Season 1/selected.bin"

node - "$OUT" <<'JS'
const fs = require('fs')
const path = require('path')
const { cleanupUnselected, snapshotPaths } = require('./lib/wt.js')
const out = process.argv[2]

// snapshot exactly when wt.js does — before client.add() creates fragments
const pre = snapshotPaths(out)

// pieces shared with selected files create these after the snapshot
fs.writeFileSync(path.join(out, 'Season 1', 'fragment.bin'), 'junk')
fs.mkdirSync(path.join(out, 'Season 2'))
fs.writeFileSync(path.join(out, 'Season 2', 'ep2.bin'), 'junk')
fs.writeFileSync(path.join(out, 'Empty Pre', 'frag.bin'), 'junk')

cleanupUnselected([
  { path: 'Season 1/preexisting.bin' },  // 0: unselected but pre-existing
  { path: 'Season 1/selected.bin' },     // 1: selected
  { path: 'Season 1/fragment.bin' },     // 2: unselected fragment (new)
  { path: 'Season 2/ep2.bin' },          // 3: unselected fragment (new)
  { path: 'Empty Pre/frag.bin' }         // 4: new file in pre-existing dir
], out, [1], pre)
JS

if [ -f "$OUT/Season 1/preexisting.bin" ] \
   && [ "$(cat "$OUT/Season 1/preexisting.bin")" = "earlier download" ]; then
    ok "pre-existing unselected file survives"
else
    fail "pre-existing file was deleted"
fi

if [ -f "$OUT/Season 1/selected.bin" ]; then
    ok "selected file survives"
else
    fail "selected file was deleted"
fi

if [ ! -e "$OUT/Season 1/fragment.bin" ] && [ ! -e "$OUT/Season 2/ep2.bin" ]; then
    ok "new fragments from this run are removed"
else
    fail "fragment cleanup missed: $(find "$OUT" -type f | tr '\n' ' ')"
fi

if [ ! -e "$OUT/Season 2" ]; then
    ok "empty fragment directory removed"
else
    fail "empty fragment directory left behind"
fi

if [ -d "$OUT/Empty Pre" ] && [ ! -e "$OUT/Empty Pre/frag.bin" ]; then
    ok "pre-existing empty directory survives fragment cleanup"
else
    fail "pre-existing directory was removed with its fragment"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
