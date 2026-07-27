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

internal struct TimestampValue: Hashable {
    internal let secondsSinceEpoch: Double

    internal func equals(_ other: TimestampValue, fractionalDigits: Int) -> Bool {
        let scale = pow(10.0, Double(max(0, min(9, fractionalDigits))))
        return (secondsSinceEpoch * scale).rounded() == (other.secondsSinceEpoch * scale).rounded()
    }

    internal static func parse(_ raw: String) -> TimestampValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return nil }
        for formatter in Self.formatters {
            if let date = formatter.date(from: trimmed) {
                return TimestampValue(secondsSinceEpoch: date.timeIntervalSince1970)
            }
        }
        return nil
    }

    private static let formatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
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
