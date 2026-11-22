//
//  BinanceScenario.swift
//  Gingham Bench
//
//  Binance's public market data (spot), live, no key needed: a live market, so the numbers
//  vary with it (and with the network). Two scenarios:
//
//  - `binance-tickers`: a row per traded pair (about 3,100): the 24-hour tickers of every pair
//    (`!ticker_1d@arr`, every second) and each pair's best bid and ask as they change
//    (`<pair>@bookTicker`, over a few connections of 1,024 streams), sorted by trades.
//  - `binance-books`: the order books of six pairs, a row per price level (about 58,000):
//    changes every 100 ms (`<pair>@depth@100ms`) on a REST snapshot of 5,000 levels a side,
//    kept in step as Binance's docs say (`BinanceBookSync`); a level whose quantity drops to 0
//    leaves (the last row takes its place), a new level comes at the end; sorted by pair, then
//    price, highest first.
//
//  Frames are received and decoded off the main thread; once per screen frame everything that
//  came is applied to the store in one batch, telling the engine (as the synthetic feeds do).
//  The domain is `binance.com` (`--binance-domain binance.us` where that one is closed).
//

import AppKit

final class BinanceStore: BenchSource, ColumnArrays {
    enum Mode { case tickers, depth }

    let mode: Mode
    let columns: [ColumnSpec]
    private(set) var rowCount = 0
    private var numbers: [[Double]]
    private var texts: [[String]]
    private var ids: [Int] = []
    private var nextID = 0
    private var columnIndex: [String: Int] = [:]
    private var rowOfSymbol: [String: Int] = [:]
    private struct LevelKey: Hashable {
        let symbol: String
        let isBid: Bool
        let price: UInt64
    }
    private var rowOfLevel: [LevelKey: Int] = [:]
    private var levelOfRow: [LevelKey] = []
    /// Rows changed since the engine was last told, in two groups (0: a new row or a column the
    /// order depends on, 1: the others), each with the columns changed; marks keep a row once.
    private var pending: [(rows: [Int], marks: [Bool], columns: IndexSet)] = [([], [], []), ([], [], [])]
    weak var engine: Engine?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .tickers:
            columns = [
                ColumnSpec(id: "symbol", title: "Pair", width: 110, kind: .text),
                ColumnSpec(id: "last", title: "Price", width: 130, kind: .number, digits: 8),
                ColumnSpec(id: "bid", title: "Bid", width: 130, kind: .number, digits: 8),
                ColumnSpec(id: "bidQty", title: "Bid qty", width: 120, kind: .number, digits: 4),
                ColumnSpec(id: "ask", title: "Ask", width: 130, kind: .number, digits: 8),
                ColumnSpec(id: "askQty", title: "Ask qty", width: 120, kind: .number, digits: 4),
                ColumnSpec(id: "spread", title: "Spread", width: 80, kind: .percent, digits: 3),
                ColumnSpec(id: "change", title: "24h", width: 80, kind: .percent, digits: 2),
                ColumnSpec(id: "high", title: "24h high", width: 130, kind: .number, digits: 8),
                ColumnSpec(id: "low", title: "24h low", width: 130, kind: .number, digits: 8),
                ColumnSpec(id: "volume", title: "Volume", width: 150, kind: .number, digits: 2),
                ColumnSpec(id: "quoteVolume", title: "Turnover", width: 150, kind: .number, digits: 0),
                ColumnSpec(id: "trades", title: "Trades", width: 100, kind: .number, digits: 0),
                ColumnSpec(id: "updated", title: "Updated", width: 100, kind: .time),
            ]
        case .depth:
            columns = [
                ColumnSpec(id: "symbol", title: "Pair", width: 100, kind: .text),
                ColumnSpec(id: "side", title: "Side", width: 60, kind: .text),
                ColumnSpec(id: "price", title: "Price", width: 140, kind: .number, digits: 8),
                ColumnSpec(id: "qty", title: "Quantity", width: 130, kind: .number, digits: 5),
                ColumnSpec(id: "amount", title: "Amount", width: 130, kind: .number, digits: 2),
                ColumnSpec(id: "updated", title: "Updated", width: 100, kind: .time),
            ]
        }
        numbers = columns.map { _ in [] }
        texts = columns.map { _ in [] }
        columnIndex = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1.id, $0) })
    }

    /// Tickers by trades, most first; levels by pair, then price, highest first.
    var sort: [SortSpec] {
        switch mode {
        case .tickers: [SortSpec(column: 12, ascending: false)]
        case .depth: [SortSpec(column: 0, ascending: true), SortSpec(column: 2, ascending: false)]
        }
    }

    func number(_ row: Int, _ column: Int) -> Double { numbers[column][row] }
    func text(_ row: Int, _ column: Int) -> String { texts[column][row] }
    func identifier(_ row: Int) -> Int { ids[row] }
    func numberArray(_ column: Int) -> [Double]? { columns[column].kind == .text ? nil : numbers[column] }
    func textArray(_ column: Int) -> [String]? { columns[column].kind == .text ? texts[column] : nil }

    // MARK: Writing

    private func column(_ id: String) -> Int { columnIndex[id]! }

    private func appendRow() -> Int {
        for index in columns.indices {
            if columns[index].kind == .text { texts[index].append("") } else { numbers[index].append(.nan) }
        }
        ids.append(nextID)
        nextID += 1
        rowCount += 1
        engine?.insertRows(rowCount - 1 ..< rowCount)
        return rowCount - 1
    }

    private func write(_ value: Double, _ column: Int, _ row: Int, group: Int) {
        let old = numbers[column][row]
        guard old != value, !(old.isNaN && value.isNaN) else { return }
        numbers[column][row] = value
        note(row, column, group: group)
    }

    private func write(_ text: String, _ column: Int, _ row: Int, group: Int) {
        guard texts[column][row] != text else { return }
        texts[column][row] = text
        note(row, column, group: group)
    }

    private func note(_ row: Int, _ column: Int, group: Int) {
        if pending[group].marks.count < rowCount {
            pending[group].marks.append(contentsOf: repeatElement(false, count: rowCount - pending[group].marks.count))
        }
        if !pending[group].marks[row] {
            pending[group].marks[row] = true
            pending[group].rows.append(row)
        }
        pending[group].columns.insert(column)
    }

    /// Tells the engine which cells changed (at the end of a batch, and before rows move).
    func flushUpdates() {
        for group in pending.indices where !pending[group].rows.isEmpty {
            engine?.reloadRows(pending[group].rows.filter { $0 < rowCount }, columns: pending[group].columns)
            for row in pending[group].rows where row < pending[group].marks.count { pending[group].marks[row] = false }
            pending[group].rows.removeAll(keepingCapacity: true)
            pending[group].columns = []
        }
    }

    func apply(_ ticker: BinanceTicker) {
        guard mode == .tickers else { return }
        let row = rowOfSymbol[ticker.symbol] ?? {
            let row = appendRow()
            rowOfSymbol[ticker.symbol] = row
            write(ticker.symbol, column("symbol"), row, group: 0)
            return row
        }()
        write(ticker.last, column("last"), row, group: 0)
        write(ticker.changePercent / 100, column("change"), row, group: 0)
        write(ticker.high, column("high"), row, group: 0)
        write(ticker.low, column("low"), row, group: 0)
        write(ticker.volume, column("volume"), row, group: 0)
        write(ticker.quoteVolume, column("quoteVolume"), row, group: 0)
        write(ticker.trades, column("trades"), row, group: 0)
        write(Double(ticker.eventTime), column("updated"), row, group: 0)
    }

    func apply(_ book: BinanceBook) {
        guard mode == .tickers, let row = rowOfSymbol[book.symbol] else { return }
        write(book.bid, column("bid"), row, group: 1)
        write(book.bidQuantity, column("bidQty"), row, group: 1)
        write(book.ask, column("ask"), row, group: 1)
        write(book.askQuantity, column("askQty"), row, group: 1)
        let middle = (book.bid + book.ask) / 2
        write(middle > 0 ? (book.ask - book.bid) / middle : .nan, column("spread"), row, group: 1)
    }

    /// Order book levels of a pair: a quantity of 0 removes the level. `time`: µs.
    func apply(levels: [BinanceDepth.Level], isBid: Bool, symbol: String, time: Int64) {
        guard mode == .depth else { return }
        for level in levels {
            let key = LevelKey(symbol: symbol, isBid: isBid, price: level.price.bitPattern)
            if let row = rowOfLevel[key] {
                if level.quantity == 0 {
                    removeLevel(at: row)
                } else {
                    write(level.quantity, column("qty"), row, group: 1)
                    write(level.price * level.quantity, column("amount"), row, group: 1)
                    write(Double(time), column("updated"), row, group: 1)
                }
            } else if level.quantity != 0 {
                let row = appendRow()
                rowOfLevel[key] = row
                levelOfRow.append(key)
                write(symbol, column("symbol"), row, group: 0)
                write(isBid ? "Bid" : "Ask", column("side"), row, group: 0)
                write(level.price, column("price"), row, group: 0)
                write(level.quantity, column("qty"), row, group: 0)
                write(level.price * level.quantity, column("amount"), row, group: 0)
                write(Double(time), column("updated"), row, group: 0)
            }
        }
    }

    /// Every level of a pair goes (its book is loaded again).
    func removeLevels(of symbol: String) {
        let rows = rowOfLevel.filter { $0.key.symbol == symbol }.map(\.value).sorted(by: >)
        for row in rows { removeLevel(at: row) }
    }

    /// The last row takes the level's place (no shift), told to the engine so; the changes
    /// noted so far are told first (their rows move).
    private func removeLevel(at row: Int) {
        flushUpdates()
        let last = rowCount - 1
        rowOfLevel[levelOfRow[row]] = nil
        if row != last {
            levelOfRow[row] = levelOfRow[last]
            rowOfLevel[levelOfRow[row]] = row
            ids[row] = ids[last]
            for index in columns.indices {
                if columns[index].kind == .text { texts[index][row] = texts[index][last] } else { numbers[index][row] = numbers[index][last] }
            }
        }
        levelOfRow.removeLast()
        ids.removeLast()
        for index in columns.indices {
            if columns[index].kind == .text { texts[index].removeLast() } else { numbers[index].removeLast() }
        }
        rowCount -= 1
        engine?.removeRowReplacingWithLast(row)
    }
}

