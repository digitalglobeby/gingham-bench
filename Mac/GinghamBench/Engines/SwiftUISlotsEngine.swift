//
//  SwiftUISlotsEngine.swift
//  Gingham Bench
//
//  SwiftUI's Table with rows identified by their place, as the tuned AppKit engines address the
//  places in view: the row objects are slots (`SlotRow`, an `@Observable` object with a property
//  per column, each cell a small view reading only its own property), slot n always the n-th row
//  shown, never moved. A batch writes new values into the slots whose content changed, and
//  nothing else:
//
//  - a slot whose place shows another record now (a row moved in the sorted order, a removed row's
//    place taken by the last row) gets every column; a slot whose record stayed and changed gets
//    the changed columns; a value is assigned only when it differs;
//  - the rows array changes only when the number of rows does, once a batch (slots added or taken
//    off at the end), so there are no moves for SwiftUI to work out and no table to rebuild;
//  - the order is the tuned AppKit engines' (`TunedRows`: the incremental `LiveOrder`, a static
//    table sorted in the background), with every place counted as "in view": SwiftUI asks only for
//    the rows it shows, but a slot it shows later must already have its values.
//
//  What it gives up, as the tuned SwiftUI engine's rebuild does: selection and row animations
//  follow places, not records. Its cost moves to rewriting slots: after a sort of a static table,
//  every slot gets new values.
//

import AppKit
import SwiftUI

final class SwiftUISlotsEngine: Engine {
    let kind = EngineKind.swiftuiSlots
    private let model = SwiftUITunedModel()
    let view: NSView
    private let rows = TunedRows()
    /// The slots, slot n for the n-th place; `model.rows` is this array (set again only when the
    /// number of rows changes).
    private var slots: [SlotRow] = []
    private var columnCount = 0
    private var depth = 0
    /// The fewest rows the store had during the batch: places from there on may show other
    /// records (a removed row's place taken by the last, new rows at the end).
    private var lowestCount = 0
    private var isSettingSortOrder = false
    private weak var innerTable: NSTableView?

