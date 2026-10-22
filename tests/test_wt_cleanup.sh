#!/usr/bin/env bash
# Regression tests for wt.js's staged downloads.
#
# A download run used to write straight into the destination and then delete
# fragments of unselected files — but bittorrent pieces don't align to file
# boundaries, so one episode of a season pack writes pieces of its
# neighbours. The old cleanup could also delete a pre-existing file that
# happened to share a path. Downloads now land in a hidden per-run stage and
# only the selected files are moved out; the rest of the stage (fragments of
# unselected files) is deleted wholesale, and a run interrupted by a crash
# leaves a stage the next run recognises by its dead pid and removes.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

if ! command -v node >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
        echo "node not found — CI requires it" >&2
        exit 1
    fi
    echo "node not found — skipping"
    exit 0
fi

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
mkdir -p "$OUT/Season 1"
printf 'earlier download\n' > "$OUT/Season 1/preexisting.bin"
printf 'old\n' > "$OUT/Season 1/selected.bin"

NODE_RC=0
NODE_OUT="$(node - "$OUT" <<'JS'
const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')
const wt = require('./lib/wt.js')
const out = process.argv[2]

const checks = []
const check = (name, cond) => checks.push([name, !!cond])

// exported helpers exist (the get path in wt.js uses them)
check('exports staging helpers',
      typeof wt.stagingDirFor === 'function'
      && typeof wt.cleanupStaleStaging === 'function'
      && typeof wt.moveSelected === 'function')

// a stage lives inside the destination, hidden, and carries our pid
const stage = wt.stagingDirFor(out)
check('stage is inside the destination', path.dirname(stage) === out)
check('stage is hidden and pid-tagged',
      path.basename(stage).startsWith(wt.STAGING_PREFIX)
      && path.basename(stage).startsWith(`${wt.STAGING_PREFIX}${process.pid}-`))

fs.mkdirSync(path.join(stage, 'Season 1'), { recursive: true })
fs.writeFileSync(path.join(stage, 'Season 1', 'selected.bin'), 'new data')
// fragments of unselected neighbours: these must never reach the destination
fs.writeFileSync(path.join(stage, 'Season 1', 'fragment.bin'), 'junk')
fs.mkdirSync(path.join(stage, 'Season 2'))
fs.writeFileSync(path.join(stage, 'Season 2', 'ep2.bin'), 'junk')

const files = [
  { path: 'Season 1/preexisting.bin' },  // 0: not selected by this run
  { path: 'Season 1/selected.bin' },     // 1: selected
  { path: 'Season 1/fragment.bin' },     // 2: unselected fragment
  { path: 'Season 2/ep2.bin' },          // 3: unselected fragment
]
const moved = wt.moveSelected(files, [1], stage, out)
check('moveSelected reports only the picked file',
      moved.length === 1 && moved[0] === 'Season 1/selected.bin')
check('picked file lands in place',
      fs.readFileSync(path.join(out, 'Season 1', 'selected.bin'), 'utf8') === 'new data')
check('a picked file replaces the old copy',
      fs.readFileSync(path.join(out, 'Season 1', 'selected.bin'), 'utf8') !== 'old')
check('unselected fragments stay in the stage',
      fs.existsSync(path.join(stage, 'Season 1', 'fragment.bin'))
      && fs.existsSync(path.join(stage, 'Season 2', 'ep2.bin')))
check('pre-existing file is untouched',
      fs.readFileSync(path.join(out, 'Season 1', 'preexisting.bin'), 'utf8').trimEnd()
      === 'earlier download')

// removing the stage (what wt.js does after the move) leaves only the pick
fs.rmSync(stage, { recursive: true, force: true })
check('no fragment reaches the destination',
      !fs.existsSync(path.join(out, 'Season 1', 'fragment.bin'))
      && !fs.existsSync(path.join(out, 'Season 2', 'ep2.bin')))
check('stage is gone', !fs.existsSync(stage))

// stale-stage cleanup: dead pid removed, live pid kept
const dead = spawnSync(process.execPath, ['-e', '']).pid
const stale = path.join(out, `${wt.STAGING_PREFIX}${dead}-stale`)
const live = path.join(out, `${wt.STAGING_PREFIX}${process.pid}-live`)
fs.mkdirSync(stale)
fs.writeFileSync(path.join(stale, 'leftover.bin'), 'x')
fs.mkdirSync(live)
wt.cleanupStaleStaging(out)
check('a stage from a dead run is removed', !fs.existsSync(stale))
check('a stage from a live run is kept', fs.existsSync(live))

for (const [name, pass] of checks) {
  console.log(`${pass ? 'node-ok' : 'node-fail'}\t${name}`)
}
process.exit(checks.every(([, p]) => p) ? 0 : 1)
JS
)" || NODE_RC=$?

while IFS=$'\t' read -r status name; do
    case "$status" in
        node-ok)   ok "$name" ;;
        node-fail) fail "$name" ;;
    esac
done <<< "$NODE_OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && [ "$NODE_RC" -eq 0 ]
