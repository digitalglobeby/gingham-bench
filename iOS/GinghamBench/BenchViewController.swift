import OSLog
import UIKit

// The bench's screen: the engine, rows and changes a second in menus at the
// top, the frames a second and the main thread's load live in the title,
// and Test (this engine, once) and Run All (every engine, `-runs` times).
//
// One display link at the screen's full rate drives everything, in order,
// every frame: the frame meter, the changes due since the last frame (the
// rate times the time passed, so every engine gets the same changes a
// second however many frames it makes), then the scroll position.
//
// Each engine, for each run: made anew on rows made anew (the same seed, the
// same sequence of changes), shown for `settle` seconds, scrolled down and up
// for `warmUp` seconds without measuring (cells, caches and text made once),
// then each test (ScrollProfile.swift) measured in turn, half a second apart.
// Positions are computed from the time of the frame being made, so a dropped
// frame leaves the content further along, as under a finger. The values keep
// changing all along; the engine's view ignores touches meanwhile.
//
// Each measured test is also an os_signpost interval ("Scroll test", in the
// Points of Interest category), so a trace (Instruments' Animation Hitches)
// can tell the tests apart.

@MainActor
final class BenchViewController: UIViewController {
    private let data = BenchData()
    private let meter = FrameMeter()
    private var options = BenchOptions.fromLaunchArguments()
    private var engine: BenchEngine?
    private var engineKind = BenchEngineKind.gingham
    private let container = UIView()
    private let liveLabel = UILabel()
    private let resultLabel = UILabel()
    private var link: CADisplayLink?
    private var liveTimer: Timer?
    private var lastTick: CFTimeInterval?
    private var pendingChanges = 0.0
    /// The shown engine's row height (measured after it settles).
    private var rowHeight = BenchLayout.rowHeight
    private let signposter = OSSignposter(subsystem: "by.digitalglobe.gingham-bench", category: .pointsOfInterest)

    /// A scroll in progress: the warm-up (`profile` nil, not measured) or a test.
    private struct Motion {
        var profile: ScrollProfile?
        var duration: TimeInterval
        /// The rows' height over 24 points (speeds are for 24-point rows).
        var scale: CGFloat
        var start: CFTimeInterval?
        var changesMade = 0
        var changesOnScreen = 0
        var updateCalls = 0
        var updateSeconds: CFTimeInterval = 0
        var updateMax: CFTimeInterval = 0
        var deepest: CGFloat = 0
        var cpuStart: TimeInterval = 0
        var wallStart: CFTimeInterval = 0
        var thermalStart = ProcessInfo.ThermalState.nominal
        var thermalWorst = ProcessInfo.ThermalState.nominal
        var visibleDataRows = 0
        var signpost: OSSignpostIntervalState?
    }
    private var motion: Motion?

    /// The engine being tested: its run, the steps left (nil: the warm-up).
    private struct Session {
        var kind: BenchEngineKind
        var run: Int
        var steps: [ScrollProfile?]
        var restFPS = 0
    }
    private var session: Session?

    /// The engines still to test, and the results so far.
    private var plan: [(kind: BenchEngineKind, run: Int)] = []
    private var planEngines: [BenchEngineKind] = []
    private var planRuns = 1
    private var planResults: [BenchRunResult] = []
    private var planStart = Date()
    private var isRunningPlan = false
    private var stepTask: Task<Void, Never>?

