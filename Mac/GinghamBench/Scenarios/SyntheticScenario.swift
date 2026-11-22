//
//  SyntheticScenario.swift
//  Gingham Bench
//
//  The generated live scenarios (live trades, order book, trade feed): `FeedStore` keeps the
//  rows by column on the main thread and is every engine's data source; once per screen frame
//  the changes the generator made since the last frame are applied in one batch, in the order
//  they were made, telling the engine about each: rows removed (the last row moved into the
//  place), rows added at the end, and the changed cells, reported together before a removal
//  and at the end of the batch (rows that changed a sort column apart from the others, so a
//  sorted table re-places only those).
//

import AppKit

final class FeedStore: BenchSource, ColumnArrays {
    let model: FeedModel
    let columns: [ColumnSpec]
    private(set) var rowCount = 0
    /// Columns: numbers (the other kind's array empty), text.
    private var numbers: [[Double]]
    private var texts: [[String]]
    private var keys: [Int] = []
    private let isText: [Bool]
    /// Updates not yet told to the engine.
    private var pendingRows: [Int] = []
    private var pendingMasks: [UInt64] = []

    init(model: FeedModel) {
        self.model = model
        columns = model.columns
        isText = columns.map { $0.kind == .text }
        numbers = columns.map { _ in [] }
        texts = columns.map { _ in [] }
    }

    func number(_ row: Int, _ column: Int) -> Double { numbers[column][row] }
    func text(_ row: Int, _ column: Int) -> String { texts[column][row] }
    func identifier(_ row: Int) -> Int { keys[row] }
    func numberArray(_ column: Int) -> [Double]? { isText[column] ? nil : numbers[column] }
    func textArray(_ column: Int) -> [String]? { isText[column] ? texts[column] : nil }

    /// The generator's rows as they are.
    func load(cells: [Double], count: Int) {
        let width = columns.count
        for column in columns.indices {
            if isText[column] {
                texts[column] = (0..<count).map { model.text(column: column, code: cells[$0 * width + column]) }
            } else {
                numbers[column] = (0..<count).map { cells[$0 * width + column] }
            }
        }
        keys = (0..<count).map { Int(cells[$0 * width]) }
        rowCount = count
    }

    private func write(_ values: ArraySlice<Double>, row: Int, mask: UInt64) {
        var bits = mask
        let start = values.startIndex
        while bits != 0 {
            let column = bits.trailingZeroBitCount
            bits &= bits - 1
            if isText[column] {
                texts[column][row] = model.text(column: column, code: values[start + column])
            } else {
                numbers[column][row] = values[start + column]
            }
        }
    }

    /// A batch applied; the number of row changes.
    func apply(_ batch: FeedBatch, engine: Engine?) -> Int {
        guard !batch.isEmpty else { return 0 }
        let width = columns.count
        var valueIndex = 0
        var insertedFrom: Int?
        func flushInserts() {
            if let first = insertedFrom, first < rowCount { engine?.insertRows(first..<rowCount) }
            insertedFrom = nil
        }
        for index in 0..<batch.count {
            let row = Int(batch.rows[index])
            switch batch.kinds[index] {
            case .delete:
                flushInserts()
                flushUpdates(engine: engine)
                removeRow(row)
                engine?.removeRowReplacingWithLast(row)
            case .insert:
                let values = batch.values[valueIndex ..< valueIndex + width]
                valueIndex += width
                if insertedFrom == nil { insertedFrom = rowCount }
                for column in columns.indices {
                    if isText[column] {
                        texts[column].append(model.text(column: column, code: values[values.startIndex + column]))
                    } else {
                        numbers[column].append(values[values.startIndex + column])
                    }
                }
                keys.append(Int(values[values.startIndex]))
                rowCount += 1
            case .update:
                flushInserts()
                write(batch.values[valueIndex ..< valueIndex + width], row: row, mask: batch.masks[index])
                valueIndex += width
                pendingRows.append(row)
                pendingMasks.append(batch.masks[index])
            }
        }
        flushInserts()
        flushUpdates(engine: engine)
        return batch.count
    }

    private func removeRow(_ row: Int) {
        let last = rowCount - 1
        for column in columns.indices {
            if isText[column] {
                if row != last { texts[column][row] = texts[column][last] }
                texts[column].removeLast()
            } else {
                if row != last { numbers[column][row] = numbers[column][last] }
                numbers[column].removeLast()
            }
        }
        if row != last { keys[row] = keys[last] }
        keys.removeLast()
        rowCount -= 1
    }

    /// The changed cells told at once: rows that changed a sort column, then the others, each
    /// group with the columns any of its rows changed.
    private func flushUpdates(engine: Engine?) {
        guard !pendingRows.isEmpty else { return }
        defer {
            pendingRows.removeAll(keepingCapacity: true)
            pendingMasks.removeAll(keepingCapacity: true)
        }
        guard let engine else { return }
        var sortMask: UInt64 = 0
        for column in engine.sortColumns { sortMask |= 1 << UInt64(column) }
        var groups: [(mask: UInt64, rows: [Int])] = [(0, []), (0, [])]
        for (row, mask) in zip(pendingRows, pendingMasks) {
            let group = mask & sortMask != 0 ? 0 : 1
            groups[group].mask |= mask
            groups[group].rows.append(row)
        }
        for (mask, rows) in groups where !rows.isEmpty {
            var columns = IndexSet()
            var bits = mask
            while bits != 0 {
                columns.insert(bits.trailingZeroBitCount)
                bits &= bits - 1
            }
            engine.reloadRows(rows, columns: columns)
        }
    }
}

final class SyntheticScenario: Scenario {
    let id: ScenarioID
    private let model: FeedModel
    private let store: FeedStore
    private let rows: Int
    private var pump: FeedPump?
    let sort: [SortSpec]
    var source: BenchSource { store }

    init(id: ScenarioID, model: FeedModel, sortByAmount: Bool, rows: Int?) {
        self.id = id
        self.model = model
        self.rows = rows ?? model.rows
        store = FeedStore(model: model)
        sort = sortByAmount ? [SortSpec(column: 5, ascending: false)] : []
    }

    /// The rate the model generates (row changes a second, before merging a row's changes
    /// within a tick); the subtitle shows what was measured.
    var nominalChanges: Int {
        switch model {
        case .trades: 45_000
        case .orders: 244_000
        case .instruments: 300_000
        }
    }

    var subtitle: String {
        let what: String
        switch model {
        case .trades: what = "trades sorted by amount"
        case .orders: what = "orders"
        case .instruments: what = "instruments, 23 columns"
        }
        return "\(rows.formatted()) \(what) · about \(nominalChanges.formatted()) changes a second"
    }

    func prepare() async throws {
        let model = model, rows = rows
        let generator = await Task.detached(priority: .userInitiated) { FeedGenerator(model: model, rows: rows) }.value
        store.load(cells: generator.cells, count: generator.count)
        pump = FeedPump(generator: generator, changesPerSecond: nominalChanges)
    }

    func start() { pump?.start() }
    func stop() { pump?.stop() }

    func applyPending(to engine: Engine?) -> Int {
        guard let pump else { return 0 }
        let batch = pump.take()
        guard !batch.isEmpty else { return 0 }
        engine?.beginUpdates()
        let changes = store.apply(batch, engine: engine)
        engine?.endUpdates()
        return changes
    }
}
