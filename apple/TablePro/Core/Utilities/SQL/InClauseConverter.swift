//
//  InClauseConverter.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLQuoting

internal struct InClauseConverter {
    internal let columnIndex: Int
    internal let columnTypes: [ColumnType]
    internal let escapeStringLiteral: ((String) -> String)?

    /// What the engine puts in front of a string literal. SQL Server's `N` is the only one, and
    /// without it an `IN` list pasted into a query on a non-Unicode collation matches the rows
    /// whose text was already damaged rather than the rows the user copied.
    internal var stringLiteralPrefix: String = ""

    // The session's escapes, for when no driver escaper is passed.
    internal var stringEscapes: SQLStringEscapes = .standard

    // SQL Server has no TRUE or FALSE: `flag IN (TRUE)` reads TRUE as a column name.
    internal var booleanLiteralStyle: SQLDialectDescriptor.BooleanLiteralStyle = .truefalse

    // Picks the binary literal's spelling; without one it is the standard X'...'.
    internal var databaseType: DatabaseType?

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
        case .null:
            return nil
        case .bytes(let data):
            return binaryLiteral(data)
        case .text(let value):
            return formatScalar(value, type: type)
        }
    }

    private func binaryLiteral(_ data: Data) -> String {
        databaseType.flatMap { CompareSQLLiteral.binaryLiteral(for: data, databaseType: $0) } ?? "X'\(data.uppercaseHex())'"
    }

    private func formatScalar(_ value: String, type: ColumnType) -> String {
        if type.isBooleanType {
            guard let synonym = ColumnTypeSQLQuoting.booleanSynonym(for: value) else { return quoted(value) }
            let isNumeric = booleanLiteralStyle == .numeric
            switch synonym {
            case .isTrue:
                return isNumeric ? "1" : "TRUE"
            case .isFalse:
                return isNumeric ? "0" : "FALSE"
            @unknown default:
                return quoted(value)
            }
        }
        guard ColumnTypeSQLQuoting.isNumericLiteral(value, for: type) else { return quoted(value) }
        return value
    }

    private func quoted(_ value: String) -> String {
        let escaped = escapeStringLiteral?(value) ?? SQLQuoting.stringLiteralBody(value, escapes: stringEscapes)
        return "\(stringLiteralPrefix)'\(escaped)'"
    }
}
