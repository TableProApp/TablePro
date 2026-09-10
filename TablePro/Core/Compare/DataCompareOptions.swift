//
//  DataCompareOptions.swift
//  TablePro
//
//  How two rows are matched and how two values are judged equal.
//  The set of columns used to compare is deliberately separate from the set
//  written: an audit column can be excluded from matching while still being
//  carried into the generated statement.
//

import Foundation
import TableProPluginKit

internal struct DataCompareOptions: Codable, Hashable, Sendable {
    internal var keyColumns: [String] = []
    internal var excludedFromComparison: Set<String> = []
    internal var insertMissingRows = true
    internal var updateDifferingRows = true
    internal var deleteExtraRows = false
    internal var floatTolerance: Double = 0
    internal var timestampFractionalDigits = 6
    internal var maxRetainedEntries = 5_000

    internal init() {}

    internal static let `default` = DataCompareOptions()

    internal var hasKey: Bool {
        !keyColumns.isEmpty
    }

    internal func comparisonColumns(from columns: [String]) -> [String] {
        let keys = Set(keyColumns.map { $0.lowercased() })
        return columns.filter { column in
            let lowered = column.lowercased()
            return !keys.contains(lowered) && !excludedFromComparison.contains(where: { $0.lowercased() == lowered })
        }
    }
}

internal enum ComparisonRule: String, Codable, Hashable, Sendable {
    case exactValue
    case nullEquality
    case floatTolerance
    case timestampPrecision
    case binaryContent
    case typeMismatch

    internal var displayName: String {
        switch self {
        case .exactValue:
            return String(localized: "Exact value")
        case .nullEquality:
            return String(localized: "NULL only equals NULL")
        case .floatTolerance:
            return String(localized: "Numeric tolerance")
        case .timestampPrecision:
            return String(localized: "Timestamp precision")
        case .binaryContent:
            return String(localized: "Binary content")
        case .typeMismatch:
            return String(localized: "Value kind differs")
        }
    }
}

internal struct ValueComparison {
    internal let isEqual: Bool
    internal let rule: ComparisonRule
}

internal struct CellValueComparator {
    private let options: DataCompareOptions

    internal init(options: DataCompareOptions) {
        self.options = options
    }

    internal func compare(_ lhs: PluginCellValue, _ rhs: PluginCellValue) -> ValueComparison {
        switch (lhs, rhs) {
        case (.null, .null):
            return ValueComparison(isEqual: true, rule: .nullEquality)
        case (.null, _), (_, .null):
            return ValueComparison(isEqual: false, rule: .nullEquality)
        case (.bytes(let left), .bytes(let right)):
            return ValueComparison(isEqual: left == right, rule: .binaryContent)
        case (.text(let left), .text(let right)):
            return compareText(left, right)
        default:
            return ValueComparison(isEqual: false, rule: .typeMismatch)
        }
    }

    private func compareText(_ lhs: String, _ rhs: String) -> ValueComparison {
        if lhs == rhs {
            return ValueComparison(isEqual: true, rule: .exactValue)
        }
        if options.floatTolerance > 0,
           let left = Double(lhs.trimmingCharacters(in: .whitespaces)),
           let right = Double(rhs.trimmingCharacters(in: .whitespaces)) {
            let equal = (left - right).magnitude <= options.floatTolerance
            return ValueComparison(isEqual: equal, rule: .floatTolerance)
        }
        if let left = TimestampValue.parse(lhs), let right = TimestampValue.parse(rhs) {
            let equal = left.equals(right, fractionalDigits: options.timestampFractionalDigits)
            return ValueComparison(isEqual: equal, rule: .timestampPrecision)
        }
        return ValueComparison(isEqual: false, rule: .exactValue)
    }
}

/// An instant, held as whole nanoseconds since the epoch.
///
/// `DateFormatter` clamps a fractional second to milliseconds whatever the pattern says, so
/// parsing `10:00:00.123456` and `10:00:00.123457` through it produced the same value and every
/// microsecond difference read as identical no matter what precision the user asked for. The
/// fraction is therefore split off and parsed as an integer, and the comparison stays in integer
/// arithmetic: scaling a `Double` seconds value by 1e9 leaves the exact-integer range and puts
/// the same precision loss back into the path that was just fixed.
internal struct TimestampValue: Hashable {
    internal let nanosecondsSinceEpoch: Int64

    internal func equals(_ other: TimestampValue, fractionalDigits: Int) -> Bool {
        let divisor = Self.divisor(forFractionalDigits: fractionalDigits)
        return Self.floorDivide(nanosecondsSinceEpoch, by: divisor)
            == Self.floorDivide(other.nanosecondsSinceEpoch, by: divisor)
    }

    internal static func parse(_ raw: String) -> TimestampValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return nil }
        let split = FractionalSecond.split(from: trimmed)
        for formatter in Self.formatters {
            guard let date = formatter.date(from: split.withoutFraction) else { continue }
            let seconds = date.timeIntervalSince1970.rounded()
            guard seconds.magnitude < Double(Int64.max / Self.nanosecondsPerSecond) else { return nil }
            return TimestampValue(
                nanosecondsSinceEpoch: Int64(seconds) * Self.nanosecondsPerSecond + split.nanoseconds
            )
        }
        return nil
    }

    private static func divisor(forFractionalDigits digits: Int) -> Int64 {
        let clamped = max(0, min(9, digits))
        var divisor: Int64 = 1
        for _ in 0 ..< (9 - clamped) { divisor *= 10 }
        return divisor
    }

    private static func floorDivide(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    private static let formatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]
        return patterns.map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            return formatter
        }
    }()
}

/// Splits `.123456` off a timestamp so the whole-second part can go through `DateFormatter` and
/// the fraction can be read exactly. Only a dot followed by digits after the time counts, so a
/// date alone and an offset like `+05:30` both pass through untouched.
internal enum FractionalSecond {
    internal struct Split {
        internal let withoutFraction: String
        internal let nanoseconds: Int64
    }

    internal static func split(from text: String) -> Split {
        guard let dot = text.firstIndex(of: "."), dot > text.startIndex else {
            return Split(withoutFraction: text, nanoseconds: 0)
        }
        let afterDot = text.index(after: dot)
        let digits = text[afterDot...].prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return Split(withoutFraction: text, nanoseconds: 0) }

        var withoutFraction = String(text[text.startIndex ..< dot])
        withoutFraction += text[text.index(afterDot, offsetBy: digits.count)...]
        return Split(withoutFraction: withoutFraction, nanoseconds: nanoseconds(from: digits))
    }

    private static func nanoseconds(from digits: Substring) -> Int64 {
        let significant = digits.prefix(9)
        guard var value = Int64(significant) else { return 0 }
        for _ in 0 ..< (9 - significant.count) { value *= 10 }
        return value
    }
}
