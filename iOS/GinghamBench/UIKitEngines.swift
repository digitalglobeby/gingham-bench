import UIKit

// UITableView and UICollectionView, set up for speed the way UIKit's own
// guidance has it (WWDC21 "Make blazing fast lists and collection views"):
//
// - Fixed row heights: `rowHeight` 24 with estimated heights off
//   (`estimatedRowHeight` 0), and a compositional layout of absolute
//   24-point items; nothing is measured or corrected while scrolling.
// - Reused cells whose content is a plain view of seven labels laid out with
//   frames: no Auto Layout constraints to solve when a cell is reused, no
//   content configurations rebuilt per cell. Configuring a cell sets seven
//   strings; the number formatters are made once.
// - Cell prefetching on (the default since iOS 15, set explicitly): cells are
//   configured ahead of the scroll. There is no data prefetching
//   (`prefetchDataSource`): the rows are in memory.
// - Focus off (`allowsFocus = false`): with a hardware keyboard attached, the
//   focus system otherwise looks for a cell to focus as cells come and go.
// - A plain data source, not a diffable one: the rows never move, appear
//   or disappear, only their values change, and identity is the index. A
//   diffable data source's `apply` diffs every identifier on the main thread
//   (100,000 or 1,000,000 of them, for each change); its own way to update
//   values, a snapshot with `reconfigureItems`, costs that too.
// - The cell registration API (`UICollectionView.CellRegistration`) for the
//   collection view; the table view registers its cell class.
//
// Two ways to show changed values, two engines each:
//
// - typical: `reconfigureRows(at:)` / `reconfigureItems(at:)`, Apple's
//   recommended way since iOS 15 (it configures the existing cell again,
//   no new cell). Only rows near the screen are passed (UIKit ignores the
//   others, but each call starts an update pass). UITableView's call costs
//   time in proportion to the table's rows, whichever rows are passed:
//   measured in the iPhone simulator, 3.7 ms at 10,000 rows, 30 ms at
//   100,000 and 300 ms at 1,000,000. UICollectionView's took 0.9 ms at
//   100,000 rows and 3.3 ms at 1,000,000. (Each run records the time spent
//   applying changes: `updateMsAverage`, `updateMsMax`.)
// - tuned: the app keeps a map of rows to the cells showing them (filled in
//   `cellForRowAt`/`cellForItemAt`) and sets the changed values on those
//   cells itself; UIKit isn't asked to do anything. A cell keeps its entry
//   until it is configured for another row, so cells kept off screen or
//   prefetched (shown again later without being configured again) are
//   updated too and never show stale values.

/// A row of labels: the name and the numbers, in fixed widths.
final class BenchRowView: UIView {
    private let labels: [UILabel]

    override init(frame: CGRect) {
        labels = BenchColumn.allCases.map { column in
            let label = UILabel()
            if column == .name {
                label.font = .systemFont(ofSize: BenchLayout.fontSize)
                label.textAlignment = .natural
            } else {
                label.font = .monospacedDigitSystemFont(ofSize: BenchLayout.fontSize, weight: .regular)
                label.textAlignment = .right
            }
            return label
        }
        super.init(frame: frame)
        labels.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x = BenchLayout.leadingInset
        for (label, column) in zip(labels, BenchColumn.allCases) {
            let width = BenchLayout.width(of: column)
            label.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + BenchLayout.spacing
        }
    }

    func show(_ row: BenchRow) {
        for (label, column) in zip(labels, BenchColumn.allCases) {
            label.text = BenchFormat.text(row, column)
        }
    }

    /// Only the columns a change touches.
    func showChanges(_ row: BenchRow) {
        for column in BenchColumn.changing {
            labels[column.index].text = BenchFormat.text(row, column)
        }
    }
}

/// A cell that remembers the row it shows (for the tuned engines' map).
protocol BenchCell: AnyObject {
    var rowView: BenchRowView { get }
    var row: Int { get set }
}

/// The rows near the screen among `changed`: the visible ones and a screenful
/// on each side (prefetched cells are there), each once.
private func changedRowsNearScreen(_ changed: [Int], visible: [IndexPath]) -> [Int] {
    guard let first = visible.map(\.item).min(), let last = visible.map(\.item).max() else { return [] }
    let margin = last - first + 1
    let near = (first - margin)...(last + margin)
    return Array(Set(changed.filter { near.contains($0) }))
}

/// The tuned engines' map of rows to the cells configured for them.
private struct CellMap<Cell: BenchCell> {
    private var cells: [Int: Cell] = [:]

