#!/usr/bin/env bash
# Run every test suite (Python + shell) and summarize. CI calls this; locally
# it is the one command to run before a commit.
#
# Deliberately no `set -e`: one failing suite must not hide the others. The
# final status is non-zero if anything failed.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PASSED=0
FAILED=0
FAILED_NAMES=""

run_suite() {  # $1 = label, rest = command to run
    local label="$1"
    shift
    printf '\n== %s\n' "$label"
    if "$@"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES$label"$'\n'
    fi
}

run_suite "python (unittest)" \
    python3 -m unittest discover -s tests -p 'test_*.py'

for t in tests/test_*.sh; do
    [ -f "$t" ] || continue
    run_suite "$t" bash "$t"
done

printf '\n========================================\n'
printf '%d suites passed, %d failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    printf 'failed:\n%s' "$FAILED_NAMES"
    exit 1
fi
