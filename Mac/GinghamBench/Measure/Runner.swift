//
//  Runner.swift
//  Gingham Bench
//
//  Measuring from the command line. The app started with `--scenario` runs every scenario ×
//  engine × run asked for, each in a new process of itself (`--child`): no engine runs after
//  another in the same process (no warm caches, no leftovers, a hang can't stop the rest), and a
//  table that never shows its rows is reported as such. A child:
//
//  1. makes the scenario's rows (not measured), then the engine's table, in the window;
//  2. waits until the table has its rows: at most `--load-timeout` seconds (else "timeout");
//  3. starts the feed, waits `--warmup` seconds, measures `--seconds` seconds;
//  4. appends a JSON line to `--output` and quits.
//
//  A watchdog thread writes the result itself when the main thread doesn't come back.
//

import AppKit

/// Writes a result when the main thread can't: no rows in time, or stuck after the window.
nonisolated final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let data: MeterData
    private var template: RunResult
    private let output: String?
    private var deadlineNote = "didn't finish in time"
    private var loadDeadline: CFTimeInterval
    private let loadTimeout: Double
    private var window: (start: CFTimeInterval, end: CFTimeInterval)?
    private var overallDeadline: CFTimeInterval?
    private var isDone = false

    init(data: MeterData, template: RunResult, output: String?, loadTimeout: Double) {
        self.data = data
        self.template = template
        self.output = output
        self.loadTimeout = loadTimeout
        loadDeadline = .infinity
    }

    func loading(from start: CFTimeInterval) { lock.withLock { loadDeadline = start + loadTimeout } }
    func loaded(window: (start: CFTimeInterval, end: CFTimeInterval)?, deadline: CFTimeInterval? = nil) {
        lock.withLock {
            loadDeadline = .infinity
            self.window = window
            overallDeadline = deadline
        }
    }
    /// A deadline for the next step (nil: none), with what to report if it passes, and the
    /// result so far.
    func step(deadline: CFTimeInterval?, note: String, partial: RunResult? = nil) {
        lock.withLock {
            overallDeadline = deadline
            deadlineNote = note
            if let partial { template = partial }
        }
    }

    /// The result so far (written if the run crashes or hangs).
    func update(template: RunResult) { lock.withLock { self.template = template } }

    /// The process crashed (`CrashCatcher`, on its thread): the result so far as "crashed".
    func crashed(_ description: String) {
        let result: RunResult? = lock.withLock {
            guard !isDone else { return nil }
            isDone = true
            var result = template
            result.status = "crashed"
            result.note = description
            return result
        }
        guard let result else { return }
        if let output { result.append(to: output) }
        print("RESULT \(result.jsonLine)")
        fflush(stdout)
    }

    /// The main thread wrote the result: nothing to do.
    func done() { lock.withLock { isDone = true } }

    func start() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CACurrentMediaTime()
                let (done, loadDeadline, window, deadline, note, partial) = lock.withLock {
                    (isDone, self.loadDeadline, self.window, overallDeadline, deadlineNote, template)
                }
                if done { return }
                var result = partial
                if now > loadDeadline {
                    result.status = "timeout"
                    result.note = "no rows shown within \(Int(loadTimeout)) s"
                } else if let window, now > window.end + 15 {
                    result.status = "stuck"
                    result.note = "the main thread didn't come back within 15 s after the measured window"
                    result.numbers = data.summary(from: window.start, to: window.end)
                } else if let deadline, now > deadline {
                    result.status = "timeout"
                    result.note = note
                } else {
                    continue
                }
                lock.withLock { isDone = true }
                if let output { result.append(to: output) }
                print("RESULT \(result.jsonLine)")
                fflush(stdout)
                exit(3)
            }
        }
        thread.name = "Watchdog"
        thread.start()
    }
}

