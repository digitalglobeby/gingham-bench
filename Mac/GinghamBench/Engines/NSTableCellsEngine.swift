//
//  NSTableCellsEngine.swift
//  Gingham Bench
//
//  NSTableView in its older, cell-based mode, tuned: the first thing AppKit veterans suggest for
//  big, busy tables. There are no views per cell: the table draws every visible cell itself with
//  one `NSTextFieldCell` per column (`dataCell`), asking the data source for each cell's value
//  (`tableView(_:objectValueFor:row:)`) as it draws. Apple has discouraged cell-based tables
//  since macOS 10.10 but they still work.
//
//  - Updates: nothing is reloaded; at the end of a batch only the changed cells in view are
//    marked for drawing (`setNeedsDisplay(frameOfCell(atColumn:row:))`, the whole row for a row
//    that shows another record now), so the table redraws just those.
//  - Fixed geometry as the tuned view-based table: 20-point rows, no column autoresizing.
//  - Sorting: the same incremental `LiveOrder` as the tuned engines (only changed rows
//    re-placed; a static table sorted in the background).
//  - A change in the number of rows: one `noteNumberOfRowsChanged()` per batch.
//
//  (The delegate doesn't implement `tableView(_:viewFor:row:)`: that is what keeps the table
//  cell-based.)
//

import AppKit

final class NSTableCellsEngine: NSObject, Engine, NSTableViewDataSource, NSTableViewDelegate {
    let kind = EngineKind.nstableCells
    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    private let rows = TunedRows()
    private var columnIndex: [String: Int] = [:]
    private var depth = 0
    private var isSettingDescriptors = false
    var view: NSView { scrollView }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    override init() {
        super.init()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.wantsLayer = true
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
    }

    func load(_ source: BenchSource, sort: [SortSpec]) {
        rows.load(source, sort: sort)
        columnIndex = Dictionary(uniqueKeysWithValues: source.columns.enumerated().map { ($1.id, $0) })
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for spec in source.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.isTrailing { column.headerCell.alignment = .right }
            let cell = NSTextFieldCell(textCell: "")
            cell.font = Self.font
            cell.alignment = spec.isTrailing ? .right : .left
            cell.lineBreakMode = .byTruncatingTail
            cell.isEditable = false
            column.dataCell = cell
            column.isEditable = false
            tableView.addTableColumn(column)
        }
        isSettingDescriptors = true
        tableView.sortDescriptors = sort.map { NSSortDescriptor(key: source.columns[$0.column].id, ascending: $0.ascending) }
        isSettingDescriptors = false
        tableView.reloadData()
    }

    private var visibleRows: Range<Int> {
        let visible = tableView.rows(in: tableView.visibleRect)
        return visible.lowerBound ..< max(visible.lowerBound, visible.upperBound)
    }

    // MARK: Updates

    func beginUpdates() {
        depth += 1
        if depth == 1 { rows.begin(visible: visibleRows) }
    }

    func endUpdates() {
        depth -= 1
        guard depth == 0 else { return }
        let ended = rows.end(visible: visibleRows)
        let shown = tableView.numberOfRows
        for refresh in ended.refreshes where refresh.display < shown {
            if refresh.allColumns {
                tableView.setNeedsDisplay(tableView.rect(ofRow: refresh.display))
            } else {
                for column in ended.columns { tableView.setNeedsDisplay(tableView.frameOfCell(atColumn: column, row: refresh.display)) }
            }
        }
        if ended.countChanged { tableView.noteNumberOfRowsChanged() }
    }

    func insertRows(_ inserted: Range<Int>) { rows.insertRows(inserted) }
    func removeRowReplacingWithLast(_ row: Int) { rows.removeRowReplacingWithLast(row) }
    func reloadRows(_ changed: [Int], columns: IndexSet) { rows.reloadRows(changed, columns: columns) }

    // MARK: Sorting

    var sortColumns: Set<Int> { Set(rows.sortSpecs.map(\.column)) }

    func sort(by sort: [SortSpec]) {
        guard let source = rows.source else { return }
        tableView.sortDescriptors = sort.map { NSSortDescriptor(key: source.columns[$0.column].id, ascending: $0.ascending) }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSettingDescriptors else { return }
        var sort: [SortSpec] = []
        for descriptor in tableView.sortDescriptors {
            if let key = descriptor.key, let column = columnIndex[key] { sort.append(SortSpec(column: column, ascending: descriptor.ascending)) }
        }
        rows.sort(by: sort) { [weak self] in self?.tableView.reloadData() }
    }

    var isSorting: Bool { rows.isSorting }
    var displayedRowCount: Int { tableView.numberOfRows }

    func sourceRow(atDisplayIndex index: Int) -> Int? {
        guard index >= 0, index < rows.count else { return nil }
        let row = rows.sourceRow(atDisplay: index)
        return row >= 0 ? row : nil
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let tableColumn, let source = rows.source, let index = columnIndex[tableColumn.identifier.rawValue] else { return nil }
        let sourceRow = rows.sourceRow(atDisplay: row)
        return sourceRow >= 0 && sourceRow < source.rowCount ? BenchFormat.text(source, row: sourceRow, column: index) : ""
    }
}
