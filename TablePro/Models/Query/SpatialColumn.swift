//
//  SpatialColumn.swift
//  TablePro
//

import Foundation
import TableProGeometry
import TableProPluginKit

/// Identifies a result column by name rather than by position, so a map configuration survives a
/// re-execution that reorders the SELECT list. The occurrence disambiguates duplicate names.
struct SpatialColumnID: Hashable, Sendable {
    let name: String
    let occurrence: Int
}

/// A column the map can draw, decided once per column from its declared type and a sample of its
/// values.
///
/// Per column and never per value, for the reason the MongoDB UUID codec exists: a decision taken
/// per value lets one row in a column render as something the rest of the column is not. Sampling
/// still decides the column, the way `BsonDocumentFlattener.columnKinds` votes on one.
///
/// The declared type alone cannot answer this, and it is wrong in both directions. Oracle's
/// `SDO_GEOMETRY`, Teradata's `ST_GEOMETRY` and SQL Server's `geography` all classify `.spatial`
/// and hand over text no reader can draw, SQL Server's being MS-SSCLRT serialization rather than
/// WKB, so a type-only gate offered Map and then drew nothing. MongoDB goes the other way: its
/// GeoJSON arrives in a column the app types `JSON`, so a type-only gate never offered Map at all.
struct SpatialColumn: Identifiable, Equatable, Sendable {
    let id: SpatialColumnID
    let index: Int
    let displayName: String
    let type: ColumnType

    var name: String { id.name }

    /// How many of a column's values are read before it is accepted or refused. Four is enough to
    /// pass a column whose leading rows are NULL without paying for the projection twice.
    private static let sampleSize = 4

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
            guard drawable(type, at: index, in: tableRows) else { return nil }
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
        for (index, type) in tableRows.columnTypes.enumerated() {
            if drawable(type, at: index, in: tableRows) { return true }
        }
        return false
    }

    /// The two declarations carry different weight, so they are judged differently.
    ///
    /// A `.spatial` column is the engine's own word that the column holds geometry, so it is
    /// believed unless the values contradict it: an empty result and an all-NULL column both keep
    /// the Map segment, which is what stops the mode from appearing and vanishing as pages load. A
    /// `JSON` column says nothing about geometry, so it has to earn the segment by holding a value
    /// that reads.
    private static func drawable(_ type: ColumnType, at index: Int, in tableRows: TableRows) -> Bool {
        switch type {
        case .spatial:
            let sample = sampleGeometry(at: index, in: tableRows)
            return sample.readable > 0 || sample.unreadable == 0
        case .json:
            return sampleGeometry(at: index, in: tableRows).readable > 0
        default:
            return false
        }
    }

    /// A value that reads as an empty geometry counts as neither: `POINT EMPTY` is a legitimate
    /// value that says nothing about whether the column can be drawn.
    private static func sampleGeometry(
        at index: Int,
        in tableRows: TableRows
    ) -> (readable: Int, unreadable: Int) {
        var readable = 0
        var unreadable = 0
        var sampled = 0
        for row in tableRows.rows {
            guard index < row.values.count, let text = row[index].spatialText else { continue }
            sampled += 1
            switch SpatialValueReader.read(text) {
            case .success(let value):
                if value.geometry.isEmpty { break }
                readable += 1
                return (readable, unreadable)
            case .failure:
                unreadable += 1
            }
            guard sampled < sampleSize else { break }
        }
        return (readable, unreadable)
    }
}

extension PluginCellValue {
    /// The text a geometry reader is given for this cell.
    ///
    /// A driver hands geometry over as text on every engine the reader supports, so `.bytes` is
    /// read through `sortKey`, which is the hex spelling the grid shows: that is what a PostGIS
    /// column whose `ST_AsEWKT` rewrite failed arrives as.
    var spatialText: String? {
        switch self {
        case .null:
            return nil
        case .text(let text):
            return text.isEmpty ? nil : text
        case .bytes(let data):
            return data.isEmpty ? nil : sortKey
        }
    }
}
