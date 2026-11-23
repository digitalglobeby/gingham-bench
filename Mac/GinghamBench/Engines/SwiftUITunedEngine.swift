//
//  SwiftUITunedEngine.swift
//  Gingham Bench
//
//  SwiftUI's Table as an expert would set it up for live data, every choice aimed at giving
//  SwiftUI less to compare and redraw:
//
//  - Rows are `@Observable` objects with a stored property per column (`SlotRow`), and each cell
//    is a small view that reads only its own property: a changed value updates that cell alone,
//    with no array change and nothing to diff. A value is assigned only when it differs (an
//    assignment notifies even when equal).
//  - Columns are written out statically (`TableColumn`s in the table's builder, one Table per
//    column count the scenarios have), not `TableColumnForEach` over an array of values.
//  - Unsorted, the rows array changes only when rows come or go, in place (append, the last row
//    moved into a removed row's place); never replaced as a whole.
//  - Sorted, the app's order is kept by the same incremental `LiveOrder` as the tuned AppKit
//    engines (only rows whose sort key changed are re-placed), and when the order changed the
//    table gets the reordered array with a new `.id`: SwiftUI builds the table afresh instead of
//    working out every row's move (measured: diffing 20,000 rows' moves took seconds a frame,
//    `--swiftui-diff-moves` turns the `.id` off to compare). A header click goes through the
//    `sortOrder` binding; a static table is sorted in the background.
//

import AppKit
import SwiftUI

@Observable final class SlotRow: Identifiable {
    let id: Int
    var s0 = SwiftUICell.text("")
    var s1 = SwiftUICell.text("")
    var s2 = SwiftUICell.text("")
    var s3 = SwiftUICell.text("")
    var s4 = SwiftUICell.text("")
    var s5 = SwiftUICell.text("")
    var s6 = SwiftUICell.text("")
    var s7 = SwiftUICell.text("")
    var s8 = SwiftUICell.text("")
    var s9 = SwiftUICell.text("")
    var s10 = SwiftUICell.text("")
    var s11 = SwiftUICell.text("")
    var s12 = SwiftUICell.text("")
    var s13 = SwiftUICell.text("")
    var s14 = SwiftUICell.text("")
    var s15 = SwiftUICell.text("")
    var s16 = SwiftUICell.text("")
    var s17 = SwiftUICell.text("")
    var s18 = SwiftUICell.text("")
    var s19 = SwiftUICell.text("")
    var s20 = SwiftUICell.text("")
    var s21 = SwiftUICell.text("")
    var s22 = SwiftUICell.text("")
    var s23 = SwiftUICell.text("")

    init(id: Int) { self.id = id }

    /// A column's value: reading it in a view observes only that property.
    subscript(slot: Int) -> SwiftUICell {
        get {
            switch slot {
            case 0: s0
            case 1: s1
            case 2: s2
            case 3: s3
            case 4: s4
            case 5: s5
            case 6: s6
            case 7: s7
            case 8: s8
            case 9: s9
            case 10: s10
            case 11: s11
            case 12: s12
            case 13: s13
            case 14: s14
            case 15: s15
            case 16: s16
            case 17: s17
            case 18: s18
            case 19: s19
            case 20: s20
            case 21: s21
            case 22: s22
            default: s23
            }
        }
        set {
            switch slot {
            case 0: s0 = newValue
            case 1: s1 = newValue
            case 2: s2 = newValue
            case 3: s3 = newValue
            case 4: s4 = newValue
            case 5: s5 = newValue
            case 6: s6 = newValue
            case 7: s7 = newValue
            case 8: s8 = newValue
            case 9: s9 = newValue
            case 10: s10 = newValue
            case 11: s11 = newValue
            case 12: s12 = newValue
            case 13: s13 = newValue
            case 14: s14 = newValue
            case 15: s15 = newValue
            case 16: s16 = newValue
            case 17: s17 = newValue
            case 18: s18 = newValue
            case 19: s19 = newValue
            case 20: s20 = newValue
            case 21: s21 = newValue
            case 22: s22 = newValue
            default: s23 = newValue
            }
        }
    }
}