final class BinanceScenario: Scenario {
    let id: ScenarioID
    private let mode: BinanceStore.Mode
    private let store: BinanceStore
    private let domain: String
    private var connections: [BinanceConnection] = []
    private var books: [String: BinanceBookSync] = [:]
    private var fetchingBooks: Set<String> = []
    private var snapshotFetches = 0
    private var lastError: String?
    private var isStopped = false
    static let bookSymbols = ["btcusdt", "ethusdt", "solusdt", "bnbusdt", "xrpusdt", "dogeusdt"]
    var source: BenchSource { store }
    var sort: [SortSpec] { store.sort }

    init(id: ScenarioID, mode: BinanceStore.Mode, domain: String) {
        self.id = id
        self.mode = mode
        self.domain = domain
        store = BinanceStore(mode: mode)
    }

    var subtitle: String {
        switch mode {
        case .tickers: "\(store.rowCount.formatted()) Binance pairs, live · sorted by trades · numbers vary with the market"
        case .depth: "\(store.rowCount.formatted()) order book levels of 6 Binance pairs, live · sorted by pair and price"
        }
    }

    private func streamURL(_ streams: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "stream.\(domain)"
        components.port = 9443
        components.path = "/stream"
        var query = [URLQueryItem(name: "timeUnit", value: "MICROSECOND")]
        if !streams.isEmpty { query.insert(URLQueryItem(name: "streams", value: streams.joined(separator: "/")), at: 0) }
        components.queryItems = query
        return components.url
    }

