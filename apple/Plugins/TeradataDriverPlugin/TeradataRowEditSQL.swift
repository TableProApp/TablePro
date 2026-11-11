//
//  TeradataRowEditSQL.swift
//  TeradataDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLQuoting
import TableProTeradataCore

/// Teradata literals and the INSERT a new grid row becomes. The driver sends statements as text, so every value is
/// written as a literal here rather than bound.
enum TeradataRowEditSQL {
    static func literal(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let string):
            return SQLQuoting.stringLiteral(string)
        case .bytes(let data):
            return "'" + data.map { String(format: "%02X", $0) }.joined() + "'XB"
        }
    }

    static func insert(
        target: String,
        columns: [String],
        values: [PluginCellValue],
        expressionColumns: Set<Int> = [],
        defaultColumns: Set<Int> = []
    ) -> String {
        let written = zip(columns, values).enumerated().filter { !defaultColumns.contains($0.offset) }
        guard !written.isEmpty else { return "INSERT INTO \(target) DEFAULT VALUES" }
        let columnList = written.map { TeradataSchemaQueries.quoteIdentifier($0.element.0) }.joined(separator: ", ")
        let valueList = written.map { cell in
            value(cell.element.1, isExpression: expressionColumns.contains(cell.offset))
        }.joined(separator: ", ")
        return "INSERT INTO \(target) (\(columnList)) VALUES (\(valueList))"
    }

    static func assignment(column: String, value: PluginCellValue, isExpression: Bool, isDefault: Bool = false) -> String {
        let name = TeradataSchemaQueries.quoteIdentifier(column)
        guard !isDefault else { return "\(name) = DEFAULT" }
        return "\(name) = \(Self.value(value, isExpression: isExpression))"
    }

    // The host checked a marked cell's text against the engine's vocabulary before handing it over.
    private static func value(_ value: PluginCellValue, isExpression: Bool) -> String {
        guard isExpression, case .text(let sql) = value else { return literal(value) }
        return sql
    }
}
