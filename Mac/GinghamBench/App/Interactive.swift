//
//  Interactive.swift
//  Gingham Bench
//
//  Window mode (no `--scenario`): pick a scenario and an engine and watch them, for trying the
//  engines by hand and for recording screenshots and video. The numbers are the last second's,
//  measured as in the command-line runs (but in one process, without warm-up or runs: use the
//  command line for numbers to compare). `--cycle N` switches engines every N seconds.
//

import AppKit

final class InteractiveController: NSObject {
    private let options: Options
    private let ui: BenchWindow
    private let meter = Meter()
    private var screenMeter: ScreenMeter?
    private let scenarioPopUp = NSPopUpButton()
    private let enginePopUp = NSPopUpButton()
    private let sortButton = NSButton(title: "Sort", target: nil, action: nil)
    private var scenario: Scenario?
    private var engine: Engine?
    private var scenarioID: ScenarioID
    private var kind: EngineKind
    private var preparing = 0
    private var sortStart: CFTimeInterval?
    private var sortedAscending = false
    private var cycled = 0
    private var lastBarUpdate: CFTimeInterval = 0

    init(options: Options) {
        self.options = options
        scenarioID = options.initialScenario
        kind = options.initialEngine
        ui = BenchWindow(size: options.windowSize, interactive: true)
        super.init()
        scenarioPopUp.addItems(withTitles: ScenarioID.allCases.map(\.title))
        enginePopUp.addItems(withTitles: EngineKind.allCases.map(\.title))
        scenarioPopUp.selectItem(at: ScenarioID.allCases.firstIndex(of: scenarioID) ?? 0)
        enginePopUp.selectItem(at: EngineKind.allCases.firstIndex(of: kind) ?? 0)
        for (control, action) in [(scenarioPopUp, #selector(scenarioChanged)), (enginePopUp, #selector(engineChanged)),
                                  (sortButton, #selector(sortClicked))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        sortButton.bezelStyle = .rounded
        for view in [scenarioPopUp, enginePopUp, sortButton] { ui.bar.controls.addArrangedSubview(view) }
    }

    func start() {
        ui.show()
        // The window's frame (screen points, top-left origin), for recording it.
        let frame = ui.window.frame, screen = ui.window.screen?.frame ?? .zero
        print("WINDOW \(Int(frame.minX)),\(Int(screen.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)
        meter.onFrame = { [weak self] now in self?.frame(now) }
        meter.start(on: ui.container)
        if options.screenMeter {
            // What the eye sees: the big number is the table's screen updates when it can be measured.
            let screenMeter = ScreenMeter(data: meter.data)
            self.screenMeter = screenMeter
            let (window, body, rate) = (ui.window, ui.tableBody, meter.refreshRate)
            Task { await screenMeter.start(window: window, tableBody: body, refreshRate: rate) }
        }
        engine = nil
        openScenario()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.meter.data.trim(before: CACurrentMediaTime() - 60) }
        }
        // For checking the layout without a screen recording permission: the window's views
        // drawn into a PNG (GPU-drawn content, Gingham's rows, stays empty) and quit.
        if let path = ProcessInfo.processInfo.environment["GINGHAM_BENCH_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let view = self?.ui.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
        }
        if let cycle = options.cycle {
            Timer.scheduledTimer(withTimeInterval: cycle, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.nextEngine() }
            }
        }
    }

    private func nextEngine() {
        cycled += 1
        if options.quitAfterCycle, cycled >= EngineKind.allCases.count { NSApp.terminate(nil) }
        let all = EngineKind.allCases
        kind = all[((all.firstIndex(of: kind) ?? 0) + 1) % all.count]
        enginePopUp.selectItem(at: all.firstIndex(of: kind) ?? 0)
        showEngine()
    }

    @objc private func scenarioChanged() {
        scenarioID = ScenarioID.allCases[max(0, scenarioPopUp.indexOfSelectedItem)]
        openScenario()
    }

    @objc private func engineChanged() {
        kind = EngineKind.allCases[max(0, enginePopUp.indexOfSelectedItem)]
        showEngine()
    }

    private func openScenario() {
        scenario?.stop()
        scenario = nil
        engine = nil
        ui.container.subviews.forEach { $0.removeFromSuperview() }
        ui.bar.engine.stringValue = kind.title
        ui.bar.subtitle.stringValue = "Preparing the rows…"
        ui.bar.clearNumbers()
        sortButton.isHidden = !scenarioID.isSort
        preparing += 1
        let ticket = preparing
        let scenario = scenarioID.make(options: options)
        Task {
            do {
                try await scenario.prepare()
            } catch {
                guard ticket == preparing else { return }
                ui.bar.subtitle.stringValue = "Couldn't load: \(error.localizedDescription)"
                return
            }
            guard ticket == preparing else {
                scenario.stop()
                return
            }
            self.scenario = scenario
            showEngine()
            scenario.start()
        }
    }

    private func showEngine() {
        guard let scenario else { return }
        ui.bar.engine.stringValue = kind.title
        ui.bar.subtitle.stringValue = scenario.subtitle
        ui.window.title = "Gingham Bench: \(scenarioID.title) — \(kind.title) (\(kind.setup))"
        let engine = kind.make()
        engine.framePresented = { [meter] in meter.presented() }
        ui.show(engine.view)
        scenario.attach(engine)
        engine.load(scenario.source, sort: scenario.sort)
        self.engine = engine
        sortedAscending = false
    }

    @objc private func sortClicked() {
        guard let engine, let scenario = scenario as? SortScenario else { return }
        sortedAscending.toggle()
        sortStart = CACurrentMediaTime()
        engine.sort(by: sortedAscending ? [scenario.sortSpec] : [])
    }

    private func frame(_ now: CFTimeInterval) {
        if let engine, let scenario {
            meter.data.applied(scenario.applyPending(to: engine, at: now), at: now)
            if let start = sortStart, !engine.isSorting {
                sortStart = nil
                ui.bar.subtitle.stringValue = "\(scenario.subtitle) · \(sortedAscending ? "sorted" : "unsorted") in \(String(format: "%.2f", now - start)) s"
            }
        }
        if now - lastBarUpdate >= 0.25 {
            lastBarUpdate = now
            let second = meter.data.lastSecond(now: now)
            if engine != nil {
                ui.bar.update(updates: second.updates, busy: second.busy, callbacks: second.callbacks, age: second.age,
                              screen: screenMeter?.state == "running" ? second.screen : nil, refreshRate: meter.refreshRate)
            }
        }
    }
}
