//
//  TunedRows.swift
//  Gingham Bench
//
//  The bookkeeping of the tuned AppKit engines ("NSTableView, tuned" and "NSCollectionView"):
//  the app's order of the rows when sorted (`LiveOrder`: only changed rows re-placed), and,
//  at the end of each batch, exactly which cells in view show something else now, so that the
//  engine updates those cells in place and nothing more:
//
//  - unsorted: the changed rows in view, only their changed columns; a row that got another
//    record (the store moved its last row there) in every column;
//  - sorted: each place in view whose record changed (rows moved) in every column, and places
//    whose record stayed but changed values in the changed columns.
//

import Foundation

final class TunedRows {
    private(set) var source: BenchSource?
    private(set) var liveOrder: LiveOrder?
    private(set) var sortSpecs: [SortSpec] = []
    private var countAtBegin = 0
    /// The records in view when the batch began (sorted).
    private var visibleBefore: [Int] = []
    private var visibleRangeBefore = 0..<0
    /// Store rows changed in the batch, marked once, and the columns any of them changed.
    private var changedMark: [Bool] = []
    private var changed: [Int] = []
    private var changedColumns = IndexSet()
    /// Rows that got another record.
    private var replaced = Set<Int>()
    /// A background sort's number: a newer request makes an older result stale.
    private var sortGeneration = 0
    private(set) var isSorting = false
    /// The keys of the last sorted columns of a static store (see `SortKeyCache`).
    private let sortKeys = SortKeyCache()

    var count: Int { source?.rowCount ?? 0 }
    var isSorted: Bool { liveOrder != nil }
    var allColumns: IndexSet { IndexSet(integersIn: 0..<(source?.columns.count ?? 0)) }

    func load(_ source: BenchSource, sort: [SortSpec]) {
        self.source = source
        sortSpecs = sort
        liveOrder = sort.isEmpty ? nil : LiveOrder.makeNow(source, sort: sort)
        changedMark = [Bool](repeating: false, count: source.rowCount)
    }

    func sourceRow(atDisplay index: Int) -> Int {
        guard let liveOrder else { return index }
        return index < liveOrder.order.count ? liveOrder.order[index] : -1
    }

    // MARK: A batch

    func begin(visible: Range<Int>) {
        countAtBegin = count
        if let liveOrder {
            visibleRangeBefore = visible.clamped(to: 0..<liveOrder.order.count)
            visibleBefore = Array(liveOrder.order[visibleRangeBefore])
        }
    }

    /// Times the store's changes didn't match the rows this side knows (a change the engine
    /// wasn't told about): the rows are then rebuilt from the store at the end of the batch, and
    /// the run's order check reports it, rather than an index out of range.
    private(set) var desyncs = 0
    private var lostStep = false

    private func loseStep() {
        if !lostStep { desyncs += 1 }
        lostStep = true
    }

    func insertRows(_ rows: Range<Int>) {
        guard !lostStep else { return }
        // The rows come at the end: right after the rows known so far, and the store has them.
        guard rows.lowerBound == changedMark.count, let source, rows.upperBound <= source.rowCount else { return loseStep() }
        changedMark.append(contentsOf: repeatElement(false, count: rows.count))
        liveOrder?.rowsInserted(rows, source: source)
    }

    func removeRowReplacingWithLast(_ row: Int) {
        guard !lostStep else { return }
        // The store has removed it already: one row fewer than known, `row` among them.
        guard let source, source.rowCount == changedMark.count - 1, row >= 0, row <= source.rowCount else { return loseStep() }
        let last = changedMark.count - 1
        if row != last {
            changedMark[row] = changedMark[last]
            if changedMark[row] { changed.append(row) }
            replaced.insert(row)
        }
        changedMark.removeLast()
        liveOrder?.rowRemovedReplacingWithLast(row)
    }

    func reloadRows(_ rows: [Int], columns: IndexSet) {
        guard let source, !lostStep else { return }
        changedColumns.formUnion(columns)
        for row in rows where row < changedMark.count && !changedMark[row] {
            changedMark[row] = true
            changed.append(row)
        }
        liveOrder?.rowsChanged(rows, columns: columns, source: source)
    }

    /// A place in view to update: its display row, the store row it shows, and whether every
    /// column changed (else only `Ended.columns`).
    struct Refresh {
        let display: Int
        let row: Int
        let allColumns: Bool
    }

    struct Ended {
        /// The rows were rebuilt from the store (they had lost step): reload everything.
        var reloadAll = false
        var countChanged: Bool
        var refreshes: [Refresh]
        /// The columns that changed in the rows that kept their place.
        var columns: IndexSet
    }

    /// At the end of the batch: whether the number of rows changed, and the places in view to
    /// update. (Loops, no closures: see `AppSortWork`.)
    func end(visible: Range<Int>) -> Ended {
        if lostStep, let source {
            lostStep = false
            liveOrder = sortSpecs.isEmpty ? nil : LiveOrder.makeNow(source, sort: sortSpecs)
            changedMark = [Bool](repeating: false, count: source.rowCount)
            changed.removeAll(keepingCapacity: true)
            replaced.removeAll(keepingCapacity: true)
            changedColumns = []
            return Ended(reloadAll: true, countChanged: true, refreshes: [], columns: [])
        }
        var ended = Ended(countChanged: count != countAtBegin, refreshes: [], columns: changedColumns)
        if let liveOrder {
            liveOrder.placePending()
            let order = liveOrder.order
            let range = visible.clamped(to: 0..<order.count)
            for display in range {
                let row = order[display]
                let before = display - visibleRangeBefore.lowerBound
                if display >= visibleRangeBefore.lowerBound, before < visibleBefore.count, visibleBefore[before] == row,
                   !replaced.contains(row) {
                    if changedMark[row] { ended.refreshes.append(Refresh(display: display, row: row, allColumns: false)) }
                } else {
                    ended.refreshes.append(Refresh(display: display, row: row, allColumns: true))
                }
            }
        } else {
            for row in changed where row < count && visible.contains(row) && !replaced.contains(row) {
                ended.refreshes.append(Refresh(display: row, row: row, allColumns: false))
            }
            for row in replaced where row < count && visible.contains(row) {
                ended.refreshes.append(Refresh(display: row, row: row, allColumns: true))
            }
        }
        for row in changed where row < changedMark.count { changedMark[row] = false }
        changed.removeAll(keepingCapacity: true)
        replaced.removeAll(keepingCapacity: true)
        changedColumns = []
        return ended
    }

    // MARK: Sorting

    /// Sorted as asked: at once for a live store (its rows change under a background sort), in
    /// the background on all cores for a static one; `done` runs on the main thread when the
    /// new order is in place.
    func sort(by sort: [SortSpec], done: @escaping () -> Void) {
        guard let source else { return }
        sortSpecs = sort
        sortGeneration += 1
        guard !sort.isEmpty else {
            liveOrder = nil
            isSorting = false
            done()
            return
        }
        guard source.isStatic else {
            liveOrder = LiveOrder.makeNow(source, sort: sort)
            done()
            return
        }
        let generation = sortGeneration
        isSorting = true
        Task { @MainActor in
            let order = await LiveOrder.make(source, sort: sort, cache: self.sortKeys)
            guard generation == self.sortGeneration else { return }
            self.liveOrder = order
            self.isSorting = false
            done()
        }
    }
}
