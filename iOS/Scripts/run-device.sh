#!/bin/bash
# Measures Gingham Bench on a connected iPhone or iPad and copies the results
# into iOS/results/. Three measurements, each its own option (default: --app):
#
#   --app       the app's own tests: every engine scrolled (steady, fast,
#               flicks) while values change, at 100,000 rows and 1,000
#               changes a second, then at 1,000,000 rows and 10,000 a second;
#               frames from main-thread callbacks, CPU time, update times.
#               The app's JSON report and log per scenario.
#   --ui-tests  real flicks by XCUITest, measured by the system
#               (XCTOSSignpostMetric: the render server's hitch time ratio
#               and frame rate). The .xcresult and its metrics as JSON.
#   --hitches   Instruments' Animation Hitches, one recording per engine
#               while the app runs its tests: every hitch the render server
#               saw, attributed to each test. The .trace files and a summary.
#   --all       all three.
#
#   iOS/Scripts/run-device.sh [--device UDID] [--no-build] [modes] [-- app arguments]
#
# App arguments after -- replace the default scenarios of --app (and are
# added to each engine's run with --hitches), e.g.
#   iOS/Scripts/run-device.sh -- -engine gingham,tableViewTuned -rows 1000000 -rate 10000
# They're listed in iOS/GinghamBench/BenchResults.swift. Without --device,
# the first connected iPhone or iPad. GINGHAM_BENCH_ROWS / _RATE set the UI
# tests' rows and changes a second (default 100,000 and 1,000).
#
# Before running: the device unlocked and awake (the app keeps the screen on),
# Low Power Mode off, no keyboard attached, at room temperature, other apps
# closed; don't touch it while it runs. --app takes about 20 minutes, --ui-tests
# about 25, --hitches about 10. Needs Xcode 26 or later, and automatic signing
# (the project's team is CX4XTQ23ND; DEVELOPMENT_TEAM=... to use yours).

set -euo pipefail

DEVICE="${GINGHAM_BENCH_DEVICE:-}"
BUNDLE_ID="by.digitalglobe.gingham-bench"
BUILD=1
RUN_APP=0
RUN_UI=0
RUN_HITCHES=0
APP_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --app) RUN_APP=1; shift ;;
        --ui-tests) RUN_UI=1; shift ;;
        --hitches) RUN_HITCHES=1; shift ;;
        --all) RUN_APP=1; RUN_UI=1; RUN_HITCHES=1; shift ;;
        --) shift; APP_ARGS=("$@"); break ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (app arguments go after --)" >&2; exit 2 ;;
    esac
done
[[ $RUN_APP -eq 0 && $RUN_UI -eq 0 && $RUN_HITCHES -eq 0 ]] && RUN_APP=1

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$IOS_DIR/build"
APP="$DERIVED/Build/Products/Release-iphoneos/GinghamBench.app"
RESULTS="$IOS_DIR/results"
STAMP="$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$RESULTS"

# The device (the first connected iPhone or iPad unless given) and its kind.
LIST="$(mktemp)"
xcrun devicectl list devices --json-output "$LIST" > /dev/null 2>&1 || true
read -r DEVICE DEVICE_TYPE < <(python3 -I - "$LIST" "$DEVICE" <<'EOF'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
wanted = sys.argv[2]
for device in devices:
    hardware, connection = device.get("hardwareProperties", {}), device.get("connectionProperties", {})
    if wanted:
        if hardware.get("udid") == wanted:
            print(wanted, hardware.get("deviceType", "unknown"))
            break
    elif hardware.get("reality") == "physical" and hardware.get("platform") == "iOS" \
            and connection.get("tunnelState") == "connected":
        print(hardware.get("udid", ""), hardware.get("deviceType", "unknown"))
        break
else:
    print(wanted or "-", "unknown")
EOF
)
rm -f "$LIST"
[[ "$DEVICE" != "-" ]] || { echo "No connected iPhone or iPad (or pass --device UDID)." >&2; exit 1; }
echo "Device: $DEVICE ($DEVICE_TYPE)"

# The bench's commit, recorded in the report.
COMMIT="$(git -C "$IOS_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$IOS_DIR" status --porcelain -- . ../Shared 2>/dev/null)" ]]; then COMMIT="$COMMIT-modified"; fi
SETTINGS=(BENCH_COMMIT="$COMMIT")
[[ -n "${DEVELOPMENT_TEAM:-}" ]] && SETTINGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")

if [[ $BUILD -eq 1 && ( $RUN_APP -eq 1 || $RUN_HITCHES -eq 1 ) ]]; then
    echo "Building (Release, commit $COMMIT)…"
    xcodebuild -project "$IOS_DIR/GinghamBench.xcodeproj" -scheme "Gingham Bench" -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
        "${SETTINGS[@]}" build > "$RESULTS/build-$STAMP.log" 2>&1 \
        || { echo "Build failed; see $RESULTS/build-$STAMP.log" >&2; tail -20 "$RESULTS/build-$STAMP.log" >&2; exit 1; }
    rm -f "$RESULTS/build-$STAMP.log"
