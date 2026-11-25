//
//  Engine.swift
//  Gingham Bench
//
//  A table of one engine showing a scenario's rows. Everything before the table (the data, its
//  generation, the store, the frame's batch) is the same code for every engine; each engine
//  is told what changed the way its framework expects and does what an app using it would.
//
//  The store tells the engine about its changes as it makes them, between `beginUpdates` and
//  `endUpdates` (one batch a screen frame): rows added at the end, a row removed with the last
//  row moved into its place (no shifting of the rows after it), and rows whose values changed
//  with the columns that changed. Rows are always the store's ("source") rows; engines that
//  show them in another order keep their own order.
//

import AppKit

nonisolated enum EngineKind: String, CaseIterable, Sendable {
    case gingham
    case nstable
    case nstableTuned = "nstable-tuned"
    case nstableCells = "nstable-cells"
    case collection
    case swiftui
    case swiftuiTuned = "swiftui-tuned"
    case swiftuiSlots = "swiftui-slots"

    var title: String {
        switch self {
        case .gingham: "Gingham"
        case .nstable: "NSTableView"
        case .nstableTuned: "NSTableView, tuned"
        case .nstableCells: "NSTableView, cell-based"
        case .collection: "NSCollectionView"
        case .swiftui: "SwiftUI Table"
        case .swiftuiTuned: "SwiftUI Table, tuned"
        case .swiftuiSlots: "SwiftUI Table, slots"
        }
    }

    /// One line on how the engine is used, for the window and the report.
    var setup: String {
        switch self {
        case .gingham: "sortsRows, targeted reloads"
        case .nstable: "app re-sorts after each batch, reloads rows in view"
        case .nstableTuned: "incremental sort, in-place cell updates of rows in view"
        case .nstableCells: "NSCell-based, changed cells redrawn, incremental sort"
        case .collection: "custom row layout, incremental sort, in-place item updates"
        case .swiftui: "@Observable rows, sortOrder binding"
        case .swiftuiTuned: "@Observable row objects, static columns, incremental sort, rows rebuilt on reorder"
        case .swiftuiSlots: "rows identified by place, values written into them, incremental sort"
        }
    }

    @MainActor func make() -> Engine {
        switch self {
        case .gingham: GinghamEngine()
        case .nstable: NSTableEngine()
        case .nstableTuned: NSTableTunedEngine()
        case .nstableCells: NSTableCellsEngine()
        case .collection: CollectionEngine()
        case .swiftui: SwiftUIEngine()
        case .swiftuiTuned: SwiftUITunedEngine()
        case .swiftuiSlots: SwiftUISlotsEngine()
        }
    }
}

protocol Engine: AnyObject {
    var kind: EngineKind { get }
    var view: NSView { get }
    /// The columns and every row, shown in `sort`'s order (none: the store's).
    func load(_ source: BenchSource, sort: [SortSpec])
    func beginUpdates()
    func endUpdates()
    /// Rows added at the end (the store has them).
    func insertRows(_ rows: Range<Int>)
    /// The store removed `row` and moved its last row there (`row` may be the last row).
    func removeRowReplacingWithLast(_ row: Int)
    /// These rows' values changed in these columns.
    func reloadRows(_ rows: [Int], columns: IndexSet)
    /// Columns the rows are sorted by (the store tells rows that changed them apart).
    var sortColumns: Set<Int> { get }
    /// As a click on a column's header would: sorted by these columns (none: the store's order).
    func sort(by sort: [SortSpec])
    /// A sort asked for isn't on the screen yet (only Gingham and the tuned engines sort in the
    /// background; the others sort before `sort(by:)` returns).
    var isSorting: Bool { get }
    /// Whether the table has its rows (SwiftUI's Table may take long, or forever, to load many).
    var showsRows: Bool { get }
    /// The store's row shown at a place, and the rows shown, for checking an order.
    func sourceRow(atDisplayIndex index: Int) -> Int?
    var displayedRowCount: Int { get }
    /// Times the engine's rows lost step with the store's changes and were rebuilt (a bug in the
    /// bench if ever above 0; the order check reports it).
    var desyncCount: Int { get }
    /// The rows and columns the engine has laid out for its view (on a window larger than the
    /// screen, all of them, not only the part the screen shows); nil if it can't tell.
    var rendered: (rows: Int, columns: Int)? { get }
    /// The text the cells in view show now, for engines whose cells can be read (view-based
    /// AppKit tables; the others draw their text themselves): checked against the store.
    func shownTexts() -> [(display: Int, column: Int, text: String)]
    /// Called when a frame drawn by the engine is on the screen, if the engine can tell (Gingham).
    var framePresented: (() -> Void)? { get set }
}

extension Engine {
    var desyncCount: Int { 0 }
    var rendered: (rows: Int, columns: Int)? { nil }
    func shownTexts() -> [(display: Int, column: Int, text: String)] { [] }
    var showsRows: Bool { true }
    var framePresented: (() -> Void)? {
        get { nil }
        set {}
    }
}
