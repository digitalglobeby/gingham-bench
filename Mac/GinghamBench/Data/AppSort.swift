//
//  AppSort.swift
//  Gingham Bench
//
//  How the apps of NSTableView, NSCollectionView and SwiftUI's Table sort, since those tables
//  leave sorting to the app:
//
//  - `AppSort.order`: what an app typically writes, the whole order sorted again with a
//    comparator over the store's values (numbers read from the store's arrays, text compared
//    with `localizedStandardCompare`, Finder's order). Used by the "NSTableView" engine.
//  - `LiveOrder`: what an expert writes for live data. Each row's sort key is computed once
//    and kept (numbers as they are, text as its rank among the column's distinct texts, so
//    rows compare by Doubles); after a batch only the rows whose keys changed are taken out
//    and merged back into the order (O(rows + changed × log changed), not a full sort). A full
//    sort of a static table runs on all cores in the background (`ParallelSort`) while the
//    table keeps showing the old order. Used by "NSTableView, tuned" and "NSCollectionView".
//

import Foundation

/// A sort column's values, read from the store's arrays (on the main thread) for a sort that
/// runs without touching the store.
nonisolated enum SortColumn: Sendable {
    case numbers([Double], ascending: Bool)
    case texts([String], ascending: Bool)
}

enum AppSort {
    /// The rows in `sort`'s order (none: the store's), sorted from scratch.
    static func order(of source: BenchSource, by sort: [SortSpec]) -> [Int] {
        guard !sort.isEmpty else { return Array(0..<source.rowCount) }
        return AppSortWork.order(count: source.rowCount, by: columns(of: source, sort: sort))
    }

    static func columns(of source: BenchSource, sort: [SortSpec]) -> [SortColumn] {
        // (Every store keeps its columns as arrays: `ColumnArrays`.)
        let arrays = source as? ColumnArrays
        var columns: [SortColumn] = []
        for spec in sort {
            if source.columns[spec.column].kind == .text {
                columns.append(.texts(arrays?.textArray(spec.column) ?? [], ascending: spec.ascending))
            } else {
                columns.append(.numbers(arrays?.numberArray(spec.column) ?? [], ascending: spec.ascending))
            }
        }
        return columns
    }
}