/// Names a column and a direction for the header (the `sortOrder` binding); the app sorts by its
/// own keys (`LiveOrder`), so this comparator is never asked to compare.
nonisolated struct SlotComparator: SortComparator, Hashable, Sendable {
    var slot: Int
    var order: SortOrder = .forward
    func compare(_ lhs: SlotRow, _ rhs: SlotRow) -> ComparisonResult { .orderedSame }
}

@Observable final class SwiftUITunedModel {
    var rows: [SlotRow] = []
    var columns: [SwiftUIColumn] = []
    var sortOrder: [SlotComparator] = []
    /// A new value makes SwiftUI build the table afresh (sorted live data, a new order).
    var generation = 0
    @ObservationIgnored var sortOrderChanged: (() -> Void)?
}

struct SlotCell: View {
    let row: SlotRow
    let slot: Int
    let column: SwiftUIColumn

    var body: some View { SwiftUICellView(value: row[slot], column: column) }
}

@available(macOS 14.4, *)
struct SwiftUITunedTableView: View {
    @Bindable var model: SwiftUITunedModel

    var body: some View {
        table
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .monospacedDigit()
            .id(model.generation)
            .onChange(of: model.sortOrder) { model.sortOrderChanged?() }
    }

    private func column(_ slot: Int) -> TableColumn<SlotRow, SlotComparator, SlotCell, Text> {
        let column = model.columns[min(slot, model.columns.count - 1)]
        return TableColumn(column.title, sortUsing: SlotComparator(slot: slot)) { row in SlotCell(row: row, slot: slot, column: column) }
    }

    private func sized(_ slot: Int) -> some TableColumnContent<SlotRow, SlotComparator> {
        let spec = model.columns[min(slot, model.columns.count - 1)]
        return column(slot).width(spec.width).alignment(spec.kind == .text ? .leading : .trailing)
    }

    @ViewBuilder private var table: some View {
        switch model.columns.count {
        case 6:
            Table(model.rows, sortOrder: $model.sortOrder) {
                sized(0); sized(1); sized(2); sized(3); sized(4); sized(5)
            }
        case 8:
            Table(model.rows, sortOrder: $model.sortOrder) {
                sized(0); sized(1); sized(2); sized(3); sized(4); sized(5); sized(6); sized(7)
            }
        case 14:
            Table(model.rows, sortOrder: $model.sortOrder) {
                Group { sized(0); sized(1); sized(2); sized(3); sized(4); sized(5); sized(6); sized(7); sized(8); sized(9) }
                Group { sized(10); sized(11); sized(12); sized(13) }
            }
        case 23:
            Table(model.rows, sortOrder: $model.sortOrder) {
                Group { sized(0); sized(1); sized(2); sized(3); sized(4); sized(5); sized(6); sized(7); sized(8); sized(9) }
                Group { sized(10); sized(11); sized(12); sized(13); sized(14); sized(15); sized(16); sized(17); sized(18); sized(19) }
                Group { sized(20); sized(21); sized(22) }
            }
        default:
            Text("No static table for \(model.columns.count) columns")
        }
    }
}

final class SwiftUITunedEngine: Engine {
    let kind = EngineKind.swiftuiTuned
    private let model = SwiftUITunedModel()
    let view: NSView
    private var source: BenchSource?
    /// The rows in the store's order while sorted (the model's are in the display order);
    /// unsorted, the model's rows are in the store's order and this stays empty.
    private var storeRows: [SlotRow] = []
    private var liveOrder: LiveOrder?
    private var depth = 0
    private var isSettingSortOrder = false
    private var sortGeneration = 0
    private(set) var isSorting = false
    private weak var innerTable: NSTableView?
    /// `--swiftui-diff-moves`: the reordered rows given to the same table (SwiftUI diffs them).
    static var diffsMoves = false

