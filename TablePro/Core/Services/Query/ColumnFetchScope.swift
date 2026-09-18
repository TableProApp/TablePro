//
//  ColumnFetchScope.swift
//  TablePro
//

import Foundation

enum ColumnFetchScope {
    /// Sort columns are retained the way primary keys are: a browse query resolves its sort
    /// against the list it is handed, so a sorted column dropped from the projection leaves
    /// nothing to sort by and the order is silently lost.
    static func selectColumns(
        schemaColumns: [String],
        hiddenColumns: Set<String>,
        primaryKeyColumns: [String],
        sortColumns: [String] = []
    ) -> [String]? {
        guard !hiddenColumns.isEmpty, !schemaColumns.isEmpty else { return nil }
        let schema = Set(schemaColumns)
        guard sortColumns.allSatisfy(schema.contains) else { return nil }
        let retained = Set(primaryKeyColumns).union(sortColumns)
        let kept = schemaColumns.filter { !hiddenColumns.contains($0) || retained.contains($0) }
        guard !kept.isEmpty, kept.count < schemaColumns.count else { return nil }
        return kept
    }

    /// Every column the visibility picker must offer: the known schema, then anything the
    /// result carries that the schema missed, then columns still hidden from both.
    ///
    /// A schemaless store can return fields the schema sample never saw. Hiding matches on
    /// name, so a column the grid renders but the picker never lists cannot be hidden at all.
    static func visibilityPickerColumns(
        schemaColumns: [String]?,
        resultColumns: [String],
        hiddenColumns: Set<String>
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for name in (schemaColumns ?? []) + resultColumns where !seen.contains(name) {
            seen.insert(name)
            ordered.append(name)
        }
        let missingHidden = hiddenColumns.subtracting(seen)
        return missingHidden.isEmpty ? ordered : ordered + missingHidden.sorted()
    }

    /// Drops hidden-column entries for columns that no longer exist. A hidden
    /// column is intentionally absent from the (scoped) result, so prune against
    /// the schema and the result together; either alone drops a column the other
    /// one still knows about.
    static func prunedHiddenColumns(
        _ hiddenColumns: Set<String>,
        schemaColumns: [String]?,
        resultColumns: [String]
    ) -> Set<String> {
        var valid = Set(resultColumns)
        if let schemaColumns, !schemaColumns.isEmpty {
            valid.formUnion(schemaColumns)
        } else {
            valid.formUnion(hiddenColumns)
        }
        return hiddenColumns.intersection(valid)
    }
}