    init() {
        if #available(macOS 14.4, *) {
            let hosting = NSHostingView(rootView: SwiftUITunedTableView(model: model))
            hosting.sizingOptions = []
            view = hosting
        } else {
            view = NSHostingView(rootView: Text("SwiftUI's Table column alignment needs macOS 14.4 or later"))
        }
        model.sortOrderChanged = { [weak self] in self?.sortOrderChanged() }
    }

    private func cell(_ source: BenchSource, _ row: Int, _ column: Int) -> SwiftUICell {
        source.columns[column].kind == .text ? .text(source.text(row, column)) : .number(source.number(row, column))
    }

    /// The slot shows the store's row in these columns (all: nil). Values are set only when they
    /// differ: an assignment notifies even when equal.
    private func fill(_ slot: SlotRow, row: Int, columns: IndexSet?) {
        guard let source = rows.source, row >= 0, row < source.rowCount else { return }
        if let columns {
            for column in columns where column < columnCount {
                let value = cell(source, row, column)
                if slot[column] != value { slot[column] = value }
            }
        } else {
            for column in 0..<columnCount {
                let value = cell(source, row, column)
                if slot[column] != value { slot[column] = value }
            }
        }
    }

    func load(_ source: BenchSource, sort: [SortSpec]) {
        rows.load(source, sort: sort)
        columnCount = source.columns.count
        model.columns = source.columns.enumerated().map { index, spec in
            SwiftUIColumn(id: index, title: spec.title, width: spec.pitch - ColumnSpec.swiftUISpacing, kind: spec.kind, digits: spec.digits)
        }
        isSettingSortOrder = true
        model.sortOrder = sort.map { SlotComparator(slot: $0.column, order: $0.ascending ? .forward : .reverse) }
        isSettingSortOrder = false
        slots = []
        fillAll()
    }

    /// Every slot from the order (after a load, a sort or a lost step).
    private func fillAll() {
        let count = rows.count
        if slots.count > count { slots.removeLast(slots.count - count) }
        slots.reserveCapacity(count)
        for place in 0..<count {
            if place == slots.count { slots.append(SlotRow(id: place)) }
            fill(slots[place], row: rows.sourceRow(atDisplay: place), columns: nil)
        }
        if model.rows.count != slots.count || model.rows.isEmpty { model.rows = slots }
    }

    // MARK: Updates

    func beginUpdates() {
        depth += 1
        guard depth == 1 else { return }
        lowestCount = rows.count
        // Every place counts as in view (see the top).
        rows.begin(visible: 0..<rows.count)
    }

    func endUpdates() {
        depth -= 1
        guard depth == 0 else { return }
        let count = rows.count
        let ended = rows.end(visible: 0..<count)
        if ended.reloadAll {
            fillAll()
            model.generation += 1
            return
        }
        // The number of rows: slots added (filled) or taken off at the end, one array change.
        let before = slots.count
        if count != before {
            if count > before {
                for place in before..<count {
                    let slot = SlotRow(id: place)
                    fill(slot, row: rows.sourceRow(atDisplay: place), columns: nil)
                    slots.append(slot)
                }
            } else {
                slots.removeLast(before - count)
            }
            model.rows = slots
        }
        // Unsorted, the places past the fewest rows of the batch show the records the store put
        // there (the last row moved into a removed one's place, rows added after it).
        if !rows.isSorted {
            for place in min(lowestCount, before) ..< min(before, count) {
                fill(slots[place], row: place, columns: nil)
            }
        }
        for refresh in ended.refreshes where refresh.display < slots.count {
            fill(slots[refresh.display], row: refresh.row, columns: refresh.allColumns ? nil : ended.columns)
        }
    }

    func insertRows(_ inserted: Range<Int>) { rows.insertRows(inserted) }

    func removeRowReplacingWithLast(_ row: Int) {
        rows.removeRowReplacingWithLast(row)
        if let source = rows.source { lowestCount = min(lowestCount, source.rowCount) }
    }

    func reloadRows(_ changed: [Int], columns: IndexSet) { rows.reloadRows(changed, columns: columns) }

    // MARK: Sorting

    var sortColumns: Set<Int> { Set(rows.sortSpecs.map(\.column)) }

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

    /// The new order's records written into the slots when it's ready.
    private func applySort(_ sort: [SortSpec]) {
        rows.sort(by: sort) { [weak self] in self?.fillAll() }
    }

    var isSorting: Bool { rows.isSorting }
    var desyncCount: Int { rows.desyncs }
    var displayedRowCount: Int { model.rows.count }

    /// Scrolled through the scroll view SwiftUI's Table puts its NSTableView in.
    private var scroller = ClipScroller()
    func scroll(toY y: CGFloat) {
        if innerTable == nil { innerTable = SwiftUIEngine.findTable(in: view) }
        scroller.scroll(innerTable?.enclosingScrollView, toY: y)
    }
    var rowPitch: CGFloat {
        if innerTable == nil { innerTable = SwiftUIEngine.findTable(in: view) }
        guard let table = innerTable else { return 24 }
        return table.rowHeight + table.intercellSpacing.height
    }

    func sourceRow(atDisplayIndex index: Int) -> Int? {
        guard index >= 0, index < rows.count else { return nil }
        let row = rows.sourceRow(atDisplay: index)
        return row >= 0 ? row : nil
    }

    var showsRows: Bool {
        if innerTable == nil { innerTable = SwiftUIEngine.findTable(in: view) }
        return (innerTable?.numberOfRows ?? 0) > 0 || rows.count == 0
    }

    /// The rows and columns of the NSTableView SwiftUI's Table is made of, in its visible rect.
    var rendered: (rows: Int, columns: Int)? {
        if innerTable == nil { innerTable = SwiftUIEngine.findTable(in: view) }
        guard let table = innerTable else { return nil }
        return (table.rows(in: table.visibleRect).length, table.columnIndexes(in: table.visibleRect).count)
    }

    /// The slots of the rows in view, as text: what their cells show (checked against the store
    /// after a run, so a slot left with an old value fails).
    func shownTexts() -> [(display: Int, column: Int, text: String)] {
        guard let source = rows.source else { return [] }
        if innerTable == nil { innerTable = SwiftUIEngine.findTable(in: view) }
        guard let table = innerTable else { return [] }
        var texts: [(display: Int, column: Int, text: String)] = []
        let visible = table.rows(in: table.visibleRect)
        for place in visible.lowerBound ..< min(visible.upperBound, slots.count) {
            for column in 0..<columnCount {
                texts.append((place, column, BenchFormat.text(of: slots[place][column], spec: source.columns[column])))
            }
        }
        return texts
    }
}
