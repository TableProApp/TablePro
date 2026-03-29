//
//  BigQueryStatementGenerator.swift
//  BigQueryDriverPlugin
//
//  Generates GoogleSQL DML statements (INSERT, UPDATE, DELETE) from tracked cell changes.
//

import Foundation
import os
import TableProPluginKit

internal struct BigQueryStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryStatementGenerator")

    let projectId: String
    let dataset: String
    let tableName: String
    let columns: [String]
    let columnTypeNames: [String]

    private var fullyQualifiedTable: String {
        "`\(projectId).\(dataset).\(tableName)`"
    }

    func generateStatements(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])] {
        var statements: [(statement: String, parameters: [String?])] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateInsert(for: change, insertedRowData: insertedRowData) {
                    statements.append(stmt)
                }
            case .update:
                if let stmt = generateUpdate(for: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateDelete(for: change) {
                    statements.append(stmt)
                }
            }
        }

        return statements
    }

    // MARK: - INSERT

    private func generateInsert(
        for change: PluginRowChange,
        insertedRowData: [Int: [String?]]
    ) -> (statement: String, parameters: [String?])? {
        var values: [String: String?] = [:]

        if let rowData = insertedRowData[change.rowIndex] {
            for (index, column) in columns.enumerated() where index < rowData.count {
                values[column] = rowData[index]
            }
        } else {
            for cellChange in change.cellChanges {
                values[cellChange.columnName] = cellChange.newValue
            }
        }

        var colNames: [String] = []
        var colValues: [String] = []

        for column in columns {
            guard let value = values[column] else { continue }
            let typeIndex = columns.firstIndex(of: column) ?? 0
            let typeName = typeIndex < columnTypeNames.count ? columnTypeNames[typeIndex] : "STRING"
            colNames.append(quoteIdentifier(column))
            colValues.append(formatValue(value, typeName: typeName))
        }

        guard !colNames.isEmpty else {
            Self.logger.warning("Skipping INSERT - no values provided")
            return nil
        }

        let statement = "INSERT INTO \(fullyQualifiedTable) (\(colNames.joined(separator: ", "))) " +
            "VALUES (\(colValues.joined(separator: ", ")))"
        return (statement: statement, parameters: [])
    }

    // MARK: - UPDATE

    private func generateUpdate(
        for change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard !change.cellChanges.isEmpty else { return nil }

        guard let whereClause = buildWhereClause(from: change) else {
            Self.logger.warning("Skipping UPDATE - cannot build WHERE clause")
            return nil
        }

        var setClauses: [String] = []
        for cellChange in change.cellChanges {
            let typeIndex = columns.firstIndex(of: cellChange.columnName) ?? 0
            let typeName = typeIndex < columnTypeNames.count ? columnTypeNames[typeIndex] : "STRING"
            let formattedValue = formatValue(cellChange.newValue, typeName: typeName)
            setClauses.append("\(quoteIdentifier(cellChange.columnName)) = \(formattedValue)")
        }

        let statement = "UPDATE \(fullyQualifiedTable) SET \(setClauses.joined(separator: ", ")) WHERE \(whereClause)"
        return (statement: statement, parameters: [])
    }

    // MARK: - DELETE

    private func generateDelete(
        for change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard let whereClause = buildWhereClause(from: change) else {
            Self.logger.warning("Skipping DELETE - cannot build WHERE clause")
            return nil
        }

        let statement = "DELETE FROM \(fullyQualifiedTable) WHERE \(whereClause)"
        return (statement: statement, parameters: [])
    }

    // MARK: - Helpers

    private func buildWhereClause(from change: PluginRowChange) -> String? {
        guard let originalRow = change.originalRow else { return nil }

        var conditions: [String] = []
        for (index, column) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let typeName = index < columnTypeNames.count ? columnTypeNames[index] : "STRING"

            if let value = originalRow[index] {
                // Skip complex types (STRUCT/ARRAY/RECORD) — BigQuery cannot compare with =
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                    continue
                }
                conditions.append(
                    "\(quoteIdentifier(column)) = \(formatValue(value, typeName: typeName))"
                )
            } else {
                conditions.append("\(quoteIdentifier(column)) IS NULL")
            }
        }

        guard !conditions.isEmpty else { return nil }
        return conditions.joined(separator: " AND ")
    }

    private func formatValue(_ value: String?, typeName: String) -> String {
        guard let value else { return "NULL" }

        let upperType = typeName.uppercased()

        if upperType == "INT64" || upperType == "INTEGER" ||
            upperType == "FLOAT64" || upperType == "FLOAT" ||
            upperType == "NUMERIC" || upperType == "BIGNUMERIC"
        {
            let isNumeric = value.range(
                of: #"^-?\d+(\.\d+)?([eE][+-]?\d+)?$"#,
                options: .regularExpression
            ) != nil
            if isNumeric { return value }
            return "'\(escapeString(value))'"
        }

        if upperType == "BOOL" || upperType == "BOOLEAN" {
            let lower = value.lowercased()
            if lower == "true" || lower == "1" { return "TRUE" }
            if lower == "false" || lower == "0" { return "FALSE" }
            return "'\(escapeString(value))'"
        }

        if value.lowercased() == "null" {
            return "NULL"
        }

        // JSON type: wrap with JSON keyword for proper literal syntax
        if upperType == "JSON" {
            return "JSON '\(escapeString(value))'"
        }

        // ARRAY: square bracket literals are valid GoogleSQL
        if upperType.hasPrefix("ARRAY"), value.hasPrefix("[") {
            return value
        }

        // STRUCT: pass through — user must enter valid BigQuery STRUCT literal
        if upperType.hasPrefix("STRUCT") {
            return value
        }

        // BYTES: displayed as base64, wrap with FROM_BASE64() for editing
        if upperType == "BYTES" {
            return "FROM_BASE64('\(escapeString(value))')"
        }

        // Temporal types need explicit casting for WHERE clause comparisons
        if upperType == "TIMESTAMP" {
            return "TIMESTAMP '\(escapeString(value))'"
        }
        if upperType == "DATE" {
            return "DATE '\(escapeString(value))'"
        }
        if upperType == "DATETIME" {
            return "DATETIME '\(escapeString(value))'"
        }
        if upperType == "TIME" {
            return "TIME '\(escapeString(value))'"
        }

        return "'\(escapeString(value))'"
    }

    private func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "\\`")
        return "`\(escaped)`"
    }

    private func escapeString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "'", with: "''")
    }
}
