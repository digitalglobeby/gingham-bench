import SwiftUI
import UIKit

// SwiftUI's Table and List, written for speed the way SwiftUI's guidance
// has it:
//
// - Stable identity: the rows are `Identifiable` by a constant id, given to
//   `Table`/`List` directly (no `id: \.self`, no indices, no `AnyView`).
// - Fine-grained updates: each row is an `@Observable` object with one
//   property per column, and each number is a view of its own that reads only
//   its property, so a change redraws that cell alone; nothing is diffed, and
//   no rows array changes while the values do.
// - Fixed geometry: fixed column widths, one line of text; List's rows are
//   24 points (`defaultMinListRowHeight`, no vertical row insets, a fixed
//   frame), so nothing is measured again while scrolling.
// - The same cached number formatters as the UIKit engines.
// - No column header (`tableColumnHeaders(.hidden)`), like the other engines.
//
// Table's rows can't be made lower: measured 44 points in the iPhone
// simulator (iOS 18) and 52 in the iPad simulator (iOS 27.2) with this text,
// whatever `defaultMinListRowHeight`, row insets or the cells' frames say;
// each run records the height it measured. So that Table gets the same rows a
// second as the others, the scroll test moves it faster in points
// (ScrollProfile.swift).
//
// On iPhone, `Table` shows only its first column, as a list (by design, in
// any orientation and size class; overriding the size class doesn't change
// it). It then does far less than the others, so iPhone runs leave it out
// unless it is named (`-engine swiftUITable`); its results say how many
// columns it showed.
//
// The scroll test moves the scroll view SwiftUI makes for the table or list
// (`UIScrollView`): what a finger moves. SwiftUI has no API to set a scroll
// offset on a List or Table every frame.

/// A number cell: reads only its column's property, so only that cell is
/// updated when the value changes.
struct BenchNumberText: View {
    let row: BenchRow
    let column: BenchColumn

    var body: some View {
        Text(BenchFormat.text(row, column))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: Table

struct BenchTableView: View {
    let rows: [BenchRow]

    var body: some View {
        Table(rows) {
            TableColumn(BenchColumn.name.title) { row in Text(row.name) }
                .width(Self.width(.name))
            TableColumn(BenchColumn.clicks.title) { row in BenchNumberText(row: row, column: .clicks) }
                .width(Self.width(.clicks))
            TableColumn(BenchColumn.views.title) { row in BenchNumberText(row: row, column: .views) }
                .width(Self.width(.views))
            TableColumn(BenchColumn.spend.title) { row in BenchNumberText(row: row, column: .spend) }
                .width(Self.width(.spend))
            TableColumn(BenchColumn.revenue.title) { row in BenchNumberText(row: row, column: .revenue) }
                .width(Self.width(.revenue))
            TableColumn(BenchColumn.profit.title) { row in BenchNumberText(row: row, column: .profit) }
                .width(Self.width(.profit))
            TableColumn(BenchColumn.roi.title) { row in BenchNumberText(row: row, column: .roi) }
                .width(Self.width(.roi))
        }
        .tableColumnHeaders(.hidden)
        .font(.system(size: BenchLayout.fontSize))
        .lineLimit(1)
        .environment(\.defaultMinListRowHeight, BenchLayout.rowHeight)
    }

    /// A column's width: its text's and the room between columns.
    private static func width(_ column: BenchColumn) -> CGFloat {
        BenchLayout.width(of: column) + BenchLayout.spacing
    }
}

@MainActor
final class SwiftUITableEngine: BenchEngine {
    let kind = BenchEngineKind.swiftUITable
    let controller: UIViewController
    private weak var cachedScrollView: UIScrollView?
    /// On iPhone, only the first column (see above).
    var columnsShown: Int { UIDevice.current.userInterfaceIdiom == .phone ? 1 : BenchColumn.allCases.count }

    init(rows: [BenchRow]) {
        controller = UIHostingController(rootView: BenchTableView(rows: rows))
    }

    /// (The rows' objects tell SwiftUI themselves.)
    func rowsChanged(_ rows: [Int]) {}

    private var scrollView: UIScrollView? {
        if let cachedScrollView { return cachedScrollView }
        cachedScrollView = controller.view.firstScrollView()
        return cachedScrollView
    }

    func scroll(toY y: CGFloat) { scrollView?.benchScroll(toY: y) }
    var scrolledY: CGFloat { scrollView?.benchScrolledY ?? 0 }
    var measuredRowHeight: CGFloat? { scrollView?.benchMedianRowHeight }
    var visibleDataRows: Int { scrollView?.benchVisibleRows ?? 0 }
    var scrollingViewName: String { scrollView.map { String(describing: type(of: $0)) } ?? "none" }
}

// MARK: List

struct BenchListView: View {
    let rows: [BenchRow]

    var body: some View {
        List(rows) { row in
            BenchListRow(row: row)
                .listRowInsets(EdgeInsets(top: 0, leading: BenchLayout.leadingInset, bottom: 0, trailing: 0))
        }
        .listStyle(.plain)
        .font(.system(size: BenchLayout.fontSize))
        .lineLimit(1)
        .environment(\.defaultMinListRowHeight, BenchLayout.rowHeight)
    }
}

struct BenchListRow: View {
    let row: BenchRow

    var body: some View {
        HStack(spacing: BenchLayout.spacing) {
            Text(row.name)
                .frame(width: BenchLayout.nameWidth, alignment: .leading)
            BenchNumberText(row: row, column: .clicks)
                .frame(width: BenchLayout.numberWidth)
            BenchNumberText(row: row, column: .views)
                .frame(width: BenchLayout.numberWidth)
            BenchNumberText(row: row, column: .spend)
                .frame(width: BenchLayout.numberWidth)
            BenchNumberText(row: row, column: .revenue)
                .frame(width: BenchLayout.numberWidth)
            BenchNumberText(row: row, column: .profit)
                .frame(width: BenchLayout.numberWidth)
            BenchNumberText(row: row, column: .roi)
                .frame(width: BenchLayout.numberWidth)
        }
        .frame(maxWidth: .infinity, minHeight: BenchLayout.rowHeight, maxHeight: BenchLayout.rowHeight, alignment: .leading)
    }
}

@MainActor
final class SwiftUIListEngine: BenchEngine {
    let kind = BenchEngineKind.swiftUIList
    let controller: UIViewController
    private weak var cachedScrollView: UIScrollView?

    init(rows: [BenchRow]) {
        controller = UIHostingController(rootView: BenchListView(rows: rows))
    }

    /// (The rows' objects tell SwiftUI themselves.)
    func rowsChanged(_ rows: [Int]) {}

    private var scrollView: UIScrollView? {
        if let cachedScrollView { return cachedScrollView }
        cachedScrollView = controller.view.firstScrollView()
        return cachedScrollView
    }

    func scroll(toY y: CGFloat) { scrollView?.benchScroll(toY: y) }
    var scrolledY: CGFloat { scrollView?.benchScrolledY ?? 0 }
    var measuredRowHeight: CGFloat? { scrollView?.benchMedianRowHeight }
    var visibleDataRows: Int { scrollView?.benchVisibleRows ?? 0 }
    var scrollingViewName: String { scrollView.map { String(describing: type(of: $0)) } ?? "none" }
}