    /// `cell` now shows `row` (it may have shown another one before).
    mutating func configure(_ cell: Cell, row: Int) {
        if cell.row >= 0, cells[cell.row] === cell { cells[cell.row] = nil }
        cell.row = row
        cells[row] = cell
    }

    /// Sets the changed values on the cells that show these rows.
    func show(_ changed: [Int], from rows: [BenchRow]) {
        for row in changed {
            if let cell = cells[row], cell.row == row { cell.rowView.showChanges(rows[row]) }
        }
    }
}

// MARK: UITableView

@MainActor
final class TableViewEngine: NSObject, BenchEngine, UITableViewDataSource {
    let kind: BenchEngineKind
    let controller = UIViewController()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let rows: [BenchRow]
    private let tuned: Bool
    private var cellMap = CellMap<Cell>()

    final class Cell: UITableViewCell, BenchCell {
        let rowView = BenchRowView()
        var row = -1
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            rowView.frame = contentView.bounds
            rowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(rowView)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("made in code") }
    }

    init(rows: [BenchRow], tuned: Bool) {
        self.rows = rows
        self.tuned = tuned
        kind = tuned ? .tableViewTuned : .tableView
        super.init()
        tableView.register(Cell.self, forCellReuseIdentifier: "row")
        tableView.dataSource = self
        // Fixed heights: no estimating, no self-sizing.
        tableView.rowHeight = BenchLayout.rowHeight
        tableView.estimatedRowHeight = 0
        tableView.isPrefetchingEnabled = true
        tableView.allowsFocus = false
        tableView.frame = controller.view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(tableView)
    }

    func rowsChanged(_ changed: [Int]) {
        if tuned { return cellMap.show(changed, from: rows) }
        let near = changedRowsNearScreen(changed, visible: tableView.indexPathsForVisibleRows ?? [])
        guard !near.isEmpty else { return }
        tableView.reconfigureRows(at: near.map { IndexPath(row: $0, section: 0) })
    }

    func scroll(toY y: CGFloat) { tableView.benchScroll(toY: y) }
    var scrolledY: CGFloat { tableView.benchScrolledY }
    var measuredRowHeight: CGFloat? { tableView.benchMedianRowHeight }
    var visibleDataRows: Int { tableView.benchVisibleRows }
    var scrollingViewName: String { "UITableView" }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! Cell
        cell.rowView.show(rows[indexPath.row])
        if tuned { cellMap.configure(cell, row: indexPath.row) }
        return cell
    }
}

// MARK: UICollectionView

@MainActor
final class CollectionViewEngine: NSObject, BenchEngine, UICollectionViewDataSource {
    let kind: BenchEngineKind
    let controller = UIViewController()
    private let collectionView: UICollectionView
    private let rows: [BenchRow]
    private let tuned: Bool
    private var cellMap = CellMap<Cell>()
    private var registration: UICollectionView.CellRegistration<Cell, Int>!

    final class Cell: UICollectionViewCell, BenchCell {
        let rowView = BenchRowView()
        var row = -1
        override init(frame: CGRect) {
            super.init(frame: frame)
            rowView.frame = contentView.bounds
            rowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(rowView)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("made in code") }
    }

    init(rows: [BenchRow], tuned: Bool) {
        self.rows = rows
        self.tuned = tuned
        kind = tuned ? .collectionViewTuned : .collectionView
        // A list of fixed-height rows: absolute sizes, nothing estimated.
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(BenchLayout.rowHeight))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group)))
        super.init()
        registration = UICollectionView.CellRegistration<Cell, Int> { [unowned self] cell, _, row in
            cell.rowView.show(self.rows[row])
            if self.tuned { self.cellMap.configure(cell, row: row) }
        }
        collectionView.dataSource = self
        collectionView.isPrefetchingEnabled = true
        collectionView.allowsFocus = false
        collectionView.backgroundColor = .systemBackground
        collectionView.frame = controller.view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(collectionView)
    }

    func rowsChanged(_ changed: [Int]) {
        if tuned { return cellMap.show(changed, from: rows) }
        let near = changedRowsNearScreen(changed, visible: collectionView.indexPathsForVisibleItems)
        guard !near.isEmpty else { return }
        collectionView.reconfigureItems(at: near.map { IndexPath(item: $0, section: 0) })
    }

    func scroll(toY y: CGFloat) { collectionView.benchScroll(toY: y) }
    var scrolledY: CGFloat { collectionView.benchScrolledY }
    var measuredRowHeight: CGFloat? { collectionView.benchMedianRowHeight }
    var visibleDataRows: Int { collectionView.benchVisibleRows }
    var scrollingViewName: String { "UICollectionView" }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: indexPath.item)
    }
}
