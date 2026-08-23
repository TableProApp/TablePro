//
//  InClauseConverter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct InClauseConverter {
    internal let columnIndex: Int
    internal let columnTypes: [ColumnType]
    internal let escapeStringLiteral: ((String) -> String)?

    private static let maxRows = 50_000

    func generateInClause(rows: [[PluginCellValue]]) -> String {
        let cappedRows = rows.prefix(Self.maxRows)
        let columnType: ColumnType = columnTypes.indices.contains(columnIndex)
            ? columnTypes[columnIndex]
            : .text(rawType: nil)

        let values: [String] = cappedRows.compactMap { row in
            guard row.indices.contains(columnIndex) else { return nil }
            return format(cell: row[columnIndex], type: columnType)
        }

        guard !values.isEmpty else { return "()" }
        return "(\(values.joined(separator: ", ")))"
    }

    private func format(cell: PluginCellValue, type: ColumnType) -> String? {
        switch cell {
        case .null, .bytes:
            return nil
        case .text(let value):
            return formatScalar(value, type: type)
        }
    }

    private func formatScalar(_ value: String, type: ColumnType) -> String {
        if type.isBooleanType {
            guard let synonym = ColumnTypeSQLQuoting.booleanSynonym(for: value) else { return quoted(value) }
            switch synonym {
            case .isTrue:
                return "TRUE"
            case .isFalse:
                return "FALSE"
            @unknown default:
                return quoted(value)
            }
        }
        guard ColumnTypeSQLQuoting.isNumericLiteral(value, for: type) else { return quoted(value) }
        return value
    }

    private func quoted(_ value: String) -> String {
        let escaped = escapeStringLiteral?(value) ?? value.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }
}
