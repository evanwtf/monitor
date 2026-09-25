#!/usr/bin/env bash
# Tests for release-pr-number.sh. It runs unattended on every merge, and
# refusing correctly is most of its job, so most of the cases are refusals.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/release-pr-number.sh"
failures=0

# expect <name> <output> <exit status> <subject> <parent count>
expect() {
    local name="$1" want="$2" want_status="$3" got status
    got="$("$script" "$4" "$5" 2>/dev/null)"
    status=$?
    if [ "$got" = "$want" ] && [ "$status" -eq "$want_status" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: got '$got' (exit $status), want '$want' (exit $want_status)"
        failures=$((failures + 1))
    fi
}

# The shapes that carry a number.
expect "merge commit" 66 0 "Merge pull request #66 from evanwtf/chart-smoothing" 2
expect "merge commit #51, the one in #53" 51 0 \
    "Merge pull request #51 from evanwtf/docs/agents-and-readme" 2
expect "squash merge" 12 0 "Add a thing (#12)" 1
expect "merge subject wins over a trailing number" 60 0 \
    "Merge pull request #60 from evanwtf/x (#58)" 2

# A direct push: no number, and that is fine.
expect "direct push" "" 0 "Fix a typo" 1
expect "a number mid-subject is not a squash" "" 0 "Revert (#12) and more" 1
expect "no space before from" "" 0 "Merge pull request #12from x" 1

# The refusals.
expect "merge commit with no number" "" 1 "Merge branch 'feature' into main" 2
expect "octopus merge with no number" "" 1 "Merge branches 'a' and 'b'" 3
expect "padded parent count, as wc -w gives on macOS" "" 1 "Merge branch 'x'" "      2"
expect "parent count missing" "" 1 "Fix a typo" ""
expect "parent count not a number" "" 1 "Fix a typo" "two"

if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "all passed"
