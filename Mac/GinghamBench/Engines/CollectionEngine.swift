//
//  CollectionEngine.swift
//  Gingham Bench
//
//  NSCollectionView (AppKit's counterpart of UICollectionView) showing the rows as items, each
//  a row of labels at the columns' widths, set up the way an expert would for many rows that
//  change:
//
//  - A custom layout (`RowsLayout`) for fixed 20 pt rows: an item's frame is computed from its
//    index, nothing is cached or measured, so a change in the number of rows costs nothing per
//    row (NSCollectionViewFlowLayout prepares every item's attributes).
//  - Items are reused (`makeItem(withIdentifier:for:)`); their labels are plain NSTextFields
//    with frames (no Auto Layout) that set their text only when it changes (`TunedCell`). Only
//    the columns in view have their labels shown and filled, as NSTableView makes cells only
//    for the columns in its visible rect; the others are hidden until scrolled into view.
//  - Updates: the items in view whose text changed are updated in place (`item(at:)`), only the
//    changed rows and columns; a change in the number of rows is one batch of item inserts or
//    deletes at the end.
//  - Sorting: the same `LiveOrder` as the tuned NSTableView (only changed rows re-placed; a
//    static table sorted in the background).
//
//  NSCollectionView has no column header; a header of labels over it shows the columns.
//

import AppKit

final class RowsLayout: NSCollectionViewLayout {
    var rowHeight: CGFloat = 20
    var rowWidth: CGFloat = 800