    init() {
        if #available(macOS 14.4, *) {
            view = NSHostingView(rootView: SwiftUITunedTableView(model: model))
        } else {
            view = NSHostingView(rootView: Text("SwiftUI's Table column alignment needs macOS 14.4 or later"))
        }
        model.sortOrderChanged = { [weak self] in self?.sortOrderChanged() }
    }

    private func cell(_ row: Int, _ column: Int) -> SwiftUICell {
        guard let source else { return .text("") }
        return source.columns[column].kind == .text ? .text(source.text(row, column)) : .number(source.number(row, column))
    }

    private func makeRow(_ row: Int) -> SlotRow {
        let object = SlotRow(id: source?.identifier(row) ?? row)
        for column in 0..<(source?.columns.count ?? 0) { object[column] = cell(row, column) }
        return object
    }

    /// The rows in the display order.
    private func displayed() -> [SlotRow] {
        guard let liveOrder else { return storeRows }
        var rows: [SlotRow] = []
        rows.reserveCapacity(liveOrder.order.count)
        for row in liveOrder.order { rows.append(storeRows[row]) }
        return rows
    }

    func load(_ source: BenchSource, sort: [SortSpec]) {
        self.source = source
        model.columns = source.columns.enumerated().map { index, spec in
            SwiftUIColumn(id: index, title: spec.title, width: spec.width, kind: spec.kind, digits: spec.digits)
        }
        isSettingSortOrder = true
        model.sortOrder = sort.map { SlotComparator(slot: $0.column, order: $0.ascending ? .forward : .reverse) }
        isSettingSortOrder = false
        var rows: [SlotRow] = []
        rows.reserveCapacity(source.rowCount)
        for row in 0..<source.rowCount { rows.append(makeRow(row)) }
        if sort.isEmpty {
            model.rows = rows
        } else {
            storeRows = rows
            liveOrder = LiveOrder.makeNow(source, sort: sort)
            model.rows = displayed()
        }
    }

    // MARK: Updates

    func beginUpdates() { depth += 1 }

    func endUpdates() {
        depth -= 1
        guard depth == 0, let liveOrder else { return }
        if liveOrder.placePending() {
            model.rows = displayed()
            if !Self.diffsMoves { model.generation += 1 }
        }
    }

    func insertRows(_ inserted: Range<Int>) {
        guard let source else { return }
        if liveOrder != nil {
            for row in inserted { storeRows.append(makeRow(row)) }
            liveOrder?.rowsInserted(inserted, source: source)
        } else {
            for row in inserted { model.rows.append(makeRow(row)) }
        }
    }

    func removeRowReplacingWithLast(_ row: Int) {
        if liveOrder != nil {
            let last = storeRows.removeLast()
            if row < storeRows.count { storeRows[row] = last }
            liveOrder?.rowRemovedReplacingWithLast(row)
        } else {
            let last = model.rows.removeLast()
            if row < model.rows.count { model.rows[row] = last }
        }
    }

    func reloadRows(_ changed: [Int], columns: IndexSet) {
        guard let source else { return }
        let objects = liveOrder != nil ? storeRows : model.rows
        for row in changed where row < objects.count {
            let object = objects[row]
            for column in columns {
                let value = cell(row, column)
                if object[column] != value { object[column] = value }
            }
        }
        liveOrder?.rowsChanged(changed, columns: columns, source: source)
    }

    // MARK: Sorting

    var sortColumns: Set<Int> { Set(liveOrder?.sort.map(\.column) ?? []) }

    func sort(by sort: [SortSpec]) {
        isSettingSortOrder = true
        model.sortOrder = sort.map { SlotComparator(slot: $0.column, order: $0.ascending ? .forward : .reverse) }
        isSettingSortOrder = false
        applySort(sort)
    }

    private func sortOrderChanged() {
        guard !isSettingSortOrder else { return }
        applySort(model.sortOrder.map { SortSpec(column: $0.slot, ascending: $0.order == .forward) })
    }

    private func applySort(_ sort: [SortSpec]) {
        guard let source else { return }
        sortGeneration += 1
        let generation = sortGeneration
        if liveOrder == nil, !sort.isEmpty { storeRows = model.rows }
        guard !sort.isEmpty else {
            if liveOrder != nil {
                liveOrder = nil
                model.rows = storeRows
                storeRows = []
                model.generation += 1
            }
            isSorting = false
            return
        }
        isSorting = true
        Task { @MainActor in
            let order = await LiveOrder.make(source, sort: sort)
            guard generation == self.sortGeneration else { return }
            self.liveOrder = order
            self.model.rows = self.displayed()
            self.model.generation += 1
            self.isSorting = false
        }
    }

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