/// The sorting itself, outside the main actor: a comparator made in a main-actor function
/// checks that it runs on the main thread on every call (Swift 6's dynamic isolation checks,
/// `swift_task_isCurrentExecutor`), which costs more than the comparison. Hot closures and loops
/// of the app-side engines live in `nonisolated` helpers like this one; `Scripts/check-isolation.sh`
/// checks the Release binary for it.
nonisolated enum AppSortWork {
    /// The rows sorted by the columns, as a typical app's comparator does: numbers by value
    /// (empty first), text in Finder's order (`localizedStandardCompare`).
    static func order(count: Int, by columns: [SortColumn]) -> [Int] {
        var order = Array(0..<count)
        if columns.count == 1, case .numbers(let keys, let ascending) = columns[0] {
            // One numeric column (the live scenarios): its array read directly, as an app's
            // comparator reads a property of its model.
            order.sort { a, b in
                let x = keys[a], y = keys[b]
                if x.isNaN || y.isNaN { return ascending ? (x.isNaN && !y.isNaN) : (y.isNaN && !x.isNaN) }
                return ascending ? x < y : x > y
            }
            return order
        }
        if columns.count == 1, case .texts(let texts, let ascending) = columns[0] {
            order.sort { a, b in
                let result = texts[a].localizedStandardCompare(texts[b])
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            return order
        }
        order.sort { a, b in compare(a, b, columns) == .orderedAscending }
        return order
    }

    static func compare(_ a: Int, _ b: Int, _ columns: [SortColumn]) -> ComparisonResult {
        for column in columns {
            var result: ComparisonResult
            var ascending = true
            switch column {
            case .texts(let texts, let up):
                result = texts[a].localizedStandardCompare(texts[b])
                ascending = up
            case .numbers(let values, let up):
                let x = values[a], y = values[b]
                result = x.isNaN ? (y.isNaN ? .orderedSame : .orderedAscending) : y.isNaN ? .orderedDescending
                    : x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
                ascending = up
            }
            if !ascending { result = ComparisonResult(rawValue: -result.rawValue)! }
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}

/// A store whose columns are arrays (every store here): sorts read them without a call per value.
protocol ColumnArrays {
    func numberArray(_ column: Int) -> [Double]?
    func textArray(_ column: Int) -> [String]?
}

/// The order of rows sorted by the app, kept up to date by placing only the changed rows.
final class LiveOrder {
    /// Display row → store row.
    private(set) var order: [Int] = []
    /// Store row → display row (-1: waiting to be placed).
    private var position: [Int] = []
    let sort: [SortSpec]
    /// Each sort column's key of each store row (descending columns negated): rows compare by
    /// these Doubles, then by their identity.
    private var keys: [[Double]]
    private var identity: [Int] = []
    /// Text columns: each distinct text's rank (fractional, so a new text goes between two
    /// without the others' ranks changing), and the distinct texts in order.
    private var ranks: [[String: Double]]
    private var rankedTexts: [[String]]
    /// Rows to place at the end of the batch, marked once.
    private var pending: [Int] = []
    private var isPending: [Bool] = []
    private var removedSlots = 0

    var columns: Set<Int> { Set(sort.map(\.column)) }

    /// The rows sorted. With `parallel`, the keys of text columns are ranked and the rows
    /// sorted on all cores (call it off the main thread for a static store: see `make`).
    /// `identity` empty: the rows' indexes are their identity (a static store).
    nonisolated init(sort: [SortSpec], columns: [ColumnSpec], numbers: [[Double]?], texts: [[String]?], identity: [Int], count: Int) {
        self.sort = sort
        self.identity = identity
        keys = []
        ranks = []
        rankedTexts = []
        for spec in sort {
            let sign = spec.ascending ? 1.0 : -1.0
            if columns[spec.column].kind == .text, let texts = texts[spec.column] {
                let (distinct, rankOf) = Self.rank(texts)
                ranks.append(rankOf)
                rankedTexts.append(distinct)
                keys.append(ParallelSort.map(count) { row in sign * rankOf[texts[row]]! })
            } else {
                ranks.append([:])
                rankedTexts.append([])
                let values = numbers[spec.column] ?? []
                keys.append(values.map { $0.isNaN ? -sign * .infinity : sign * $0 })
            }
        }
        var order = Array(0..<count)
        let keys = keys, ids = identity
        ParallelSort.sort(&order) { a, b in Self.less(a, b, keys: keys, identity: ids) }
        self.order = order
        position = [Int](repeating: 0, count: count)
        for (display, row) in order.enumerated() { position[row] = display }
        isPending = [Bool](repeating: false, count: count)
    }

    /// A source's rows sorted: in the background for a static store (the table keeps showing
    /// the old order meanwhile), on the main thread for a live one (its rows change under it).
    static func make(_ source: BenchSource, sort: [SortSpec]) async -> LiveOrder {
        let columns = source.columns
        let arrays = source as? ColumnArrays
        let numbers = columns.indices.map { column in sort.contains { $0.column == column } ? arrays?.numberArray(column) : nil }
        let texts = columns.indices.map { column in sort.contains { $0.column == column } ? arrays?.textArray(column) : nil }
        let count = source.rowCount
        if source.isStatic {
            // (A static store's rows are their identity: nothing to read on the main thread.)
            return await Task.detached(priority: .userInitiated) {
                LiveOrder(sort: sort, columns: columns, numbers: numbers, texts: texts, identity: [], count: count)
            }.value
        }
        return LiveOrder(sort: sort, columns: columns, numbers: numbers, texts: texts, identity: (0..<count).map(source.identifier), count: count)
    }

    static func makeNow(_ source: BenchSource, sort: [SortSpec]) -> LiveOrder {
        let columns = source.columns
        let arrays = source as? ColumnArrays
        let numbers = columns.indices.map { column in sort.contains { $0.column == column } ? arrays?.numberArray(column) : nil }
        let texts = columns.indices.map { column in sort.contains { $0.column == column } ? arrays?.textArray(column) : nil }
        return LiveOrder(sort: sort, columns: columns, numbers: numbers, texts: texts,
                         identity: source.isStatic ? [] : (0..<source.rowCount).map(source.identifier), count: source.rowCount)
    }

    /// The order without the moving rows (and removed places), with the moving rows merged in.
    nonisolated private static func merge(order: [Int], moving: [Int], isPending: [Bool], keys: [[Double]], identity: [Int]) -> [Int] {
        var moving = moving
        moving.sort { less($0, $1, keys: keys, identity: identity) }
        var merged: [Int] = []
        merged.reserveCapacity(order.count + moving.count)
        var next = 0
        for row in order where row >= 0 && !isPending[row] {
            while next < moving.count, less(moving[next], row, keys: keys, identity: identity) {
                merged.append(moving[next])
                next += 1
            }
            merged.append(row)
        }
        merged.append(contentsOf: moving[next...])
        return merged
    }

    nonisolated private static func less(_ a: Int, _ b: Int, keys: [[Double]], identity: [Int]) -> Bool {
        for column in keys {
            let x = column[a], y = column[b]
            if x != y { return x < y }
        }
        return identity.isEmpty ? a < b : identity[a] < identity[b]
    }

    /// The distinct texts in Finder's order and each one's rank, sorted on all cores.
    nonisolated private static func rank(_ texts: [String]) -> ([String], [String: Double]) {
        var seen = Set<String>(minimumCapacity: 1024)
        var distinct: [NSString] = []
        for text in texts where seen.insert(text).inserted { distinct.append(text as NSString) }
        // On one thread: `localizedStandardCompare` doesn't scale across cores (measured: 4 threads
        // 1.2 times faster than one, 8 slower than one; the comparisons contend for a lock).
        var indexes = Array(distinct.indices)
        indexes.sort { a, b in distinct[a].localizedStandardCompare(distinct[b] as String) == .orderedAscending }
        var rankOf = [String: Double](minimumCapacity: distinct.count)
        var sorted: [String] = []
        sorted.reserveCapacity(distinct.count)
        for (rank, index) in indexes.enumerated() {
            let text = distinct[index] as String
            rankOf[text] = Double(rank)
            sorted.append(text)
        }
        return (sorted, rankOf)
    }

    // MARK: Changes

    private func key(for row: Int, spec index: Int, source: BenchSource) -> Double {
        let spec = sort[index]
        let sign = spec.ascending ? 1.0 : -1.0
        if source.columns[spec.column].kind == .text {
            let text = source.text(row, spec.column)
            if let rank = ranks[index][text] { return sign * rank }
            // A new text: between its neighbors in Finder's order.
            let texts = rankedTexts[index]
            var low = 0, high = texts.count
            while low < high {
                let middle = (low + high) / 2
                if texts[middle].localizedStandardCompare(text) == .orderedAscending { low = middle + 1 } else { high = middle }
            }
            let before = low > 0 ? ranks[index][texts[low - 1]]! : (texts.isEmpty ? 0 : ranks[index][texts[0]]! - 2)
            let after = low < texts.count ? ranks[index][texts[low]]! : before + 2
            let rank = (before + after) / 2
            rankedTexts[index].insert(text, at: low)
            ranks[index][text] = rank
            return sign * rank
        }
        let value = source.number(row, spec.column)
        return value.isNaN ? -sign * .infinity : sign * value
    }

    private func markPending(_ row: Int) {
        if !isPending[row] {
            isPending[row] = true
            pending.append(row)
        }
    }

    /// Rows added at the end of the store.
    func rowsInserted(_ rows: Range<Int>, source: BenchSource) {
        for row in rows {
            position.append(-1)
            isPending.append(false)
            if !identity.isEmpty || row == 0 { identity.append(source.identifier(row)) }
            for index in keys.indices { keys[index].append(key(for: row, spec: index, source: source)) }
            markPending(row)
        }
    }

    /// The store removed `row` and moved its last row there. (`pending` may keep stale entries:
    /// `placePending` takes only rows still marked.)
    func rowRemovedReplacingWithLast(_ row: Int) {
        let last = position.count - 1
        if position[row] >= 0 {
            order[position[row]] = -1
            removedSlots += 1
        }
        if row != last {
            // The last row's record is at `row` now, with its keys and its place.
            position[row] = position[last]
            if position[row] >= 0 { order[position[row]] = row }
            for index in keys.indices { keys[index][row] = keys[index][last] }
            if !identity.isEmpty { identity[row] = identity[last] }
            isPending[row] = isPending[last]
            if isPending[row] { pending.append(row) }
        }
        position.removeLast()
        isPending.removeLast()
        if !identity.isEmpty { identity.removeLast() }
        for index in keys.indices { keys[index].removeLast() }
    }

    /// These rows' values changed in `columns`: re-placed if a sort column is among them.
    func rowsChanged(_ rows: [Int], columns changed: IndexSet, source: BenchSource) {
        var specs: [Int] = []
        for index in sort.indices where changed.contains(sort[index].column) { specs.append(index) }
        guard !specs.isEmpty else { return }
        for row in rows where row < position.count {
            var moved = false
            for index in specs {
                let key = key(for: row, spec: index, source: source)
                if keys[index][row] != key {
                    keys[index][row] = key
                    moved = true
                }
            }
            if moved { markPending(row) }
        }
    }

    /// The changed rows taken out and merged back in their places. Whether the order changed.
    @discardableResult
    func placePending() -> Bool {
        guard !pending.isEmpty || removedSlots > 0 else { return false }
        // The rows still marked, once each.
        var moving: [Int] = []
        moving.reserveCapacity(pending.count)
        for row in pending where row < isPending.count && isPending[row] {
            isPending[row] = false
            moving.append(row)
        }
        for row in moving { isPending[row] = true }
        let merged = Self.merge(order: order, moving: moving, isPending: isPending, keys: keys, identity: identity)
        order = merged
        for (display, row) in order.enumerated() { position[row] = display }
        for row in moving { isPending[row] = false }
        pending.removeAll(keepingCapacity: true)
        removedSlots = 0
        return true
    }
}

/// A merge sort on all cores: chunks sorted at once, then merged in pairs at once.
nonisolated enum ParallelSort {
    static func chunks(_ count: Int) -> Int {
        count < 50_000 ? 1 : ProcessInfo.processInfo.activeProcessorCount * 2
    }

    static func range(_ chunk: Int, of count: Int) -> Range<Int> {
        let chunks = chunks(count)
        return count * chunk / chunks ..< count * (chunk + 1) / chunks
    }

    /// `body` of each index, on all cores.
    static func map(_ count: Int, _ body: (Int) -> Double) -> [Double] {
        var result = [Double](repeating: 0, count: count)
        withoutActuallyEscaping(body) { body in
            nonisolated(unsafe) let body = body
            result.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let base = buffer
                DispatchQueue.concurrentPerform(iterations: chunks(count)) { chunk in
                    for index in range(chunk, of: count) { base[index] = body(index) }
                }
            }
        }
        return result
    }

    static func sort(_ values: inout [Int], by less: (Int, Int) -> Bool) {
        let count = values.count
        let chunks = chunks(count)
        guard chunks > 1 else {
            values.sort(by: less)
            return
        }
        withoutActuallyEscaping(less) { less in
            nonisolated(unsafe) let less = less
            values.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let base = buffer
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let part = range(chunk, of: count)
                    var slice = UnsafeMutableBufferPointer(rebasing: base[part])
                    slice.sort(by: less)
                }
                var runs = (0..<chunks).map { range($0, of: count) }
                var scratch = [Int](repeating: 0, count: count)
                scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                    nonisolated(unsafe) var from = base, to = scratchBuffer
                    while runs.count > 1 {
                        let pairs = runs.count / 2
                        nonisolated(unsafe) let (source, target) = (from, to)
                        let current = runs
                        DispatchQueue.concurrentPerform(iterations: pairs) { pair in
                            let left = current[2 * pair], right = current[2 * pair + 1]
                            var i = left.lowerBound, j = right.lowerBound, k = left.lowerBound
                            while i < left.upperBound, j < right.upperBound {
                                if less(source[j], source[i]) { target[k] = source[j]; j += 1 } else { target[k] = source[i]; i += 1 }
                                k += 1
                            }
                            while i < left.upperBound { target[k] = source[i]; i += 1; k += 1 }
                            while j < right.upperBound { target[k] = source[j]; j += 1; k += 1 }
                        }
                        var next = (0..<pairs).map { current[2 * $0].lowerBound ..< current[2 * $0 + 1].upperBound }
                        if current.count % 2 == 1, let last = current.last {
                            for k in last { target[k] = source[k] }
                            next.append(last)
                        }
                        runs = next
                        swap(&from, &to)
                    }
                    if from.baseAddress != base.baseAddress {
                        for k in 0..<count { base[k] = from[k] }
                    }
                }
            }
        }
    }
}
