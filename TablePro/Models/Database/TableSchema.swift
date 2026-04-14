//
//  TableSchema.swift
//  TablePro
//
//  Represents table structure metadata for row parsing and validation.
//

import Foundation

/// Represents the structure of a database table
struct TableSchema {
    /// Column names in order
    let columns: [String]

    /// Primary key column names (empty if no PK). Supports composite keys.
    let primaryKeyColumns: [String]

    /// First primary key column name, for UI contexts that need a single column
    /// (e.g., default filter column, ORDER BY).
    var primaryKeyColumn: String? { primaryKeyColumns.first }

    /// Number of columns
    var columnCount: Int {
        columns.count
    }

    /// Get indices of all primary key columns
    var primaryKeyIndices: [Int] {
        primaryKeyColumns.compactMap { columns.firstIndex(of: $0) }
    }

    /// Get index of first primary key column
    var primaryKeyIndex: Int? { primaryKeyIndices.first }

    /// Check if a column name exists
    func hasColumn(_ name: String) -> Bool {
        columns.contains(name)
    }

    /// Get column index by name
    func columnIndex(for name: String) -> Int? {
        columns.firstIndex(of: name)
    }
}
