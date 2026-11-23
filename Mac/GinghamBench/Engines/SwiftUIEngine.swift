//
//  SwiftUIEngine.swift
//  Gingham Bench
//
//  SwiftUI's Table as its documentation shows it, in an NSHostingView:
//
//  - an `@Observable` model holding the rows as an array of `Identifiable` values (each row's
//    values for every column, its id the record's identity), the columns made with
//    `TableColumnForEach`, each cell a `Text` of the value with its format style;
//  - sorting through the `sortOrder` binding (a header click changes it; the app sorts the
//    rows with it, as Table shows rows in the order given);
//  - a batch changes the rows in place: the array is taken out of the model for the batch
//    (one change the view sees, no copy), the changed values written, rows appended or the last
//    one moved into a removed row's place, then put back; sorted, the rows are kept in the
//    store's order apart and sorted into the model at the end of each batch.
//
//  Whether the Table has its rows is read from the NSTableView SwiftUI uses inside the hosting
//  view (its number of rows): with hundreds of thousands of rows the first load may take very
//  long, and the runner reports it as a timeout.
//

import AppKit
import SwiftUI

/// A cell's value (numbers NaN when empty).
nonisolated enum SwiftUICell: Hashable, Sendable {
    case text(String)
    case number(Double)
}

nonisolated struct SwiftUIRow: Identifiable, Sendable {
    let id: Int
    var values: [SwiftUICell]
}

nonisolated struct SwiftUIColumn: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let width: CGFloat
    let kind: ColumnKind
    let digits: Int
}

/// Rows by a column: numbers by value (empty first), text in Finder's order.
nonisolated struct SwiftUIRowComparator: SortComparator, Hashable, Sendable {
    var column: Int
    var order: SortOrder = .forward

    func compare(_ lhs: SwiftUIRow, _ rhs: SwiftUIRow) -> ComparisonResult {
        let result: ComparisonResult
        switch (lhs.values[column], rhs.values[column]) {
        case (.text(let a), .text(let b)): result = a.localizedStandardCompare(b)
        case (.number(let a), .number(let b)):
            result = a.isNaN ? (b.isNaN ? .orderedSame : .orderedAscending) : b.isNaN ? .orderedDescending
                : a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        default: result = .orderedSame
        }
        guard order == .reverse else { return result }
        return ComparisonResult(rawValue: -result.rawValue)!
    }
}

@Observable final class SwiftUITableModel {
    var rows: [SwiftUIRow] = []
    var columns: [SwiftUIColumn] = []
    var sortOrder: [SwiftUIRowComparator] = []
    @ObservationIgnored var sortOrderChanged: (() -> Void)?
}

@available(macOS 14.4, *)
struct SwiftUITableView: View {
    @Bindable var model: SwiftUITableModel

