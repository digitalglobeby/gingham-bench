#!/bin/zsh
# The next measurement session, unattended (prepared on 2026-11-23). Every step is a
# Scripts/run-all.sh call (it builds Release, checks the isolation, runs the self-test and writes
# results/<date>.jsonl and .md, so each step has its own files); everything is logged to
# results/session-<date>.log.
#
#   Scripts/next-session.sh                 steps 1–6 on the MacBook's display, once (about 7 hours)
#   Scripts/next-session.sh 2 3             those steps (1 to 6)
#   Scripts/next-session.sh --sets 3 2 3    steps 2 and 3, three sets of each: the steps run in rounds, so the
#                                           sets of a step are a round apart (here about 2 hours); the README's
#                                           tables combine them (Scripts/readme-tables.py: the median of the
#                                           sets' medians, with the range across the sets)
#   Scripts/next-session.sh 4k NAME [WxH]   later, on its own: the 4K monitor (60 Hz), NAME a part of its
#                                           name; a window filling its visible area (or WxH), then 3840x2160
#                                           on it (about 1 h 45 min)
#
# Before: a quiet Mac on power, Low Power Mode off, other apps closed, nothing building, indexing or
# syncing; the built-in display at 120 Hz in the mode of the published results (2056 × 1329 points);
# the network up (Binance); the terminal's Screen Recording permission on (and its Developer Tools
# permission for the trace pass); don't touch the Mac. Every result's header shows the Gingham
# version it ran with (Mac/project.yml: `from:`) and the bench's commit.
#
# The Mac's power (CPU + GPU) needs powermetrics, which needs root: start it in another terminal
# before the session and leave it running to the end (about 160 KB a second: some 3 GB for the
# whole session), then give its file to the session:
#
#   sudo powermetrics -s cpu_power,gpu_power,tasks --show-process-gpu --show-process-energy \
#       -i 1000 -f plist -o ~/gingham-power.plist
#   POWER=~/gingham-power.plist Scripts/next-session.sh
#
# Each step's runs then get the power in their measured windows (results/<date>.jsonl, `power`, and
# the Markdown's "Mac power" column). Without POWER the session runs as before, without power.
#
# Unattended: the Mac stays awake (caffeinate) for the whole session; before each step it waits until
# the Mac has settled (all processes together under 30% of the CPU, three readings in a row; at most
# 45 minutes, then it goes on and says so); the trace pass deletes Instruments' raw kernel traces
# (instruments*.ktrace in the temporary folder) after every traced run, and leftovers are deleted
# after each step; under 40 GB free the session stops (checked before each step and every 30 s).
# Scenarios whose runs failed on the network (Binance didn't answer after 4 tries: status
# "network") are run once more at the end of the session, at the window size they had.
#
# Estimates from the 2026-11-23/24 sessions, with 8 engines now (84 minutes for the default set of 7
# engines, ~50 for four scenarios at 2040 × 1080, each with its screen and trace passes):
#   1. Default window (1000 × 640): every scenario (the quiet table, scrolling and the number sort
#      too), 3 runs of 10 s, the screen pass and the trace pass on live-trades and order-book.
#      ~2 h 30 min.
#   2. Full size (2040 × 1080): the four generated live scenarios (live-trades, order-book,
#      trade-feed, wide-trades), with the screen and trace passes. ~1 h.
#   3. Larger than the screen (3840 × 2160 points, 7680 × 4320 pixels; about a third of it on the
#      MacBook's screen): the same four scenarios. No trace pass (the recording already slows runs
#      at 2040 × 1080); the screen pass runs, but at this size the capture costs the runs it
#      measures (Gingham's 120 fell to 60 with it), so read updates, main thread busy and data
#      age. ~1 h (SwiftUI's runs mostly run out their timeouts).
#   4. An equal update rate, the default window: the four live scenarios with the changes applied
#      30 times a second for every engine (--update-rate 30), as an app that coalesces does: what
#      each engine costs at a rate the AppKit tables can hold. No screen meter. ~45 min.
#   5. The same at 2040 × 1080. ~45 min.
#   6. 60 updates a second at 2040 × 1080 (--update-rate 60). ~45 min.
#   4k. The 4K monitor at 60 Hz, later: the four scenarios in a window filling it (~50 min), then
#      3840 × 2160 points on it (~50 min). Numbers at 60 Hz aren't comparable with 120 Hz ones.
# Plus the waits for the Mac to settle before each step (a few minutes each), and about 5 s after
# every run for the window server to settle (the app waits; some 40 minutes over the six steps).
set -e
cd "$(dirname "$0")/.."
mkdir -p results build
LOG="results/session-$(date +%Y-%m-%d-%H%M).log"
exec > >(tee -a "$LOG") 2>&1
LIVE=live-trades,order-book,trade-feed,wide-trades
MIN_FREE_GB=40

