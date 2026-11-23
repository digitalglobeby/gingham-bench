//
//  Report.swift
//  Gingham Bench
//
//  A run's result as a JSON line (with the machine it ran on), and the Markdown table made
//  from a file of them: per scenario and engine, the lowest and highest of the runs.
//

import AppKit
import Gingham

nonisolated struct Machine: Codable, Sendable {
    var model: String
    var chip: String
    var cores: Int
    var memoryGB: Int
    var macOS: String
    var gingham: String
    var screen: String
    var refreshRate: Int
    var lowPowerMode: Bool
    var thermalState: String
    var build: String

    @MainActor static func current(screen: NSScreen?) -> Machine {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var value = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &value, &size, nil, 0)
            return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let info = ProcessInfo.processInfo
        let thermal = thermalName(info.thermalState.rawValue)
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        let version = info.operatingSystemVersion
        return Machine(model: sysctl("hw.model"), chip: sysctl("machdep.cpu.brand_string"), cores: info.activeProcessorCount,
                       memoryGB: Int(info.physicalMemory / 1_073_741_824),
                       macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                       gingham: GHTableView.version, screen: screen?.localizedName ?? "?",
                       refreshRate: screen?.maximumFramesPerSecond ?? 0, lowPowerMode: info.isLowPowerModeEnabled,
                       thermalState: thermal, build: build)
    }

    static func thermalName(_ state: Int) -> String {
        switch state {
        case 0: "nominal"
        case 1: "fair"
        case 2: "serious"
        case 3: "critical"
        default: "unknown"
        }
    }

    var line: String {
        "\(model), \(chip), \(cores) cores, \(memoryGB) GB, macOS \(macOS), Gingham \(gingham), \(screen) at \(refreshRate) Hz, \(build) build"
            + (lowPowerMode ? ", LOW POWER MODE ON" : "") + (thermalState != "nominal" ? ", thermal state \(thermalState)" : "")
    }
}

/// Frames of the bench's window seen by the system (an Instruments trace: Animation Hitches).
nonisolated struct SystemFrames: Codable, Sendable {
    /// Core Animation commits of the process that reached a display swap (`hitches-updates`).
    var clientUpdatesPerSecond: Double?
    /// GPU frames the process drew into its table's largest surface (`metal-io-surface-access`),
    /// and those the window server then read to composite (shown).
    var gpuFramesPerSecond: Double?
    var gpuFramesShownPerSecond: Double?
    /// The display's frames (swaps) that showed new content of the window: those its commits went
    /// into and those its GPU frames went into, once each.
    var framesShownPerSecond: Double?
    var trace: String?
    /// The share of the measured window the trace covers.
    var windowCovered: Double?
}

nonisolated struct SortNumbers: Codable, Sendable {
    /// From the request to the first screen frame with the new order.
    var seconds: Double
    /// Display-link callbacks the main thread got to meanwhile.
    var framesDuring: Int
    var longestFrameGapMs: Double
}