    var body: some View {
        Table(model.rows, sortOrder: $model.sortOrder) {
            TableColumnForEach(model.columns) { column in
                TableColumn(column.title, sortUsing: SwiftUIRowComparator(column: column.id)) { row in
                    SwiftUICellView(value: row.values[column.id], column: column)
                }
                .width(column.width)
                .alignment(column.kind == .text ? .leading : .trailing)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .monospacedDigit()
        .onChange(of: model.sortOrder) { model.sortOrderChanged?() }
    }
}

struct SwiftUICellView: View {
    let value: SwiftUICell
    let column: SwiftUIColumn

    var body: some View {
        switch value {
        case .text(let text):
            Text(text).lineLimit(1)
        case .number(let number) where number.isNaN:
            Text("")
        case .number(let number):
            switch column.kind {
            case .percent: Text(number, format: .percent.precision(.fractionLength(column.digits))).lineLimit(1)
            case .time: Text(BenchFormat.time(microseconds: number)).lineLimit(1)
            default: Text(number, format: .number.precision(.fractionLength(column.digits))).lineLimit(1)
            }
        }
    }
}

final class SwiftUIEngine: Engine {
    let kind = EngineKind.swiftui
    private let model = SwiftUITableModel()
    let view: NSView
    private var source: BenchSource?
    /// The rows in the store's order while sorted (the model's are sorted).
    private var storeRows: [SwiftUIRow] = []
    /// The rows being changed in a batch (taken out of the model or `storeRows`).
    private var working: [SwiftUIRow] = []
    private var depth = 0
    private var isSettingSortOrder = false
    private weak var innerTable: NSTableView?

    init() {
        if #available(macOS 14.4, *) {
            view = NSHostingView(rootView: SwiftUITableView(model: model))
        } else {
            view = NSHostingView(rootView: Text("SwiftUI's TableColumnForEach needs macOS 14.4 or later"))
        }
        model.sortOrderChanged = { [weak self] in self?.sortOrderChanged() }
    }

    private var isSorted: Bool { !model.sortOrder.isEmpty }

    private func cell(_ row: Int, _ column: Int) -> SwiftUICell {
        guard let source else { return .text("") }
        return source.columns[column].kind == .text ? .text(source.text(row, column)) : .number(source.number(row, column))
    }

    private func makeRow(_ row: Int) -> SwiftUIRow {
        let count = source?.columns.count ?? 0
        var values: [SwiftUICell] = []
        values.reserveCapacity(count)
        for column in 0..<count { values.append(cell(row, column)) }
        return SwiftUIRow(id: source?.identifier(row) ?? row, values: values)
    }

    func load(_ source: BenchSource, sort: [SortSpec]) {
        self.source = source
        model.columns = source.columns.enumerated().map { index, spec in
            SwiftUIColumn(id: index, title: spec.title, width: spec.pitch - ColumnSpec.swiftUISpacing, kind: spec.kind, digits: spec.digits)
        }
        isSettingSortOrder = true
        model.sortOrder = sort.map { SwiftUIRowComparator(column: $0.column, order: $0.ascending ? .forward : .reverse) }
        isSettingSortOrder = false
        var rows: [SwiftUIRow] = []
        rows.reserveCapacity(source.rowCount)
        for row in 0..<source.rowCount { rows.append(makeRow(row)) }
        if isSorted {
            storeRows = rows
            model.rows = rows.sorted(using: model.sortOrder)
        } else {
            model.rows = rows
        }
    }

    // MARK: Updates

    func beginUpdates() {
        depth += 1
        guard depth == 1 else { return }
        if isSorted { swap(&working, &storeRows) } else { swap(&working, &model.rows) }
    }

    func endUpdates() {
        depth -= 1
        guard depth == 0 else { return }
        if isSorted {
            swap(&working, &storeRows)
            model.rows = storeRows.sorted(using: model.sortOrder)
        } else {
            swap(&working, &model.rows)
        }
        working = []
        if lostStep, let source {
            lostStep = false
            storeRows = []
            load(source, sort: model.sortOrder.map { SortSpec(column: $0.column, ascending: $0.order == .forward) })
        }
    }

    /// Changes that didn't match the rows known (see `Engine.desyncCount`): rebuilt at the end.
    private(set) var desyncCount = 0
    private var lostStep = false

    func insertRows(_ rows: Range<Int>) {
        guard !lostStep else { return }
        guard depth > 0, rows.lowerBound == working.count else {
            desyncCount += 1
            lostStep = true
            return
        }
        for row in rows { working.append(makeRow(row)) }
    }

    func removeRowReplacingWithLast(_ row: Int) {
        guard !lostStep else { return }
        guard depth > 0, let source, source.rowCount == working.count - 1 else {
            desyncCount += 1
            lostStep = true
            return
        }
        let last = working.removeLast()
        if row < working.count { working[row] = last }
    }

    func reloadRows(_ rows: [Int], columns: IndexSet) {
        guard !lostStep else { return }
        for row in rows where row < working.count {
            for column in columns { working[row].values[column] = cell(row, column) }
        }
    }

    // MARK: Sorting

    var sortColumns: Set<Int> { Set(model.sortOrder.map(\.column)) }

    func sort(by sort: [SortSpec]) {
        // As a header click does through the binding; the app sorts (`sortOrderChanged`).
        isSettingSortOrder = true
        model.sortOrder = sort.map { SwiftUIRowComparator(column: $0.column, order: $0.ascending ? .forward : .reverse) }
        isSettingSortOrder = false
        applySortOrder()
    }

    private func sortOrderChanged() {
        guard !isSettingSortOrder else { return }
        applySortOrder()
    }

    private func applySortOrder() {
        if isSorted {
            // (Unsorted until now: the model's rows are in the store's order.)
            if storeRows.isEmpty { storeRows = model.rows }
            model.rows = storeRows.sorted(using: model.sortOrder)
        } else if !storeRows.isEmpty {
            model.rows = storeRows
            storeRows = []
        }
    }

    var isSorting: Bool { false }

    var showsRows: Bool {
        if innerTable == nil { innerTable = Self.findTable(in: view) }
        return (innerTable?.numberOfRows ?? 0) > 0 || source?.rowCount == 0
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = findTable(in: subview) { return table }
        }
        return nil
    }

    var displayedRowCount: Int { model.rows.count }

    /// The rows and columns of the NSTableView SwiftUI's Table is made of, in its visible rect.
    var rendered: (rows: Int, columns: Int)? {
        if innerTable == nil { innerTable = Self.findTable(in: view) }
        guard let table = innerTable else { return nil }
        return (table.rows(in: table.visibleRect).length, table.columnIndexes(in: table.visibleRect).count)
    }

    /// Rows are found by their records' identity (made again when a check starts at place 0).
    private var rowOfID: [Int: Int] = [:]

    func sourceRow(atDisplayIndex index: Int) -> Int? {
        guard let source, index < model.rows.count else { return nil }
        if index == 0 || rowOfID.isEmpty {
            rowOfID = [:]
            rowOfID.reserveCapacity(source.rowCount)
            for row in 0..<source.rowCount { rowOfID[source.identifier(row)] = row }
        }
        return rowOfID[model.rows[index].id]
    }
}