say() { echo "[$(date +%H:%M:%S)] $*" }

# The powermetrics recording (POWER=file): given to every step's runs.
POWER_ARGS=()
if [[ -n "$POWER" ]]; then
  POWER=${~POWER}
  if [[ ! -s "$POWER" ]]; then
    say "✗ POWER=$POWER: no such file (start powermetrics first, see the top of this script)"
    exit 64
  fi
  POWER_ARGS=(--power "$POWER")
fi

# Whether the powermetrics recording still grows (it stopped: the rest of the session has no power).
power_alive() {
  [[ -z "$POWER" ]] && return 0
  local before=$(stat -f %z "$POWER")
  sleep 3
  (( $(stat -f %z "$POWER") > before ))
}

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

# Scenarios to run again at the end ("scenarios|arguments" lines), for runs the network failed.
AGAIN=()

run() {
  check_disk
  wait_settled
  say "▸ Scripts/run-all.sh $*"
  power_alive || say "⚠︎ $POWER doesn't grow: is powermetrics still running? (this step's runs get no power)"
  local exit_status=0 marker=build/session-step-marker
  touch $marker
  Scripts/run-all.sh "$@" "${POWER_ARGS[@]}" || exit_status=$?
  clean_kernel_traces
  say "  done (exit $exit_status), $(free_gb) GB free"
  # The step's results: scenarios with runs the network failed.
  local failed=$(find results -maxdepth 1 -name '*.jsonl' -newer $marker -exec python3 -I -c '
import json, sys
names = set()
for path in sys.argv[1:]:
    for line in open(path):
        try: run = json.loads(line)
        except ValueError: continue
        if run.get("status") == "network": names.add(run["scenario"])
print(",".join(sorted(names)))' {} +)
  if [[ -n "$failed" ]]; then
    say "  the network failed runs of $failed: they run again at the end"
    local window=() i
    for (( i = 1; i <= $#; i++ )); do [[ "${@[i]}" == --window || "${@[i]}" == --screen ]] && window+=("${@[i]}" "${@[i+1]}"); done
    AGAIN+=("$failed|${window[*]}")
  fi
}

# Once: a scenario the network fails again stays failed, for a rerun by hand.
run_again() {
  local entry pending=("${AGAIN[@]}")
  AGAIN=()
  for entry in "${pending[@]}"; do
    local scenarios=${entry%%|*} rest=${entry#*|}
    say "▸ again, the network having failed them: $scenarios"
    run --scenario $scenarios ${=rest}
  done
}

step() {
  case $1 in
    1) run --trace-pass ;;
    2) run --scenario $LIVE --window 2040x1080 --trace-pass ;;
    3) run --scenario $LIVE --window 3840x2160 ;;
    4) run --scenario $LIVE --update-rate 30 --no-screen-meter ;;
    5) run --scenario $LIVE --window 2040x1080 --update-rate 30 --no-screen-meter ;;
    6) run --scenario $LIVE --window 2040x1080 --update-rate 60 --no-screen-meter ;;
    *) say "no step $1"; exit 64 ;;
  esac
}

# One build first, signed with the project's team (a failed build is tried once more; run-all.sh
# then finds it built): no session with a build signed some other way.
build_signed() {
  xcodebuild -project Mac/GinghamBench.xcodeproj -scheme GinghamBench -configuration Release \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' BENCH_COMMIT="$(Scripts/bench-commit.sh)" \
    build >> build/session-build.log 2>&1
}

# Awake for the whole session, the display too.
caffeinate -dims -w $$ &
watch_disk &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null' EXIT
say "session log: $LOG · Gingham $(grep -A2 'Gingham:' Mac/project.yml | grep -m1 'from:' | sed 's/.*from: *//') · bench $(Scripts/bench-commit.sh) · $(free_gb) GB free · power: ${POWER:-not recorded (no POWER)}"
check_disk
build_signed || build_signed || { say "✗ the Release build failed (build/session-build.log)"; exit 1 }

if [[ "$1" == 4k ]]; then
  [[ -n "$2" ]] || { say "usage: Scripts/next-session.sh 4k NAME [WxH]"; exit 64 }
  run --scenario $LIVE --screen "$2" --window "${3:-fill}"
  run --scenario $LIVE --screen "$2" --window 3840x2160
else
  SETS=1
  if [[ "$1" == --sets ]]; then
    SETS=$2
    shift 2
    [[ "$SETS" == <1-9> ]] || { say "usage: Scripts/next-session.sh --sets N [steps]"; exit 64 }
  fi
  STEPS=("$@")
  (( ${#STEPS} )) || STEPS=(1 2 3 4 5 6)
  for (( set = 1; set <= SETS; set++ )); do
    (( SETS > 1 )) && say "▸▸ set $set of $SETS: steps ${STEPS[*]}"
    for s in $STEPS; do step $s; done
  done
fi
run_again
say "session done: today's results/*.md"
