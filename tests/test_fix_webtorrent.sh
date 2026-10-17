#!/usr/bin/env bash
# Regression tests for lib/fix-webtorrent.sh.
#
# webtorrent 2.8.5 (what webtorrent-cli 6.x installs) computes its debug id
# as arr2hex(parsedTorrent.infoHash) — passing the info-hash hex STRING to
# uint8-util's arr2hex, which in >=2.3 only accepts typed arrays. Every
# torrent add then dies with an unhandled ERR_INVALID_ARG_TYPE before any
# network IO. The repair script detects that combination and rewrites the
# call sites the way upstream webtorrent 3.x did.
#
# Each test builds a synthetic node_modules tree — no network, and the
# machine's real webtorrent install is never touched.
set -euo pipefail

cd "$(dirname "$0")/.."
FIX="$(pwd)/lib/fix-webtorrent.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

ROOTS=()
# the guard idiom, not bare "${ROOTS[@]}": macOS's stock bash 3.2 throws
# "unbound variable" expanding an empty array under set -u (see the longer
# note in bin/sail's pick_video)
cleanup() { rm -rf ${ROOTS[@]+"${ROOTS[@]}"}; }
trap cleanup EXIT

# make_tree <strict|lenient> — build a fake webtorrent + uint8-util install.
# strict reproduces uint8-util >=2.3 (typed-array-only arr2hex), lenient
# reproduces <=2.2.x (accepts anything Buffer.from accepts).
make_tree() {
    local root="$('mktemp' -d)"
    ROOTS+=("$root")
    local wt="$root/node_modules/webtorrent"
    mkdir -p "$wt/lib" "$root/node_modules/uint8-util/dist/src"
    printf '{ "name": "webtorrent", "version": "2.8.5" }\n' > "$wt/package.json"
    # the two arr2hex call sites webtorrent 2.8.5 ships
    cat > "$wt/lib/torrent.js" <<'EOF'
      this.infoHash = parsedTorrent.infoHash
      this._debugId = arr2hex(parsedTorrent.infoHash).substring(0, 7)
    _processParsedTorrent (parsedTorrent) {
      this._debugId = arr2hex(parsedTorrent.infoHash).substring(0, 7)
EOF
    if [ "$1" = strict ]; then
        printf '{ "name": "uint8-util", "version": "2.3.2" }\n' \
            > "$root/node_modules/uint8-util/package.json"
        printf "export const arr2hex = (data) => Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('hex')\n" \
            > "$root/node_modules/uint8-util/dist/src/node.js"
    else
        printf '{ "name": "uint8-util", "version": "2.2.5" }\n' \
            > "$root/node_modules/uint8-util/package.json"
        printf "export const arr2hex = (data) => '' + Buffer.from(data).toString('hex')\n" \
            > "$root/node_modules/uint8-util/dist/src/node.js"
    fi
    printf '%s' "$root"
}

tj() { printf '%s/node_modules/webtorrent/lib/torrent.js' "$1"; }

# 1. strict uint8-util + vulnerable webtorrent -> both call sites repaired
R="$(make_tree strict)"
if bash "$FIX" "$R/node_modules/webtorrent" >/dev/null 2>&1 \
   && [ "$(grep -c 'parsedTorrent\.infoHash?\.substring(0, 7)' "$(tj "$R")")" -eq 2 ] \
   && ! grep -q 'arr2hex(parsedTorrent' "$(tj "$R")"; then
    ok "strict uint8-util: both call sites rewritten"
else
    fail "strict uint8-util: call sites not rewritten"
fi

# 2. lenient uint8-util (<=2.2) never crashes -> file must be untouched
R="$(make_tree lenient)"
BEFORE="$(md5 -q "$(tj "$R")")"
if bash "$FIX" "$R/node_modules/webtorrent" >/dev/null 2>&1 \
   && [ "$(md5 -q "$(tj "$R")")" = "$BEFORE" ]; then
    ok "lenient uint8-util: torrent.js left untouched"
else
    fail "lenient uint8-util: torrent.js was modified anyway"
fi

# 3. already-fixed webtorrent (no vulnerable pattern) -> untouched, exit 0
R="$(make_tree strict)"
sed -i '' 's/arr2hex(parsedTorrent\.infoHash)\.substring(0, 7)/parsedTorrent.infoHash?.substring(0, 7)/g' "$(tj "$R")"
BEFORE="$(md5 -q "$(tj "$R")")"
if bash "$FIX" "$R/node_modules/webtorrent" >/dev/null 2>&1 \
   && [ "$(md5 -q "$(tj "$R")")" = "$BEFORE" ]; then
    ok "already-fixed webtorrent: no-op"
else
    fail "already-fixed webtorrent: file changed"
fi

# 4. idempotent: a second run on a repaired tree changes nothing
R="$(make_tree strict)"
bash "$FIX" "$R/node_modules/webtorrent" >/dev/null 2>&1 || true
BEFORE="$(md5 -q "$(tj "$R")")"
if bash "$FIX" "$R/node_modules/webtorrent" >/dev/null 2>&1 \
   && [ "$(md5 -q "$(tj "$R")")" = "$BEFORE" ]; then
    ok "idempotent on repaired tree"
else
    fail "second run modified the file again"
fi

# 5. uint8-util unresolvable (probe impossible) -> repair anyway; a missed
#    repair leaves sail dead, an unnecessary one is harmless
R="$(make_tree strict)"
rm -rf "$R/node_modules/uint8-util"
bash "$FIX" "$R/node_modules/webtorrent" >/dev/null 2>&1 || true
if ! grep -q 'arr2hex(parsedTorrent' "$(tj "$R")"; then
    ok "unresolvable uint8-util: repaired anyway"
else
    fail "unresolvable uint8-util: not repaired"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
