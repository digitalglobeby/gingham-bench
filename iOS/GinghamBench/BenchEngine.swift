import UIKit

// The engines compared. Each shows the same rows and columns (BenchData.swift)
// in rows 24 points high, 15-point text, the same column widths, no column
// header, filling the same area, and is told about changes the way its
// framework is meant to be:
//
// - Gingham: the table reloads the changed cells (`reloadData(forRows:columnIndexes:)`).
// - UITableView and UICollectionView, each twice:
//   - typical: the changed rows are reconfigured (`reconfigureRows(at:)`,
//     `reconfigureItems(at:)`), Apple's recommended way to update a cell's
//     content since iOS 15;
//   - tuned: the app keeps its own map of rows to the cells showing them and
//     sets the changed values on those cells directly, without asking the
//     table or collection view to do anything.
// - SwiftUI Table and List: nothing to tell; the row objects are observable,
//   and SwiftUI updates the cells that read a changed property.
//
// The scroll test moves each engine's own scroll position, the way a finger
// does: Gingham's with its public `scroll(to:)`, the others' through their
// `UIScrollView` (for SwiftUI, the one it makes inside its view).

@MainActor
protocol BenchEngine: AnyObject {
    var kind: BenchEngineKind { get }
    /// The engine's view controller, shown under the bench's controls.
    var controller: UIViewController { get }
    /// These rows' values changed (data source indexes; a row may repeat).
    func rowsChanged(_ rows: [Int])
    /// Scrolls to `y` points below the top of the rows (clamped to the content).
    func scroll(toY y: CGFloat)
    /// How far below the top of the rows the view is scrolled.
    var scrolledY: CGFloat { get }
    /// What the engine's rows measure on screen (for the results: the same
    /// 24 points in every engine, unless one can't be made to).
    var measuredRowHeight: CGFloat? { get }
    /// Rows at least partly on screen (for the results: the same in every engine).
    var visibleDataRows: Int { get }
    /// The class that scrolls (for the results).
    var scrollingViewName: String { get }
    /// How many columns the engine shows (all seven, but SwiftUI Table on iPhone).
    var columnsShown: Int { get }
}

extension BenchEngine {
    var columnsShown: Int { BenchColumn.allCases.count }
}

enum BenchEngineKind: Int, CaseIterable {
    case gingham, tableView, tableViewTuned, collectionView, collectionViewTuned, swiftUITable, swiftUIList

    var title: String {
        switch self {
        case .gingham: "Gingham"
        case .tableView: "UITableView (typical)"
        case .tableViewTuned: "UITableView (tuned)"
        case .collectionView: "UICollectionView (typical)"
        case .collectionViewTuned: "UICollectionView (tuned)"
        case .swiftUITable: "SwiftUI Table"
        case .swiftUIList: "SwiftUI List"
        }
    }

    /// The name launch arguments use (`-engine collectionViewTuned`).
    var argument: String {
        switch self {
        case .gingham: "gingham"
        case .tableView: "tableView"
        case .tableViewTuned: "tableViewTuned"
        case .collectionView: "collectionView"
        case .collectionViewTuned: "collectionViewTuned"
        case .swiftUITable: "swiftUITable"
        case .swiftUIList: "swiftUIList"
        }
    }

    init?(argument: String) {
        let lowered = argument.lowercased()
        if let index = Int(lowered), let kind = Self(rawValue: index) {
            self = kind
        } else if let kind = Self.allCases.first(where: { $0.argument.lowercased() == lowered || $0.title.lowercased() == lowered }) {
            self = kind
        } else {
            return nil
        }
    }

    /// The engines a run of all tests: on iPhone, all but SwiftUI Table,
    /// which shows only its first column there (see SwiftUIEngines.swift).
    static var comparable: [BenchEngineKind] {
        UIDevice.current.userInterfaceIdiom == .phone ? allCases.filter { $0 != .swiftUITable } : allCases
    }

    func make(data: BenchData, ginghamExtras: Bool) -> BenchEngine {
        switch self {
        case .gingham: GinghamEngine(rows: data.rows, extras: ginghamExtras)
        case .tableView: TableViewEngine(rows: data.rows, tuned: false)
        case .tableViewTuned: TableViewEngine(rows: data.rows, tuned: true)
        case .collectionView: CollectionViewEngine(rows: data.rows, tuned: false)
        case .collectionViewTuned: CollectionViewEngine(rows: data.rows, tuned: true)
        case .swiftUITable: SwiftUITableEngine(rows: data.rows)
        case .swiftUIList: SwiftUIListEngine(rows: data.rows)
        }
    }
}

extension UIScrollView {
    /// Scrolls to `y` points below the top of the content, clamped, like a finger would leave it.
    func benchScroll(toY y: CGFloat) {
        let top = -adjustedContentInset.top
        let bottom = max(top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        contentOffset = CGPoint(x: contentOffset.x, y: min(bottom, max(top, top + y)))
    }

    var benchScrolledY: CGFloat { contentOffset.y + adjustedContentInset.top }

    /// Rows (cells) at least partly on screen in a table or collection view.
    var benchVisibleRows: Int {
        switch self {
        case let table as UITableView: table.indexPathsForVisibleRows?.count ?? 0
        case let collection as UICollectionView: collection.indexPathsForVisibleItems.count
        default: 0
        }
    }

    /// The median height of the visible cells of a table or collection view.
    var benchMedianRowHeight: CGFloat? {
        let heights: [CGFloat]
        switch self {
        case let table as UITableView: heights = table.visibleCells.map(\.bounds.height)
        case let collection as UICollectionView: heights = collection.visibleCells.map(\.bounds.height)
        default: return nil
        }
        guard !heights.isEmpty else { return nil }
        return heights.sorted()[heights.count / 2]
    }
}

extension UIView {
    /// The first scroll view in this view's subtree, breadth first.
    func firstScrollView() -> UIScrollView? {
        var queue: [UIView] = [self]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView { return scroll }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
