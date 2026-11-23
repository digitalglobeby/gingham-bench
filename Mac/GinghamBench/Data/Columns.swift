//
//  Columns.swift
//  Gingham Bench
//
//  What every engine shows: the same columns, the same values and the same text for them.
//  A scenario's store describes its columns with `ColumnSpec` and hands out values through
//  `BenchSource`; Gingham formats numbers itself (`GHValueFormat`), the other engines through
//  `BenchFormat`, which writes the same text (checked by `--check-formats`).
//

import AppKit
import Gingham

nonisolated enum ColumnKind: Sendable {
    /// Text (`BenchSource.text`).
    case text
    /// A number (`BenchSource.number`, NaN when empty), shown with `digits` after the point.
    case number
    /// A number shown as a percentage (0.0123 is "1.23%").
    case percent
    /// Microseconds since 1970 (`BenchSource.number`), shown as the local time `HH:mm:ss.SSS`.
    case time
}

nonisolated struct ColumnSpec: Sendable {
    let id: String
    let title: String
    let width: CGFloat
    let kind: ColumnKind
    var digits = 2

    var isTrailing: Bool { kind != .text }
    var isNumeric: Bool { kind != .text }
}

/// A column to sort by.
nonisolated struct SortSpec: Sendable, Equatable {
    var column: Int
    var ascending: Bool
}

/// The rows a scenario shows, read by every engine on the main thread.
protocol BenchSource: AnyObject {
    var columns: [ColumnSpec] { get }
    var rowCount: Int { get }
    /// A number, percent or time column's value (NaN: empty).
    func number(_ row: Int, _ column: Int) -> Double
    /// A text column's value ("" is empty).
    func text(_ row: Int, _ column: Int) -> String
    /// The row's identity: stays with the record while rows move (SwiftUI's `Identifiable`,
    /// Gingham's `identifierForRow`).
    func identifier(_ row: Int) -> Int
    /// Whether the rows never change (the sort scenario): the tuned engines then sort them in
    /// the background.
    var isStatic: Bool { get }
}

extension BenchSource {
    var isStatic: Bool { false }
}

/// The text of a cell for NSTableView, NSCollectionView and SwiftUI's Table: the same text
/// Gingham shows for the same value (grouping separators, the digits asked for, the current
/// locale). The format styles are made once per column kind and number of digits.
enum BenchFormat {
    private static var numberStyles: [Int: FloatingPointFormatStyle<Double>] = [:]
    private static var percentStyles: [Int: FloatingPointFormatStyle<Double>.Percent] = [:]

    static func number(_ value: Double, digits: Int) -> String {
        if value.isNaN { return "" }
        let style = numberStyles[digits] ?? {
            let style = FloatingPointFormatStyle<Double>(locale: .current).precision(.fractionLength(digits))
            numberStyles[digits] = style
            return style
        }()
        return style.format(value)
    }

    static func percent(_ value: Double, digits: Int) -> String {
        if value.isNaN { return "" }
        let style = percentStyles[digits] ?? {
            let style = FloatingPointFormatStyle<Double>.Percent(locale: .current).precision(.fractionLength(digits))
            percentStyles[digits] = style
            return style
        }()
        return style.format(value)
    }

    /// A cell's text.
    static func text(_ source: BenchSource, row: Int, column: Int) -> String {
        let spec = source.columns[column]
        switch spec.kind {
        case .text: return source.text(row, column)
        case .number: return number(source.number(row, column), digits: spec.digits)
        case .percent: return percent(source.number(row, column), digits: spec.digits)
        case .time: return time(microseconds: source.number(row, column))
        }
    }

    /// `HH:mm:ss.SSS` in the local time zone, made by hand (a date formatter per cell would cost
    /// more than the rest of the cell). Gingham gets this same text.
    nonisolated static func time(microseconds: Double) -> String {
        if microseconds.isNaN { return "" }
        let milliseconds = Int64(microseconds / 1000) + Int64(localOffset) * 1000
        let day = ((milliseconds % 86_400_000) + 86_400_000) % 86_400_000
        let (hours, minutes, seconds, millis) = (day / 3_600_000, day / 60_000 % 60, day / 1000 % 60, day % 1000)
        func two(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let three = millis < 10 ? "00\(millis)" : millis < 100 ? "0\(millis)" : "\(millis)"
        return "\(two(hours)):\(two(minutes)):\(two(seconds)).\(three)"
    }

    nonisolated private static let localOffset = TimeZone.current.secondsFromGMT()

    /// Gingham's format for a column (what `text` above writes for the others).
    static func ginghamFormat(_ spec: ColumnSpec) -> GHValueFormat {
        switch spec.kind {
        case .text, .time: .automatic
        case .number: .number(fractionDigits: spec.digits)
        case .percent: .percent(fractionDigits: spec.digits)
        }
    }

    /// Compares this formatting with Gingham's for some values; the differences, if any.
    static func differencesFromGingham() -> [String] {
        let values: [Double] = [0, 1, -1, 0.5, 1234.5678, -98765.4321, 0.000123, 12_345_678.9, 3.14159, 1e9, 0.0123]
        var differences: [String] = []
        for digits in [0, 2, 4] {
            for value in values {
                let ours = number(value, digits: digits), theirs = GHValueFormat.number(fractionDigits: digits).string(for: value)
                if ours != theirs { differences.append("number \(value) (\(digits) digits): \"\(ours)\" vs Gingham's \"\(theirs)\"") }
            }
        }
        for value in values {
            let ours = percent(value, digits: 2), theirs = GHValueFormat.percent(fractionDigits: 2).string(for: value)
            if ours != theirs { differences.append("percent \(value): \"\(ours)\" vs Gingham's \"\(theirs)\"") }
        }
        return differences
    }
}
