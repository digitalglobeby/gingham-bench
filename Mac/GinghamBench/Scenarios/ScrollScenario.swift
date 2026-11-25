//
//  ScrollScenario.swift
//  Gingham Bench
//
//  `scroll`: a static table of 100,000 trades (the sort scenarios' rows), scrolled down at a
//  steady 200 rows a second from the feed's start to the run's end, nothing changing: the
//  commonest use of a table, where no engine has live data to keep up with. Every display-link
//  callback moves the table to where the speed puts it at that time (`--update-rate` doesn't pace
//  it): a late callback moves it further, as under a finger, so an engine that stalls shows it in
//  its callbacks, longest stall and frames with new data. Each engine scrolls by its own means
//  (an NSScrollView's clip view for AppKit's tables and the one inside SwiftUI's, Gingham's
//  `scroll(to:)`), and by its own row height, so every engine brings the same rows a second onto
//  the screen (SwiftUI's rows are taller). An update applied is a step of the scroll.
//

import AppKit

final class ScrollScenario: Scenario {
    let id: ScenarioID
    private let store = SortStore()
    private let rows: Int
    /// Rows a second.
    static let rowsPerSecond = 200.0
    private var startTime: CFTimeInterval?
    private var isRunning = false
    var source: BenchSource { store }
    var sort: [SortSpec] { [] }

    init(id: ScenarioID, rows: Int) {
        self.id = id
        self.rows = rows
    }

    var subtitle: String { "\(rows.formatted()) trades scrolled down at \(Int(Self.rowsPerSecond)) rows a second" }

    func prepare() async throws {
        let rows = rows
        let generated = await Task.detached(priority: .userInitiated) { SortStore.generate(rows: rows) }.value
        store.load(generated)
    }

    func start() {
        isRunning = true
        startTime = nil
    }

    func stop() { isRunning = false }

    func applyPending(to engine: Engine?, at time: CFTimeInterval) -> Applied {
        guard isRunning, let engine else { return Applied() }
        let start = startTime ?? time
        startTime = start
        engine.scroll(toY: CGFloat(time - start) * CGFloat(Self.rowsPerSecond) * engine.rowPitch)
        return Applied(changes: 1)
    }
}
