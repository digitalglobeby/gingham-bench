//
//  FeedGenerator.swift
//  Gingham Bench
//
//  The synthetic live data, generated in this process on a thread of its own with a fixed
//  seed: the same stream of changes on every run and every Mac, at the same rates, for every
//  engine. Three models:
//
//  - `trades` (scenario `live-trades`): the README's comparison window, 20,000 trades of 32
//    pairs; 60 times a second 750 random trades change price and quantity (45,000 changes a
//    second). The same generator (seed, steps) as the original comparison app.
//  - `orders` (`order-book`): 200,000 resting orders of 500 instruments; every 2 ms 0.2% of
//    the rows are picked (Zipf-distributed, exponent 1: the first rows are the busiest), each
//    partially filled or repriced by 1–3 ticks; 50,000 new orders a second, and as many leave
//    (filled ones first, then random cancels). About 244,000 row changes a second (an order
//    picked twice in one tick counts once).
//  - `instruments` (`trade-feed`): 1,000,000 instruments with 23 fields; every 10 ms 0.5% of
//    the rows are picked (Zipf, exponent 1), each changing 3 fields (half of the changes move
//    the price: last and change, bid/ask when the price leaves the spread), plus status
//    changes; 1,000 instruments listed and 1,000 delisted a second. About 300,000 row changes
//    a second.
//
//  The orders and instruments models follow the `orders` and `firehose` scenarios of ngfeed,
//  the network feed server the earlier measurements used; generating in-process removes the
//  network and the JSON decoding (both off the main thread there) so anyone can reproduce it.
//
//  A tick's changes go into a batch the main thread takes once per screen frame (`FeedPump`).
//  Rows are removed by moving the last row into the removed row's place, and both the
//  generator and the store do the same, so a change names its row by index.
//

import Foundation
import QuartzCore

nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In 0..<1.
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    mutating func uniform(_ range: Range<Double>) -> Double { range.lowerBound + uniform() * (range.upperBound - range.lowerBound) }
    mutating func below(_ count: Int) -> Int { Int(next() % UInt64(max(count, 1))) }
    mutating func normal() -> Double {
        let u = max(uniform(), 1e-300), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
    mutating func exponential() -> Double { -log(max(1 - uniform(), 1e-300)) }
    /// Poisson-distributed count with this mean (normal approximation past 30).
    mutating func poisson(_ mean: Double) -> Int {
        if mean > 30 { return max(0, Int((mean + mean.squareRoot() * normal()).rounded())) }
        let limit = exp(-mean)
        var k = 0, p = 1.0
        repeat { k += 1; p *= uniform() } while p > limit
        return k - 1
    }
}

/// Picks rows with Zipf-distributed ranks (rank 1 = row 0), from a table of cumulative weights.
nonisolated struct ZipfPicker {
    private let cumulative: [Double]

    init(count: Int, exponent: Double) {
        var sum = 0.0
        var cumulative = [Double](repeating: 0, count: count)
        for k in 0..<count {
            sum += exponent == 1 ? 1 / Double(k + 1) : pow(Double(k + 1), -exponent)
            cumulative[k] = sum
        }
        for k in 0..<count { cumulative[k] /= sum }
        self.cumulative = cumulative
    }

    func pick(_ random: inout SeededRandom, below count: Int) -> Int {
        let u = random.uniform()
        var low = 0, high = cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle] < u { low = middle + 1 } else { high = middle }
        }
        return min(low, count - 1)
    }
}

/// Changes taken by the main thread: in order, deletes (a row index), inserts (a record) and
/// updates (a row index, the changed fields and the record).
nonisolated struct FeedBatch: Sendable {
    enum Kind: UInt8, Sendable { case delete, insert, update }
    var kinds: [Kind] = []
    var rows: [Int32] = []
    var masks: [UInt64] = []
    /// Records of inserts and updates, `width` values each, in the order of their changes.
    var values: [Double] = []

    var count: Int { kinds.count }
    var isEmpty: Bool { kinds.isEmpty }

    mutating func append(contentsOf other: FeedBatch) {
        kinds += other.kinds
        rows += other.rows
        masks += other.masks
        values += other.values
    }

    mutating func removeAll() {
        kinds.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        masks.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
    }
}

