//
//  RowSortComparator.swift
//  TablePro
//

import Foundation

internal enum RowSortComparator {
    internal static func compare(_ lhs: String, _ rhs: String, columnType: ColumnType?) -> ComparisonResult {
        if let columnType {
            switch columnType {
            case .integer:
                if let l = Int64(lhs), let r = Int64(rhs) {
                    return order(l, r)
                }
            case .decimal:
                if let l = Double(lhs), let r = Double(rhs) {
                    return order(l, r)
                }
            case .boolean:
                // MySQL's TINYINT(1) is a boolean that stores any integer from -128 to 127.
                if let l = booleanNumber(lhs), let r = booleanNumber(rhs) {
                    return order(l, r)
                }
            default:
                break
            }
        }
        return lhs.compare(rhs, options: [.numeric])
    }

    // One number per value, so `1`, `2` and `true` order the same way whichever pair is compared.
    private static func booleanNumber(_ text: String) -> Int64? {
        if let number = Int64(text) { return number }
        return StoredBoolean.value(of: text).map { $0 ? 1 : 0 }
    }

    private static func order<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }
}
