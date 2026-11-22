#!/bin/zsh
# Builds the Mac app (Release) and runs every scenario with every engine, each run in a process
# of its own, writing results/<date>.jsonl (a JSON line per run) and results/<date>.md (the table).
#
#   Scripts/run-all.sh                          everything: 6 scenarios × 5 engines × 3 runs of 10 s (~25 min)
#   Scripts/run-all.sh --scenario live-trades   any of the app's arguments (see Mac/GinghamBench/App/Options.swift)
#   Scripts/run-all.sh --runs 5 --seconds 20
#
# For numbers worth comparing: a quiet Mac (other apps closed, nothing building or syncing), on
# power, Low Power Mode off, the window on the built-in display (it opens on the display with the
# highest refresh rate), and don't touch the Mac while it runs: the window must stay in front.
# Binance scenarios need the network (binance.com; --binance-domain binance.us where it's closed).
set -e
cd "$(dirname "$0")/.."
STAMP=$(date +%Y-%m-%d-%H%M)
DERIVED=build/DerivedData
LOG=build/build-$STAMP.log
mkdir -p build results

if pmset -g | grep -q "lowpowermode *1"; then
  echo "⚠︎ Low Power Mode is on: numbers will be lower. Turn it off in System Settings › Battery."
fi
if [[ "$(pmset -g batt | head -1)" == *"Battery Power"* ]]; then
  echo "⚠︎ On battery: plug in for steady numbers."
fi

build() {
  xcodebuild -project Mac/GinghamBench.xcodeproj -scheme GinghamBench -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' "$@" build >> "$LOG" 2>&1
}
echo "▸ building Release (log: $LOG)"
# Signed with the project's team if this Mac has its certificate; otherwise signed to run locally.
if ! build; then
  echo "  (no signing certificate of the project's team: building signed to run locally)"
  build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= || { echo "✗ build failed:"; grep -E "error:" "$LOG" | head -5; exit 1 }
fi
APP="$DERIVED/Build/Products/Release/Gingham Bench.app/Contents/MacOS/Gingham Bench"

# Awake for the whole run (display too: a sleeping display stops the frames).
caffeinate -dimsu -w $$ &
"$APP" --scenario all --engine all --seconds 10 --runs 3 --output "results/$STAMP.jsonl" "$@"
