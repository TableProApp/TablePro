//
//  SpatialColumn.swift
//  TablePro
//

import Foundation

/// Identifies a result column by name rather than by position, so a map configuration survives a
/// re-execution that reorders the SELECT list. The occurrence disambiguates duplicate names.
struct SpatialColumnID: Hashable, Sendable {
    let name: String
    let occurrence: Int
}

/// A column the map can draw, decided once per column from its declared type.
///
/// Per column and never per value, for the reason the MongoDB UUID codec exists: a decision taken
/// per value lets one row in a column render as something the rest of the column is not.
struct SpatialColumn: Identifiable, Equatable, Sendable {
    let id: SpatialColumnID
    let index: Int
    let displayName: String
    let type: ColumnType

    var name: String { id.name }

    static func columns(in tableRows: TableRows) -> [SpatialColumn] {
        var occurrences: [String: Int] = [:]
        let totals = tableRows.columns.reduce(into: [String: Int]()) { result, name in
            result[name, default: 0] += 1
        }

        return tableRows.columns.enumerated().compactMap { index, name in
            occurrences[name, default: 0] += 1
            let occurrence = occurrences[name, default: 1]
            guard index < tableRows.columnTypes.count else { return nil }
            let type = tableRows.columnTypes[index]
            guard case .spatial = type else { return nil }
            let displayName = totals[name, default: 0] > 1 ? "\(name) (\(occurrence))" : name
            return SpatialColumn(
                id: SpatialColumnID(name: name, occurrence: occurrence),
                index: index,
                displayName: displayName,
                type: type
            )
        }
    }

    static func hasSpatialColumn(in tableRows: TableRows) -> Bool {
        tableRows.columnTypes.contains { type in
            if case .spatial = type { return true }
            return false
        }
    }
}