/// One scenario, engine and run, in this process.
final class ChildRun {
    private let options: Options
    private let scenarioID: ScenarioID
    private let kind: EngineKind
    private let ui: BenchWindow
    private let meter = Meter()
    private var screenMeter: ScreenMeter?
    private var scenario: Scenario?
    private var engine: Engine?
    private var watchdog: Watchdog?
    private var template: RunResult?
    private var loadStart: CFTimeInterval = 0
    private var loadedAt: CFTimeInterval?
    private var window: (start: CFTimeInterval, end: CFTimeInterval)?
    /// The table shown, the feed not started yet: the window server's GPU baseline.
    private var baseline: ClosedRange<CFTimeInterval>?
    private var feedStarted = false
    private var finished = false
    /// The window ended: the feed stops and the order shown is checked.
    private var verifying = false
    private var activity: NSObjectProtocol?
    private var lastBarUpdate: CFTimeInterval = 0
    private var lastLockCheck: CFTimeInterval = 0
    private var lagFrames = 0, checkedFrames = 0, differingPlaces = 0
    private var observers: [NSObjectProtocol] = []

    init(options: Options, ui: BenchWindow) {
        self.options = options
        scenarioID = options.scenarios[0]
        kind = options.engines[0]
        self.ui = ui
    }

    func start() {
        // No App Nap or timer coalescing while measuring, for every engine alike.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measuring")
        ui.bar.engine.stringValue = kind.title
        ui.bar.detail.stringValue = "\(scenarioID.title) · run \(options.run) · \(kind.setup)"
        ui.bar.subtitle.stringValue = "Preparing the rows…"
        ui.show()
        let scenario = scenarioID.make(options: options)
        self.scenario = scenario
        // From here on a crash or a hang is reported as this run's result.
        let watchdog = Watchdog(data: meter.data, template: makeBasicResult(status: "ok", note: nil), output: options.output,
                                loadTimeout: options.loadTimeout)
        self.watchdog = watchdog
        watchdog.start()
        CrashCatcher.report = { [watchdog] description in watchdog.crashed(description) }
        Task {
            do {
                try await scenario.prepare()
            } catch {
                finish(status: "error", note: error.localizedDescription)
                return
            }
            begin(scenario)
        }
    }

    private func makeTemplate(_ scenario: Scenario) -> RunResult {
        RunResult(scenario: scenarioID.rawValue, engine: kind.rawValue, engineTitle: kind.title, run: options.run, pass: options.pass,
                  status: "ok", note: nil, rows: scenario.source.rowCount, warmup: options.warmup(for: scenarioID), loadSeconds: nil,
                  nominalChangesPerSecond: scenario.nominalChangesPerSecond, numbers: nil,
                  sorts: nil, orderCheck: nil, machine: Machine.current(screen: ui.window.screen),
                  date: ISO8601DateFormatter().string(from: Date()))
    }

