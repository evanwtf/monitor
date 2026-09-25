#!/usr/bin/env bash
# Prints the number of the pull request a commit on main came from, so that
# release.yml can read the pull request's release labels.
#
# Usage: release-pr-number.sh <subject> <parent-count>
#
# Two subject shapes carry a number:
#
#   merge commit:  "Merge pull request #12 from owner/branch"  ->  12
#   squash merge:  "Some change (#12)"                         ->  12
#
# A direct push has neither. It prints nothing and succeeds: no pull request
# means no labels, and the release takes the patch default.
#
# A merge commit (more than one parent) with neither shape fails. It came from
# somewhere, and treating it as "no labels" is how #51 shipped a release
# despite its release:skip label (#53). A stopped release is a message. A
# release that quietly picks the wrong version is not.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <subject> <parent-count>" >&2
    exit 1
fi
subject="$1"
# `wc -w` pads its output on macOS.
parents="${2//[[:space:]]/}"
case "$parents" in
    '' | *[!0-9]*)
        echo "parent count is not a number: '$2'" >&2
        exit 1
        ;;
esac

# The merge-commit pattern goes first. After it matches, the pattern space is
# the bare number, so the squash pattern cannot match a second time.
number="$(printf '%s\n' "$subject" | sed -n \
    -e 's/^Merge pull request #\([0-9][0-9]*\) from .*/\1/p' \
    -e 's/.*(#\([0-9][0-9]*\))$/\1/p' | head -n 1)"

if [ -z "$number" ] && [ "$parents" -gt 1 ]; then
    echo "merge commit with no pull request number in its subject: $subject" >&2
    echo "refusing to guess its release labels" >&2
    exit 1
fi

if [ -n "$number" ]; then
    printf '%s\n' "$number"
fi