nonisolated struct RunResult: Codable, Sendable {
    var scenario: String
    var engine: String
    var engineTitle: String
    var run: Int
    /// nil: a measured run; "screen": a run of the separate screen-truth pass (only its screen
    /// numbers are used).
    var pass: String?
    /// ok; timeout (no rows within the load timeout, or a sort step too long); stuck (the main
    /// thread didn't come back after the window); invalid (the window was covered or the screen
    /// locked during the run); error.
    var status: String
    var note: String?
    var rows: Int
    var warmup: Double
    var loadSeconds: Double?
    /// Generated scenarios: the row changes a second the feed makes.
    var nominalChangesPerSecond: Double?
    var numbers: RunNumbers?
    var sorts: [SortNumbers]?
    /// The order shown checked against the store after the run (live scenarios: stopped, then
    /// every row in its place; sorts: Finder's order all the way down): "ok" or what's wrong.
    var orderCheck: String?
    /// The screen meter's state: "running", or why there are no screen numbers.
    var screenMeter: String?
    /// The measured window in wall-clock time (seconds since 1970) and the process: to find the
    /// window in a system trace (`--trace-pass`, `Scripts/trace-frames.py`).
    var windowStartEpoch: Double?
    var windowEndEpoch: Double?
    var pid: Int32?
    /// From a system trace of the run (`Scripts/trace-frames.py`).
    var systemFrames: SystemFrames?
    /// Sorts: two seconds with nothing changing after the sorts, as a check of the screen meter
    /// (should be about 0 screen updates while the callbacks go on).
    var quietScreenUpdatesPerSecond: Double?
    var quietCallbacksPerSecond: Double?
    var machine: Machine
    var date: String

    var jsonLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Appends the line to a file (made if needed).
    func append(to path: String) {
        let url = URL(fileURLWithPath: path)
        let data = Data((jsonLine + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

nonisolated enum Report {
    static func read(_ path: String) -> [RunResult] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return text.split(separator: "\n").compactMap { try? decoder.decode(RunResult.self, from: Data($0.utf8)) }
    }

    /// The median of the runs, and their lowest and highest: "120 (118–120)".
    private static func median(_ values: [Double], digits: Int = 0, suffix: String = "") -> String {
        guard !values.isEmpty else { return "—" }
        let sorted = values.sorted()
        let middle = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let format = { (value: Double) in value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic)) }
        let (low, high) = (format(sorted.first!), format(sorted.last!))
        return format(middle) + suffix + (low == high ? "" : " (\(low)–\(high))")
    }

    private static func localDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return String(iso.prefix(10)) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func markdown(_ results: [RunResult]) -> String {
        guard let first = results.first else { return "No results.\n" }
        var lines = ["# Gingham Bench results", "",
                     "\(Self.localDate(first.date)) · \(first.machine.line)", ""]
        let machines = Set(results.map(\.machine.line))
        if machines.count > 1 { lines += ["Note: these runs come from \(machines.count) different setups.", ""] }
        let scenarios = ScenarioID.allCases.map(\.rawValue).filter { id in results.contains { $0.scenario == id } }
        for scenario in scenarios {
            let ofScenario = results.filter { $0.scenario == scenario }
            let id = ScenarioID(rawValue: scenario)
            lines.append("## \(id?.title ?? scenario)")
            lines.append("")
            if id?.isSort == true {
                lines.append("| Engine | Time to sorted order | Frames during the sort | Longest stall | Finder's order | Quiet: screen updates/s · callbacks/s | Runs |")
                lines.append("| --- | --- | --- | --- | --- | --- | --- |")
            } else {
                lines.append("| Engine | Screen updates/s (table) | System frames/s (trace) | Updates applied/s | Data age p50 / p99 | Main thread busy | Longest stall | Callbacks/s | Changes applied/s | CPU | GPU | Window server GPU | GPU, process + window server | Energy | Memory | Order | Runs |")
                lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
            }
            for engine in EngineKind.allCases.map(\.rawValue) {
                let allRuns = ofScenario.filter { $0.engine == engine }
                guard let title = allRuns.first?.engineTitle else { continue }
                // The measured runs; a separate screen pass gives only the screen numbers.
                let screenRuns = allRuns.filter { $0.status == "ok" && $0.numbers?.screenUpdatesPerSecond != nil }
                let traced = allRuns.compactMap(\.systemFrames?.framesShownPerSecond)
                let runs = allRuns.filter { $0.pass == nil }
                let ok = runs.filter { $0.status == "ok" }
                let failed = runs.filter { $0.status != "ok" }
                let failure = failed.first.map { "\($0.status): \($0.note ?? "")" }
                let runCount = "\(runs.count)" + (failed.isEmpty ? "" : " (\(failed.count) \(failure ?? "failed"))")
                let checks = ok.compactMap(\.orderCheck)
                let order = checks.isEmpty ? "—" : checks.allSatisfy { $0 == "ok" } ? "ok" : "WRONG: " + (checks.first { $0 != "ok" } ?? "")
                if id?.isSort == true {
                    let sorts = ok.flatMap { $0.sorts ?? [] }
                    let quietScreen = screenRuns.compactMap(\.quietScreenUpdatesPerSecond) + ok.compactMap(\.quietScreenUpdatesPerSecond)
                    let quietCallbacks = allRuns.compactMap(\.quietCallbacksPerSecond)
                    let quiet = quietScreen.isEmpty ? "—" : "\(median(quietScreen)) · \(median(quietCallbacks))"
                    guard !sorts.isEmpty else {
                        lines.append("| \(title) | \(failure ?? "—") | | | | | \(runs.count) |")
                        continue
                    }
                    lines.append("| \(title) | \(median(sorts.map(\.seconds), digits: 2, suffix: " s")) | \(median(sorts.map { Double($0.framesDuring) })) | \(median(sorts.map(\.longestFrameGapMs), suffix: " ms")) | \(order) | \(quiet) | \(runCount) |")
                } else {
                    let numbers = ok.compactMap(\.numbers)
                    guard !numbers.isEmpty else {
                        // (Only the screen or trace pass ran: their columns.)
                        let screens = screenRuns.compactMap(\.numbers?.screenUpdatesPerSecond)
                        lines.append("| \(title) | \(screens.isEmpty ? failure ?? "—" : median(screens)) | \(traced.isEmpty ? "—" : median(traced)) | | | | | | | | | | | | | | \(runs.count) |")
                        continue
                    }
                    var changes = median(numbers.map(\.changesPerSecond))
                    if let nominal = ok.first?.nominalChangesPerSecond, let lowest = numbers.map(\.changesPerSecond).min(), lowest < nominal * 0.95 {
                        changes += " ⚠︎ \(Int(lowest / nominal * 100))% of the feed"
                    }
                    let ages = "\(median(numbers.compactMap(\.dataAgeP50Ms), suffix: " ms")) / \(median(numbers.compactMap(\.dataAgeP99Ms), suffix: " ms"))"
                    let presented = numbers.compactMap(\.presentedPerSecond)
                    let updates = median(numbers.map(\.updatesAppliedPerSecond)) + (presented.isEmpty ? "" : "; presented \(median(presented))*")
                    let screens = screenRuns.compactMap(\.numbers?.screenUpdatesPerSecond)
                    let shares = screenRuns.compactMap(\.numbers?.screenChangedShareMedian)
                    let screen = screens.isEmpty ? "— (\(ok.first?.screenMeter ?? "no meter"))"
                        : median(screens) + (shares.isEmpty ? "" : ", \(median(shares.map { $0 * 100 }))% changed")
                    lines.append("| \(title) | \(screen) | \(traced.isEmpty ? "—" : median(traced)) | \(updates) | \(ages) | \(median(numbers.map { $0.busyShare * 100 }, suffix: "%")) | \(median(numbers.map(\.longestStallMs), suffix: " ms")) | \(median(numbers.map(\.callbacksPerSecond))) | \(changes) | \(median(numbers.compactMap(\.cpuPercent), suffix: "%")) | \(median(numbers.compactMap(\.gpuMsPerSecond), digits: 1, suffix: " ms/s")) | \(median(numbers.compactMap(\.windowServerGPUMsPerSecond), digits: 1, suffix: " ms/s")) | \(median(numbers.compactMap(\.totalGPUMsPerSecond), digits: 1, suffix: " ms/s")) | \(median(numbers.compactMap(\.energyMilliwatts), suffix: " mW")) | \(median(numbers.compactMap(\.memoryMB), suffix: " MB")) | \(order) | \(runCount) |")
                }
            }
            lines.append("")
        }
        let hot = results.compactMap(\.numbers?.thermalState).filter { $0 != "nominal" && $0 != "fair" }
        if !hot.isEmpty { lines += ["⚠︎ \(hot.count) runs reached the thermal state \(Set(hot).sorted().joined(separator: ", ")): compare those with care.", ""] }
        lines += ["Each value: the median of the runs (lowest–highest). Screen updates/s (table): window frames ScreenCaptureKit delivered",
                  "whose changed pixels reached the table's body (not the top bar or the header), what the eye sees; \"% changed\": the",
                  "median share of the table's body that changed in one. System frames/s (trace): the window's frames the system showed",
                  "(an Instruments trace of one more run: the process's Core Animation commits that reached the display, plus its GPU",
                  "frames the window server composited); commits include the top bar's. Updates applied/s: display-link callbacks that applied new data",
                  "(at most the screen's refresh rate). *Presented: frames that reached the screen; only Gingham can report it",
                  "(`GHTableView.framePresented`), no other engine has a way to tell. Data age: from the time a change was due",
                  "(Binance: its arrival) to the start of the callback that applied it (that frame's apply, layout, commit and",
                  "presentation not included).",
                  "Main thread busy: share of time its run loop wasn't waiting. Longest stall: the longest time between two callbacks.",
                  "Callbacks/s: display-link callbacks the main thread got to. CPU: all threads, 100% = one core. GPU: the process's GPU",
                  "time and the window server's above its rate with the table shown and nothing changing (it composites all apps;",
                  "AppKit's drawing is composited there, Gingham's drawn in the process), and their sum, ms a second. Energy: as the kernel accounts it to the process",
                  "(mostly the CPU's). The window server's CPU time isn't measured. Order: the order shown,",
                  "checked against the store after the run. See the README for how each engine is set up.", ""]
        return lines.joined(separator: "\n")
    }
}
