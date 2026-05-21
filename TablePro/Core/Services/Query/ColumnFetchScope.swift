//
//  ColumnFetchScope.swift
//  TablePro
//

import Foundation

enum ColumnFetchScope {
    static func selectColumns(
        schemaColumns: [String],
        hiddenColumns: Set<String>,
        primaryKeyColumns: [String]
    ) -> [String]? {
        guard !hiddenColumns.isEmpty, !schemaColumns.isEmpty else { return nil }
        let primaryKeys = Set(primaryKeyColumns)
        let kept = schemaColumns.filter { !hiddenColumns.contains($0) || primaryKeys.contains($0) }
        guard !kept.isEmpty, kept.count < schemaColumns.count else { return nil }
        return kept
    }
}
