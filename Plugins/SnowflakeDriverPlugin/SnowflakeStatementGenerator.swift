//
//  SnowflakeStatementGenerator.swift
//  SnowflakeDriverPlugin
//
//  Generates Snowflake DML from tracked grid changes using server-side bind
//  placeholders. Semi-structured columns (VARIANT, OBJECT, ARRAY) bind through
//  PARSE_JSON, which Snowflake rejects inside a VALUES clause, so inserts that
//  touch them use the INSERT INTO ... SELECT form.
//

import Foundation
import os
import TableProPluginKit

struct SnowflakeStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeStatementGenerator")

    let qualifiedTable: String
    let columns: [String]
    let columnTypeNames: [String]
    let primaryKeyColumns: [String]

    func generateStatements(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let statement = insertStatement(for: change, insertedRowData: insertedRowData) else { continue }
                statements.append(statement)
            case .update:
                guard let statement = updateStatement(for: change) else { continue }
                statements.append(statement)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex),
                      let statement = deleteStatement(for: change) else { continue }
                statements.append(statement)
            @unknown default:
                continue
            }
        }
        return statements
    }

    static func isSemiStructured(_ typeName: String) -> Bool {
        let base = typeName.uppercased().components(separatedBy: "(")[0].trimmingCharacters(in: .whitespaces)
        return ["VARIANT", "OBJECT", "ARRAY"].contains(base)
    }

    private func insertStatement(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var values: [(column: String, value: PluginCellValue)] = []
        if let rowData = insertedRowData[change.rowIndex] {
            for (index, column) in columns.enumerated() where index < rowData.count {
                values.append((column, rowData[index]))
            }
        } else {
            for cellChange in change.cellChanges {
                values.append((cellChange.columnName, cellChange.newValue))
            }
        }
        guard !values.isEmpty else { return nil }

        let names = values.map { quoteIdentifier($0.column) }
        let placeholders = values.map { placeholder(for: $0.column) }
        let parameters = values.map(\.value)
        let usesSelect = values.contains { Self.isSemiStructured(typeName(for: $0.column)) }

        let statement = usesSelect
            ? "INSERT INTO \(qualifiedTable) (\(names.joined(separator: ", "))) SELECT \(placeholders.joined(separator: ", "))"
            : "INSERT INTO \(qualifiedTable) (\(names.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
        return (statement, parameters)
    }

    private func updateStatement(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty else { return nil }
        guard let condition = whereClause(for: change) else {
            Self.logger.error("Skipping UPDATE for \(qualifiedTable, privacy: .public): no identifying columns to build a WHERE clause")
            return nil
        }

        var setClauses: [String] = []
        var parameters: [PluginCellValue] = []
        for cellChange in change.cellChanges {
            setClauses.append("\(quoteIdentifier(cellChange.columnName)) = \(placeholder(for: cellChange.columnName))")
            parameters.append(cellChange.newValue)
        }
        parameters.append(contentsOf: condition.parameters)

        let statement = "UPDATE \(qualifiedTable) SET \(setClauses.joined(separator: ", ")) WHERE \(condition.sql)"
        return (statement, parameters)
    }

    private func deleteStatement(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let condition = whereClause(for: change) else {
            Self.logger.error("Skipping DELETE for \(qualifiedTable, privacy: .public): no identifying columns to build a WHERE clause")
            return nil
        }
        return ("DELETE FROM \(qualifiedTable) WHERE \(condition.sql)", condition.parameters)
    }

    private func whereClause(for change: PluginRowChange) -> (sql: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow else { return nil }

        let keyColumns = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        var conditions: [String] = []
        var parameters: [PluginCellValue] = []

        for column in keyColumns {
            guard let index = columns.firstIndex(of: column), index < originalRow.count else { continue }
            if Self.isSemiStructured(typeName(for: column)) { continue }
            let value = originalRow[index]
            if case .null = value {
                conditions.append("\(quoteIdentifier(column)) IS NULL")
            } else {
                conditions.append("\(quoteIdentifier(column)) = ?")
                parameters.append(value)
            }
        }

        guard !conditions.isEmpty else { return nil }
        return (conditions.joined(separator: " AND "), parameters)
    }

    private func typeName(for column: String) -> String {
        guard let index = columns.firstIndex(of: column), index < columnTypeNames.count else { return "TEXT" }
        return columnTypeNames[index]
    }

    private func placeholder(for column: String) -> String {
        Self.isSemiStructured(typeName(for: column)) ? "PARSE_JSON(?)" : "?"
    }

    private func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
