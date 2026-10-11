//
//  TeradataRowEditSQL.swift
//  TeradataDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProTeradataCore

/// Teradata literals and the INSERT a new grid row becomes. The driver sends statements as text, so every value is
/// written as a literal here rather than bound.
enum TeradataRowEditSQL {
    /// What the grid stages for a column the user leaves to the server's default. It is a marker, never a value.
    static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    static func literal(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let string):
            return "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
        case .bytes(let data):
            return "'" + data.map { String(format: "%02X", $0) }.joined() + "'XB"
        }
    }

    static func insert(target: String, columns: [String], values: [PluginCellValue]) -> String {
        let written = zip(columns, values).filter { $0.1 != defaultMarker }
        guard !written.isEmpty else { return "INSERT INTO \(target) DEFAULT VALUES" }
        let columnList = written.map { TeradataSchemaQueries.quoteIdentifier($0.0) }.joined(separator: ", ")
        let valueList = written.map { literal($0.1) }.joined(separator: ", ")
        return "INSERT INTO \(target) (\(columnList)) VALUES (\(valueList))"
    }
}
