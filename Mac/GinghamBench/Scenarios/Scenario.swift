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
    case orderBook = "order-book"
    case tradeFeed = "trade-feed"
    case binanceTickers = "binance-tickers"
    case binanceBooks = "binance-books"
    case sortText = "sort-text"

    var title: String {
        switch self {
        case .liveTrades: "Live trades"
        case .orderBook: "Order book"
        case .tradeFeed: "Trade feed"
        case .binanceTickers: "Binance tickers"
        case .binanceBooks: "Binance order books"
        case .sortText: "Sort by text"
        }
    }

    /// Live market data from the network: numbers vary with the market.
    var isLiveMarket: Bool { self == .binanceTickers || self == .binanceBooks }

    @MainActor func make(options: Options) -> Scenario {
        switch self {
        case .liveTrades: SyntheticScenario(id: self, model: .trades, sortByAmount: true, rows: options.rows)
        case .orderBook: SyntheticScenario(id: self, model: .orders, sortByAmount: false, rows: options.rows)
        case .tradeFeed: SyntheticScenario(id: self, model: .instruments, sortByAmount: false, rows: options.rows)
        case .binanceTickers: BinanceScenario(id: self, mode: .tickers, domain: options.binanceDomain)
        case .binanceBooks: BinanceScenario(id: self, mode: .depth, domain: options.binanceDomain)
        case .sortText: SortScenario(rows: options.rows ?? 1_000_000, column: options.sortColumn)
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
    /// The feed starts (live scenarios).
    func start()
    func stop()
    /// Applies what came since the last call to the store, telling the engine; the row changes
    /// applied. Called once per screen frame.
    func applyPending(to engine: Engine?) -> Int
}

extension Scenario {
    func start() {}
    func stop() {}
    func applyPending(to engine: Engine?) -> Int { 0 }
}

struct ScenarioError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
