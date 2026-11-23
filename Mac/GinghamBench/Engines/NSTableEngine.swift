//
//  NSTableEngine.swift
//  Gingham Bench
//
//  NSTableView as an app typically writes it (the README's "NSTableView" column):
//
//  - view-based, one reused NSTextField label per cell (`makeView(withIdentifier:)`), text set
//    from the store's value each time a cell is asked for; fixed row height (20 pt);
//  - NSTableView doesn't sort, so the app does: when sorted, after every batch it sorts all rows
//    again (`AppSort.order`, a comparator over the store's arrays) and reloads the rows in view
//    (all of them: after a sort any row in view may show another record), or the whole table
//    when the number of rows changed;
//  - unsorted, changes go through the documented targeted updates inside
//    `beginUpdates`/`endUpdates`: `insertRows(at:)`, `removeRows(at:)` for the last row (the
//    store moved it into the removed row's place) and `reloadData(forRowIndexes:columnIndexes:)`
//    for the changed rows that are in view, with only their changed columns.
//
//  A header click sets `sortDescriptors`; the app sorts in `sortDescriptorsDidChange`, on the
//  main thread, and reloads.
//

import AppKit

final class NSTableEngine: NSObject, Engine, NSTableViewDataSource, NSTableViewDelegate {
    let kind = EngineKind.nstable
    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    private var source: BenchSource?
    private var columnIndex: [String: Int] = [:]
    private var sortSpecs: [SortSpec] = []
    /// Display row → store row while sorted.
    private var order: [Int]?
    private var depth = 0
    private var changedRows = IndexSet()
    private var changedColumns = IndexSet()
    private var countChanged = false
    private var valuesChanged = false
    var view: NSView { scrollView }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    override init() {
        super.init()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
    }

    func load(_ source: BenchSource, sort: [SortSpec]) {
        self.source = source
        columnIndex = Dictionary(uniqueKeysWithValues: source.columns.enumerated().map { ($1.id, $0) })
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for spec in source.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.isTrailing { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        sortSpecs = sort
        order = sort.isEmpty ? nil : AppSort.order(of: source, by: sort)
        // (Set after the order: setting them calls `sortDescriptorsDidChange`, which sorts again.)
        isSettingDescriptors = true
        tableView.sortDescriptors = sort.map { NSSortDescriptor(key: source.columns[$0.column].id, ascending: $0.ascending) }
        isSettingDescriptors = false
        tableView.reloadData()
    }

    private var isSettingDescriptors = false

    // MARK: Updates

    func beginUpdates() {
        depth += 1
        if depth == 1, order == nil { tableView.beginUpdates() }
    }

    func endUpdates() {
        depth -= 1
        guard depth == 0, let source else { return }
        if order != nil {
            if countChanged || valuesChanged {
                // Sorted again, every row; then the rows in view (or all, with another count).
                order = AppSort.order(of: source, by: sortSpecs)
                if countChanged {
                    tableView.reloadData()
                } else {
                    let visible = tableView.rows(in: tableView.visibleRect)
                    if visible.length > 0 {
                        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.lowerBound..<min(visible.upperBound, source.rowCount)),
                                             columnIndexes: IndexSet(integersIn: 0..<source.columns.count))
                    }
                }
            }
        } else {
            var rows = changedRows
            rows.remove(integersIn: source.rowCount ..< max(source.rowCount, (rows.last ?? 0) + 1))
            if !rows.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: changedColumns) }
            tableView.endUpdates()
        }
        (changedRows, changedColumns, countChanged, valuesChanged) = ([], [], false, false)
    }

    func insertRows(_ rows: Range<Int>) {
        countChanged = true
        guard order == nil else { return }
        tableView.insertRows(at: IndexSet(integersIn: rows), withAnimation: [])
    }

    func removeRowReplacingWithLast(_ row: Int) {
        countChanged = true
        guard order == nil, let source else { return }
        // The last row goes; the removed row's place shows what the last one showed.
        let last = source.rowCount
        tableView.removeRows(at: [last], withAnimation: [])
        if row < last, isVisible(row) {
            changedRows.insert(row)
            changedColumns.insert(integersIn: 0..<source.columns.count)
        }
    }

    func reloadRows(_ rows: [Int], columns: IndexSet) {
        guard order == nil else {
            if !rows.isEmpty { valuesChanged = true }
            return
        }
        // Only rows in view are reloaded; the others are read when they scroll in.
        let visible = tableView.rows(in: tableView.visibleRect)
        var any = false
        for row in rows where row >= visible.lowerBound && row < visible.upperBound {
            changedRows.insert(row)
            any = true
        }
        if any { changedColumns.formUnion(columns) }
    }

    private func isVisible(_ row: Int) -> Bool {
        let visible = tableView.rows(in: tableView.visibleRect)
        return row >= visible.lowerBound && row < visible.upperBound
    }

    // MARK: Sorting

    var sortColumns: Set<Int> { Set(sortSpecs.map(\.column)) }

    func sort(by sort: [SortSpec]) {
        guard let source else { return }
        // As a header click does: the descriptors change, and the app sorts (below).
        tableView.sortDescriptors = sort.map { NSSortDescriptor(key: source.columns[$0.column].id, ascending: $0.ascending) }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSettingDescriptors, let source else { return }
        sortSpecs = tableView.sortDescriptors.compactMap { descriptor in
            descriptor.key.flatMap { columnIndex[$0] }.map { SortSpec(column: $0, ascending: descriptor.ascending) }
        }
        order = sortSpecs.isEmpty ? nil : AppSort.order(of: source, by: sortSpecs)
        tableView.reloadData()
    }

    var isSorting: Bool { false }
    var displayedRowCount: Int { tableView.numberOfRows }

    func shownTexts() -> [(display: Int, column: Int, text: String)] {
        var texts: [(display: Int, column: Int, text: String)] = []
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.lowerBound ..< min(visible.upperBound, tableView.numberOfRows) {
            for column in 0..<tableView.numberOfColumns {
                if let field = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTextField {
                    texts.append((row, column, field.stringValue))
                }
            }
        }
        return texts
    }

    func sourceRow(atDisplayIndex index: Int) -> Int? {
        guard let source, index >= 0, index < source.rowCount else { return nil }
        return order?[index] ?? index
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { source?.rowCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let source, let index = columnIndex[tableColumn.identifier.rawValue] else { return nil }
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = tableColumn.identifier
            field.font = Self.font
            field.lineBreakMode = .byTruncatingTail
            field.alignment = source.columns[index].isTrailing ? .right : .left
        }
        var sourceRow = row
        if let order { sourceRow = row < order.count ? order[row] : -1 }
        field.stringValue = sourceRow >= 0 && sourceRow < source.rowCount ? BenchFormat.text(source, row: sourceRow, column: index) : ""
        return field
    }
}
