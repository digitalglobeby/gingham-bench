#!/bin/zsh
# Prints the bench's commit as the builds record it (BENCH_COMMIT, in every result line): the short
# hash of HEAD, with "-modified" when the app's sources (Mac/, iOS/, Shared/) differ from it.
cd "$(dirname "$0")/.."
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[[ -n "$(git status --porcelain -- Mac iOS Shared 2>/dev/null)" ]] && COMMIT="$COMMIT-modified"
echo "$COMMIT"