    private func begin(_ scenario: Scenario) {
        let template = makeTemplate(scenario)
        self.template = template
        watchdog?.update(template: template)
        guard let watchdog else { return }
        ui.bar.subtitle.stringValue = scenario.subtitle
        let engine = kind.make()
        self.engine = engine
        engine.framePresented = { [meter] in meter.presented() }
        ui.show(engine.view)
        loadStart = CACurrentMediaTime()
        watchdog.loading(from: loadStart)
        scenario.attach(engine)
        engine.load(scenario.source, sort: scenario.sort)
        meter.onFrame = { [weak self] now in self?.frame(now) }
        meter.start(on: ui.container)
        watchInterruptions()
        if options.screenMeter {
            let screenMeter = ScreenMeter(data: meter.data)
            self.screenMeter = screenMeter
            let (window, body, rate) = (ui.window, ui.tableBody, meter.refreshRate)
            Task { await screenMeter.start(window: window, tableBody: body, refreshRate: rate) }
        }
        if scenarioID.isSort, let sortScenario = scenario as? SortScenario {
            Task { await runSorts(sortScenario, engine: engine) }
        }
        // A test of the crash reporting: a Swift runtime trap two seconds in.
        if ProcessInfo.processInfo.environment["GINGHAM_BENCH_CRASH_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let empty: [Int] = []
                print(empty[Int(CACurrentMediaTime()) % 3 + 1])
            }
        }
    }

    /// A covered window isn't drawn by every engine alike (Gingham stops drawing what isn't
    /// seen), and a locked screen or a sleeping display stops the frames: such runs don't count.
    private func watchInterruptions() {
        let data = meter.data
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: ui.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkVisible(CACurrentMediaTime()) }
        })
        let distributed = DistributedNotificationCenter.default()
        for (name, what) in [("com.apple.screenIsLocked", "the screen locked"), ("com.apple.screensaver.didstart", "the screen saver started")] {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                data.interrupted(what, at: CACurrentMediaTime())
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, what) in [(NSWorkspace.screensDidSleepNotification, "the display slept"), (NSWorkspace.willSleepNotification, "the Mac slept"),
                             (NSWorkspace.sessionDidResignActiveNotification, "the user session switched")] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in data.interrupted(what, at: CACurrentMediaTime()) })
        }
    }

    private func checkVisible(_ now: CFTimeInterval) {
        if !ui.window.occlusionState.contains(.visible) { meter.data.interrupted("the window was covered", at: now) }
        if now - lastLockCheck >= 1 {
            lastLockCheck = now
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
                meter.data.interrupted("the screen was locked", at: now)
            }
        }
    }

    private func frame(_ now: CFTimeInterval) {
        guard !finished, let scenario, let engine else { return }
        // The trace pass keeps the top bar still until the window ends, so that every Core
        // Animation commit of the process that reaches the display is the table's.
        let barFrozen = options.pass == "trace" && !(window.map { now >= $0.end } ?? false) && loadedAt != nil
        if now - lastBarUpdate >= 0.25, !barFrozen {
            lastBarUpdate = now
            let second = meter.data.lastSecond(now: now)
            ui.bar.update(updates: second.updates, busy: second.busy, callbacks: second.callbacks, age: second.age,
                          screen: screenMeter?.state == "running" ? second.screen : nil, refreshRate: meter.refreshRate)
        }
        checkVisible(now)
        guard !scenarioID.isSort else { return }
        guard let loadedAt else {
            if engine.showsRows {
                self.loadedAt = now
                // Two seconds with the table shown and nothing changing (from a quarter second
                // after it showed): the window server's GPU rate then is its baseline.
                baseline = (now + 0.25)...(now + 2.25)
                let start = now + 2.25 + options.warmup(for: scenarioID)
                window = (start, start + options.seconds)
                watchdog?.loaded(window: window)
            }
            return
        }
        guard feedStarted else {
            if now >= loadedAt + 2.25 {
                feedStarted = true
                scenario.start()
            }
            return
        }
        // (Visible-truth check: does the engine show the top rows the store has, one frame after
        // the last batch? Counted before the next batch is applied.)
        if SyntheticScenario.checksVisibleTruth, let synthetic = scenario as? SyntheticScenario, !synthetic.topRows.isEmpty, !engine.isSorting {
            var differing = 0
            for (index, row) in synthetic.topRows.enumerated() where engine.sourceRow(atDisplayIndex: index) != row { differing += 1 }
            if differing > 0 { lagFrames += 1 }
            differingPlaces += differing
            checkedFrames += 1
        }
        // Everything that came since the last callback, applied at once.
        meter.data.applied(scenario.applyPending(to: engine, at: now), at: now)
        if let window, now >= window.end, !verifying { finishMeasured(window) }
    }

    private func finishMeasured(_ window: (start: CFTimeInterval, end: CFTimeInterval)) {
        guard var result = template, !finished, let scenario, let engine else { return }
        verifying = true
        result.loadSeconds = loadedAt.map { $0 - loadStart }
        if checkedFrames > 0 { FileHandle.standardError.write(Data("visible truth: the engine's top rows differed from the store's at \(lagFrames) of \(checkedFrames) callbacks, \(String(format: "%.1f", Double(differingPlaces) / Double(checkedFrames))) of the 30 places on average\n".utf8)) }
        let epochOffset = Date().timeIntervalSince1970 - CACurrentMediaTime()
        result.windowStartEpoch = window.start + epochOffset
        result.windowEndEpoch = window.end + epochOffset
        result.pid = ProcessInfo.processInfo.processIdentifier
        let screenRunning = screenMeter?.state == "running"
        result.numbers = meter.data.summary(from: window.start, to: window.end, baseline: baseline, screen: screenRunning)
        result.screenMeter = screenMeter?.state ?? "off (--no-screen-meter)"
        let interruptions = meter.data.interruptions(in: (loadedAt ?? window.start)...window.end)
        if let first = interruptions.first {
            result.status = "invalid"
            result.note = "\(first) during the run"
        }
        // The feed stops; what it made is applied by the next callbacks; then the order shown is
        // checked against the store.
        scenario.stop()
        watchdog?.step(deadline: CACurrentMediaTime() + 60, note: "the order check after the run didn't finish within 60 s", partial: result)
        Task {
            await frames(3)
            let deadline = CACurrentMediaTime() + 10
            while engine.isSorting, CACurrentMediaTime() < deadline { await sleep(5) }
            await frames(2)
            result.rows = scenario.source.rowCount
            result.orderCheck = engine.isSorting ? "still sorting 10 s after the feed stopped"
                : Self.checkOrder(engine, source: scenario.source, sort: scenario.sort) ?? Self.checkShownText(engine, source: scenario.source) ?? "ok"
            write(result)
        }
    }

    /// Waits for some display-link callbacks.
    private func frames(_ count: Int) async {
        let start = CACurrentMediaTime()
        while meter.data.frames(in: start...CACurrentMediaTime()).count < count, CACurrentMediaTime() - start < 5 { await sleep(2) }
    }

    /// The text of the cells in view, for engines that can tell (the view-based AppKit tables),
    /// against what the store says now: an in-place update that went stale fails here. Nil: right.
    static func checkShownText(_ engine: Engine, source: BenchSource) -> String? {
        for shown in engine.shownTexts() {
            guard let row = engine.sourceRow(atDisplayIndex: shown.display), row < source.rowCount else { continue }
            let expected = BenchFormat.text(source, row: row, column: shown.column)
            if shown.text != expected {
                return "stale text at place \(shown.display), column \(source.columns[shown.column].id): \"\(shown.text)\", the store \"\(expected)\""
            }
        }
        return nil
    }

    /// Whether the engine shows every row of the store once, in the scenario's order (ties in
    /// any order; unsorted: the store's order): nil, or what's wrong.
    static func checkOrder(_ engine: Engine, source: BenchSource, sort: [SortSpec], allowingDesyncs: Bool = false) -> String? {
        if engine.desyncCount > 0, !allowingDesyncs { return "the engine lost step with the store's changes \(engine.desyncCount) times (rows rebuilt)" }
        let count = source.rowCount
        guard engine.displayedRowCount == count else { return "shows \(engine.displayedRowCount) rows of \(count)" }
        var seen = [Bool](repeating: false, count: count)
        let columns = sort.isEmpty ? [] : AppSort.columns(of: source, sort: sort)
        var previous = -1
        for index in 0..<count {
            guard let row = engine.sourceRow(atDisplayIndex: index), row >= 0, row < count else { return "no row at place \(index)" }
            if seen[row] { return "row \(row) shown twice" }
            seen[row] = true
            if sort.isEmpty {
                if row != index { return "row \(row) at place \(index)" }
            } else if previous >= 0, AppSortWork.compare(previous, row, columns) == .orderedDescending {
                return "out of order at place \(index)"
            }
            previous = row
        }
        return nil
    }

    private func makeBasicResult(status: String, note: String?) -> RunResult {
        RunResult(scenario: scenarioID.rawValue, engine: kind.rawValue, engineTitle: kind.title, run: options.run, pass: options.pass,
                  status: status, note: note, rows: 0, warmup: 0, loadSeconds: nil, nominalChangesPerSecond: nil,
                  numbers: nil, sorts: nil, orderCheck: nil, machine: Machine.current(screen: ui.window.screen),
                  date: ISO8601DateFormatter().string(from: Date()))
    }

    private func finish(status: String, note: String?) {
        var result = template ?? makeBasicResult(status: status, note: note)
        result.status = status
        result.note = note
        write(result)
    }

    private func write(_ result: RunResult) {
        guard !finished else { return }
        finished = true
        watchdog?.done()
        screenMeter?.stop()
        scenario?.stop()
        meter.stop()
        if let output = options.output { result.append(to: output) }
        print("RESULT \(result.jsonLine)")
        fflush(stdout)
        exit(result.status == "ok" ? 0 : 2)
    }

    // MARK: The sort scenario

    private func sleep(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    /// Waits until frames come steadily: 20 in a row, none more than 50 ms after the one before.
    private func settle(timeout: Double) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            await sleep(50)
            let now = CACurrentMediaTime()
            let recent = Array(meter.data.frames(in: (now - 2)...now).suffix(21))
            if recent.count == 21, zip(recent.dropFirst(), recent).allSatisfy({ $0 - $1 < 0.05 }), let last = recent.last, now - last < 0.05 {
                return true
            }
        }
        return false
    }

    private func runSorts(_ scenario: SortScenario, engine: Engine) async {
        while !engine.showsRows {
            await sleep(10)
        }
        loadedAt = CACurrentMediaTime()
        watchdog?.loaded(window: nil, deadline: CACurrentMediaTime() + 90)
        guard await settle(timeout: 60) else {
            finish(status: "timeout", note: "frames didn't come steadily within 60 s of loading")
            return
        }
        var sorts: [SortNumbers] = []
        // Each step may take at most a minute (SwiftUI's Table may take far longer to show a
        // million rows in another order); past it the watchdog reports the sorts done so far.
        let stepTimeout = 60.0
        var partial = template
        partial?.loadSeconds = loadedAt.map { $0 - loadStart }
        for round in 1...3 {
            ui.bar.subtitle.stringValue = "\(scenario.subtitle) · sort \(round) of 3"
            watchdog?.step(deadline: CACurrentMediaTime() + stepTimeout, note: "unsorting before sort \(round) didn't reach the screen within \(Int(stepTimeout)) s", partial: partial)
            engine.sort(by: [])
            while engine.isSorting { await sleep(5) }
            _ = await settle(timeout: 30)
            watchdog?.step(deadline: CACurrentMediaTime() + stepTimeout, note: "sort \(round) didn't reach the screen within \(Int(stepTimeout)) s", partial: partial)
            let start = CACurrentMediaTime()
            engine.sort(by: [scenario.sortSpec])
            while engine.isSorting { await sleep(1) }
            let ready = CACurrentMediaTime()
            while (meter.data.lastFrame ?? 0) <= ready { await sleep(1) }
            let frames = meter.data.frames(in: start...CACurrentMediaTime())
            guard let shown = frames.first(where: { $0 > ready }) else { continue }
            var gap = 0.0, previous = start
            for time in frames where time <= shown {
                gap = max(gap, time - previous)
                previous = time
            }
            sorts.append(SortNumbers(seconds: shown - start, framesDuring: frames.filter { $0 < shown }.count, longestFrameGapMs: gap * 1000))
            partial?.sorts = sorts
            await sleep(300)
        }
        watchdog?.step(deadline: CACurrentMediaTime() + 120, note: "checking the order took over 2 minutes", partial: partial)
        // A check of the screen meter: two seconds with nothing changing (callbacks go on).
        let quietStart = CACurrentMediaTime()
        await sleep(2000)
        guard var result = template else { return }
        if screenMeter?.state == "running" {
            let quiet = meter.data.summary(from: quietStart, to: CACurrentMediaTime(), screen: true)
            result.quietScreenUpdatesPerSecond = quiet.screenUpdatesPerSecond
            result.quietCallbacksPerSecond = quiet.callbacksPerSecond
        }
        result.screenMeter = screenMeter?.state ?? "off (--no-screen-meter)"
        result.loadSeconds = loadedAt.map { $0 - loadStart }
        result.sorts = sorts
        result.orderCheck = isInFinderOrder(engine, scenario: scenario) ? "ok" : "not in Finder's order"
        let interruptions = meter.data.interruptions(in: (loadedAt ?? 0)...CACurrentMediaTime())
        if let first = interruptions.first {
            result.status = "invalid"
            result.note = "\(first) during the run"
        }
        write(result)
    }

    /// Every row shown, in Finder's order of the sorted column (ties in any order).
    private func isInFinderOrder(_ engine: Engine, scenario: SortScenario) -> Bool {
        let source = scenario.source
        var previous: String?
        for index in 0..<source.rowCount {
            guard let row = engine.sourceRow(atDisplayIndex: index), row < source.rowCount else { return false }
            let text = source.text(row, scenario.sortColumn)
            if let previous, previous != text, previous.localizedStandardCompare(text) == .orderedDescending { return false }
            previous = text
        }
        return true
    }
}