nonisolated enum FeedModel: String, Sendable {
    case trades, orders, instruments

    var rows: Int {
        switch self {
        case .trades: 20_000
        case .orders: 200_000
        case .instruments: 1_000_000
        }
    }

    /// Seconds between ticks.
    var tickInterval: Double {
        switch self {
        case .trades: 1.0 / 60
        case .orders: 0.002
        case .instruments: 0.010
        }
    }

    var columns: [ColumnSpec] {
        switch self {
        case .trades:
            return [
                ColumnSpec(id: "trade", title: "Trade", width: 80, kind: .number, digits: 0),
                ColumnSpec(id: "pair", title: "Pair", width: 110, kind: .text),
                ColumnSpec(id: "side", title: "Side", width: 60, kind: .text),
                ColumnSpec(id: "price", title: "Price", width: 110, kind: .number, digits: 2),
                ColumnSpec(id: "quantity", title: "Quantity", width: 100, kind: .number, digits: 2),
                ColumnSpec(id: "amount", title: "Amount", width: 130, kind: .number, digits: 2),
                ColumnSpec(id: "change", title: "Change %", width: 90, kind: .number, digits: 2),
                ColumnSpec(id: "updates", title: "Updates", width: 80, kind: .number, digits: 0),
            ]
        case .orders:
            return [
                ColumnSpec(id: "id", title: "ID", width: 110, kind: .text),
                ColumnSpec(id: "symbol", title: "Symbol", width: 110, kind: .text),
                ColumnSpec(id: "venue", title: "Venue", width: 60, kind: .text),
                ColumnSpec(id: "side", title: "Side", width: 60, kind: .text),
                ColumnSpec(id: "price", title: "Price", width: 120, kind: .number, digits: 4),
                ColumnSpec(id: "qty", title: "Quantity", width: 120, kind: .number, digits: 4),
                ColumnSpec(id: "filled", title: "Filled", width: 120, kind: .number, digits: 4),
                ColumnSpec(id: "placed", title: "Placed", width: 100, kind: .time),
            ]
        case .instruments:
            return [
                ColumnSpec(id: "id", title: "ID", width: 130, kind: .text),
                ColumnSpec(id: "symbol", title: "Symbol", width: 100, kind: .text),
                ColumnSpec(id: "venue", title: "Venue", width: 60, kind: .text),
                ColumnSpec(id: "status", title: "Status", width: 70, kind: .text),
                ColumnSpec(id: "bid", title: "Bid", width: 110, kind: .number, digits: 4),
                ColumnSpec(id: "ask", title: "Ask", width: 110, kind: .number, digits: 4),
                ColumnSpec(id: "last", title: "Last", width: 110, kind: .number, digits: 4),
                ColumnSpec(id: "open", title: "Open", width: 110, kind: .number, digits: 4),
                ColumnSpec(id: "change", title: "Change", width: 80, kind: .percent, digits: 2),
                ColumnSpec(id: "volume", title: "Volume", width: 130, kind: .number, digits: 2),
                ColumnSpec(id: "trades", title: "Trades", width: 80, kind: .number, digits: 0),
                ColumnSpec(id: "updated", title: "Updated", width: 100, kind: .time),
            ] + (1...10).map { ColumnSpec(id: "m\($0)", title: "M\($0)", width: 90, kind: .number, digits: 4) }
                + [ColumnSpec(id: "note", title: "Note", width: 160, kind: .text)]
        }
    }

    /// A text column's text for the code in a record.
    func text(column: Int, code: Double) -> String {
        let code = Int(code)
        switch (self, column) {
        case (.trades, 1): return FeedNames.pairs[code]
        case (.trades, 2): return code == 1 ? "Sell" : "Buy"
        case (.orders, 0): return "o\(code)"
        case (.orders, 1), (.instruments, 1): return FeedNames.symbols[code % FeedNames.symbols.count]
        case (.orders, 2), (.instruments, 2): return FeedNames.venues[code % FeedNames.venues.count]
        case (.orders, 3): return code == 1 ? "Sell" : "Buy"
        case (.instruments, 0): return FeedNames.instrumentID(key: code)
        case (.instruments, 3): return FeedNames.statuses[code]
        case (.instruments, 22): return code == 0 ? "" : FeedNames.notes[(code - 1) % FeedNames.notes.count]
        default: return ""
        }
    }

    /// The record's field that is its identity (a key, never reused).
    var keyField: Int { self == .trades ? 0 : 0 }
}

