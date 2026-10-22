#!/usr/bin/env bash
# Regression tests for lib/dashboard.sh's stop_render.
#
# stop_render SIGKILLs the dashboard renderer and then reaps it. That reaping
# `wait` returns 137, and under `set -e` a bare wait aborted the function
# before it cleared the block — losing the download's done/error output and
# exiting 137. It also never cleared RENDER_PID, so the EXIT trap cleared the
# block a second time.
#
# The function is extracted from the real module (rather than copied here) so
# these tests fail if the shipped code regresses.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

W="$(mktemp -d)"
cleanup() {
    if [ -f "$W/rpid" ]; then
        kill -9 "$(cat "$W/rpid")" 2>/dev/null || true
    fi
    rm -rf "$W"
}
trap cleanup EXIT

start_renderer() {  # prints the pid of a process that ignores TERM
    bash -c 'trap "" TERM; sleep 30' &
    printf '%s' "$!"
}

# extract the function exactly as shipped: from its definition to the first
# closing brace in column 1
awk '/^stop_render\(\) \{/ { copy = 1 } copy { print } copy && /^\}/ { exit }' \
    lib/dashboard.sh > "$W/stop_render.sh"
# shellcheck disable=SC2016  # the single-quoted $pid is the point
if ! grep -q 'wait "\$pid".*|| true' "$W/stop_render.sh"; then
    fail "stop_render uses an errexit-safe wait"
else
    ok "stop_render uses an errexit-safe wait"
fi

# --- 1. under set -e, SIGKILL from the wait must not abort the caller ------
cat > "$W/case1.sh" <<'EOF'
set -euo pipefail
. "$1/stop_render.sh"
WORK="$2"; mkdir -p "$WORK"; : > "$WORK/render.frame"
DASH_H=15
bash -c 'trap "" TERM; sleep 30' &
RENDER_PID=$!
printf '%s' "$RENDER_PID" > "$3"
stop_render > "$4"
printf 'pid=[%s]\n' "$RENDER_PID"
printf 'SURVIVED\n'
EOF
bash "$W/case1.sh" "$W" "$W/work1" "$W/rpid" "$W/out1" > "$W/stdout1" 2>"$W/stderr1" || true
if grep -qx SURVIVED "$W/stdout1"; then
    ok "set -e caller survives the renderer's SIGKILL"
else
    fail "caller aborted: $(tr '\n' ' ' < "$W/stderr1")"
fi
if grep -qx 'pid=\[\]' "$W/stdout1"; then
    ok "RENDER_PID cleared after stop_render"
else
    fail "RENDER_PID not cleared: $(grep '^pid=' "$W/stdout1" || true)"
fi
if ! kill -0 "$(cat "$W/rpid")" 2>/dev/null; then
    ok "renderer is reaped"
else
    fail "renderer still running"
fi

CLEARS="$(grep -o $'\033\[15A' "$W/out1" | wc -l | tr -d ' ' || true)"
if [ "$CLEARS" -eq 1 ]; then
    ok "exactly one dashboard clear"
else
    fail "dashboard cleared $CLEARS times"
fi

# --- 2. explicit stop + EXIT trap must clear only once ---------------------
cat > "$W/case2.sh" <<'EOF'
set -euo pipefail
. "$1/stop_render.sh"
WORK="$2"; mkdir -p "$WORK"; : > "$WORK/render.frame"
DASH_H=15
trap 'if [ -n "${RENDER_PID:-}" ]; then stop_render; fi' EXIT
bash -c 'trap "" TERM; sleep 30' &
RENDER_PID=$!
stop_render
EOF
bash "$W/case2.sh" "$W" "$W/work2" > "$W/out2" 2>"$W/stderr2" || true
CLEARS="$(grep -o $'\033\[15A' "$W/out2" | wc -l | tr -d ' ' || true)"
if [ "$CLEARS" -eq 1 ]; then
    ok "explicit stop + trap clears once (no double erase)"
else
    fail "explicit stop + trap cleared $CLEARS times"
fi

# --- 3. no frame drawn yet: don't erase unrelated output -------------------
cat > "$W/case3.sh" <<'EOF'
set -euo pipefail
. "$1/stop_render.sh"
WORK="$2"; mkdir -p "$WORK"
DASH_H=15
bash -c 'trap "" TERM; sleep 30' &
RENDER_PID=$!
stop_render > "$3"
EOF
bash "$W/case3.sh" "$W" "$W/work3" "$W/out3" > /dev/null 2>"$W/stderr3" || true
CLEARS="$(grep -o $'\033\[15A' "$W/out3" | wc -l | tr -d ' ' || true)"
if [ "$CLEARS" -eq 0 ] && grep -q $'\033\[?25h' "$W/out3"; then
    ok "no frame drawn: cursor restored, nothing erased"
else
    fail "no frame drawn: clears=$CLEARS out=[$(cat "$W/out3")]"
fi

# --- 4. a short terminal: erase the height the renderer actually used -----
cat > "$W/case4.sh" <<'EOF'
set -euo pipefail
. "$1/stop_render.sh"
WORK="$2"; mkdir -p "$WORK"; : > "$WORK/render.frame"
printf '11\n' > "$WORK/render.h"
DASH_H=15
bash -c 'trap "" TERM; sleep 30' &
RENDER_PID=$!
stop_render > "$3"
EOF
bash "$W/case4.sh" "$W" "$W/work4" "$W/out4" > /dev/null 2>"$W/stderr4" || true
CLEARS="$(grep -o $'\033\[11A' "$W/out4" | wc -l | tr -d ' ' || true)"
if [ "$CLEARS" -eq 1 ] && [ ! -f "$W/work4/render.h" ]; then
    ok "render.h height is used and cleaned up"
else
    fail "render.h height ignored: clears=$CLEARS"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
