//
//  NSTableTunedEngine.swift
//  Gingham Bench
//
//  NSTableView as an AppKit expert would write it for live data, every choice aimed at doing
//  less per frame:
//
//  - Cells: a plain NSTextField label per cell (no NSTableCellView, no Auto Layout: the table
//    sets its frame), made once per column and reused (`makeView(withIdentifier:)`); a cell
//    keeps the text it shows and sets `stringValue` only when the text differs, so an unchanged
//    cell is neither formatted into a new layout nor redrawn.
//  - Fixed row height (`rowHeight` 20, `rowSizeStyle = .custom`, no automatic row heights), no
//    column autoresizing, layer-backed scroll view (the default on current macOS, set anyway).
//  - Updates: nothing is reloaded through the table. At the end of a batch the cells in view
//    whose text changed get it in place (`view(atColumn:row:makeIfNecessary: false)`): only
//    the changed rows in view and only their changed columns. Rows out of view aren't touched;
//    they're read when they scroll in. A change in the number of rows is one
//    `noteNumberOfRowsChanged()` a batch (no per-row insert/remove bookkeeping).
//  - Sorting: the app's order is kept by `LiveOrder`: every row's sort key computed once (text
//    as its rank among the distinct texts, so comparisons are of Doubles), and after a batch
//    only rows whose key changed are taken out and merged back (no full sort a frame). A header
//    click on a static table sorts in the background on all cores and the table keeps showing
//    the old order until the new one is ready.
//

import AppKit

/// A cell that sets its text only when it changes.
final class TunedCell: NSTextField {
    private var shown = ""

    func show(_ text: String) {
        guard text != shown else { return }
        shown = text
        stringValue = text
    }
}

final class NSTableTunedEngine: NSObject, Engine, NSTableViewDataSource, NSTableViewDelegate {
    let kind = EngineKind.nstableTuned
    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    private let rows = TunedRows()
    private var columnIndex: [String: Int] = [:]
    private var identifiers: [NSUserInterfaceItemIdentifier] = []
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
        tableView.usesAutomaticRowHeights = false
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
        identifiers = source.columns.map { NSUserInterfaceItemIdentifier($0.id) }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for spec in source.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.isTrailing { column.headerCell.alignment = .right }
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
        guard depth == 0, let source = rows.source else { return }
        let ended = rows.end(visible: visibleRows)
        let shown = tableView.numberOfRows, all = rows.allColumns
        for refresh in ended.refreshes where refresh.display < shown {
            for column in refresh.allColumns ? all : ended.columns {
                if let cell = tableView.view(atColumn: column, row: refresh.display, makeIfNecessary: false) as? TunedCell {
                    cell.show(BenchFormat.text(source, row: refresh.row, column: column))
                }
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
        let sort = tableView.sortDescriptors.compactMap { descriptor in
            descriptor.key.flatMap { columnIndex[$0] }.map { SortSpec(column: $0, ascending: descriptor.ascending) }
        }
        rows.sort(by: sort) { [weak self] in self?.tableView.reloadData() }
    }

    var isSorting: Bool { rows.isSorting }
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
        guard index >= 0, index < rows.count else { return nil }
        let row = rows.sourceRow(atDisplay: index)
        return row >= 0 ? row : nil
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let source = rows.source, let index = columnIndex[tableColumn.identifier.rawValue] else { return nil }
        let cell: TunedCell
        if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? TunedCell {
            cell = reused
        } else {
            cell = TunedCell(labelWithString: "")
            cell.identifier = tableColumn.identifier
            cell.font = Self.font
            cell.lineBreakMode = .byTruncatingTail
            cell.alignment = source.columns[index].isTrailing ? .right : .left
        }
        let sourceRow = rows.sourceRow(atDisplay: row)
        cell.show(sourceRow >= 0 && sourceRow < source.rowCount ? BenchFormat.text(source, row: sourceRow, column: index) : "")
        return cell
    }
}
