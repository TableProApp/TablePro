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

    /// Primary key column name (if exists)
    let primaryKeyColumn: String?

    /// Number of columns
    var columnCount: Int {
        columns.count
    }

    /// Get index of primary key column
    var primaryKeyIndex: Int? {
        guard let pkColumn = primaryKeyColumn else { return nil }
        return columns.firstIndex(of: pkColumn)
    }

    /// Check if a column name exists
    func hasColumn(_ name: String) -> Bool {
        columns.contains(name)
    }

    /// Get column index by name
    func columnIndex(for name: String) -> Int? {
        columns.firstIndex(of: name)
    }
}
