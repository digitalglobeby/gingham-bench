import Foundation
import GameController
import Gingham
import UIKit

// Launch arguments (each `-name value`, read through UserDefaults' argument
// domain), and the results: a line per test and per engine on standard output
// (`RESULT {json}`, `BENCH_SUMMARY {json}`), and one JSON file in the app's
// Documents (`gingham-bench-<date>.json`, also copied to `latest.json`).
//
//   -engine all | gingham,tableView,tableViewTuned,collectionView,
//                 collectionViewTuned,swiftUITable,swiftUIList
//                      (names or 0…6, comma separated; default: all, but
//                      SwiftUI Table on iPhone, where it shows one column)
//   -rows 100000       rows (default 100,000)
//   -rate 1000         changes a second (default 1,000)
//   -screenShare 0.2   share of the changes made to rows on or near the
//                      screen (default 0.2; the rest go to any row)
//   -profiles steady,fast,flicks
//                      the tests each engine runs (default: all three; see
//                      ScrollProfile.swift)
//   -speed 3000        the steady test's points a second for 24-point rows
//   -fastSpeed 8000    the fast test's, and the flicks' starting speed
//   -duration 8        seconds each test lasts (default 8)
//   -warmUp 2          seconds of unmeasured scrolling before an engine's
//                      first test (default 2)
//   -settle 2          seconds each engine shows before that (default 2)
//   -runs 3            runs of each engine (default 3), interleaved:
//                      every engine once, then again
//   -ginghamExtras YES Gingham's header, pinned column and summary row
//   -autoTest YES      run the tests at launch
//   -exitWhenDone YES  quit when done (for `devicectl … --console`)
//   -uiTest YES        set by the UI tests (no automatic tests)
//
// Example: -autoTest YES -engine all -runs 3 -rows 100000 -rate 1000

struct BenchOptions {
    var engines: [BenchEngineKind] = BenchEngineKind.comparable
    var rows = 100_000
    var rate = 1_000
    var screenShare = 0.2
    var profiles: [ScrollProfile] = ScrollProfile.allCases
    var speed: CGFloat = 3_000
    var fastSpeed: CGFloat = 8_000
    var duration: TimeInterval = 8
    var warmUp: TimeInterval = 2
    var settle: TimeInterval = 2
    var runs = 3
    var ginghamExtras = false
    var autoTest = false
    var exitWhenDone = false