fi
if [[ $RUN_APP -eq 1 || $RUN_HITCHES -eq 1 ]]; then
    [[ -d "$APP" ]] || { echo "No app at $APP (build first)" >&2; exit 1; }
    echo "Installing…"
    xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
fi

# One launch of the app's tests: log and JSON report into results/.
run_app() {
    local name="$1"; shift
    local log="$RESULTS/ios-$name-$STAMP.log" report="$RESULTS/ios-$name-$STAMP.json"
    echo "App tests ($name): $*"
    # --console waits for the app to quit and passes its output through.
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console "$BUNDLE_ID" \
        -- -autoTest YES -exitWhenDone YES "$@" 2>&1 | tee "$log" | grep -E '^(RESULT|BENCH_DONE|BENCH_ERROR)' | cut -c1-140 || true
    grep -q '^BENCH_DONE' "$log" || { echo "The run didn't finish (no BENCH_DONE in $log)." >&2; return 1; }
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" --source Documents/latest.json --destination "$report" > /dev/null
    echo "→ $report"
    if [[ "$(plutil -extract device.lowPowerMode raw -o - "$report" 2>/dev/null)" == "true" ]]; then echo "Warning: Low Power Mode was on." >&2; fi
    if [[ "$(plutil -extract device.hardwareKeyboard raw -o - "$report" 2>/dev/null)" == "true" ]]; then echo "Warning: a hardware keyboard was attached." >&2; fi
}

if [[ $RUN_APP -eq 1 ]]; then
    if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
        run_app custom "${APP_ARGS[@]}"
    else
        run_app 100k -engine all -runs 3 -rows 100000 -rate 1000
        run_app 1m -engine all -runs 3 -rows 1000000 -rate 10000
    fi
fi

if [[ $RUN_UI -eq 1 ]]; then
    BUNDLE="$RESULTS/ios-flicks-$STAMP.xcresult"
    echo "UI tests (real flicks, system hitch metrics)…"
    TEST_RUNNER_GINGHAM_BENCH_ROWS="${GINGHAM_BENCH_ROWS:-100000}" TEST_RUNNER_GINGHAM_BENCH_RATE="${GINGHAM_BENCH_RATE:-1000}" \
        xcodebuild test -project "$IOS_DIR/GinghamBench.xcodeproj" -scheme "Gingham Bench" \
        -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
        -resultBundlePath "$BUNDLE" "${SETTINGS[@]}" > "$RESULTS/ios-flicks-$STAMP.log" 2>&1 \
        || echo "Some UI tests failed; see $RESULTS/ios-flicks-$STAMP.log" >&2
    xcrun xcresulttool get test-results metrics --path "$BUNDLE" > "$RESULTS/ios-flicks-$STAMP.json"
    echo "→ $RESULTS/ios-flicks-$STAMP.json"
fi

if [[ $RUN_HITCHES -eq 1 ]]; then
    ENGINES=(gingham tableView tableViewTuned collectionView collectionViewTuned swiftUIList)
    # SwiftUI Table shows one column on iPhone: only on iPad.
    [[ "$DEVICE_TYPE" == "iPad" ]] && ENGINES+=(swiftUITable)
    for engine in "${ENGINES[@]}"; do
        trace="$RESULTS/ios-hitches-$engine-$STAMP.trace"
        echo "Animation Hitches: $engine…"
        # Instruments leaves its raw kernel trace (instruments*.ktrace, 1–2 GB) in the temporary
        # folder: those of this recording are deleted after it.
        KTRACES_BEFORE=$(ls "${TMPDIR:-/tmp/}"instruments*.ktrace 2>/dev/null || true)
        # The recording ends when the app quits; the os_signpost instrument
        # records the app's "Scroll test" intervals to attribute the hitches.
        xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost --device "$DEVICE" \
            --time-limit 10m --no-prompt --output "$trace" \
            --launch -- "$BUNDLE_ID" -autoTest YES -exitWhenDone YES -engine "$engine" -runs 1 ${APP_ARGS[@]+"${APP_ARGS[@]}"} \
            > "$RESULTS/ios-hitches-$engine-$STAMP.log" 2>&1 \
            || echo "Recording $engine reported problems; see $RESULTS/ios-hitches-$engine-$STAMP.log" >&2
        python3 -I "$IOS_DIR/Scripts/hitches-summary.py" "$trace" > "$RESULTS/ios-hitches-$engine-$STAMP.json" \
            || echo "Couldn't summarize $trace (open it in Instruments)." >&2
        for ktrace in "${TMPDIR:-/tmp/}"instruments*.ktrace; do
            [[ -e "$ktrace" ]] || continue
            grep -qxF "$ktrace" <<< "$KTRACES_BEFORE" || rm -f "$ktrace"
        done
        echo "→ $RESULTS/ios-hitches-$engine-$STAMP.json"
    done
fi
