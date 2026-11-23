import Gingham
import UIKit

// Gingham, through its public API as an app uses it: columns with formats,
// a data source that returns each cell's value, and targeted reloads of the
// changed cells. The table formats the numbers itself from the columns'
// formats (the same styles and locale the other engines get from
// NumberFormatter).
//
// By default it shows what the others show: the rows, no header, no summary
// row. `-ginghamExtras YES` adds what Gingham would usually show and the
// others don't: a header, the name column pinned at the leading edge, and a
// summary row with every column's average over all rows, kept up to date
// while the values change (the summaries read their numbers in bulk through
// `numbersFor`, as Gingham's documentation suggests for live data).

@MainActor
final class GinghamEngine: BenchEngine, GHTableViewDataSource {
    let kind = BenchEngineKind.gingham
    let controller = UIViewController()
    private let table = GHTableView(frame: .zero)
    private let rows: [BenchRow]
    /// The columns a change touches, as indexes in `table.columns`.
    private let changingColumns = IndexSet(BenchColumn.changing.map(\.index))

    init(rows: [BenchRow], extras: Bool) {
        self.rows = rows
        // Same widths as the other engines: the text's width plus the room between columns.
        table.columns = BenchColumn.allCases.map { column in
            let width = Double(BenchLayout.width(of: column) + BenchLayout.spacing)
            if column == .name {
                return .column(GHTableColumn(column.rawValue, title: column.title, width: width, pin: extras ? .leading : .none))
            }
            return .column(GHTableColumn(column.rawValue, title: column.title, width: width,
                                         alignment: .trailing, headerAlignment: .trailing,
                                         format: Self.format(of: column),
                                         summary: extras ? .aggregate(.average) : .none))
        }
        table.showsHeader = extras
        table.showsSummaryRow = extras
        table.tableStyle = GHTableStyle(fontSize: BenchLayout.fontSize)
        table.locale = BenchFormat.locale
        table.rowHeight = BenchLayout.rowHeight
        table.dataSource = self
        table.frame = controller.view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(table)
    }

    private static func format(of column: BenchColumn) -> GHValueFormat {
        switch column {
        case .name: .automatic
        case .clicks, .views: .number(fractionDigits: 0)
        case .spend, .revenue, .profit: .currency(code: "USD")
        case .roi: .percent(fractionDigits: 1)
        }
    }

    func rowsChanged(_ changed: [Int]) {
        // The feed's form of a targeted reload: rows in any order, repeated or not.
        table.reloadData(forRows: changed, columnIndexes: changingColumns)
    }

    func scroll(toY y: CGFloat) {
        table.scroll(to: CGPoint(x: table.contentOffset.x, y: y))
    }

    var scrolledY: CGFloat { table.contentOffset.y }
    var measuredRowHeight: CGFloat? { table.rowHeight }
    var scrollingViewName: String { "GHTableView" }
    var columnsShown: Int { table.columns.count }

    var visibleDataRows: Int {
        let bounds = table.bounds
        // The first row under the header (if any), then each row that reaches into the view.
        var row = -1
        var y = bounds.minY + 0.5
        while row < 0, y < bounds.maxY {
            row = table.row(at: CGPoint(x: bounds.midX, y: y))
            y += 1
        }
        guard row >= 0 else { return 0 }
        var count = 0
        while row < rows.count {
            let frame = table.rect(ofRow: row)
            guard frame.minY < bounds.maxY else { break }
            if frame.intersects(bounds) { count += 1 }
            row += 1
        }
        return count
    }

    // MARK: Data source

    func numberOfRows(in tableView: GHTableView) -> Int { rows.count }

    func tableView(_ tableView: GHTableView, valueFor column: GHTableColumn, row: Int) -> GHCellValue {
        let item = rows[row]
        guard let benchColumn = BenchColumn(rawValue: column.id), benchColumn != .name else { return .text(item.name) }
        return .number(item.value(benchColumn))
    }

    /// The summaries' numbers for a range of rows at once (with the extras).
    func tableView(_ tableView: GHTableView, numbersFor column: GHTableColumn, rows range: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let benchColumn = BenchColumn(rawValue: column.id), benchColumn != .name else { return false }
        for (offset, row) in range.enumerated() { values[offset] = rows[row].value(benchColumn) }
        return true
    }

    /// The summaries' numbers for the rows a batch of updates changed (with the extras).
    func tableView(_ tableView: GHTableView, numbersFor column: GHTableColumn, atRows indexes: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let benchColumn = BenchColumn(rawValue: column.id), benchColumn != .name else { return false }
        for (offset, row) in indexes.enumerated() { values[offset] = rows[row].value(benchColumn) }
        return true
    }
}
