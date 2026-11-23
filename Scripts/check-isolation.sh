#!/bin/zsh
# Checks that the hot code of the app-side engines doesn't pay for Swift 6's dynamic isolation
# checks. The app is in the Swift 6 language mode with main-actor default isolation: a closure
# made in a main-actor function checks it runs on the main thread (`swift_task_isCurrentExecutor`)
# every time it's called, which made a sort's comparator 18 times slower. Hot closures and loops
# (comparators, merges, the store's batch, the generator, the per-cell paths) live in
# `nonisolated` helpers; this script disassembles the Release binary and fails if a function
# matching the hot patterns below calls the check. Entry points AppKit calls (`@objc` data source
# and delegate methods) check once per call by design and are listed, not failed.
#
#   Scripts/check-isolation.sh [path to the app's binary]   (default: the Release build of run-all.sh)
set -e
cd "$(dirname "$0")/.."
BIN=${1:-"build/DerivedData/Build/Products/Release/Gingham Bench.app/Contents/MacOS/Gingham Bench"}
[[ -f "$BIN" ]] || { echo "✗ no binary at $BIN (build Release first)"; exit 1 }
HOT='AppSortWork|LiveOrder\.(merge|less|rank|placePending|rowsChanged|rowsInserted|rowRemoved)|ParallelSort|TunedRows\.|FeedStore\.(apply|write|removeRow|flushUpdates)|FeedGenerator|FeedPump|ZipfPicker|SeededRandom|SwiftUIRowComparator|SlotRow\.subscript|BenchFormat|BinanceStore\.(apply|write|note|flush|removeLevel)|closure #[0-9]+ in .*(endUpdates|reloadRows|insertRows|applyPending|AppSort)|checkOrder|MeterData'
otool -tV "$BIN" | python3 -c '
import re, subprocess, sys
current, hits = None, {}
for line in sys.stdin:
    if line and not line[0].isspace() and line.rstrip().endswith(":") and not line.startswith("("):
        current = line.strip()[:-1]
    elif "isCurrentExecutor" in line and current:
        hits[current] = hits.get(current, 0) + 1
names = list(hits)
demangled = subprocess.run(["swift", "demangle", "--simplified"], input="\n".join(names), capture_output=True, text=True).stdout.split("\n")
for name, readable in zip(names, demangled):
    print(readable)
' > build/isolation-checks.txt
COUNT=$(wc -l < build/isolation-checks.txt | tr -d ' ')
BAD=$(grep -E "$HOT" build/isolation-checks.txt | grep -v -E "^@objc|deinit" || true)
echo "Functions with an isolation check: $COUNT (list: build/isolation-checks.txt)"
echo "AppKit entry points among them (one check per call): $(grep -c '^@objc' build/isolation-checks.txt || true)"
if [[ -n "$BAD" ]]; then
  echo "✗ hot functions with an isolation check:"
  echo "$BAD" | sed 's/^/  /'
  exit 1
fi
echo "✓ no hot function calls swift_task_isCurrentExecutor"