/// Runs the children one after another and writes the Markdown table (no window of its own).
enum Orchestrator {
    static func run(_ options: Options) -> Int32 {
        let output = options.output ?? "results/\(Self.stamp()).jsonl"
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var failures = 0
        // The runs: engines take turns within each round, so a slow drift of the machine (heat,
        // background work) spreads over all of them. With `--separate-screen-pass` the measured
        // runs go without the screen meter and one more round of every scenario and engine runs
        // with it (its numbers give the screen updates column).
        var jobs: [(scenario: ScenarioID, run: Int, engine: EngineKind, screen: Bool, pass: String?)] = []
        for scenario in options.scenarios where !options.onlyTracePass {
            for run in 1...options.runs {
                for engine in options.engines {
                    jobs.append((scenario, run, engine, options.screenMeter && !options.separateScreenPass, nil))
                }
            }
        }
        if options.separateScreenPass, options.screenMeter, !options.onlyTracePass {
            for scenario in options.scenarios {
                for engine in options.engines { jobs.append((scenario, 1, engine, true, "screen")) }
            }
        }
        // `--trace-pass`: one more run of every engine on the key live scenarios, recorded by
        // Instruments (Animation Hitches), whose trace gives the system's count of the window's
        // frames (`TraceFrames`), next to the screen meter of the same run.
        // One trace on the disk at a time, in the caches: recorded, read, deleted.
        let traceDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gingham-bench-traces").path
        if options.tracePass || options.onlyTracePass {
            let key = options.scenarios.filter { $0 == .liveTrades || $0 == .orderBook }
            for scenario in key.isEmpty ? options.scenarios.filter({ !$0.isSort }) : key {
                for engine in options.engines { jobs.append((scenario, 1, engine, options.screenMeter, "trace")) }
            }
            try? FileManager.default.createDirectory(atPath: traceDirectory, withIntermediateDirectories: true)
        }
        let total = jobs.count
        var done = 0
        print("Gingham Bench: \(total) runs → \(output)")
        for (scenario, run, engine, screen, pass) in jobs {
                    do {
                    done += 1
                    print("[\(done)/\(total)] \(scenario.rawValue) · \(engine.title) · \(pass.map { "\($0) pass" } ?? "run \(run)")", terminator: "")
                    fflush(stdout)
                    let process = Process()
                    var childArguments = options.childArguments(scenario: scenario, engine: engine, run: run, output: output, screenMeter: screen, pass: pass)
                    let tracePath = "\(traceDirectory)/\(scenario.rawValue)-\(engine.rawValue).trace"
                    if pass == "trace" {
                        // A short run, so that the trace stays under 10 seconds: 2 s of warm-up
                        // (Instruments attaches meanwhile) and 4 s measured.
                        childArguments += ["--warmup", "2", "--seconds", "4"]
                        // Room for a trace: stop under 40 GB free.
                        let free = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                        if free < 40_000_000_000 {
                            print(" — stopped: \(free / 1_000_000_000) GB free, the trace pass needs 40")
                            break
                        }
                    }
                    // One bench window at a time: no other copy of the app may be running.
                    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                    if !others.isEmpty {
                        print(" — another copy of the app is running (pid \(others.map(\.processIdentifier))); it is asked to quit first", terminator: "")
                        others.forEach { $0.terminate() }
                        Thread.sleep(forTimeInterval: 2)
                        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
                    }
                    process.executableURL = executable
                    process.arguments = childArguments
                    // The child's output in a file (a pipe could fill up and block it).
                    let log = FileManager.default.temporaryDirectory.appendingPathComponent("gingham-bench-child-\(UUID().uuidString).txt")
                    FileManager.default.createFile(atPath: log.path, contents: nil)
                    let handle = try? FileHandle(forWritingTo: log)
                    process.standardOutput = handle
                    process.standardError = handle
                    defer { try? FileManager.default.removeItem(at: log) }
                    do { try process.run() } catch {
                        print(" — couldn't start: \(error.localizedDescription)")
                        failures += 1
                        continue
                    }
                    // The trace pass: Instruments attaches to this very process (launched by xctrace,
                    // a path inside an app bundle goes through Launch Services, which may start
                    // another copy of the app with the same bundle id).
                    var recorder: Process?
                    if pass == "trace" {
                        try? FileManager.default.removeItem(atPath: tracePath)
                        let xctrace = Process()
                        xctrace.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                        // Only the instruments with the tables read (`TraceFrames`): the whole Animation
                        // Hitches template (with its time profiler, thread states and hang detection)
                        // slowed the traced run to 60 frames a second.
                        xctrace.arguments = ["xctrace", "record", "--instrument", "Hitches", "--instrument", "Display", "--no-prompt",
                                             "--output", tracePath, "--time-limit", "10s", "--attach", String(process.processIdentifier)]
                        xctrace.standardOutput = FileHandle.nullDevice
                        xctrace.standardError = FileHandle.nullDevice
                        try? xctrace.run()
                        recorder = xctrace
                    }
                    defer {
                        if let recorder {
                            // (It ends when the process it records exits, and saves the trace.)
                            let saved = Date().addingTimeInterval(120)
                            while recorder.isRunning, Date() < saved { Thread.sleep(forTimeInterval: 0.2) }
                            if recorder.isRunning { recorder.interrupt() }
                        }
                    }
                    // A child that outlives every timeout of its own is stopped.
                    let limit = Date().addingTimeInterval(options.loadTimeout + options.warmup(for: scenario) + options.seconds + 660)
                    while process.isRunning, Date() < limit { Thread.sleep(forTimeInterval: 0.2) }
                    if process.isRunning {
                        process.terminate()
                        print(" — killed after the time limit")
                        failures += 1
                        continue
                    }
                    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    let line = text.split(separator: "\n").last { $0.hasPrefix("RESULT ") }
                    if let line {
                        print(" — " + summary(of: String(line.dropFirst(7))))
                        if pass == "trace", let recorder {
                            let saved = Date().addingTimeInterval(120)
                            while recorder.isRunning, Date() < saved { Thread.sleep(forTimeInterval: 0.2) }
                            addSystemFrames(output: output, scenario: scenario, engine: engine, trace: tracePath)
                            // Its numbers are saved: the trace goes (`--keep-traces` keeps it).
                            if !options.keepTraces { try? FileManager.default.removeItem(atPath: tracePath) }
                        }
                    } else {
                        // Ended without a result (a crash macOS caught first, a kill): reported as a failed run.
                        let how = process.terminationReason == .uncaughtSignal ? "signal \(process.terminationStatus)" : "exit status \(process.terminationStatus)"
                        let result = RunResult(scenario: scenario.rawValue, engine: engine.rawValue, engineTitle: engine.title, run: run,
                                               pass: pass, status: "crashed", note: "the app ended without a result (\(how)); see ~/Library/Logs/DiagnosticReports",
                                               rows: 0, warmup: options.warmup(for: scenario), loadSeconds: nil, nominalChangesPerSecond: nil,
                                               numbers: nil, sorts: nil, orderCheck: nil, machine: Machine.current(screen: NSScreen.main),
                                               date: ISO8601DateFormatter().string(from: Date()))
                        result.append(to: output)
                        print(" — crashed: \(result.note ?? "")")
                    }
                    if process.terminationStatus != 0 { failures += 1 }
                    Thread.sleep(forTimeInterval: 1)
                    }
        }
        let markdownPath = (output as NSString).deletingPathExtension + ".md"
        let markdown = Report.markdown(Report.read(output))
        try? markdown.write(toFile: markdownPath, atomically: true, encoding: .utf8)
        print("\n" + markdown)
        print("Wrote \(output) and \(markdownPath)")
        return failures == 0 ? 0 : 1
    }

