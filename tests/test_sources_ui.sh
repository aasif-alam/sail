#!/usr/bin/env bash
# Regression tests for `sail sources` and the config semantics behind it.
#
# The UI used to show every source as off when no config existed, even though
# searches used the six defaults; saving an all-off list wrote an empty file
# that search.py then treated as "use the defaults" again. An existing file
# must be authoritative — including an empty one — while a missing file means
# the defaults. The box's right border was also two columns off the content.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

N="$(python3 lib/search.py --list-sources | wc -l | tr -d ' ')"
NDEFAULT="$(python3 lib/search.py --list-sources | awk -F'\t' '$3 == 1' | wc -l | tr -d ' ')"
CONF="$W/sources.conf"

strip() { sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g'; }
run_ui() {  # $1 = config path; rest = lines to feed the prompt
    local conf="$1"; shift
    printf '%s\n' "$@" | SAIL_SOURCES="$conf" bash bin/sail sources
}
count_on()  { printf '%s\n' "$1" | grep -c -F '[x]' || true; }
count_off() { printf '%s\n' "$1" | grep -c -F '[ ]' || true; }
enabled_in() {
    SAIL_SOURCES="$1" python3 -c \
        'import sys; sys.path.insert(0, "lib"); import search; print(",".join(search.load_enabled()))'
}

# --- 1. no config: the UI must show the real default selection -------------
OUT="$(run_ui "$CONF" s)"
PLAIN="$(printf '%s\n' "$OUT" | strip)"
ON="$(count_on "$PLAIN")"
OFF="$(count_off "$PLAIN")"
if [ "$ON" -eq "$NDEFAULT" ] && [ "$OFF" -eq $((N - NDEFAULT)) ]; then
    ok "no config: defaults shown as on ($ON on, $OFF off)"
else
    fail "no config: $ON on / $OFF off (want $NDEFAULT / $((N - NDEFAULT)))"
fi
if [ ! -e "$CONF" ]; then
    ok "no config: merely viewing creates no file"
else
    fail "viewing created $CONF"
fi
if printf '%s\n' "$PLAIN" | grep -q "nothing changed"; then
    ok "no config + save: nothing written"
else
    fail "expected 'nothing changed'"
fi

# --- 2. existing empty config: every source off, and search uses none ------
: > "$CONF"
OUT="$(run_ui "$CONF" s)"
PLAIN="$(printf '%s\n' "$OUT" | strip)"
if [ "$(count_on "$PLAIN")" -eq 0 ] && [ "$(count_off "$PLAIN")" -eq "$N" ]; then
    ok "empty config: all sources shown off"
else
    fail "empty config: $(count_on "$PLAIN") on / $(count_off "$PLAIN") off"
fi
if [ -z "$(enabled_in "$CONF")" ]; then
    ok "empty config: load_enabled returns none (not defaults)"
else
    fail "empty config: load_enabled returned $(enabled_in "$CONF")"
fi

# --- 3. x then s writes an empty file (save "none") ------------------------
rm -f "$CONF"
OUT="$(run_ui "$CONF" x s)"
if [ -f "$CONF" ] && [ ! -s "$CONF" ]; then
    ok "x + s saves an empty file"
else
    fail "x + s did not create an empty file"
fi

# --- 4. an existing config is authoritative --------------------------------
printf 'nyaa\n' > "$CONF"
OUT="$(run_ui "$CONF" q)"
PLAIN="$(printf '%s\n' "$OUT" | strip)"
if [ "$(count_on "$PLAIN")" -eq 1 ] \
   && printf '%s\n' "$PLAIN" | grep -F '[x]' | grep -q 'nyaa'; then
    ok "existing config: only its sources shown on"
else
    fail "existing config: wrong selection"
fi
if [ "$(enabled_in "$CONF")" = "nyaa" ]; then
    ok "existing config: load_enabled matches the file"
else
    fail "existing config: load_enabled=[$(enabled_in "$CONF")]"
fi

# --- 5. toggling one default off saves the remaining defaults --------------
rm -f "$CONF"
run_ui "$CONF" 1 s >/dev/null
if [ -f "$CONF" ] && ! grep -qx 'tpb' "$CONF" \
   && [ "$(wc -l < "$CONF" | tr -d ' ')" -eq $((NDEFAULT - 1)) ]; then
    ok "toggle tpb off: file keeps the other defaults"
else
    fail "toggle tpb off: file=[$(tr '\n' ',' < "$CONF" 2>/dev/null)]"
fi

# --- 5b. whitespace in the config reads the same way a search reads it -----
printf '  nyaa  \n\n# comment\n' > "$CONF"
OUT="$(run_ui "$CONF" q)"
PLAIN="$(printf '%s\n' "$OUT" | strip)"
if [ "$(count_on "$PLAIN")" -eq 1 ] \
   && printf '%s\n' "$PLAIN" | grep -F '[x]' | grep -q 'nyaa'; then
    ok "padded config name is recognized as enabled"
else
    fail "padded config name was missed"
fi
# a save rewrites clean names (and leaves no temp file behind)
run_ui "$CONF" a s >/dev/null
if grep -qx 'nyaa' "$CONF" && ! grep -Eq '^[[:space:]]|[[:space:]]$' "$CONF" \
   && ! ls "$CONF".tmp.* >/dev/null 2>&1; then
    ok "saving normalizes whitespace and leaves no temp file"
else
    fail "save left [$(tr '\n' ',' < "$CONF")] or a temp file"
fi

# --- 6. every box line has the same display width --------------------------
rm -f "$CONF"
OUT="$(run_ui "$CONF" q)"
PLAIN="$(printf '%s\n' "$OUT" | strip)"
WIDTHS="$(printf '%s\n' "$PLAIN" | grep -E '^  [│╭╰]' \
    | while IFS= read -r line; do
          printf '%s' "$line" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '
      done | sort -u)"
if [ "$(printf '%s\n' "$WIDTHS" | grep -c . || true)" -eq 1 ]; then
    ok "box borders and content share one width ($WIDTHS)"
else
    fail "box line widths differ: $(printf '%s' "$WIDTHS" | tr '\n' ' ')"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
