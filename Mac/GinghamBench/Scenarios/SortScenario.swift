//
//  SortScenario.swift
//  Gingham Bench
//
//  A static table of 1,000,000 trades, sorted by a text column as a click on its header would
//  sort it: by "Pair" (`sort-text`: about 500 distinct pairs, the busiest far more frequent, as
//  in real trades; the earlier measurement sorted 1,000,000 Binance trades by pair) or by
//  "Account" (`sort-text-account`: nearly every row a different name with a number, so the
//  numeric-aware Finder order matters). Generated from a fixed seed.
//
//  Measured by the runner (`SortRun`): three times from the unsorted order, the time from the
//  request to the first screen frame with the new order, the frames that came meanwhile and the
//  longest gap between them, and whether the order shown is Finder's
//  (`localizedStandardCompare`) all the way down.
//

import AppKit

final class SortStore: BenchSource, ColumnArrays {
    let columns: [ColumnSpec] = [
        ColumnSpec(id: "trade", title: "Trade ID", width: 100, kind: .number, digits: 0),
        ColumnSpec(id: "pair", title: "Pair", width: 110, kind: .text),
        ColumnSpec(id: "side", title: "Side", width: 60, kind: .text),
        ColumnSpec(id: "price", title: "Price", width: 120, kind: .number, digits: 4),
        ColumnSpec(id: "quantity", title: "Quantity", width: 110, kind: .number, digits: 4),
        ColumnSpec(id: "amount", title: "Amount", width: 120, kind: .number, digits: 2),
        ColumnSpec(id: "time", title: "Time", width: 100, kind: .time),
        ColumnSpec(id: "account", title: "Account", width: 200, kind: .text),
    ]
    private(set) var rowCount = 0
    private var numbers: [[Double]] = Array(repeating: [], count: 8)
    private var texts: [[String]] = Array(repeating: [], count: 8)
    var isStatic: Bool { true }

    func number(_ row: Int, _ column: Int) -> Double { numbers[column][row] }
    func text(_ row: Int, _ column: Int) -> String { texts[column][row] }
    func identifier(_ row: Int) -> Int { row }
    func numberArray(_ column: Int) -> [Double]? { columns[column].kind == .text ? nil : numbers[column] }
    func textArray(_ column: Int) -> [String]? { columns[column].kind == .text ? texts[column] : nil }

    nonisolated struct Generated: Sendable {
        var numbers: [[Double]]
        var texts: [[String]]
    }

    nonisolated static func generate(rows: Int, seed: UInt64 = 7) -> Generated {
        var random = SeededRandom(seed: seed)
        // ~500 pairs: bases with quotes, as an exchange lists them ("BTCUSDT").
        let quotes = ["USDT", "FDUSD", "USDC", "BTC", "TRY"]
        let pairs = FeedNames.bases.prefix(100).flatMap { base in quotes.map { base + $0 } }.filter { $0 != "BTCBTC" }
        let picker = ZipfPicker(count: pairs.count, exponent: 1)
        let first = ["Northwind", "Blue Harbor", "Ålesund", "Zürich", "Évora", "Kyoto", "Lakeside", "Oak Ridge", "Silverline",
                     "Acme", "Bright Path", "Coastal", "Delta", "Évian", "Granite", "Harbor Point", "Ironwood", "Juniper",
                     "Keystone", "Lumen", "Maple", "Nordic", "Orchard", "Pinecrest", "Quarry", "Redwood", "Summit", "Tidewater",
                     "Umber", "Valley", "Willow", "Yellowstone", "Zenith", "árvore", "école", "o'Brien", "McAllister", "van Dijk"]
        let second = ["Capital", "Partners", "Trading", "Fund", "Holdings", "Markets", "Ventures", "Asset Management", "Group",
                      "Securities", "Investments", "Desk"]
        var numbers: [[Double]] = Array(repeating: [], count: 8)
        var texts: [[String]] = Array(repeating: [], count: 8)
        for column in [0, 3, 4, 5, 6] { numbers[column].reserveCapacity(rows) }
        for column in [1, 2, 7] { texts[column].reserveCapacity(rows) }
        let start = 1_767_605_400_000_000.0
        for row in 0..<rows {
            let pair = picker.pick(&random, below: pairs.count)
            let price = FeedNames.basePrice(pair / quotes.count) * (1 + 0.01 * random.normal())
            let quantity = (exp(1.5 * random.normal()) * 1000 / max(price, 0.01) * 10_000).rounded() / 10_000
            numbers[0].append(Double(3_000_000_000 + row * 7 + random.below(7)))
            texts[1].append(pairs[pair])
            texts[2].append(random.below(2) == 0 ? "Buy" : "Sell")
            numbers[3].append(price)
            numbers[4].append(quantity)
            numbers[5].append(price * quantity)
            numbers[6].append(start + Double(row) * 21_600 + random.uniform(0..<20_000))
            texts[7].append("\(first[random.below(first.count)]) \(second[random.below(second.count)]) \(random.below(1_000_000))")
        }
        return Generated(numbers: numbers, texts: texts)
    }

    func load(_ generated: Generated) {
        numbers = generated.numbers
        texts = generated.texts
        rowCount = numbers[0].count
    }
}

final class SortScenario: Scenario {
    let id: ScenarioID
    private let store = SortStore()
    private let rows: Int
    /// The column sorted by (1: pair, 7: account).
    let sortColumn: Int
    var source: BenchSource { store }
    var sort: [SortSpec] { [] }

    init(id: ScenarioID, rows: Int, column: String) {
        self.id = id
        self.rows = rows
        sortColumn = column == "account" ? 7 : 1
    }

    var sortSpec: SortSpec { SortSpec(column: sortColumn, ascending: true) }

    var subtitle: String {
        "\(rows.formatted()) trades · sorted by \(sortColumn == 7 ? "account (nearly all distinct)" : "pair (about 500 distinct)") on request"
    }

    func prepare() async throws {
        let rows = rows
        let generated = await Task.detached(priority: .userInitiated) { SortStore.generate(rows: rows) }.value
        store.load(generated)
    }
}