    /// The system's frames of a trace-pass run, from its trace, written into its result line.
    private static func addSystemFrames(output: String, scenario: ScenarioID, engine: EngineKind, trace: String) {
        var results = Report.read(output)
        guard let index = results.lastIndex(where: { $0.scenario == scenario.rawValue && $0.engine == engine.rawValue && $0.pass == "trace" }),
              let pid = results[index].pid, let start = results[index].windowStartEpoch, let end = results[index].windowEndEpoch else {
            print("   (no window or process to find in the trace)")
            return
        }
        guard let frames = TraceFrames.measure(trace: trace, pid: pid, from: start, to: end) else {
            print("   (the trace couldn't be read: \(trace))")
            return
        }
        results[index].systemFrames = frames
        let text = results.map(\.jsonLine).joined(separator: "\n") + "\n"
        try? text.write(toFile: output, atomically: true, encoding: .utf8)
        let numbers = results[index].numbers
        func shown(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        print("   system: \(shown(frames.framesShownPerSecond)) frames shown/s (commits \(shown(frames.clientUpdatesPerSecond)), GPU frames \(shown(frames.gpuFramesPerSecond)), shown \(shown(frames.gpuFramesShownPerSecond)); window covered \(shown((frames.windowCovered ?? 0) * 100))%)"
              + " · screen meter \(shown(numbers?.screenUpdatesPerSecond)) · visible changes \(shown(numbers?.visibleDataChangesPerSecond))"
              + " · presented \(shown(numbers?.presentedPerSecond)) · applied \(shown(numbers?.updatesAppliedPerSecond))")
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func summary(of json: String) -> String {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let result = try? decoder.decode(RunResult.self, from: Data(json.utf8)) else { return json }
        if result.status != "ok", result.numbers == nil, result.sorts == nil { return "\(result.status): \(result.note ?? "")" }
        if result.status != "ok" { return "\(result.status): \(result.note ?? "") — " + summaryNumbers(result) }
        return summaryNumbers(result)
    }

    private static func summaryNumbers(_ result: RunResult) -> String {
        if let sorts = result.sorts {
            return sorts.map { String(format: "%.2f s (%d frames, stall %.0f ms)", $0.seconds, $0.framesDuring, $0.longestFrameGapMs) }
                .joined(separator: ", ") + (result.orderCheck.map { $0 == "ok" ? "" : ", ORDER: \($0)" } ?? "")
        }
        guard let numbers = result.numbers else { return result.status }
        let screen = numbers.screenUpdatesPerSecond.map { String(format: "%.0f screen updates/s, ", $0) } ?? "no screen meter (\(result.screenMeter ?? "?")), "
        return screen + String(format: "%.0f updates applied/s, data age %.0f/%.0f ms, main thread %.0f%% busy, stall %.0f ms, %.0f callbacks/s, %.0f changes/s, CPU %.0f%%, GPU %.1f ms/s (window server %.1f more than idle)",
                      numbers.updatesAppliedPerSecond, numbers.dataAgeP50Ms ?? .nan, numbers.dataAgeP99Ms ?? .nan, numbers.busyShare * 100,
                      numbers.longestStallMs, numbers.callbacksPerSecond, numbers.changesPerSecond, numbers.cpuPercent ?? 0, numbers.gpuMsPerSecond ?? 0,
                      numbers.windowServerGPUMsPerSecond ?? 0)
            + (result.orderCheck.map { $0 == "ok" ? "" : ", ORDER: \($0)" } ?? "")
    }
}
