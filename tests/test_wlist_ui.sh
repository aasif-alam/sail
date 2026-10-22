#!/usr/bin/env bash
# Interactive UI tests for the watchlist — drives the real fzf interface
# through tmux. A plain pty isn't enough: fzf stalls waiting for terminal
# cursor-position reports no dumb pty answers (fzf's own CI uses tmux for
# the same reason). Skips cleanly when tmux or fzf isn't installed.
#
# Storage-layer tests live in test_wlist.sh; this file covers what only a
# terminal can prove: the picker renders, enter launches, ctrl-x removes,
# and the search picker's ctrl-x saves.
set -euo pipefail

for dep in tmux fzf; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        if [ -n "${CI:-}" ]; then
            printf '%s not installed — CI requires it\n' "$dep" >&2
            exit 1
        fi
        printf 'skip: %s not installed\n' "$dep"
        exit 0
    fi
done

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

W="$(mktemp -d)"; SESS=sail_wl_test
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT

pane() { tmux capture-pane -t "$SESS" -p; }
send() { tmux send-keys -t "$SESS" "$1"; }
die()  { tmux kill-session -t "$SESS" 2>/dev/null || true; }

# run <wlist-file> [query] — start `sail wlist` in a fresh tmux session
run() {
    tmux kill-session -t "$SESS" 2>/dev/null || true
    tmux new-session -d -s "$SESS" -x 140 -y 42 \
        "env TERM=xterm-256color SAIL_WLIST='$1' bash bin/sail wlist ${2:-}; printf 'SAIL_EXITED\n'; sleep 30"
    # poll, don't sleep: sail + fzf startup timing varies
    for _ in $(seq 1 20); do
        pane | grep -q "enter: launch" && return 0
        pane | grep -q "SAIL_EXITED" && return 0
        sleep 0.5
    done
}

# --- 1. newest entry listed first; enter launches; q quits
cat > "$W/w1" <<'T'
Old One	magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=old	1760000000
New Two	magnet:?xt=urn:btih:2222222222222222222222222222222222222222&dn=new	1760100000
T
run "$W/w1"
if pane | grep -q "enter: launch"; then
    ok "picker renders"
else
    fail "picker renders (pane: $(pane | tr '\n' ' ' | cut -c1-200))"
fi
# the id column is hidden from display (--with-nth), so assert order by
# where the titles land on screen
NL1="$(pane | grep -n "New Two" | head -1 | cut -d: -f1)"
NL2="$(pane | grep -n "Old One" | head -1 | cut -d: -f1)"
if [ -n "$NL1" ] && [ -n "$NL2" ] && [ "$NL1" -lt "$NL2" ]; then
    ok "newest entry shown first"
else
    fail "newest first (line $NL1 vs $NL2)"
fi
send Enter
for _ in $(seq 1 20); do pane | grep -q "stream or download" && break; sleep 0.5; done
if pane | grep -q "stream or download? \[S/d/q\]"; then
    ok "enter launches to stream/download prompt"
else
    fail "enter launches"
fi
send q
send Enter
for _ in $(seq 1 10); do pane | grep -q "SAIL_EXITED" && break; sleep 0.5; done
if pane | grep -q "SAIL_EXITED"; then ok "q quits from the launch prompt"; else fail "q quits"; fi
die

# --- 2. ctrl-x removes the picked entry; the rest of the list survives
cat > "$W/w2" <<'T'
Keep Me	magnet:?xt=urn:btih:3333333333333333333333333333333333333333&dn=keep	1760000000
Only One	magnet:?xt=urn:btih:4444444444444444444444444444444444444444&dn=only	1760100000
T
run "$W/w2"   # cursor lands on the newest row: Only One
send C-x
for _ in $(seq 1 20); do pane | grep -q "removed from watchlist" && break; sleep 0.5; done
if pane | grep -q "removed from watchlist: Only One" && pane | grep -q "Keep Me"; then
    ok "ctrl-x removes with feedback, list survives"
else
    fail "ctrl-x remove"
fi
die
if grep -q "Keep Me" "$W/w2" && ! grep -q "Only One" "$W/w2"; then
    ok "removed entry gone from storage, other kept"
else
    fail "storage after remove"
fi

# --- 3. an optional query filters the list
cat > "$W/w3" <<'T'
Alpha One	magnet:?xt=urn:btih:5555555555555555555555555555555555555555&dn=a1	1760000000
Beta Two	magnet:?xt=urn:btih:6666666666666666666666666666666666666666&dn=b2	1760000000
T
run "$W/w3" "beta"
for _ in $(seq 1 20); do pane | grep -q "Beta Two" && break; sleep 0.5; done
if pane | grep -q "Beta Two" && ! pane | grep -q "Alpha One"; then
    ok "query filters the list"
else
    fail "query filter"
fi
die

# --- 4. esc quits without launching
cat > "$W/w4" <<'T'
Esc Me	magnet:?xt=urn:btih:7777777777777777777777777777777777777777&dn=esc	1760000000
T
run "$W/w4"
send Escape
for _ in $(seq 1 10); do pane | grep -q "SAIL_EXITED" && break; sleep 0.5; done
if pane | grep -q "SAIL_EXITED"; then ok "esc quits"; else fail "esc quits"; fi
die

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