nonisolated enum FeedNames {
    static let pairs = ["BTC/USDT", "ETH/USDT", "SOL/USDT", "BNB/USDT", "XRP/USDT", "DOGE/USDT", "ADA/USDT", "TRX/USDT",
                        "AVAX/USDT", "LINK/USDT", "DOT/USDT", "TON/USDT", "MATIC/USDT", "LTC/USDT", "BCH/USDT", "NEAR/USDT",
                        "UNI/USDT", "APT/USDT", "ARB/USDT", "OP/USDT", "ATOM/USDT", "FIL/USDT", "ETC/USDT", "XLM/USDT",
                        "ETH/BTC", "SOL/BTC", "BNB/BTC", "XRP/BTC", "SUI/USDT", "PEPE/USDT", "INJ/USDT", "SEI/USDT"]
    static let bases = ["BTC", "ETH", "SOL", "BNB", "XRP", "DOGE", "ADA", "TRX", "AVAX", "LINK", "DOT", "TON", "MATIC", "LTC", "BCH",
                        "NEAR", "UNI", "APT", "ARB", "OP", "ATOM", "FIL", "ETC", "XLM", "SUI", "PEPE", "INJ", "SEI", "AAVE", "MKR",
                        "RUNE", "GRT", "ALGO", "SAND", "MANA", "AXS", "EGLD", "FTM", "THETA", "XTZ", "EOS", "FLOW", "CHZ", "KAVA",
                        "ZEC", "DASH", "NEO", "IOTA", "QNT", "CRV", "SNX", "COMP", "ENJ", "BAT", "ZIL", "ICX", "ONT", "WAVES",
                        "KSM", "CELO", "ROSE", "GALA", "IMX", "LDO", "STX", "HBAR", "VET", "ICP", "RNDR", "FET", "AGIX", "OCEAN",
                        "WLD", "TIA", "JUP", "PYTH", "STRK", "ENA", "WIF", "BONK", "FLOKI", "SHIB", "ORDI", "BLUR", "DYDX", "GMX",
                        "SSV", "RPL", "FXS", "CVX", "BAL", "YFI", "SUSHI", "1INCH", "ZRX", "ANKR", "SKL", "STORJ", "AR", "MINA",
                        "KAS", "CFX", "XEC", "BSV", "BTT", "HOT", "RVN", "SC", "DGB", "LSK", "NANO", "XEM", "QTUM", "OMG", "ZEN",
                        "IOTX", "CKB", "API3", "BAND", "UMA", "LRC", "MASK", "AUDIO", "CTSI"]
    static let quotes = ["USD", "USDT", "EUR", "USDC"]
    static let symbols: [String] = quotes.flatMap { quote in bases.map { "\($0)-\(quote)" } }
    static let venues = ["CB", "BN", "KR", "BS", "OK", "BY", "HT", "GT"]
    static let statuses = ["Active", "Halted", "Auction", "Closed"]
    static let notes = ["watch", "rebalance", "news pending", "earnings", "low liquidity", "index change", "split", "dividend",
                        "maintenance", "delisting review", "margin call", "halt risk", "new listing", "large holder", "audit",
                        "roadmap", "fork", "airdrop", "unlock", "governance vote"]
    /// Prices in US dollars of the first bases (the others get a price from their index).
    static let basePrices: [Double] = [64_000, 3_400, 150, 580, 0.6, 0.15, 0.45, 0.12, 35, 14, 7, 6.5, 0.7, 80, 450, 6, 9, 9, 1.1,
                                       2.2, 9, 5.5, 26, 0.11, 1.4, 0.000012, 25, 0.5]

    static func basePrice(_ base: Int) -> Double {
        if base < basePrices.count { return basePrices[base] }
        var random = SeededRandom(seed: UInt64(base) &* 0x2545_F491_4F6C_DD1D)
        return pow(10, random.uniform(-1.5..<3.5))
    }

    static func quoteRate(_ quote: Int) -> Double { quote == 2 ? 1.08 : 1 }

    /// An instrument's id: its symbol and venue (and a number past the first combinations).
    static func instrumentID(key: Int) -> String {
        let combinations = symbols.count * venues.count
        let symbol = symbols[key % symbols.count], venue = venues[(key / symbols.count) % venues.count]
        return key < combinations ? "\(symbol).\(venue)" : "\(symbol).\(venue)\(key / combinations)"
    }
}

