#!/bin/sh
# Runs the test suite under standalone Lua 5.1 (built into .tools/bin; override with LUA=...).
# Test files run in separate processes, several at once (the tests use a mocked clock, so they do
# not depend on how fast they run).
#   ./run_tests.sh               all tests, one process per core
#   ./run_tests.sh -j 4          at most 4 processes at once
#   ./run_tests.sh "planner"     only tests whose name contains "planner"
#   SERIAL=1 ./run_tests.sh      everything in one process
#   TIMES=1 ./run_tests.sh       also list the slowest tests
# While it runs it shows each file's progress (tests/progress.lua): a status line redrawn in place on
# a terminal; plain lines elsewhere (CI logs), with a status line every TEST_HEARTBEAT=30 seconds.
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

# Each file's process writes its progress events to fd 3, the pipe into tests/progress.lua, which
# shows the progress as they come and at the end prints the failures from the logs and the total.
# Its exit code is the run's: 1 if a test failed or a file did not finish.
export LUA OUT="$out" FILTER="${1:-}" TEST_JOBS="$jobs"
printf '%s\n' $files | xargs -P "$jobs" -I{} sh -c \
    'TEST_FILES="$1" TEST_EVENTS=/dev/fd/3 "$LUA" tests/run.lua ${FILTER:+"$FILTER"} 3>&1 > "$OUT/$1.log" 2>&1
     printf "exit\t%s\t%s\n" "$1" "$?"' _ {} |
    "$LUA" tests/progress.lua $files
