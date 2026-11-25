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

    /// The room between two columns: NSTableView's intercell spacing (and the collection view's).
    static let spacing: CGFloat = 6
    /// SwiftUI Table's room between two columns (its NSTableView's intercell spacing).
    static let swiftUISpacing: CGFloat = 17
    /// What the column takes on the screen, the same in every engine (so all show the same columns):
    /// its width and the spacing. Gingham's columns have no spacing (their width is all of it), SwiftUI's
    /// are its width less SwiftUI's larger spacing.
    var pitch: CGFloat { width + Self.spacing }
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

    /// The text a SwiftUI cell shows for its value (`SwiftUICellView`).
    static func text(of value: SwiftUICell, spec: ColumnSpec) -> String {
        switch (value, spec.kind) {
        case (.text(let text), _): return text
        case (.number(let number), .percent): return percent(number, digits: spec.digits)
        case (.number(let number), .time): return time(microseconds: number)
        case (.number(let number), _): return number.isNaN ? "" : self.number(number, digits: spec.digits)
        }
    }

    /// A cell's text as the tuned engines make it: the same text, numbers written by hand
    /// (`FastFormat`) instead of through Foundation's format styles, as an expert's app does for a
    /// table whose values change thousands of times a second.
    static func tunedText(_ source: BenchSource, row: Int, column: Int) -> String {
        let spec = source.columns[column]
        switch spec.kind {
        case .text: return source.text(row, column)
        case .number: return FastFormat.number(source.number(row, column), digits: spec.digits)
        case .percent: return FastFormat.percent(source.number(row, column), digits: spec.digits)
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

    /// Compares this formatting with Gingham's for some values, and the tuned engines' hand-made
    /// numbers with Foundation's for a million; the differences, if any.
    static func differencesFromGingham() -> [String] {
        var differences = FastFormat.differences(samples: 1_000_000)
        let values: [Double] = [0, 1, -1, 0.5, 1234.5678, -98765.4321, 0.000123, 12_345_678.9, 3.14159, 1e9, 0.0123]
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

/// Numbers written by hand, the text Foundation's `FloatingPointFormatStyle` writes for the current
/// locale (grouping and decimal separators, minus sign, the digits asked for, rounded half to even
/// as Foundation rounds the exact value): what an expert's app does for live data, where Foundation's
/// format styles cost microseconds a value. Used by the tuned engines (NSTableView tuned and
/// cell-based, NSCollectionView); the typical ones keep Foundation's. The locale's symbols are taken
/// from Foundation's own text and checked on probe values at startup: a locale it doesn't write the
/// same way (other digits, other grouping) gets Foundation's text, as does a value whose rounding
/// can't be told apart from a tie, or a very large one. `--check-formats` compares a million values.
nonisolated enum FastFormat {
    private struct Symbols {
        var group: [UInt8] = []
        var decimal: [UInt8] = []
        var minus: [UInt8] = []
        var percentSuffix: [UInt8] = []
        var numbers = false
        var percents = false
    }

    private static let symbols = makeSymbols()
    private static let scales: [Double] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]
    private static let divisors: [UInt64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]

    static func foundationNumber(_ value: Double, digits: Int) -> String {
        value.isNaN ? "" : FloatingPointFormatStyle<Double>(locale: .current).precision(.fractionLength(digits)).format(value)
    }

    static func foundationPercent(_ value: Double, digits: Int) -> String {
        value.isNaN ? "" : FloatingPointFormatStyle<Double>.Percent(locale: .current).precision(.fractionLength(digits)).format(value)
    }

    static func number(_ value: Double, digits: Int) -> String {
        if value.isNaN { return "" }
        let symbols = symbols
        guard symbols.numbers, let text = write(value, digits: digits, symbols: symbols, suffix: nil) else {
            return foundationNumber(value, digits: digits)
        }
        return text
    }

    static func percent(_ value: Double, digits: Int) -> String {
        if value.isNaN { return "" }
        let symbols = symbols
        guard symbols.percents, let text = write(value * 100, digits: digits, symbols: symbols, suffix: symbols.percentSuffix) else {
            return foundationPercent(value, digits: digits)
        }
        return text
    }

    /// nil: Foundation's text instead (a tie or nearly, a very large value, many digits).
    private static func write(_ value: Double, digits: Int, symbols: Symbols, suffix: [UInt8]?) -> String? {
        guard digits >= 0, digits < scales.count else { return nil }
        let magnitude = abs(value) * scales[digits]
        guard magnitude < 1e12 else { return nil }
        // The product is within an ulp or so of the exact value's: only near a tie could the two
        // round apart.
        let fraction = magnitude - magnitude.rounded(.down)
        if abs(fraction - 0.5) <= max(magnitude.ulp * 8, 1e-12) { return nil }
        let whole = UInt64(magnitude.rounded(.toNearestOrEven))
        let divisor = divisors[digits]
        var integer = whole / divisor, part = whole % divisor
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        if value.sign == .minus { bytes += symbols.minus }
        // The integer's digits, last first, with a separator every three.
        var reversed: [UInt8] = []
        reversed.reserveCapacity(24)
        var written = 0
        repeat {
            if written > 0, written % 3 == 0 { reversed += symbols.group.reversed() }
            reversed.append(UInt8(48 + integer % 10))
            integer /= 10
            written += 1
        } while integer > 0
        bytes += reversed.reversed()
        if digits > 0 {
            bytes += symbols.decimal
            var fractionDigits = [UInt8](repeating: 48, count: digits)
            for index in stride(from: digits - 1, through: 0, by: -1) {
                fractionDigits[index] = UInt8(48 + part % 10)
                part /= 10
            }
            bytes += fractionDigits
        }
        if let suffix { bytes += suffix }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The symbols, read from Foundation's text of 1,234,567.5, -1 and 50%, then checked.
    private static func makeSymbols() -> Symbols {
        var symbols = Symbols()
        let sample = Array(foundationNumber(1_234_567.5, digits: 1).utf8)
        let digits = Set(Array("0123456789".utf8))
        // "1" group "234" group "567" decimal "5", digits ASCII.
        guard sample.first == UInt8(ascii: "1"), sample.last == UInt8(ascii: "5"),
              let at234 = find(Array("234".utf8), in: sample), let at567 = find(Array("567".utf8), in: sample), at567 > at234 + 3,
              Array(sample[(at234 + 3) ..< at567]) == Array(sample[1 ..< at234]) else { return symbols }
        symbols.group = Array(sample[1 ..< at234])
        symbols.decimal = Array(sample[(at567 + 3) ..< (sample.count - 1)])
        let minusOne = Array(foundationNumber(-1, digits: 0).utf8)
        guard minusOne.last == UInt8(ascii: "1"), !symbols.group.contains(where: digits.contains), !symbols.decimal.isEmpty else { return symbols }
        symbols.minus = Array(minusOne.dropLast())
        let half = Array(foundationPercent(0.5, digits: 0).utf8)
        if half.starts(with: Array("50".utf8)) { symbols.percentSuffix = Array(half.dropFirst(2)) }
        // Checked on values that show the grouping rules (a locale that groups only from five
        // digits on), ties and signs: any difference and Foundation writes them all.
        var numbers = true, percents = !symbols.percentSuffix.isEmpty
        let probes: [Double] = [0, 1, -1, 0.5, 2.5, -2.5, 12.5, 999.995, 1234.5, 1234.5678, -98765.4321, 12345.25, 1_234_567.125,
                                0.0001234, 3.14159, 1e9, 0.0123, -0.001, 123_456_789.987]
        for value in probes {
            for count in [0, 2, 4] {
                if let text = write(value, digits: count, symbols: symbols, suffix: nil), text != foundationNumber(value, digits: count) { numbers = false }
            }
            if let text = write(value * 100, digits: 2, symbols: symbols, suffix: symbols.percentSuffix), text != foundationPercent(value, digits: 2) {
                percents = false
            }
        }
        symbols.numbers = numbers
        symbols.percents = numbers && percents
        return symbols
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0 ... haystack.count - needle.count where Array(haystack[start ..< start + needle.count]) == needle { return start }
        return nil
    }

    /// The hand-made text against Foundation's for random values of the scenarios' sizes.
    static func differences(samples: Int) -> [String] {
        var random = SeededRandom(seed: 5)
        var found: [String] = []
        var mismatches = 0
        for index in 0..<samples {
            let magnitude = pow(10, random.uniform() * 14 - 5)
            let value = (random.below(4) == 0 ? -1 : 1) * magnitude
            let digits = [0, 2, 4][index % 3]
            let (ours, theirs) = index % 5 == 0 ? (percent(value / 100, digits: 2), foundationPercent(value / 100, digits: 2))
                : (number(value, digits: digits), foundationNumber(value, digits: digits))
            if ours != theirs {
                mismatches += 1
                if found.count < 10 { found.append("hand-made \"\(ours)\" vs Foundation's \"\(theirs)\" for \(value) (\(digits) digits)") }
            }
        }
        if !symbols.numbers { found.append("note: this locale's numbers aren't written by hand (Foundation writes them)") }
        if mismatches > 0 { found.append("\(mismatches) of \(samples) hand-made numbers differ from Foundation's") }
        return found
    }
}
