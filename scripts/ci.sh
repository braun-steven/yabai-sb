#!/usr/bin/env bash
#
# CI gates. `scripts/ci.sh quick` runs the debug build, CLI smoke checks and the Swift tests; `scripts/ci.sh full`
# adds the release build, payload tests and upgrade checks. Each step writes .build/ci/<step>.log and prints
# one PASS|FAIL <step> <seconds>s <log> line. A step also fails on an unlisted compiler or linker warning.
# The first failing step stops the run and prints its details.
# SWIFT and SWIFT_FLAGS come from the justfile (`just ci-quick`, `just ci`); they default like the justfile.
#

set -euo pipefail

mode=${1:-}
case $mode in
    quick|full) ;;
    *) echo "usage: $0 quick|full" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."

if ! JUST=$(command -v just); then
    echo "just is required to run CI; install it with: brew install just" >&2
    exit 1
fi

export SWIFT=${SWIFT:-xcrun swift}
export SWIFT_FLAGS=${SWIFT_FLAGS:-}

log_dir=.build/ci
allowlist=scripts/ci-warning-allowlist.txt
patterns=$log_dir/allowlist.patterns
warning_re='(^|/)[^ ]+:[0-9]+:[0-9]+: warning:|^ld: warning:|warning: '
esc=$(printf '\033')

mkdir -p "$log_dir"
# Comment and blank lines are not patterns: an empty pattern would match every line.
grep -vE '^[[:space:]]*(#|$)' "$allowlist" > "$patterns" || true

# Printed log lines: colour codes removed and each line cut, since compiler command lines are very long.
show() {
    sed "s/$esc\[[0-9;]*m//g" | cut -c1-300
}

# Warning lines of a log that the allowlist does not cover. `grep -v -f` with an empty pattern file drops every line
# on macOS grep, so the allowlist filter runs only when it has entries.
warnings_in() {
    local found
    found=$(grep -E "$warning_re" "$1" || true)
    if [[ -s $patterns && -n $found ]]; then
        found=$(printf '%s\n' "$found" | grep -v -F -f "$patterns" || true)
    fi
    printf '%s' "$found"
}

run_step() {
    local name=$1 target=$2
    local log=$log_dir/$name.log
    local start=$SECONDS rc=0 warnings seconds

    "$JUST" "$target" > "$log" 2>&1 || rc=$?

    warnings=$(warnings_in "$log")
    seconds=$((SECONDS - start))

    if [[ $rc -eq 0 && -z $warnings ]]; then
        echo "PASS $name ${seconds}s $log"
        case $name in
            test|osax-test)
                grep 'Test run with' "$log" | sed 's/^/  /' || true
                ;;
        esac
        return 0
    fi

    echo "FAIL $name ${seconds}s $log"
    if [[ $rc -ne 0 ]]; then
        echo "--- $name: exit status $rc; error lines (max 30)"
        grep -E 'error:' "$log" | sed -n '1,30p' | show || true
    fi
    if [[ -n $warnings ]]; then
        echo "--- $name: warning lines not in the allowlist (max 30)"
        printf '%s\n' "$warnings" | sed -n '1,30p' | show
    fi
    echo "--- $name: last 40 lines of $log"
    tail -n 40 "$log" | show
    return 1
}

run_step build build
run_step cli-smoke cli-smoke
run_step script-test script-test
run_step test test
if [[ $mode == full ]]; then
    run_step install install
    run_step osax-test osax-test
    run_step check-build check-build
fi

echo "ci $mode: all steps passed (logs in $log_dir)"