    static func fromLaunchArguments() -> BenchOptions {
        let defaults = UserDefaults.standard
        var options = BenchOptions()
        func has(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
        if let engines = defaults.string(forKey: "engine"), engines.lowercased() != "all" {
            let kinds = engines.split(separator: ",").compactMap { BenchEngineKind(argument: $0.trimmingCharacters(in: .whitespaces)) }
            if !kinds.isEmpty { options.engines = kinds }
        }
        if let profiles = defaults.string(forKey: "profiles") {
            let kinds = profiles.split(separator: ",").compactMap { ScrollProfile(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
            if !kinds.isEmpty { options.profiles = kinds }
        }
        if has("rows") { options.rows = max(1, defaults.integer(forKey: "rows")) }
        if has("rate") { options.rate = max(0, defaults.integer(forKey: "rate")) }
        if has("screenShare") { options.screenShare = min(1, max(0, defaults.double(forKey: "screenShare"))) }
        if has("speed") { options.speed = max(1, CGFloat(defaults.double(forKey: "speed"))) }
        if has("fastSpeed") { options.fastSpeed = max(1, CGFloat(defaults.double(forKey: "fastSpeed"))) }
        if has("duration") { options.duration = max(1, defaults.double(forKey: "duration")) }
        if has("warmUp") { options.warmUp = max(0, defaults.double(forKey: "warmUp")) }
        if has("settle") { options.settle = max(0, defaults.double(forKey: "settle")) }
        if has("runs") { options.runs = max(1, defaults.integer(forKey: "runs")) }
        options.ginghamExtras = defaults.bool(forKey: "ginghamExtras")
        options.autoTest = defaults.bool(forKey: "autoTest")
        options.exitWhenDone = defaults.bool(forKey: "exitWhenDone")
        return options
    }
}

/// One measured test of one engine.
struct BenchRunResult: Codable {
    var engine: String
    var profile: String
    var run: Int
    var rows: Int
    var changesPerSecond: Int
    var screenShare: Double
    var rowsPerSecond: Double
    /// This engine's top speed in the test (faster in points when its rows are taller).
    var topSpeedPointsPerSecond: Double
    // Main-thread frame callbacks (FrameMeter.swift).
    var averageFPS: Double
    var worstSecondFPS: Int
    var longestFrameMs: Double
    var hitches: Int
    var hitchTimeMsPerSecond: Double
    var frames: Int
    var seconds: Double
    var refreshIntervalMs: Double
    /// Frames in the second before the engine's first test, at rest: the rate the display gave.
    var restFPS: Int
    // Load.
    var mainThreadBusyPercent: Double
    /// The process's CPU time (all its threads) over the test's time; 100 = one core.
    var processCPUPercent: Double
    /// The update call alone, per frame that had changes: making the changes
    /// and telling the engine (for SwiftUI, the observation callbacks). Not
    /// comparable across engines: UIKit's typical engines do their work in
    /// it, Gingham and SwiftUI only note the change and do the work later,
    /// at layout and drawing (in the frames, main thread load and CPU time).
    var updateCalls: Int
    var updateMsAverage: Double
    var updateMsMax: Double
    // What the test really did.
    var changesMade: Int
    var changesOnScreen: Int
    var deepestScrollPoints: Double
    var rowHeightPoints: Double?
    var visibleDataRows: Int
    var columnsShown: Int
    var scrollingView: String
    var thermalStateStart: String
    var thermalStateWorst: String
}

/// An engine's runs of one test together: medians, and the worst of each figure.
struct BenchEngineSummary: Codable {
    var engine: String
    var profile: String
    var runs: Int
    var medianFPS: Double
    var lowestFPS: Double
    var medianWorstSecondFPS: Double
    var worstSecondFPS: Int
    var medianLongestFrameMs: Double
    var longestFrameMs: Double
    var medianHitchTimeMsPerSecond: Double
    var highestHitchTimeMsPerSecond: Double
    var medianMainThreadBusyPercent: Double
    var medianProcessCPUPercent: Double

    init(engine: String, profile: String, runs: [BenchRunResult]) {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        self.engine = engine
        self.profile = profile
        self.runs = runs.count
        medianFPS = median(runs.map(\.averageFPS))
        lowestFPS = runs.map(\.averageFPS).min() ?? 0
        medianWorstSecondFPS = median(runs.map { Double($0.worstSecondFPS) })
        worstSecondFPS = runs.map(\.worstSecondFPS).min() ?? 0
        medianLongestFrameMs = median(runs.map(\.longestFrameMs))
        longestFrameMs = runs.map(\.longestFrameMs).max() ?? 0
        medianHitchTimeMsPerSecond = median(runs.map(\.hitchTimeMsPerSecond))
        highestHitchTimeMsPerSecond = runs.map(\.hitchTimeMsPerSecond).max() ?? 0
        medianMainThreadBusyPercent = median(runs.map(\.mainThreadBusyPercent))
        medianProcessCPUPercent = median(runs.map(\.processCPUPercent))
    }
}

/// How the app was built.
struct BenchBuild: Codable {
    var configuration: String
    /// The bench repository's commit (set by Scripts/run-device.sh; empty from Xcode).
    var benchCommit: String
    var xcode: String
    var sdk: String
    var gingham: String

    static var current: BenchBuild {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return BenchBuild(configuration: configuration,
                          benchCommit: info["GinghamBenchCommit"] as? String ?? "",
                          xcode: "\(info["DTXcode"] as? String ?? "?") (\(info["DTXcodeBuild"] as? String ?? "?"))",
                          sdk: info["DTSDKName"] as? String ?? "?",
                          gingham: GHTableView.version)
    }
}

/// The device and the conditions the bench ran in.
struct BenchDevice: Codable {
    var model: String
    var system: String
    var isSimulator: Bool
    var maximumFramesPerSecond: Int
    var screenPoints: String
    var screenScale: Double
    var lowPowerMode: Bool
    var hardwareKeyboard: Bool
    var thermalState: String
    var processorCount: Int
    var memoryGB: Double

    static func current(screen: UIScreen?) -> BenchDevice {
        let screen = screen ?? UIScreen.main
        let info = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let isSimulator = true
        let model = "Simulator " + (info.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "?")
        #else
        let isSimulator = false
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
        return BenchDevice(model: model,
                           system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                           isSimulator: isSimulator,
                           maximumFramesPerSecond: screen.maximumFramesPerSecond,
                           screenPoints: "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))",
                           screenScale: screen.scale,
                           lowPowerMode: info.isLowPowerModeEnabled,
                           hardwareKeyboard: GCKeyboard.coalesced != nil,
                           thermalState: info.thermalState.name,
                           processorCount: info.activeProcessorCount,
                           memoryGB: (Double(info.physicalMemory) / 1_073_741_824 * 10).rounded() / 10)
    }
}

/// Everything one launch measured: the file written to Documents.
struct BenchReport: Codable {
    var app = "Gingham Bench (iOS)"
    var date: Date
    var build: BenchBuild
    var device: BenchDevice
    var settings: Settings
    var runs: [BenchRunResult]
    var summary: [BenchEngineSummary]

    struct Settings: Codable {
        var engines: [String]
        var profiles: [String]
        var rows: Int
        var changesPerSecond: Int
        var screenShare: Double
        var runsPerEngine: Int
        var secondsPerTest: Double
        var warmUpSeconds: Double
        /// For 24-point rows.
        var steadyPointsPerSecond: Double
        var fastPointsPerSecond: Double
        var rowHeightPoints: Double
        var fontSize: Double
        var ginghamExtras: Bool
    }

    /// Writes the report to Documents; returns the file's URL.
    func write() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = documents.appendingPathComponent("gingham-bench-\(formatter.string(from: date)).json")
        try data.write(to: url, options: .atomic)
        try data.write(to: documents.appendingPathComponent("latest.json"), options: .atomic)
        return url
    }
}

/// One line of JSON (for the result lines on standard output).
func jsonLine(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

/// Prints a line and flushes it at once (standard output is a pipe under
/// `devicectl --console` and would otherwise hold it back).
func benchLog(_ line: String) {
    print(line)
    fflush(stdout)
}

/// The process's CPU time so far (user and system, all threads), in seconds.
func processCPUTime() -> TimeInterval {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
