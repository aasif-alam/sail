#!/usr/bin/env bash
# Tests for wt.js meta mode — the single-process replacement for the old
# webtorrent downloadmeta + webtorrent info + python pipeline.
#
# The success path is fully offline: `webtorrent create` builds a local
# multi-file torrent, and meta mode reads it straight from disk (a .torrent
# file needs no swarm). The magnet test only checks the watchdog path with
# an info hash that cannot exist, so it too needs no working swarm.
set -euo pipefail

cd "$(dirname "$0")/.."
PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

command -v node >/dev/null 2>&1 || { echo "node not found — skipping"; exit 0; }

# locate the webtorrent module the same way bin/sail does
WTMOD="${SAIL_WTMOD:-}"
if [ -z "$WTMOD" ]; then
    WT_REAL="$(readlink -f "$(command -v webtorrent)" 2>/dev/null || true)"
    d=""
    [ -n "$WT_REAL" ] && d="$(dirname "$WT_REAL")"
    while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
        if [ -f "$d/node_modules/webtorrent/index.js" ]; then
            WTMOD="$d/node_modules/webtorrent"
            break
        fi
        d="$(dirname "$d")"
    done
fi
if [ -z "$WTMOD" ]; then
    echo "webtorrent module not found — skipping"
    exit 0
fi

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# --- fixture: a two-file torrent built locally (piece hashing is pure CPU) --
mkdir -p "$W/src/Season 1"
head -c 300000 /dev/zero > "$W/src/Season 1/ep1.bin"
head -c 200000 /dev/zero > "$W/src/Season 1/ep2.bin"
webtorrent create "$W/src" -o "$W/local.torrent" >/dev/null 2>&1

OUT="$W/out"; mkdir -p "$OUT"
rc=0; node lib/wt.js "$WTMOD" meta "$W/local.torrent" "$OUT" >"$W/meta.log" 2>&1 || rc=$?

# 1. exits 0 and names the .torrent file after the info hash
if [ "$rc" -eq 0 ]; then ok "meta: exits 0"; else fail "meta: rc=$rc"; fi
TSV_COUNT=0
[ -s "$OUT/files.tsv" ] && TSV_COUNT=$(wc -l < "$OUT/files.tsv" | tr -d ' ')
TFILE="$(cd "$OUT" && ls | grep '\.torrent$' | head -1)"
HASH="${TFILE%.torrent}"
if printf '%s' "$TFILE" | grep -Eq '^[0-9a-f]{40}\.torrent$'; then
    ok "meta: wrote <infohash>.torrent ($TFILE)"
else
    fail "meta: torrent file name is [$TFILE]"
fi

# 2. files.tsv keeps the exact shape the old python converter produced:
#    id, human size, path — one row per file, same human-size formatting
if [ "$TSV_COUNT" -eq 2 ] \
   && [ "$(awk -F'\t' 'NR==1{print $1}' "$OUT/files.tsv")" = "0" ] \
   && [ "$(awk -F'\t' 'NR==2{print $1}' "$OUT/files.tsv")" = "1" ] \
   && [ "$(awk -F'\t' 'NR==1{print $2}' "$OUT/files.tsv")" = "293.0KB" ] \
   && [ "$(awk -F'\t' 'NR==2{print $2}' "$OUT/files.tsv")" = "195.3KB" ] \
   && case "$(awk -F'\t' 'NR==1{print $3}' "$OUT/files.tsv")" in
        *"Season 1/ep1.bin") true ;; *) false ;; esac \
   && case "$(awk -F'\t' 'NR==2{print $3}' "$OUT/files.tsv")" in
        *"Season 1/ep2.bin") true ;; *) false ;; esac; then
    ok "files.tsv: 2 rows, id/size/path shape matches the old converter"
else
    fail "files.tsv: rows=$TSV_COUNT content=[$(tr '\n' '|' < "$OUT/files.tsv")]"
fi

# 3. info.json is valid json with a matching hash and file list
IJ="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
print(d["infoHash"], len(d.get("files") or []))' "$OUT/info.json" 2>/dev/null || true)"
if [ "$IJ" = "$HASH 2" ]; then
    ok "info.json: valid, infoHash matches file name, 2 files"
else
    fail "info.json: got [$IJ] want [$HASH 2]"
fi

# 4. prints INFOHASH=<hash> for callers that read the log
if grep -q "^INFOHASH=$HASH$" "$W/meta.log"; then
    ok "log: INFOHASH=<hash> line present"
else
    fail "log: no INFOHASH line for $HASH"
fi

# 5. a magnet whose hash cannot exist never gets metadata — the caller's
#    watchdog kills it and files.tsv (the success signal) never appears
OUT2="$W/out2"; mkdir -p "$OUT2"
DEAD="magnet:?xt=urn:btih:0000000000000000000000000000000000000001&tr=udp%3A%2F%2Fnope.invalid%3A9%2Fannounce"
node lib/wt.js "$WTMOD" meta "$DEAD" "$OUT2" >"$W/dead.log" 2>&1 &
DPID=$!
i=0
while kill -0 "$DPID" 2>/dev/null && [ "$i" -lt 12 ]; do
    i=$((i + 1)); sleep 0.5
done
kill "$DPID" 2>/dev/null || true
sleep 0.3
kill -9 "$DPID" 2>/dev/null || true
wait "$DPID" 2>/dev/null || true
if [ ! -e "$OUT2/files.tsv" ] && [ -z "$(ls "$OUT2" 2>/dev/null)" ]; then
    ok "dead magnet: no files.tsv, no partial output before watchdog kill"
else
    fail "dead magnet: leftovers in $OUT2 [$(ls "$OUT2" 2>/dev/null | tr '\n' ' ')]"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
