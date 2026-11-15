#!/bin/sh
# Runs the test suite under standalone Lua 5.1 (built into .tools/bin; override with LUA=...).
# Test files run in separate processes, several at once (the tests use a mocked clock, so they do
# not depend on how fast they run).
#   ./run_tests.sh               all tests, one process per core
#   ./run_tests.sh -j 4          at most 4 processes at once
#   ./run_tests.sh "planner"     only tests whose name contains "planner"
#   SERIAL=1 ./run_tests.sh      everything in one process
#   TIMES=1 ./run_tests.sh       also list the slowest tests
cd "$(dirname "$0")" || exit 1
LUA="${LUA:-./.tools/bin/lua5.1}"

jobs=""
if [ "${1:-}" = "-j" ]; then jobs="${2:-}"; shift 2 || { echo "usage: run_tests.sh [-j N] [filter]" >&2; exit 2; }
else case "${1:-}" in -j[0-9]*) jobs="${1#-j}"; shift ;; esac
fi
[ -n "$jobs" ] || jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
case "$jobs" in ''|*[!0-9]*|0) echo "run_tests.sh: -j needs a positive number" >&2; exit 2 ;; esac

if [ -n "${SERIAL:-}" ]; then exec "$LUA" tests/run.lua "$@"; fi

files="${TEST_FILES:-$(LIST_FILES=1 "$LUA" tests/run.lua)}"
out="$(mktemp -d "${TMPDIR:-/tmp}/levelscout-tests.XXXXXX")" || exit 1
trap 'rm -rf "$out"' EXIT

export LUA OUT="$out" FILTER="${1:-}"
printf '%s\n' $files | xargs -P "$jobs" -I{} sh -c \
    'TEST_FILES="$1" "$LUA" tests/run.lua ${FILTER:+"$FILTER"} > "$OUT/$1.log" 2>&1' _ {}

passed=0 failed=0 broken=""
for f in $files; do
    log="$out/$f.log"
    summary="$(tail -1 "$log" 2>/dev/null)"
    p="$(printf '%s' "$summary" | sed -n 's/^\([0-9]*\) passed, \([0-9]*\) failed$/\1/p')"
    x="$(printf '%s' "$summary" | sed -n 's/^\([0-9]*\) passed, \([0-9]*\) failed$/\2/p')"
    if [ -z "$p" ]; then
        broken="$broken $f"
        printf '== %s did not finish:\n' "$f"; tail -20 "$log" 2>/dev/null
        continue
    fi
    passed=$((passed + p)); failed=$((failed + x))
    # Failures and the TIMES=1 table; the per-file summary is replaced by the total below.
    if [ "$x" -gt 0 ] || [ -n "${TIMES:-}" ]; then
        printf '== %s\n' "$f"; sed '$d' "$log"
    fi
done

printf '%d passed, %d failed\n' "$passed" "$failed"
[ -z "$broken" ] && [ "$failed" -eq 0 ]
