//
//  ResultChartColumn.swift
//  TablePro
//

import Foundation

struct ResultChartColumn: Identifiable, Equatable, Sendable {
    enum AxisKind: Equatable, Sendable {
        case category
        case number
    }

    let index: Int
    let name: String
    let displayName: String
    let type: ColumnType

    var id: Int { index }

    var xAxisKind: AxisKind? {
        switch type {
        case .integer, .decimal:
            return .number
        case .text, .date, .timestamp, .datetime, .boolean, .enumType, .set:
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

    static func columns(in tableRows: TableRows) -> [ResultChartColumn] {
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
            return ResultChartColumn(index: index, name: name, displayName: displayName, type: type)
        }
    }
}