    private static let rowChoices = [10_000, 100_000, 1_000_000]
    private static let rateChoices = [0, 100, 1_000, 10_000]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        engineKind = options.engines.first ?? .gingham
        liveLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        liveLabel.text = "– fps"
        navigationItem.titleView = liveLabel
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        resultLabel.textColor = .secondaryLabel
        resultLabel.numberOfLines = traitCollection.userInterfaceIdiom == .pad ? 3 : 2
        resultLabel.adjustsFontSizeToFitWidth = true
        resultLabel.minimumScaleFactor = 0.7
        resultLabel.text = "Test: \(options.profiles.map(\.title).joined(separator: ", ")), \(Int(options.duration)) s each, values changing; Run All: every engine \(options.runs)×."
        container.accessibilityIdentifier = "benchEngine"
        // Under the UI tests, the engines are hidden from accessibility: XCUITest
        // would otherwise snapshot UITableView's 100,000 rows (longer than it
        // waits), and accessibility work would run as cells scroll, unlike for
        // a user without VoiceOver. The same for every engine.
        if UserDefaults.standard.bool(forKey: "uiTest") { container.accessibilityElementsHidden = true }
        for subview in [resultLabel, container] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            resultLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            resultLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            resultLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 4),
            // Inside the safe area at the sides (an iPhone's camera housing in
            // landscape), so every engine has the same width for its columns.
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateMenus()

        data.make(count: options.rows)
        showEngine(engineKind)
        meter.start()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        // The screen's full rate (120 on ProMotion; iPhones also need
        // CADisableMinimumFrameDurationOnPhone in the Info.plist).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveTick() }
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let device = BenchDevice.current(screen: view.window?.windowScene?.screen)
        benchLog("BENCH_DEVICE " + jsonLine(device))
        benchLog("BENCH_BUILD " + jsonLine(BenchBuild.current))
        benchLog("Gingham \(BenchBuild.current.gingham); display: up to \(device.maximumFramesPerSecond) frames a second"
                 + (device.lowPowerMode ? "; Low Power Mode is on (frames capped)" : "")
                 + (device.hardwareKeyboard ? "; a hardware keyboard is attached" : ""))
        if options.autoTest, !isRunningPlan, planResults.isEmpty {
            startPlan(engines: options.engines, runs: options.runs)
        }
    }

    // MARK: Menus

    private func updateMenus() {
        let enabled = !isRunningPlan
        let engineItem = UIBarButtonItem(title: engineKind.title, menu: UIMenu(title: "Engine", options: .singleSelection, children: BenchEngineKind.allCases.map { kind in
            UIAction(title: kind.title, state: kind == engineKind ? .on : .off) { [weak self] _ in self?.selectEngine(kind) }
        }))
        let rowChoices = Self.rowChoices.contains(options.rows) ? Self.rowChoices : (Self.rowChoices + [options.rows]).sorted()
        let rowsItem = UIBarButtonItem(title: Self.rowsTitle(options.rows), menu: UIMenu(title: "Rows", options: .singleSelection, children: rowChoices.map { count in
            UIAction(title: Self.rowsTitle(count), state: count == options.rows ? .on : .off) { [weak self] _ in self?.selectRows(count) }
        }))
        let rateChoices = Self.rateChoices.contains(options.rate) ? Self.rateChoices : (Self.rateChoices + [options.rate]).sorted()
        let rateItem = UIBarButtonItem(title: Self.rateTitle(options.rate), menu: UIMenu(title: "Changes a second", options: .singleSelection, children: rateChoices.map { rate in
            UIAction(title: Self.rateTitle(rate), state: rate == options.rate ? .on : .off) { [weak self] _ in self?.selectRate(rate) }
        }))
        for item in [engineItem, rowsItem, rateItem] { item.isEnabled = enabled }
        navigationItem.leftBarButtonItems = [engineItem, rowsItem, rateItem]
        let testItem = isRunningPlan
            ? UIBarButtonItem(title: "Stop", style: .plain, target: self, action: #selector(stopPlan))
            : UIBarButtonItem(title: "Test", style: .plain, target: self, action: #selector(testThisEngine))
        let allItem = UIBarButtonItem(title: "Run All", style: .done, target: self, action: #selector(runAll))
        allItem.isEnabled = enabled
        navigationItem.rightBarButtonItems = [allItem, testItem]
    }

    private static func rowsTitle(_ count: Int) -> String {
        if count >= 1_000_000, count % 1_000_000 == 0 { return "\(count / 1_000_000)M rows" }
        if count >= 1_000, count % 1_000 == 0 { return "\(count / 1_000)K rows" }
        return "\(count) rows"
    }

    private static func rateTitle(_ rate: Int) -> String {
        if rate == 0 { return "Still" }
        if rate >= 1_000, rate % 1_000 == 0 { return "\(rate / 1_000)K/s" }
        return "\(rate)/s"
    }

    private func selectEngine(_ kind: BenchEngineKind) {
        showEngine(kind)
        updateMenus()
    }

    private func selectRows(_ count: Int) {
        options.rows = count
        data.make(count: count)
        showEngine(engineKind)
        updateMenus()
    }

    private func selectRate(_ rate: Int) {
        options.rate = rate
        updateMenus()
    }

    // MARK: Engines

    /// A new engine of this kind, on the current rows, under the controls.
    private func showEngine(_ kind: BenchEngineKind) {
        if let old = engine?.controller {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        engine = nil
        let engine = kind.make(data: data, ginghamExtras: options.ginghamExtras)
        self.engine = engine
        engineKind = kind
        rowHeight = BenchLayout.rowHeight
        addChild(engine.controller)
        engine.controller.view.frame = container.bounds
        engine.controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(engine.controller.view)
        engine.controller.didMove(toParent: self)
    }

    /// The rows on or near the screen: those shown and a quarter screen on each side.
    private func screenRows(of engine: BenchEngine) -> Range<Int> {
        let first = max(0, Int(engine.scrolledY / rowHeight))
        let count = Int((container.bounds.height / rowHeight).rounded(.up)) + 1
        let margin = max(1, count / 4)
        return max(0, first - margin)..<(first + count + margin)
    }

    // MARK: Frames

    @objc private func frame(_ link: CADisplayLink) {
        if var motion, motion.start == nil, let engine {
            motion.start = link.targetTimestamp
            if let profile = motion.profile, let session {
                meter.beginMeasuring()
                motion.cpuStart = processCPUTime()
                motion.wallStart = CACurrentMediaTime()
                motion.thermalStart = ProcessInfo.processInfo.thermalState
                motion.thermalWorst = motion.thermalStart
                motion.visibleDataRows = engine.visibleDataRows
                motion.signpost = signposter.beginInterval("Scroll test", id: signposter.makeSignpostID(),
                                                           "\(engine.kind.title, privacy: .public) \(profile.rawValue, privacy: .public) run \(session.run)")
            }
            self.motion = motion
        }
        meter.frame(link)
        applyChanges(link)

        guard let motion, let start = motion.start, let engine else { return }
        let elapsed = link.targetTimestamp - start
        guard elapsed < motion.duration else { return finishMotion() }
        let y = (motion.profile ?? .steady).offset(at: elapsed, duration: motion.duration, steadySpeed: options.speed,
                                                   fastSpeed: options.fastSpeed, scale: motion.scale)
        engine.scroll(toY: y)
        let scrolled = engine.scrolledY
        if scrolled > motion.deepest { self.motion?.deepest = scrolled }
    }

    /// The changes due since the last frame (at most a second's worth after a stall).
    private func applyChanges(_ link: CADisplayLink) {
        if let lastTick { pendingChanges += Double(options.rate) * min(1, max(0, link.timestamp - lastTick)) }
        lastTick = link.timestamp
        let count = Int(pendingChanges)
        guard count > 0, let engine else { return }
        pendingChanges -= Double(count)
        // The update call alone (see `BenchRunResult.updateCalls`): engines
        // that defer the work to layout spend it later, not here.
        let started = CACurrentMediaTime()
        let (changed, onScreen) = data.tick(changing: count, screen: screenRows(of: engine), screenShare: options.screenShare)
        engine.rowsChanged(changed)
        let spent = CACurrentMediaTime() - started
        guard var motion, motion.profile != nil, motion.start != nil else { return }
        motion.changesMade += count
        motion.changesOnScreen += onScreen
        motion.updateCalls += 1
        motion.updateSeconds += spent
        motion.updateMax = max(motion.updateMax, spent)
        self.motion = motion
    }

    private func liveTick() {
        let (frames, busy) = meter.lastSecond()
        liveLabel.text = "\(frames) fps · main \(Int((busy * 100).rounded()))%"
        liveLabel.sizeToFit()
        if motion?.profile != nil, motion?.start != nil {
            let state = ProcessInfo.processInfo.thermalState
            if state.rawValue > motion?.thermalWorst.rawValue ?? 0 { motion?.thermalWorst = state }
        }
    }

    // MARK: Tests

    @objc private func testThisEngine() {
        startPlan(engines: [engineKind], runs: 1)
    }

    @objc private func runAll() {
        startPlan(engines: options.engines.count > 1 ? options.engines : BenchEngineKind.comparable, runs: options.runs)
    }

    /// Tests every engine once, then again, `runs` times (interleaved, so a
    /// device warming up over the session doesn't favor the first engine), the
    /// order turned by one each round (no engine always first or always after
    /// the same one).
    private func startPlan(engines: [BenchEngineKind], runs: Int) {
        guard !isRunningPlan else { return }
        isRunningPlan = true
        planEngines = engines
        planRuns = runs
        plan = (1...runs).flatMap { run in
            engines.indices.map { index in (kind: engines[(index + run - 1) % engines.count], run: run) }
        }
        planResults = []
        planStart = Date()
        updateMenus()
        benchLog("BENCH_START " + jsonLine(settings))
        nextEngine()
    }

    private var settings: BenchReport.Settings {
        BenchReport.Settings(engines: planEngines.map(\.title), profiles: options.profiles.map(\.rawValue), rows: options.rows,
                             changesPerSecond: options.rate, screenShare: options.screenShare, runsPerEngine: planRuns,
                             secondsPerTest: options.duration, warmUpSeconds: options.warmUp,
                             steadyPointsPerSecond: Double(options.speed), fastPointsPerSecond: Double(options.fastSpeed),
                             rowHeightPoints: Double(BenchLayout.rowHeight), fontSize: Double(BenchLayout.fontSize),
                             ginghamExtras: options.ginghamExtras)
    }

    private func nextEngine() {
        guard isRunningPlan else { return }
        guard !plan.isEmpty else { return finishPlan() }
        let (kind, run) = plan.removeFirst()
        // The same rows, and the same sequence of changes, for every engine and run.
        data.make(count: options.rows)
        pendingChanges = 0
        showEngine(kind)
        container.isUserInteractionEnabled = false
        session = Session(kind: kind, run: run, steps: (options.warmUp > 0 ? [nil] : []) + options.profiles.map { $0 })
        resultLabel.text = "\(kind.title), run \(run) of \(planRuns): settling…"
        stepTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.options.settle))
            guard !Task.isCancelled, self.isRunningPlan else { return }
            self.session?.restFPS = self.meter.lastSecond().frames
            self.rowHeight = self.engine?.measuredRowHeight ?? BenchLayout.rowHeight
            self.runNextStep()
        }
    }

    private func runNextStep() {
        guard isRunningPlan, var session, let engine else { return }
        guard !session.steps.isEmpty else {
            container.isUserInteractionEnabled = true
            return nextEngine()
        }
        let step = session.steps.removeFirst()
        self.session = session
        engine.scroll(toY: 0)
        // As many rows a second in every engine (ScrollProfile.swift).
        motion = Motion(profile: step, duration: step == nil ? options.warmUp : options.duration,
                        scale: rowHeight / BenchLayout.rowHeight)
        resultLabel.text = "\(engine.kind.title), run \(session.run) of \(planRuns): " + (step.map { $0.title + "…" } ?? "warming up…")
    }

    private func finishMotion() {
        guard let motion = motion.take(), let engine, let session else { return }
        engine.scroll(toY: 0)
        if let profile = motion.profile {
            let measured = meter.endMeasuring()
            if let state = motion.signpost { signposter.endInterval("Scroll test", state) }
            if let measured { record(measured, motion: motion, profile: profile, engine: engine, session: session) }
        }
        stepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            self?.runNextStep()
        }
    }

    private func record(_ measured: FrameMeter.Result, motion: Motion, profile: ScrollProfile, engine: BenchEngine, session: Session) {
        func rounded(_ value: Double, _ places: Double = 10) -> Double { (value * places).rounded() / places }
        let wall = CACurrentMediaTime() - motion.wallStart
        let speed = profile == .steady ? options.speed : options.fastSpeed
        let topSpeed = speed * motion.scale
        var thermalWorst = motion.thermalWorst
        let thermalNow = ProcessInfo.processInfo.thermalState
        if thermalNow.rawValue > thermalWorst.rawValue { thermalWorst = thermalNow }
        let result = BenchRunResult(engine: engine.kind.title, profile: profile.rawValue, run: session.run, rows: options.rows,
                                    changesPerSecond: options.rate, screenShare: options.screenShare,
                                    rowsPerSecond: rounded(Double(speed / BenchLayout.rowHeight)),
                                    topSpeedPointsPerSecond: Double(topSpeed.rounded()),
                                    averageFPS: rounded(measured.averageFPS),
                                    worstSecondFPS: measured.worstSecondFPS,
                                    longestFrameMs: rounded(measured.longestFrameMs),
                                    hitches: measured.hitches,
                                    hitchTimeMsPerSecond: rounded(measured.hitchTimeMsPerSecond),
                                    frames: measured.frames, seconds: rounded(measured.duration, 1000),
                                    refreshIntervalMs: rounded(measured.refreshIntervalMs, 100),
                                    restFPS: session.restFPS,
                                    mainThreadBusyPercent: rounded(measured.mainThreadBusy * 100),
                                    processCPUPercent: rounded((processCPUTime() - motion.cpuStart) / max(wall, 0.001) * 100),
                                    updateCalls: motion.updateCalls,
                                    updateMsAverage: rounded(motion.updateCalls > 0 ? motion.updateSeconds * 1000 / Double(motion.updateCalls) : 0, 100),
                                    updateMsMax: rounded(motion.updateMax * 1000, 100),
                                    changesMade: motion.changesMade, changesOnScreen: motion.changesOnScreen,
                                    deepestScrollPoints: Double(motion.deepest.rounded()),
                                    rowHeightPoints: engine.measuredRowHeight.map(Double.init),
                                    visibleDataRows: motion.visibleDataRows,
                                    columnsShown: engine.columnsShown,
                                    scrollingView: engine.scrollingViewName,
                                    thermalStateStart: motion.thermalStart.name,
                                    thermalStateWorst: thermalWorst.name)
        planResults.append(result)
        benchLog("RESULT " + jsonLine(result))
        resultLabel.text = String(format: "%@, %@, run %d: %.0f fps (worst second %d), longest frame %.0f ms, main %.0f%%",
                                  result.engine, profile.title, result.run, result.averageFPS, result.worstSecondFPS,
                                  result.longestFrameMs, result.mainThreadBusyPercent)
    }

    @objc private func stopPlan() {
        stepTask?.cancel()
        stepTask = nil
        if let motion = motion.take() {
            if motion.profile != nil, motion.start != nil { _ = meter.endMeasuring() }
            if let state = motion.signpost { signposter.endInterval("Scroll test", state) }
        }
        session = nil
        container.isUserInteractionEnabled = true
        plan = []
        isRunningPlan = false
        updateMenus()
        resultLabel.text = "Stopped."
    }

    private func finishPlan() {
        isRunningPlan = false
        session = nil
        updateMenus()
        var summary: [BenchEngineSummary] = []
        for kind in planEngines {
            for profile in options.profiles {
                let runs = planResults.filter { $0.engine == kind.title && $0.profile == profile.rawValue }
                if !runs.isEmpty { summary.append(BenchEngineSummary(engine: kind.title, profile: profile.rawValue, runs: runs)) }
            }
        }
        for line in summary { benchLog("BENCH_SUMMARY " + jsonLine(line)) }
        let report = BenchReport(date: planStart, build: .current,
                                 device: BenchDevice.current(screen: view.window?.windowScene?.screen),
                                 settings: settings, runs: planResults, summary: summary)
        do {
            let url = try report.write()
            benchLog("BENCH_FILE \(url.path)")
        } catch {
            benchLog("BENCH_ERROR could not write the results: \(error)")
        }
        let first = options.profiles.first?.rawValue
        resultLabel.text = summary.filter { $0.profile == first }
            .map { String(format: "%@ %.0f (%d)", $0.engine, $0.medianFPS, $0.worstSecondFPS) }
            .joined(separator: " · ") + "  fps (worst second), \(options.profiles.first?.title ?? "")"
        benchLog("BENCH_DONE")
        if options.exitWhenDone {
            Task {
                try? await Task.sleep(for: .seconds(1))
                exit(0)
            }
        }
    }
}
