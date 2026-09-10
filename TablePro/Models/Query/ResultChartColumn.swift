//
//  ResultChartColumn.swift
//  TablePro
//

import Foundation

/// Identifies a result column by name rather than by position, so a chart configuration survives a
/// re-execution that reorders the SELECT list. The occurrence disambiguates duplicate names.
struct ResultChartColumnID: Hashable, Sendable {
    let name: String
    let occurrence: Int
}

struct ResultChartColumn: Identifiable, Equatable, Sendable {
    /// The three primitives Swift Charts can plot: String, Double and Date.
    enum AxisKind: Equatable, Sendable {
        case category
        case number
        case date
    }

    let id: ResultChartColumnID
    let index: Int
    let displayName: String
    let type: ColumnType
    let isPrimaryKey: Bool

    var name: String { id.name }

    var xAxisKind: AxisKind? {
        switch type {
        case .integer, .decimal:
            return .number
        case .date, .timestamp, .datetime:
            return .date
        case .text, .boolean, .enumType, .set:
            return .category
        case .blob, .json, .spatial, .array:
            return nil
        }
    }

    var supportsY: Bool {
        switch type {
        case .integer, .decimal:
            return true
        default:
            return false
        }
    }

    var supportsSeries: Bool {
        switch type {
        case .text, .boolean, .enumType, .set:
            return true
        default:
            return false
        }
    }

    static func columns(in tableRows: TableRows, primaryKeyColumns: Set<String> = []) -> [ResultChartColumn] {
        var occurrences: [String: Int] = [:]
        let totals = tableRows.columns.reduce(into: [String: Int]()) { result, name in
            result[name, default: 0] += 1
        }

        return tableRows.columns.enumerated().map { index, name in
            occurrences[name, default: 0] += 1
            let occurrence = occurrences[name, default: 1]
            let displayName = totals[name, default: 0] > 1 ? "\(name) (\(occurrence))" : name
            let type = index < tableRows.columnTypes.count
                ? tableRows.columnTypes[index]
                : .text(rawType: nil)
            return ResultChartColumn(
                id: ResultChartColumnID(name: name, occurrence: occurrence),
                index: index,
                displayName: displayName,
                type: type,
                isPrimaryKey: primaryKeyColumns.contains(name)
            )
        }
    }
}
