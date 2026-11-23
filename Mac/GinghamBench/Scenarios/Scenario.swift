//
//  Scenario.swift
//  Gingham Bench
//
//  A scenario: its rows (a store every engine reads), the order they're shown in, and, for the
//  live ones, a feed of changes applied once per screen frame. Engines are measured on the same
//  scenario code; only the table differs.
//

import AppKit

nonisolated enum ScenarioID: String, CaseIterable, Sendable {
    case liveTrades = "live-trades"
    case wideTrades = "wide-trades"
    case orderBook = "order-book"
    case tradeFeed = "trade-feed"
    case binanceTickers = "binance-tickers"
    case binanceBooks = "binance-books"
    case sortText = "sort-text"
    case sortTextAccount = "sort-text-account"

    var title: String {
        switch self {
        case .liveTrades: "Live trades"
        case .wideTrades: "Wide live trades"
        case .orderBook: "Order book"
        case .tradeFeed: "Trade feed"
        case .binanceTickers: "Binance tickers"
        case .binanceBooks: "Binance order books"
        case .sortText: "Sort by pair"
        case .sortTextAccount: "Sort by account"
        }
    }

    /// Live market data from the network: numbers vary with the market.
    var isLiveMarket: Bool { self == .binanceTickers || self == .binanceBooks }

    /// A static table sorted on request (the others are live).
    var isSort: Bool { self == .sortText || self == .sortTextAccount }

    @MainActor func make(options: Options) -> Scenario {
        switch self {
        case .liveTrades: SyntheticScenario(id: self, model: .trades, sortByAmount: true, rows: options.rows)
        case .wideTrades: SyntheticScenario(id: self, model: .wideTrades, sortByAmount: true, rows: options.rows)
        case .orderBook: SyntheticScenario(id: self, model: .orders, sortByAmount: false, rows: options.rows)
        case .tradeFeed: SyntheticScenario(id: self, model: .instruments, sortByAmount: false, rows: options.rows)
        case .binanceTickers: BinanceScenario(id: self, mode: .tickers, domain: options.binanceDomain)
        case .binanceBooks: BinanceScenario(id: self, mode: .depth, domain: options.binanceDomain)
        case .sortText: SortScenario(id: self, rows: options.rows ?? 1_000_000, column: "pair")
        case .sortTextAccount: SortScenario(id: self, rows: options.rows ?? 1_000_000, column: "account")
        }
    }
}

protocol Scenario: AnyObject {
    var id: ScenarioID { get }
    var source: BenchSource { get }
    /// The order the rows are shown in.
    var sort: [SortSpec] { get }
    /// What the window's subtitle says (rows, rate).
    var subtitle: String { get }
    /// Makes the rows (may take seconds); throws if they can't be had (no network).
    func prepare() async throws
    /// The engine about to show the rows: told about every change from now on, also those that
    /// come outside `applyPending` (Binance's order book snapshots).
    func attach(_ engine: Engine)
    /// The feed starts (live scenarios).
    func start()
    func stop()
    /// Applies everything that came since the last call to the store, telling the engine.
    /// Called at every screen frame (`time`: its display-link callback).
    func applyPending(to engine: Engine?, at time: CFTimeInterval) -> Applied
    /// The row changes a second the scenario generates, if it's generated.
    var nominalChangesPerSecond: Double? { get }
}

/// What a frame applied: row changes, and how old the data was (generation or arrival → this
/// callback), with how many changes had each age.
struct Applied {
    var changes = 0
    var ages: [(age: Double, changes: Int)] = []
    /// With `GINGHAM_BENCH_VISIBLE_TRUTH`: whether the rows in view should look different.
    var visibleChanged: Bool?
}

extension Scenario {
    func attach(_ engine: Engine) {}
    func start() {}
    func stop() {}
    func applyPending(to engine: Engine?, at time: CFTimeInterval) -> Applied { Applied() }
    var nominalChangesPerSecond: Double? { nil }
}

struct ScenarioError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