    private func restURL(_ path: String, _ query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.\(domain)"
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url
    }

    private func fetch(_ url: URL?) async throws -> Data {
        guard let url else { throw ScenarioError("bad URL") }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").map { " (retry after \($0) s)" } ?? ""
            throw ScenarioError("\(url.host ?? "")\(url.path): HTTP \(http.statusCode)\(retry) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return data
    }

    /// Binance allows 6,000 request weight a minute per IP; going over gets the IP banned for
    /// minutes (then longer). A depth snapshot of 5,000 levels weighs 250, so six books weigh
    /// 1,500 and back-to-back runs would go over: before its requests a run reads the weight
    /// used this minute (`X-MBX-USED-WEIGHT-1M` of a ping, weight 1) and waits for the next
    /// minute when its requests wouldn't fit under 4,800.
    private func waitForRequestWeight(_ needed: Int) async throws {
        guard let url = restURL("/api/v3/ping") else { return }
        for _ in 0..<4 {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 418 || http.statusCode == 429 {
                let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                guard retry <= 180 else { throw ScenarioError("Binance limits this IP for \(Int(retry)) s (too many requests)") }
                try await Task.sleep(for: .seconds(retry + 1))
                continue
            }
            let used = Int(http.value(forHTTPHeaderField: "x-mbx-used-weight-1m") ?? "") ?? 0
            if used + needed <= 4_800 { return }
            let wait = 61 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
            try await Task.sleep(for: .seconds(wait))
        }
    }

    private func open(_ streams: [String], subscribing more: [String] = []) {
        guard let url = streamURL(streams) else { return }
        let connection = BinanceConnection(url: url)
        connections.append(connection)
        connection.start()
        if !more.isEmpty { connection.subscribe(more) }
    }

    /// Connects and loads until the rows are there: every pair's ticker (and its streams
    /// subscribed), or every book in step with its snapshot.
    func prepare() async throws {
        switch mode {
        case .tickers:
            try await waitForRequestWeight(100)
            let tickers = try BinanceDecoder.miniTickers(try await fetch(restURL("/api/v3/ticker/24hr", ["type": "MINI"])))
            for ticker in tickers { store.apply(ticker) }
            let books = try BinanceDecoder.bookTickers(try await fetch(restURL("/api/v3/ticker/bookTicker")))
            for book in books { store.apply(book) }
            store.flushUpdates()
            open(["!ticker_1d@arr"])
            let streams = tickers.map { $0.symbol.lowercased() + "@bookTicker" }
            for start in stride(from: 0, to: streams.count, by: BinanceConnection.streamLimit - 1) {
                open([], subscribing: Array(streams[start..<min(streams.count, start + BinanceConnection.streamLimit - 1)]))
            }
            // The subscriptions go out 200 streams every 260 ms, per connection.
            let perConnection = min(streams.count, BinanceConnection.streamLimit - 1)
            let seconds = Double(perConnection / BinanceConnection.subscribeChunk + 1) * 0.26 + 1
            try await pump(for: seconds)
        case .depth:
            try await waitForRequestWeight(250 * Self.bookSymbols.count + 250)
            for symbol in Self.bookSymbols { books[symbol.uppercased()] = BinanceBookSync() }
            open(Self.bookSymbols.map { "\($0)@depth@100ms" })
            for symbol in Self.bookSymbols { fetchBook(symbol.uppercased()) }
            let deadline = Date().addingTimeInterval(45)
            while !books.values.allSatisfy(\.isSynced) {
                if let lastError { throw ScenarioError(lastError) }
                guard Date() < deadline else { throw ScenarioError("the order books didn't load in 45 s") }
                try await pump(for: 0.1)
            }
            try await pump(for: 1)
        }
        if store.rowCount == 0 { throw ScenarioError(lastError ?? "no rows from Binance") }
    }

    /// Applies what comes (no engine yet) for a while.
    private func pump(for seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            _ = applyPending(to: nil)
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func fetchBook(_ symbol: String) {
        guard !fetchingBooks.contains(symbol), !isStopped else { return }
        fetchingBooks.insert(symbol)
        snapshotFetches += 1
        let isAgain = snapshotFetches > Self.bookSymbols.count
        Task {
            do {
                // (A book fetched again, out of step: the weight checked first.)
                if isAgain { try await waitForRequestWeight(250) }
                let snapshot = try BinanceDecoder.snapshot(try await fetch(restURL("/api/v3/depth", ["symbol": symbol, "limit": "5000"])))
                fetchingBooks.remove(symbol)
                guard var sync = books[symbol] else { return }
                let outcome = sync.snapshot(lastUpdateID: snapshot.lastUpdateID)
                books[symbol] = sync
                switch outcome {
                case .fetchAgain, .broken:
                    fetchBook(symbol)
                case .apply(let changes):
                    let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
                    let engine = store.engine
                    engine?.beginUpdates()
                    store.removeLevels(of: symbol)
                    store.apply(levels: snapshot.bids, isBid: true, symbol: symbol, time: now)
                    store.apply(levels: snapshot.asks, isBid: false, symbol: symbol, time: now)
                    for change in changes { apply(change) }
                    store.flushUpdates()
                    engine?.endUpdates()
                }
            } catch {
                fetchingBooks.remove(symbol)
                lastError = "\(symbol) snapshot: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ change: BinanceDepth) {
        store.apply(levels: change.bids, isBid: true, symbol: change.symbol, time: change.eventTime)
        store.apply(levels: change.asks, isBid: false, symbol: change.symbol, time: change.eventTime)
    }

    func stop() {
        isStopped = true
        for connection in connections { connection.close() }
        connections = []
    }

    func applyPending(to engine: Engine?) -> Int {
        var messages: [BinanceMessage] = []
        for connection in connections { messages += connection.take().messages }
        guard !messages.isEmpty else { return 0 }
        store.engine = engine
        engine?.beginUpdates()
        var changes = 0
        for message in messages {
            switch message {
            case .tickers(let tickers):
                for ticker in tickers { store.apply(ticker) }
                changes += tickers.count
            case .book(let book):
                store.apply(book)
                changes += 1
            case .trade:
                break
            case .depth(let change):
                guard var sync = books[change.symbol] else { continue }
                let outcome = sync.receive(change)
                books[change.symbol] = sync
                switch outcome {
                case .apply(let changed):
                    for change in changed {
                        apply(change)
                        changes += change.bids.count + change.asks.count
                    }
                case .broken, .fetchAgain: fetchBook(change.symbol)
                }
            case .reply:
                break
            case .error(let text):
                lastError = "Binance: \(text)"
            case .closed(let reason):
                lastError = "connection closed: \(reason)"
            }
        }
        store.flushUpdates()
        engine?.endUpdates()
        return changes
    }
}
