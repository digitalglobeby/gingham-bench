#!/bin/zsh
# Builds the Mac app (Release) and runs every scenario with every engine, each run in a process
# of its own, writing results/<date>.jsonl (a JSON line per run) and results/<date>.md (the table).
#
#   Scripts/run-all.sh                          everything: 7 scenarios × 7 engines × 3 runs of 10 s, then a
#                                               round of all with the screen meter (about 100 minutes: runs
#                                               wait for Binance's request limit, SwiftUI's Table runs out its
#                                               timeouts, and sorts on the main thread take a while)
#   Scripts/run-all.sh --scenario live-trades   any of the app's arguments (see Mac/GinghamBench/App/Options.swift)
#   Scripts/run-all.sh --runs 5 --seconds 20
#   Scripts/run-all.sh --trace-pass             also one Instruments-traced run of each engine on live-trades and
#                                               order-book: the system's count of the window's frames (~8 minutes more)
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
# The engines' hot code without Swift 6's per-call isolation checks (see the script).
Scripts/check-isolation.sh "$APP"
# Every engine keeps step with the store's changes (a replay of order book changes, no network).
"$APP" --self-test > build/self-test.txt 2>&1 || { echo "✗ self-test failed:"; grep -v "^sandbox" build/self-test.txt; exit 1 }

# Awake for the whole run, the display too (a sleeping display stops the frames; runs during
# which the screen locked or the window was covered are reported as invalid).
caffeinate -dims -w $$ &
# The measured runs go without the screen meter (its capture can cost a saturated engine a few
# percent), then one round of every scenario and engine runs with it for the screen updates.
# The screen meter needs the Screen Recording permission of the terminal app this runs in.
"$APP" --scenario all --engine all --seconds 10 --runs 3 --separate-screen-pass --output "results/$STAMP.jsonl" "$@"
