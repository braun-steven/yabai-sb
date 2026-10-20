#!/usr/bin/env bash
#
# Line coverage of Sources/ by the Swift tests: runs `swift test --enable-code-coverage` and prints lines, missed
# lines and line coverage per file, then the total. An optional argument is an extended regex of the files to show,
# e.g. `scripts/coverage.sh 'Con|TreeView'`. SWIFT and SWIFT_FLAGS select the driver like the makefile.
#

set -euo pipefail

SWIFT=${SWIFT:-xcrun swift}
filter=${1:-.}

# shellcheck disable=SC2086
$SWIFT test --enable-code-coverage ${SWIFT_FLAGS:-} >/dev/null

products=$(dirname "$(dirname "$($SWIFT test --show-codecov-path)")")
report=$(xcrun llvm-cov report \
    "$products/YabaiTests.xctest/Contents/MacOS/YabaiTests" \
    -object "$products/YabaiCoreTests.xctest/Contents/MacOS/YabaiCoreTests" \
    -instr-profile "$products/codecov/default.profdata" \
    -ignore-filename-regex='(\.build|tests)/')

# columns: file, regions, missed regions, cover, functions, missed functions, executed, lines, missed lines, cover, ...
echo "$report" | awk -v filter="$filter" -v root="$PWD/" '
    $1 ~ /^(Sources|osax)\// || index($1, root) == 1 {
        file = $1; sub(root, "", file)
        if (file ~ filter) printf "%-52s %7s %7s %8s\n", file, $8, $9, $10
    }
    $1 == "TOTAL" { printf "%-52s %7s %7s %8s\n", "TOTAL", $8, $9, $10 }
'
