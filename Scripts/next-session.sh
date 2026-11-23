#!/bin/zsh
# The next measurement session, unattended (prepared on 2026-11-23). Every step is a
# Scripts/run-all.sh call (it builds Release, checks the isolation, runs the self-test and writes
# results/<date>.jsonl and .md, so each step has its own files); everything is logged to
# results/session-<date>.log.
#
#   Scripts/next-session.sh                 steps 1–3 on the MacBook's display (about 3 h 30 min)
#   Scripts/next-session.sh 2               one step (1, 2 or 3)
#   Scripts/next-session.sh 4k NAME WxH     later, on its own: the 4K monitor (60 Hz), NAME a part of its
#                                           name, WxH its "looks like" size less about 140 × 140 points
#                                           (2560 × 1440 → 2420x1300); then 3840x2160 on it (about 1 h 30 min)
#
# Before: a quiet Mac on power, Low Power Mode off, other apps closed, nothing building, indexing or
# syncing; the built-in display at 120 Hz in the mode of the published results (2056 × 1329 points);
# the network up (Binance); the terminal's Screen Recording permission on (and its Developer Tools
# permission for the trace pass); don't touch the Mac. Every result's header shows the Gingham
# version it ran with (Mac/project.yml: `from:`).
#
# Unattended: the Mac stays awake (caffeinate) for the whole session; before each step it waits until
# the Mac has settled (all processes together under 30% of the CPU, three readings in a row; at most
# 45 minutes, then it goes on and says so); the trace pass deletes Instruments' raw kernel traces
# (instruments*.ktrace in the temporary folder) after every traced run, and leftovers are deleted
# after each step; under 40 GB free the session stops (checked before each step and every 30 s).
#
# Estimates from the 2026-11-23 session (84 minutes for the default set, 37 for three scenarios at
# 2040 × 1080, each with its screen and trace passes):
#   1. Default window (1000 × 640): every scenario, the new wide-trades too, 3 runs of 10 s, the
#      screen pass and the trace pass on live-trades and order-book. ~100 min (each sort run also
#      sorts by the other column). With the new Gingham version the whole set is rerun; this also
#      redoes the tuned NSTableView's live-trades screen run, invalid last time (the window was
#      covered).
#   2. Full size (2040 × 1080): the four generated live scenarios (live-trades, order-book,
#      trade-feed, wide-trades), with the screen and trace passes. ~50 min.
#   3. Larger than the screen (3840 × 2160 points, what a 4K display at 120 Hz would show): the same
#      four scenarios. No trace pass (the recording already slows runs at 2040 × 1080); the screen
#      pass runs, but at this size the capture halves Gingham's rate, so read presented, updates
#      applied, main thread busy and data age. ~50 min (SwiftUI's runs mostly run out their timeouts).
#   4k. The 4K monitor at 60 Hz, later: the four scenarios in a window filling it (~45 min), then
#      3840 × 2160 points on it (~45 min). Numbers at 60 Hz aren't comparable with 120 Hz ones.
# Plus the waits for the Mac to settle before each step (a few minutes each).
set -e
cd "$(dirname "$0")/.."
mkdir -p results build
LOG="results/session-$(date +%Y-%m-%d-%H%M).log"
exec > >(tee -a "$LOG") 2>&1
LIVE=live-trades,order-book,trade-feed,wide-trades
MIN_FREE_GB=40

say() { echo "[$(date +%H:%M:%S)] $*" }

free_gb() { df -k /System/Volumes/Data | awk 'NR == 2 { printf "%d", $4 / 1024 / 1024 }' }

check_disk() {
  local free=$(free_gb)
  if (( free < MIN_FREE_GB )); then
    say "✗ stopped: $free GB free, the session needs $MIN_FREE_GB"
    exit 1
  fi
}

# The CPU all processes use together, percent of the whole Mac (top's second sample: the first
# counts since boot).
cpu_busy() {
  top -l 2 -n 0 -s 3 | awk '/^CPU usage/ { idle = $7 } END { sub("%", "", idle); printf "%d", 100 - idle }'
}

wait_settled() {
  local deadline=$(( SECONDS + 45 * 60 )) calm=0 busy=0
  while (( SECONDS < deadline )); do
    busy=$(cpu_busy)
    if (( busy < 30 )); then
      calm=$(( calm + 1 ))
      if (( calm >= 3 )); then
        say "settled ($busy% CPU)"
        return 0
      fi
    else
      calm=0
      say "waiting for the Mac to settle: $busy% CPU"
      sleep 20
    fi
  done
  say "⚠︎ the Mac didn't settle under 30% CPU within 45 minutes ($busy% now): going on; compare with care"
}

# Raw kernel traces Instruments left behind, not written to for 2 minutes (none is being recorded).
clean_kernel_traces() {
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'instruments*.ktrace' -mmin +2 -print -delete 2>/dev/null | sed 's/^/  deleted /'
}

# Stops the session (and the bench) when the disk fills up while a step runs.
watch_disk() {
  while sleep 30; do
    if (( $(free_gb) < MIN_FREE_GB )); then
      say "✗ under $MIN_FREE_GB GB free during the step: stopping the session"
      pkill -f "Scripts/run-all.sh" || true
      pkill -f "Gingham Bench.app/Contents/MacOS/Gingham Bench" || true
      kill $$ 2>/dev/null || true
      exit 1
    fi
  done
}

run() {
  check_disk
  wait_settled
  say "▸ Scripts/run-all.sh $*"
  local exit_status=0
  Scripts/run-all.sh "$@" || exit_status=$?
  clean_kernel_traces
  say "  done (exit $exit_status), $(free_gb) GB free"
}

step() {
  case $1 in
    1) run --trace-pass ;;
    2) run --scenario $LIVE --window 2040x1080 --trace-pass ;;
    3) run --scenario $LIVE --window 3840x2160 ;;
    *) say "no step $1"; exit 64 ;;
  esac
}

# One build first, signed with the project's team (a failed build is tried once more; run-all.sh
# then finds it built): no session with a build signed some other way.
build_signed() {
  xcodebuild -project Mac/GinghamBench.xcodeproj -scheme GinghamBench -configuration Release \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' build >> build/session-build.log 2>&1
}

# Awake for the whole session, the display too.
caffeinate -dims -w $$ &
watch_disk &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null' EXIT
say "session log: $LOG · Gingham $(grep -A2 'Gingham:' Mac/project.yml | grep -m1 'from:' | sed 's/.*from: *//') · $(free_gb) GB free"
check_disk
build_signed || build_signed || { say "✗ the Release build failed (build/session-build.log)"; exit 1 }

if [[ "$1" == 4k ]]; then
  [[ -n "$2" && -n "$3" ]] || { say "usage: Scripts/next-session.sh 4k NAME WxH"; exit 64 }
  run --scenario $LIVE --screen "$2" --window "$3"
  run --scenario $LIVE --screen "$2" --window 3840x2160
elif [[ -n "$1" ]]; then
  step $1
else
  step 1
  step 2
  step 3
fi
say "session done: today's results/*.md"
