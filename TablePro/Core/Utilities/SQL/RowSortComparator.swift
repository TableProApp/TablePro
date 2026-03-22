//
//  RowSortComparator.swift
//  TablePro
//
//  Type-aware row value comparator for grid sorting.
//

import Foundation

/// Type-aware row value comparator for grid sorting.
/// Uses String.compare with .numeric option and type-specific fast paths for integer/decimal columns.
internal enum RowSortComparator {
    internal static func compare(_ lhs: String, _ rhs: String, columnType: ColumnType?) -> ComparisonResult {
        if let columnType {
            switch columnType {
            case .integer:
                if let l = Int64(lhs), let r = Int64(rhs) {
                    return l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
                }
            case .decimal:
                if let l = Double(lhs), let r = Double(rhs) {
                    return l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
                }
            default:
                break
            }
        }
        return lhs.compare(rhs, options: [.numeric])
    }
}
