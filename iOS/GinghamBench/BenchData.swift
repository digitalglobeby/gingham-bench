import Foundation
import Observation
import UIKit

// The rows every engine shows: a campaign's name and six numbers, some of
// them changing all the time (a live feed). Every engine reads the same
// objects and the same columns.
//
// Each row is an `@Observable` object with one property per column, so
// SwiftUI redraws only the cells whose values changed (SwiftUI's best case:
// no diffing of the whole list); the UIKit engines and Gingham are told which
// rows changed, as a feed's handler would.

/// The columns, in the order they show.
enum BenchColumn: String, CaseIterable {
    case name, clicks, views, spend, revenue, profit, roi

    var title: String {
        switch self {
        case .name: "Name"
        case .clicks: "Clicks"
        case .views: "Views"
        case .spend: "Spend"
        case .revenue: "Revenue"
        case .profit: "Profit"
        case .roi: "ROI"
        }
    }

    /// The columns with numbers (all but the name).
    static let numbers: [BenchColumn] = [.clicks, .views, .spend, .revenue, .profit, .roi]
    /// The columns a change touches (`BenchData.tick`): spend and what follows from it.
    static let changing: [BenchColumn] = [.spend, .profit, .roi]

    /// The column's index among all columns (the name is 0).
    var index: Int { Self.allCases.firstIndex(of: self)! }
}

@Observable
final class BenchRow: Identifiable {
    let id: Int
    let name: String
    var clicks: Double
    var views: Double
    var spend: Double
    var revenue: Double
    var profit: Double
    var roi: Double

    init(id: Int, name: String, clicks: Double, views: Double, spend: Double, revenue: Double) {
        self.id = id
        self.name = name
        self.clicks = clicks
        self.views = views
        self.spend = spend
        self.revenue = revenue
        profit = revenue - spend
        roi = spend > 0 ? (revenue - spend) / spend : 0
    }

    /// A number column's value. Reads (and so observes) only that property.
    func value(_ column: BenchColumn) -> Double {
        switch column {
        case .name: .nan
        case .clicks: clicks
        case .views: views
        case .spend: spend
        case .revenue: revenue
        case .profit: profit
        case .roi: roi
        }
    }
}

@MainActor
final class BenchData {
    private(set) var rows: [BenchRow] = []
    private var generator = SplitMix(seed: 7)

    /// New rows (the old ones are dropped). The same count gives the same
    /// rows and the same sequence of changes, so every engine and every run
    /// gets the same data.
    func make(count: Int) {
        var generator = SplitMix(seed: UInt64(count))
        var rows: [BenchRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let spend = Double(generator.next() % 500_000) / 100
            let revenue = spend * (0.5 + Double(generator.next() % 170) / 100)
            rows.append(BenchRow(id: index, name: "Campaign \(index + 1)", clicks: Double(generator.next() % 50_000),
                                 views: Double(generator.next() % 900_000), spend: spend, revenue: revenue))
        }
        self.rows = rows
        self.generator = SplitMix(seed: 7)
    }

    /// Changes `count` rows' spend (and the profit and ROI that follow from
    /// it); returns the rows changed (a row may repeat) and how many were on
    /// screen. A share of the changes (`screenShare`) goes to rows on or near
    /// the screen (`screen`), the rest to rows anywhere: with 100,000 rows,
    /// random changes alone would almost never reach the dozen rows shown.
    func tick(changing count: Int, screen: Range<Int>?, screenShare: Double) -> (rows: [Int], onScreen: Int) {
        guard !rows.isEmpty, count > 0 else { return ([], 0) }
        var changed: [Int] = []
        changed.reserveCapacity(count)
        var onScreen = 0
        let screen = screen.map { $0.clamped(to: 0..<rows.count) }
        for _ in 0..<count {
            let index: Int
            if let screen, !screen.isEmpty, Double(generator.next() % 10_000) < screenShare * 10_000 {
                index = screen.lowerBound + Int(generator.next() % UInt64(screen.count))
                onScreen += 1
            } else {
                index = Int(generator.next() % UInt64(rows.count))
            }
            let row = rows[index]
            let spend = row.spend + Double(generator.next() % 500) / 100
            row.spend = spend
            row.profit = row.revenue - spend
            row.roi = spend > 0 ? row.profit / spend : 0
            changed.append(index)
        }
        return (changed, onScreen)
    }
}

/// How the UIKit and SwiftUI engines show the numbers (Gingham formats its
/// own from the column's format: the same styles). Formatters are made once
/// and reused: making one per cell is the classic mistake, not made here.
@MainActor
enum BenchFormat {
    /// The locale every engine formats in (Gingham's `locale` too), so all
    /// show the same text whatever the device's region.
    static let locale = Locale(identifier: "en_US")

    static func text(_ row: BenchRow, _ column: BenchColumn) -> String {
        let value = NSNumber(value: row.value(column))
        switch column {
        case .name: return row.name
        case .clicks, .views: return integer.string(from: value) ?? ""
        case .spend, .revenue, .profit: return currency.string(from: value) ?? ""
        case .roi: return percent.string(from: value) ?? ""
        }
    }

    private static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    private static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

/// The same geometry in every engine: row height, font, column widths.
enum BenchLayout {
    static let rowHeight: CGFloat = 24
    static let fontSize: CGFloat = 15
    /// Widths of the text in a column (without the room between columns).
    static let nameWidth: CGFloat = 112
    static let numberWidth: CGFloat = 92
    /// Room between columns, and before the first one.
    static let spacing: CGFloat = 8
    static let leadingInset: CGFloat = 16

    static func width(of column: BenchColumn) -> CGFloat {
        column == .name ? nameWidth : numberWidth
    }
}

/// A small deterministic random number generator.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
