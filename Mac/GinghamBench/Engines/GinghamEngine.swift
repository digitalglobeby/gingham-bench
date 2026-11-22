//
//  GinghamEngine.swift
//  Gingham Bench
//
//  Gingham as an app would use it: a data source reading the store, the rows sorted by the
//  table itself (`sortsRows` with `sortDescriptors`, as a click on a header sets them), and
//  targeted reloads inside `beginUpdates`/`endUpdates`: `insertRows(at:)`,
//  `removeRowReplacingWithLast(at:)` and `reloadData(forRows:columnIndexes:)` with only the
//  changed columns. The data source also hands numbers over a range of rows at once
//  (`numbersFor`, `sortNumbersFor`): optional calls of the public data source protocol that
//  NSTableView and SwiftUI have no counterpart for. Nothing beyond what the other engines show
//  is turned on (no change highlights, no summary row) unless `--gingham-extras` is given.
//

import AppKit
import Gingham

final class GinghamEngine: NSObject, Engine, GHTableViewDataSource {
    let kind = EngineKind.gingham
    let table = GHTableView(frame: .zero)
    private var source: BenchSource?
    /// Column index by id, and the last column asked for (the table reads a column's cells one
    /// after another).
    private var columnIndex: [String: Int] = [:]
    private var lastColumn: (id: String, index: Int) = ("", -1)
    private var presented: (() -> Void)?
    var view: NSView { table }

    /// Highlights of changed prices and a summary row: features the other engines don't have
    /// (`--gingham-extras`), off by default so every table shows the same.
    static var showsExtras = false

    func load(_ source: BenchSource, sort: [SortSpec]) {
        self.source = source
        let specs = source.columns
        columnIndex = Dictionary(uniqueKeysWithValues: specs.enumerated().map { ($1.id, $0) })
        lastColumn = ("", -1)
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.columns = specs.map { spec in
            var column = GHTableColumn(spec.id, title: spec.title, width: spec.width,
                                       alignment: spec.isTrailing ? .trailing : .leading,
                                       headerAlignment: spec.isTrailing ? .trailing : .leading)
            column.format = BenchFormat.ginghamFormat(spec)
            if Self.showsExtras {
                if spec.kind == .number, ["price", "last", "bid", "ask", "amount"].contains(spec.id) { column.changeHighlight = .direction }
                if spec.kind == .number, ["quantity", "qty", "volume", "amount"].contains(spec.id) { column.summary = .aggregate(.sum) }
            }
            return .column(column)
        }
        table.showsSummaryRow = Self.showsExtras
        table.dataSource = self
        table.sortsRows = true
        table.sortDescriptors = descriptors(sort)
        table.reloadData()
    }

    private func descriptors(_ sort: [SortSpec]) -> [NSSortDescriptor] {
        sort.map { NSSortDescriptor(key: source?.columns[$0.column].id, ascending: $0.ascending) }
    }

    func beginUpdates() { table.beginUpdates() }
    func endUpdates() { table.endUpdates() }
    func insertRows(_ rows: Range<Int>) { table.insertRows(at: IndexSet(integersIn: rows)) }
    func removeRowReplacingWithLast(_ row: Int) { table.removeRowReplacingWithLast(at: row) }
    func reloadRows(_ rows: [Int], columns: IndexSet) { table.reloadData(forRows: rows, columnIndexes: columns) }

    var sortColumns: Set<Int> { Set(table.sortDescriptors.compactMap { $0.key.flatMap { columnIndex[$0] } }) }
    func sort(by sort: [SortSpec]) { table.sortDescriptors = descriptors(sort) }
    var isSorting: Bool { table.isSortingRows }
    func sourceRow(atDisplayIndex index: Int) -> Int? { table.row(atDisplayIndex: index) }

    var framePresented: (() -> Void)? {
        get { presented }
        set {
            presented = newValue
            table.framePresented = newValue.map { callback in { _, _ in callback() } }
        }
    }

    // MARK: GHTableViewDataSource

    private func index(of column: GHTableColumn) -> Int {
        if column.id == lastColumn.id { return lastColumn.index }
        let index = columnIndex[column.id] ?? -1
        lastColumn = (column.id, index)
        return index
    }

    func numberOfRows(in tableView: GHTableView) -> Int { source?.rowCount ?? 0 }

    func tableView(_ tableView: GHTableView, valueFor column: GHTableColumn, row: Int) -> GHCellValue {
        guard let source, row < source.rowCount else { return .empty }
        let index = index(of: column)
        guard index >= 0 else { return .empty }
        switch source.columns[index].kind {
        case .text:
            return .text(source.text(row, index))
        case .number, .percent:
            let number = source.number(row, index)
            return number.isNaN ? .empty : .number(number)
        case .time:
            let time = source.number(row, index)
            return time.isNaN ? .empty : .text(BenchFormat.time(microseconds: time))
        }
    }

    /// Times sort by their numbers (they're shown as text).
    func tableView(_ tableView: GHTableView, sortValueFor column: GHTableColumn, row: Int) -> GHCellValue {
        let index = index(of: column)
        guard let source, index >= 0, source.columns[index].kind == .time, row < source.rowCount else {
            return self.tableView(tableView, valueFor: column, row: row)
        }
        let time = source.number(row, index)
        return time.isNaN ? .empty : .number(time)
    }

    func tableView(_ tableView: GHTableView, identifierForRow row: Int) -> AnyHashable? {
        guard let source, row < source.rowCount else { return nil }
        return source.identifier(row)
    }

    func tableView(_ tableView: GHTableView, numbersFor column: GHTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        let index = index(of: column)
        guard let source, index >= 0, source.columns[index].isNumeric, rows.upperBound <= source.rowCount else { return false }
        for (offset, row) in rows.enumerated() { values[offset] = source.number(row, index) }
        return true
    }

    func tableView(_ tableView: GHTableView, numbersFor column: GHTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        let index = index(of: column)
        guard let source, index >= 0, source.columns[index].isNumeric else { return false }
        let count = source.rowCount
        for (offset, row) in rows.enumerated() { values[offset] = row >= 0 && row < count ? source.number(row, index) : .nan }
        return true
    }

    func tableView(_ tableView: GHTableView, sortNumbersFor column: GHTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        self.tableView(tableView, numbersFor: column, rows: rows, into: values)
    }

    func tableView(_ tableView: GHTableView, sortNumbersFor column: GHTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        self.tableView(tableView, numbersFor: column, atRows: rows, into: values)
    }
}