    private var count: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }

    override var collectionViewContentSize: NSSize {
        NSSize(width: max(rowWidth, collectionView?.bounds.width ?? 0), height: CGFloat(count) * rowHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let count = count
        guard count > 0 else { return [] }
        let first = max(0, Int(rect.minY / rowHeight)), last = min(count - 1, Int(rect.maxY / rowHeight))
        guard first <= last else { return [] }
        return (first...last).map { attributes(for: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes(for: indexPath.item)
    }

    private func attributes(for item: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: item, section: 0))
        attributes.frame = NSRect(x: 0, y: CGFloat(item) * rowHeight, width: max(rowWidth, collectionView?.bounds.width ?? 0), height: rowHeight)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

final class CollectionEngine: NSObject, Engine, NSCollectionViewDataSource {
    let kind = EngineKind.collection
    private let container = NSView()
    private let header = NSView()
    private let scrollView = NSScrollView()
    let collectionView = NSCollectionView()
    private let layout = RowsLayout()
    private let rows = TunedRows()
    private var depth = 0
    /// The columns in view (their labels shown and filled), and where each column starts.
    private var shownColumns = 0..<0
    private var columnStarts: [CGFloat] = []
    private static let itemID = NSUserInterfaceItemIdentifier("row")
    var view: NSView { container }

    /// A row: its labels at the columns' places.
    final class Item: NSCollectionViewItem {
        private(set) var cells: [TunedCell] = []
        private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        /// Stripes, as the other tables have.
        private var isOdd = false

        override func loadView() {
            view = NSView()
            view.wantsLayer = true
        }

        func prepare(columns: [ColumnSpec]) {
            guard cells.count != columns.count else { return }
            cells.forEach { $0.removeFromSuperview() }
            var x: CGFloat = 0
            cells = columns.map { spec in
                let cell = TunedCell(labelWithString: "")
                cell.font = Self.font
                cell.lineBreakMode = .byTruncatingTail
                cell.alignment = spec.isTrailing ? .right : .left
                cell.frame = NSRect(x: x + 3, y: 2, width: spec.pitch - 6, height: 16)
                x += spec.pitch
                view.addSubview(cell)
                return cell
            }
        }

        /// Only the columns in view show their labels.
        func show(columns: Range<Int>) {
            for (index, cell) in cells.enumerated() {
                let hidden = !columns.contains(index)
                if cell.isHidden != hidden { cell.isHidden = hidden }
            }
        }

        func stripe(_ odd: Bool) {
            guard odd != isOdd || view.layer?.backgroundColor == nil else { return }
            isOdd = odd
            view.layer?.backgroundColor = odd ? NSColor.alternatingContentBackgroundColors[1].cgColor
                : NSColor.alternatingContentBackgroundColors[0].cgColor
        }
    }

    override init() {
        super.init()
        collectionView.collectionViewLayout = layout
        collectionView.register(Item.self, forItemWithIdentifier: Self.itemID)
        collectionView.dataSource = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.controlBackgroundColor]
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        scrollView.wantsLayer = true
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        for view in [header, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // The columns in view follow the clip view's bounds (scrolling sideways, resizing).
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateShownColumns() }
            }
        }
    }

    /// The columns whose place meets the clip view's bounds.
    private func columnsInView() -> Range<Int> {
        guard let source = rows.source else { return 0..<0 }
        let rect = scrollView.contentView.bounds
        let columns = source.columns
        var first = columns.count, last = 0
        for (index, start) in columnStarts.enumerated() where start < rect.maxX && start + columns[index].pitch > rect.minX {
            first = min(first, index)
            last = max(last, index + 1)
        }
        return first < last ? first..<last : 0..<0
    }

    /// Columns that came into view get their labels shown and filled in the items in view.
    private func updateShownColumns() {
        let columns = columnsInView()
        guard columns != shownColumns, let source = rows.source else { return }
        let added = columns.filter { !shownColumns.contains($0) }
        shownColumns = columns
        for path in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: path) as? Item else { continue }
            item.show(columns: columns)
            let row = rows.sourceRow(atDisplay: path.item)
            guard row >= 0, row < source.rowCount else { continue }
            for column in added where column < item.cells.count {
                item.cells[column].show(BenchFormat.tunedText(source, row: row, column: column))
            }
        }
    }

    func load(_ source: BenchSource, sort: [SortSpec]) {
        rows.load(source, sort: sort)
        layout.rowWidth = source.columns.reduce(0) { $0 + $1.pitch }
        columnStarts = source.columns.indices.map { index in source.columns[..<index].reduce(0) { $0 + $1.pitch } }
        shownColumns = columnsInView()
        header.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        for spec in source.columns {
            let label = NSTextField(labelWithString: spec.title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = spec.isTrailing ? .right : .left
            label.frame = NSRect(x: x + 3, y: 4, width: spec.pitch - 6, height: 16)
            x += spec.pitch
            header.addSubview(label)
        }
        collectionView.reloadData()
    }

    private var visibleRows: Range<Int> {
        let rect = scrollView.contentView.bounds
        let first = max(0, Int(rect.minY / layout.rowHeight)), last = Int(rect.maxY / layout.rowHeight) + 1
        return first ..< max(first, min(last, rows.count))
    }

    // MARK: Updates

    func beginUpdates() {
        depth += 1
        if depth == 1 { rows.begin(visible: visibleRows) }
    }

    func endUpdates() {
        depth -= 1
        guard depth == 0, let source = rows.source else { return }
        let shownCount = collectionView.numberOfItems(inSection: 0)
        let ended = rows.end(visible: visibleRows)
        if ended.reloadAll {
            collectionView.reloadData()
            return
        }
        let all = rows.allColumns
        for refresh in ended.refreshes where refresh.display < shownCount {
            guard let item = collectionView.item(at: IndexPath(item: refresh.display, section: 0)) as? Item else { continue }
            for column in refresh.allColumns ? all : ended.columns where column < item.cells.count && shownColumns.contains(column) {
                item.cells[column].show(BenchFormat.tunedText(source, row: refresh.row, column: column))
            }
        }
        guard ended.countChanged else { return }
        // The items past the end come or go; the rows before them were updated above.
        let count = rows.count
        var paths = Set<IndexPath>()
        for item in min(count, shownCount) ..< max(count, shownCount) { paths.insert(IndexPath(item: item, section: 0)) }
        if count > shownCount { collectionView.insertItems(at: paths) } else { collectionView.deleteItems(at: paths) }
    }

    func insertRows(_ inserted: Range<Int>) { rows.insertRows(inserted) }
    func removeRowReplacingWithLast(_ row: Int) { rows.removeRowReplacingWithLast(row) }
    func reloadRows(_ changed: [Int], columns: IndexSet) { rows.reloadRows(changed, columns: columns) }

    // MARK: Sorting

    var sortColumns: Set<Int> { Set(rows.sortSpecs.map(\.column)) }

    func sort(by sort: [SortSpec]) {
        rows.sort(by: sort) { [weak self] in self?.collectionView.reloadData() }
    }

    var isSorting: Bool { rows.isSorting }
    var desyncCount: Int { rows.desyncs }
    var displayedRowCount: Int { collectionView.numberOfItems(inSection: 0) }

    /// The items realized (NSCollectionView makes items for what its visible rect shows) and the
    /// labels shown in one (the columns in view).
    var rendered: (rows: Int, columns: Int)? {
        let items = collectionView.indexPathsForVisibleItems()
        let labels = items.first.flatMap { (collectionView.item(at: $0) as? Item)?.cells.filter { !$0.isHidden }.count } ?? 0
        return (items.count, labels)
    }

    func shownTexts() -> [(display: Int, column: Int, text: String)] {
        var texts: [(display: Int, column: Int, text: String)] = []
        for path in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: path) as? Item else { continue }
            for (column, cell) in item.cells.enumerated() where !cell.isHidden { texts.append((path.item, column, cell.stringValue)) }
        }
        return texts
    }

    func sourceRow(atDisplayIndex index: Int) -> Int? {
        guard index >= 0, index < rows.count else { return nil }
        let row = rows.sourceRow(atDisplay: index)
        return row >= 0 ? row : nil
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! Item
        guard let source = rows.source else { return item }
        item.prepare(columns: source.columns)
        item.stripe(indexPath.item % 2 == 1)
        if shownColumns.isEmpty { shownColumns = columnsInView() }
        item.show(columns: shownColumns)
        let row = rows.sourceRow(atDisplay: indexPath.item)
        for column in shownColumns where column < item.cells.count {
            item.cells[column].show(row >= 0 && row < source.rowCount ? BenchFormat.tunedText(source, row: row, column: column) : "")
        }
        return item
    }
}
