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

    /// Drops hidden-column entries for columns that no longer exist. A hidden
    /// column is intentionally absent from the (scoped) result, so prune against
    /// the full schema when known; fall back to the result plus the current
    /// hidden set so a still-hidden column is never dropped just for being omitted.
    static func prunedHiddenColumns(
        _ hiddenColumns: Set<String>,
        schemaColumns: [String]?,
        resultColumns: [String]
    ) -> Set<String> {
        let valid: Set<String>
        if let schemaColumns, !schemaColumns.isEmpty {
            valid = Set(schemaColumns)
        } else {
            valid = Set(resultColumns).union(hiddenColumns)
        }
        return hiddenColumns.intersection(valid)
    }
}
