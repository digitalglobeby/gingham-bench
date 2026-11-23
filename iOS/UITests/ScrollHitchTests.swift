import XCTest

// Real touches, measured by the system rather than by the app: each test
// launches the bench showing one engine (values changing as in the app's own
// tests), flicks the table up and back down, and measures that with `XCTOSSignpostMetric.scrollingAndDecelerationMetric`:
// the hitch time ratio, frame rate and frame count of UIKit's scrolling and
// deceleration intervals, from the frames the render server actually showed.
// Each test repeats the measurement five times (XCTest's default) after an
// unmeasured warm-up flick each way.
//
// XCUITest waits for the app to go idle before each gesture. An engine that
// keeps the main thread busy while values change (UITableView (typical))
// never does, so XCUITest waits its full minute each time: that engine's test
// takes about a quarter of an hour; the others take a minute or two. One
// engine: -only-testing:"Gingham Bench UITests/ScrollHitchTests/testGingham".
//
// On a device (hitch metrics need one; the simulator runs the tests but may
// not report hitches):
//   iOS/Scripts/run-device.sh --ui-tests
// or
//   xcodebuild test -project iOS/GinghamBench.xcodeproj -scheme "Gingham Bench" \
//     -destination id=<UDID> -allowProvisioningUpdates -resultBundlePath flicks.xcresult
//   xcrun xcresulttool get test-results metrics --path flicks.xcresult
// Rows and changes a second: the environment variables
// TEST_RUNNER_GINGHAM_BENCH_ROWS and TEST_RUNNER_GINGHAM_BENCH_RATE
// (xcodebuild passes TEST_RUNNER_-prefixed variables to the tests).

@MainActor
final class ScrollHitchTests: XCTestCase {

    func testGingham() throws { try measureFlicks(engine: "gingham") }
    func testTableViewTypical() throws { try measureFlicks(engine: "tableView") }
    func testTableViewTuned() throws { try measureFlicks(engine: "tableViewTuned") }
    func testCollectionViewTypical() throws { try measureFlicks(engine: "collectionView") }
    func testCollectionViewTuned() throws { try measureFlicks(engine: "collectionViewTuned") }
    func testSwiftUIList() throws { try measureFlicks(engine: "swiftUIList") }

    func testSwiftUITable() throws {
        if UIDevice.current.userInterfaceIdiom == .phone {
            throw XCTSkip("On iPhone, SwiftUI Table shows only its first column; not comparable.")
        }
        try measureFlicks(engine: "swiftUITable")
    }

    private func measureFlicks(engine: String) throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "YES", "-engine", engine,
                               "-rows", environment["GINGHAM_BENCH_ROWS"] ?? "100000",
                               "-rate", environment["GINGHAM_BENCH_RATE"] ?? "1000"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "The bench didn't start")
        // Flicks by coordinates in the table, below the controls (the app hides
        // the engine from accessibility under UI tests: XCUITest's snapshot
        // of UITableView's 100,000 rows takes longer than it waits), released
        // at speed so the table keeps going (XCUITest's `.fast` is slower).
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let velocity = XCUIGestureVelocity(rawValue: 4_000)
        func flickUp() { low.press(forDuration: 0.01, thenDragTo: high, withVelocity: velocity, thenHoldForDuration: 0) }
        func flickDown() { high.press(forDuration: 0.01, thenDragTo: low, withVelocity: velocity, thenHoldForDuration: 0) }
        // Settle, then a warm-up flick each way, not measured.
        Thread.sleep(forTimeInterval: 3)
        flickUp()
        flickDown()

        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            flickUp()
            stopMeasuring()
            flickDown()
        }
        app.terminate()
    }
}
