#!/bin/zsh
# The next measurement session, step by step (prepared on 2026-11-23, not run yet). Every step is a
# Scripts/run-all.sh call: it builds Release, checks the isolation, runs the self-test and writes
# results/<date>.jsonl and .md, so each step has its own files.
#
#   Scripts/next-session.sh                 steps 1–3 on the MacBook's display (about 3 h 15 min)
#   Scripts/next-session.sh 1               one step (1, 2 or 3)
#   Scripts/next-session.sh 4k NAME WxH     step 4, at the very end: the 4K monitor (60 Hz), NAME a part of
#                                           its name, WxH its "looks like" size less about 140 × 140 points
#                                           (2560 × 1440 → 2420x1300); then 3840x2160 on it (about 1 h 30 min)
#
# Before: Gingham's new version in Mac/project.yml (`from:`), `xcodegen generate` in Mac/, and a
# build to resolve it (every result's header shows the Gingham version it ran with: check it). A
# quiet Mac: on power, Low Power Mode off, other apps closed, nothing building, indexing or syncing,
# the built-in display at 120 Hz in the mode of the published results (2056 × 1329 points), the
# network up (Binance), the terminal's Screen Recording permission on; don't touch the Mac.
#
# Estimates from the 2026-11-23 session (84 minutes for the default set, 37 for three scenarios at
# 2040 × 1080, each with its screen and trace passes):
#   1. Default window (1000 × 640): every scenario, the new wide-trades too, 3 runs of 10 s, the
#      screen pass and the trace pass on live-trades and order-book. ~95 min. As the Gingham version
#      changes, the whole set is rerun; this also redoes the tuned NSTableView's live-trades screen
#      run, invalid last time (the window was covered).
#   2. Full size (2040 × 1080): the four generated live scenarios (live-trades, order-book,
#      trade-feed, wide-trades), with the screen and trace passes. ~50 min.
#   3. Larger than the screen (3840 × 2160 points, what a 4K display at 120 Hz would show): the same
#      four scenarios. No trace pass (the recording already slows runs at 2040 × 1080); the screen
#      pass runs, but at this size the capture halves Gingham's rate, so read presented, updates
#      applied, main thread busy and data age. ~50 min (SwiftUI's runs mostly run out their timeouts).
#   4. The 4K monitor at 60 Hz, at the very end: the four scenarios in a window filling it (~45 min),
#      then 3840 × 2160 points on it (~45 min). Numbers at 60 Hz aren't comparable with 120 Hz ones.
# Between steps a 2-minute pause lets the Mac cool down.
set -e
cd "$(dirname "$0")/.."
LIVE=live-trades,order-book,trade-feed,wide-trades
echo "Gingham: $(grep -A2 'Gingham:' Mac/project.yml | grep -m1 'from:' | sed 's/.*from: *//')"

step() {
  case $1 in
    1) Scripts/run-all.sh --trace-pass ;;
    2) Scripts/run-all.sh --scenario $LIVE --window 2040x1080 --trace-pass ;;
    3) Scripts/run-all.sh --scenario $LIVE --window 3840x2160 ;;
    *) echo "no step $1"; exit 64 ;;
  esac
}

if [[ "$1" == 4k ]]; then
  [[ -n "$2" && -n "$3" ]] || { echo "usage: Scripts/next-session.sh 4k NAME WxH"; exit 64 }
  Scripts/run-all.sh --scenario $LIVE --screen "$2" --window "$3"
  sleep 120
  Scripts/run-all.sh --scenario $LIVE --screen "$2" --window 3840x2160
elif [[ -n "$1" ]]; then
  step $1
else
  step 1; sleep 120
  step 2; sleep 120
  step 3
fi
