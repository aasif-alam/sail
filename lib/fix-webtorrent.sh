#!/usr/bin/env bash
# fix-webtorrent.sh — repair the webtorrent 2.8.5 + uint8-util >=2.3 crash.
#
# webtorrent 2.8.5 (what webtorrent-cli 6.x installs via Homebrew) builds
# its debug id with `arr2hex(parsedTorrent.infoHash)` — passing the
# info-hash hex STRING to uint8-util's arr2hex. uint8-util 2.3+ (admitted
# by webtorrent's "^2.2.5" range, so fresh installs get it) only accepts
# typed arrays there, so every torrent add dies with an unhandled
# ERR_INVALID_ARG_TYPE before any network IO — search works, then every
# stream/download attempt crashes. Upstream removed the arr2hex call in
# webtorrent 3.x; until webtorrent-cli ships that, rewrite the two call
# sites the same way upstream did. Idempotent, and a no-op (one grep) on
# healthy installs. `brew reinstall webtorrent-cli` restores the original.
#
# usage: fix-webtorrent.sh [webtorrent-module-dir]
#   With no argument, the module dir is found by walking up from the
#   webtorrent binary (same discovery bin/sail uses for SAIL_WTMOD).

set -euo pipefail

# shared walk-up discovery (also used by bin/sail and the tests)
# shellcheck source=wtdir.sh
. "$(dirname "$0")/wtdir.sh"

WT="${1:-}"
if [ -z "$WT" ]; then
    WT="$(find_webtorrent_module)"
fi
[ -n "$WT" ] && [ -f "$WT/lib/torrent.js" ] || exit 0

TJ="$WT/lib/torrent.js"

# the vulnerable call sites — absent means this webtorrent is already fixed
grep -q 'arr2hex(parsedTorrent\.infoHash)' "$TJ" || exit 0

# uint8-util <=2.2 accepts strings there and never crashes; probe the copy
# webtorrent actually resolves (nearest node_modules walking up from
# webtorrent/lib) and only repair when arr2hex really is the strict kind
U8=""
d="$WT/lib"
while [ "$d" != "/" ] && [ -d "$d" ]; do
    if [ -d "$d/node_modules/uint8-util" ]; then
        U8="$d/node_modules/uint8-util"
        break
    fi
    d="$(dirname "$d")"
done
if [ -n "$U8" ] && command -v node >/dev/null 2>&1; then
    node --input-type=module -e "
import * as u8 from 'file://$U8/dist/src/node.js'
try { u8.arr2hex('00') } catch (e) { process.exit(1) }
" >/dev/null 2>&1 && exit 0
fi
# unresolvable uint8-util or missing node: repair anyway — a missed repair
# leaves every torrent add crashing, an unneeded one changes nothing

V="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$WT/package.json" 2>/dev/null | head -1)"
if sed -i '' 's/arr2hex(parsedTorrent\.infoHash)\.substring(0, 7)/parsedTorrent.infoHash?.substring(0, 7)/g' "$TJ" 2>/dev/null \
   && ! grep -q 'arr2hex(parsedTorrent\.infoHash)' "$TJ"; then
    printf '  repaired webtorrent %s (crashes with uint8-util >=2.3; fixed upstream in webtorrent 3.x): %s\n' \
        "${V:-?}" "$TJ"
else
    printf '  webtorrent %s is broken by uint8-util >=2.3 and %s could not be patched (read-only?) —\n  reinstall webtorrent-cli or report this.\n' \
        "${V:-?}" "$TJ" >&2
fi
exit 0