/// The generator's own copy of the rows (records of `width` values, row after row) and the
/// changes it makes, tick by tick.
nonisolated final class FeedGenerator: @unchecked Sendable {
    let model: FeedModel
    let width: Int
    private(set) var cells: [Double] = []
    private(set) var count = 0
    private var random: SeededRandom
    private var picker: ZipfPicker?
    /// Virtual time, µs: starts at a fixed moment, advances by the tick interval.
    private var time: Double = 1_767_605_400_000_000
    private var nextKey = 0
    private var insertCarry = 0.0, deleteCarry = 0.0, changeCarry = 0.0
    /// Per row (generator state not shown): trades' opening price, instruments' volatility.
    private var extra: [Double] = []
    /// Orders: instruments' mid prices; rows filled completely in the last tick.
    private var mids: [Double] = []
    private var completed: [Int] = []
    /// A tick's changed rows: each row's index in `updated` (-1: unchanged) and its fields.
    private var touched: [Int32] = []
    private var updated: [(row: Int, mask: UInt64)] = []
    /// The comparison app's generator (live trades), kept as it was.
    private var lcg: UInt64 = 0x9E37_79B9_7F4A_7C15

    // Rates.
    private let changeRate: Double
    private let insertsPerSecond: Double
    private let changesPerTick: Int

    init(model: FeedModel, rows: Int? = nil, seed: UInt64 = 42) {
        self.model = model
        width = model.columns.count
        random = SeededRandom(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(model.rawValue.count))
        let rows = rows ?? model.rows
        switch model {
        case .trades:
            changeRate = 0
            insertsPerSecond = 0
            changesPerTick = 45_000 / 60
        case .orders:
            changeRate = 0.002
            insertsPerSecond = 50_000
            changesPerTick = 0
        case .instruments:
            changeRate = 0.005
            insertsPerSecond = 1_000
            changesPerTick = 0
        }
        cells.reserveCapacity((rows + rows / 16) * width)
        switch model {
        case .trades:
            for row in 0..<rows { appendTrade(row) }
        case .orders:
            let instruments = min(512, max(16, rows / 400))
            mids = (0..<instruments).map { index in
                let base = index % FeedNames.bases.count, quote = index / FeedNames.bases.count % FeedNames.quotes.count
                return FeedNames.basePrice(base) / FeedNames.quoteRate(quote)
            }
            nextKey = 10_000_000
            for _ in 0..<rows { appendOrder(initial: true) }
        case .instruments:
            for _ in 0..<rows { appendInstrument(initial: true) }
        }
        if model != .trades { picker = ZipfPicker(count: rows, exponent: 1) }
        touched = [Int32](repeating: -1, count: count)
    }

    var tickInterval: Double { model.tickInterval }

    // MARK: Rows

    private func lcgNext() -> UInt64 {
        lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
        return lcg >> 33
    }

    private func appendTrade(_ row: Int) {
        let pair = Int(lcgNext() % UInt64(FeedNames.pairs.count))
        let isSell = lcgNext() % 2 == 0
        let base = 10 + Double(pair * 37 % 900) * (1 + Double(row % 7) / 10)
        let quantity = Double(lcgNext() % 100_000) / 100
        cells += [Double(row + 1), Double(pair), isSell ? 1 : 0, base, quantity, base * quantity, 0, 0]
        extra.append(base)
        count += 1
    }

    private func appendOrder(initial: Bool) {
        let instrument = random.below(mids.count)
        let mid = mids[instrument]
        let side = random.below(2)
        let tick = Self.tickSize(mid)
        let offset = Double(1 + Int(random.exponential() * 8))
        let price = max(tick, ((mid / tick).rounded() + (side == 0 ? -offset : offset)) * tick)
        let quantity = max(0.0001, (5000 * exp(1.3 * random.normal()) / mid * 10_000).rounded() / 10_000)
        let filled = initial && random.uniform() < 0.3 ? (quantity * random.uniform(0..<0.9) * 10_000).rounded() / 10_000 : 0
        let placed = initial ? time - random.uniform(0..<600_000_000) : time
        cells += [Double(nextKey), Double(instrument), Double(instrument % FeedNames.venues.count), Double(side), price, quantity, filled, placed]
        nextKey += 1
        count += 1
    }

    private static func tickSize(_ price: Double) -> Double {
        pow(10, (log10(max(price, 1e-9)).rounded(.down) - 4).clamped(to: -8...2))
    }

    private func appendInstrument(initial: Bool) {
        let key = nextKey
        nextKey += 1
        let symbol = key % FeedNames.symbols.count
        let base = symbol % FeedNames.bases.count, quote = symbol / FeedNames.bases.count
        let last = FeedNames.basePrice(base) / FeedNames.quoteRate(quote) * (1 + 0.002 * (random.uniform() - 0.5))
        let spread = 0.0001 + 0.002 * random.uniform()
        let bid = last * (1 - spread * random.uniform(0.3..<1)), ask = last * (1 + spread * random.uniform(0.3..<1))
        let open = last * exp(0.03 * random.normal())
        let volume = initial ? (1e6 * exp(1.5 * random.normal()) / last * 100).rounded() / 100 : 0
        let trades = initial ? Double(random.below(200_000)) : 0
        let updated = initial ? time - random.uniform(0..<60_000_000) : time
        let r = random.uniform()
        let status: Double = initial ? (r < 0.94 ? 0 : r < 0.96 ? 1 : r < 0.98 ? 2 : 3) : (r < 0.5 ? 2 : 0)
        let note = random.uniform() < 0.3 ? Double(1 + random.below(FeedNames.notes.count)) : 0
        cells += [Double(key), Double(symbol), Double((key / FeedNames.symbols.count) % FeedNames.venues.count), status,
                  bid, ask, last, open, last / open - 1, volume, trades, updated]
        for metric in 0..<10 {
            cells.append(random.uniform() < 0.02 ? .nan : pow(10, Double(metric % 6) - 2) * random.normal())
        }
        cells.append(note)
        extra.append(0.0003 + 0.0027 * random.uniform())   // volatility of a price step
        count += 1
    }

    /// The last row moved into `row`'s place.
    private func removeRow(_ row: Int) {
        let last = count - 1
        if row != last {
            for field in 0..<width { cells[row * width + field] = cells[last * width + field] }
            if !extra.isEmpty { extra[row] = extra[last] }
        }
        cells.removeLast(width)
        if !extra.isEmpty { extra.removeLast() }
        count -= 1
    }

    @inline(__always) private func cell(_ row: Int, _ field: Int) -> Double { cells[row * width + field] }
    @inline(__always) private func set(_ row: Int, _ field: Int, _ value: Double) { cells[row * width + field] = value }

    private func touch(_ row: Int, _ mask: UInt64, firstInserted: Int) {
        guard mask != 0, row < firstInserted else { return }   // a row inserted this tick goes out whole
        let index = touched[row]
        if index >= 0 {
            updated[Int(index)].mask |= mask
        } else {
            touched[row] = Int32(updated.count)
            updated.append((row, mask))
        }
    }

    private static func takeCarry(_ carry: inout Double, _ add: Double) -> Int {
        carry += add
        let whole = carry.rounded(.down)
        carry -= whole
        return max(0, Int(whole))
    }

    // MARK: A tick

    /// One tick of changes, appended to `batch`.
    func tick(into batch: inout FeedBatch) {
        let dt = tickInterval
        time += dt * 1_000_000
        switch model {
        case .trades: tickTrades(into: &batch)
        case .orders, .instruments: tickRows(dt: dt, into: &batch)
        }
    }

    private func tickTrades(into batch: inout FeedBatch) {
        for _ in 0..<changesPerTick {
            let row = Int(lcgNext() % UInt64(count))
            let step = Double(Int(lcgNext() % 2001) - 1000) / 100_000
            let price = max(0.01, cell(row, 3) * (1 + step))
            let quantity = Double(lcgNext() % 100_000) / 100
            set(row, 3, price)
            set(row, 4, quantity)
            set(row, 5, price * quantity)
            set(row, 6, (price / extra[row] - 1) * 100)
            set(row, 7, cell(row, 7) + 1)
            touch(row, 0b1111_1000, firstInserted: count)
        }
        emitUpdates(into: &batch)
    }

    private func tickRows(dt: Double, into batch: inout FeedBatch) {
        let orders = model == .orders
        if orders {
            // The instruments' mid prices walk.
            for _ in 0..<(1 + mids.count / 50) {
                let index = random.below(mids.count)
                mids[index] *= exp(0.0005 * random.normal())
            }
        }
        // Deletes: filled orders first, then random cancels, up to the rate; from the highest
        // row down, so moving the last row into a removed one's place doesn't move another.
        let budget = Self.takeCarry(&deleteCarry, insertsPerSecond * dt)
        var removed = Set(completed.filter { $0 < count })
        completed.removeAll(keepingCapacity: true)
        while removed.count < min(budget, count) { removed.insert(random.below(count)) }
        for row in removed.sorted(by: >) {
            removeRow(row)
            touched.removeLast()
            batch.kinds.append(.delete)
            batch.rows.append(Int32(row))
            batch.masks.append(0)
        }
        // Inserts at the end.
        let firstInserted = count
        let inserts = Self.takeCarry(&insertCarry, insertsPerSecond * dt)
        for _ in 0..<inserts {
            if orders { appendOrder(initial: false) } else { appendInstrument(initial: false) }
            touched.append(-1)
        }
        // Changes.
        let picks = Self.takeCarry(&changeCarry, changeRate * Double(count))
        if count > 0, let picker {
            for _ in 0..<picks {
                let row = picker.pick(&random, below: count)
                touch(row, orders ? changeOrder(row) : changeInstrument(row), firstInserted: firstInserted)
            }
            if !orders {
                // Status changes (0.01% of the rows a tick).
                for _ in 0..<random.poisson(Double(count) * 0.0001) {
                    let row = random.below(count)
                    touch(row, changeStatus(row), firstInserted: firstInserted)
                }
            }
        }
        for row in firstInserted..<count {
            batch.kinds.append(.insert)
            batch.rows.append(Int32(row))
            batch.masks.append(0)
            batch.values.append(contentsOf: cells[row * width ..< (row + 1) * width])
        }
        if !orders {
            for index in updated.indices {
                set(updated[index].row, 11, time)
                updated[index].mask |= 1 << 11
            }
        }
        emitUpdates(into: &batch)
    }

    private func emitUpdates(into batch: inout FeedBatch) {
        for (row, mask) in updated {
            batch.kinds.append(.update)
            batch.rows.append(Int32(row))
            batch.masks.append(mask)
            batch.values.append(contentsOf: cells[row * width ..< (row + 1) * width])
            touched[row] = -1
        }
        updated.removeAll(keepingCapacity: true)
    }

    /// Orders: a partial fill, or (half the time) the price moved by 1–3 ticks.
    private func changeOrder(_ row: Int) -> UInt64 {
        let quantity = cell(row, 5), filled = cell(row, 6)
        guard filled < quantity else { return 0 }
        if random.uniform() < 0.5 {
            let price = cell(row, 4), tick = Self.tickSize(price)
            let steps = Double(1 + random.below(3))
            set(row, 4, max(tick, ((price / tick).rounded() + (random.below(2) == 0 ? steps : -steps)) * tick))
            return 1 << 4
        }
        let fill = min(quantity, filled + max(0.0001, (quantity * random.uniform(0.05..<0.5) * 10_000).rounded() / 10_000))
        set(row, 6, fill)
        if fill >= quantity { completed.append(row) }
        return 1 << 6
    }

    /// Instruments: three fields change; half of the changes move the price.
    private func changeInstrument(_ row: Int) -> UInt64 {
        var mask: UInt64 = 0
        var fields = 3
        if random.uniform() < 0.5 {
            let last = cell(row, 6) * exp(extra[row] * random.normal())
            set(row, 6, last)
            set(row, 8, last / cell(row, 7) - 1)
            mask |= 1 << 6 | 1 << 8
            let spread = 0.0001 + 0.002 * random.uniform()
            if last < cell(row, 4) { set(row, 4, last * (1 - spread * random.uniform(0.3..<1))); mask |= 1 << 4 }
            if last > cell(row, 5) { set(row, 5, last * (1 + spread * random.uniform(0.3..<1))); mask |= 1 << 5 }
            fields -= 1
        }
        // The others from bid, ask, volume, trades and the ten metrics, no field twice.
        var chosen: UInt64 = 0
        while chosen.nonzeroBitCount < fields { chosen |= 1 << UInt64(random.below(14)) }
        while chosen != 0 {
            let pick = chosen.trailingZeroBitCount
            chosen &= chosen - 1
            let last = cell(row, 6), spread = 0.0001 + 0.002 * random.uniform()
            switch pick {
            case 0: set(row, 4, last * (1 - spread * random.uniform(0.3..<1))); mask |= 1 << 4
            case 1: set(row, 5, last * (1 + spread * random.uniform(0.3..<1))); mask |= 1 << 5
            case 2: set(row, 9, cell(row, 9) + (2000 * exp(1.2 * random.normal()) / last * 100).rounded() / 100); mask |= 1 << 9
            case 3: set(row, 10, cell(row, 10) + Double(1 + random.below(5))); mask |= 1 << 10
            default:
                let metric = pick - 4, field = 12 + metric
                let value = cell(row, field), scale = pow(10, Double(metric % 6) - 2)
                set(row, field, value.isNaN ? scale * random.normal() : random.uniform() < 0.02 ? .nan : value + scale * 0.05 * random.normal())
                mask |= 1 << UInt64(field)
            }
        }
        if random.uniform() < 0.002 {
            set(row, 22, random.uniform() < 0.7 ? 0 : Double(1 + random.below(FeedNames.notes.count)))
            mask |= 1 << 22
        }
        return mask
    }

    private func changeStatus(_ row: Int) -> UInt64 {
        let current = Int(cell(row, 3)), r = random.uniform()
        let new = current == 0 ? (r < 0.5 ? 1 : r < 0.8 ? 2 : 3) : (r < 0.8 ? 0 : [1, 2, 3].filter { $0 != current }[random.below(2)])
        set(row, 3, Double(new))
        var mask: UInt64 = 1 << 3
        if current == 3, new == 0 {
            // Open again: a new session.
            set(row, 7, cell(row, 6))
            set(row, 8, 0)
            mask |= 1 << 7 | 1 << 8
        }
        return mask
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// The generator on a thread of its own, ticking at its model's rate; the main thread takes
/// what came once per screen frame. If more than a second of changes waits (an engine that
/// can't keep up), the generator waits too: the changes applied a second then show it.
nonisolated final class FeedPump: @unchecked Sendable {
    let generator: FeedGenerator
    private let lock = NSLock()
    private var pending = FeedBatch()
    private var isRunning = false
    private var thread: Thread?
    private let backlogLimit: Int

    init(generator: FeedGenerator, changesPerSecond: Int) {
        self.generator = generator
        backlogLimit = max(1000, changesPerSecond)
    }

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "Feed generator"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    /// Everything generated since the last call.
    func take() -> FeedBatch {
        var taken = FeedBatch()
        lock.lock()
        swap(&taken, &pending)
        lock.unlock()
        return taken
    }

    private func run() {
        var local = FeedBatch()
        let interval = generator.tickInterval
        var next = CACurrentMediaTime()
        while true {
            lock.lock()
            let running = isRunning, backlog = pending.count
            lock.unlock()
            guard running else { return }
            let now = CACurrentMediaTime()
            if now < next {
                Thread.sleep(forTimeInterval: min(next - now, 0.005))
                continue
            }
            if backlog > backlogLimit {
                Thread.sleep(forTimeInterval: 0.001)
                next = CACurrentMediaTime()
                continue
            }
            generator.tick(into: &local)
            lock.lock()
            pending.append(contentsOf: local)
            lock.unlock()
            local.removeAll()
            next += interval
            // Behind by more than a tenth of a second (a busy machine): no burst to catch up.
            if CACurrentMediaTime() - next > 0.1 { next = CACurrentMediaTime() }
        }
    }
}
