//
//  DynamoDBStatementGenerator.swift
//  DynamoDBDriverPlugin
//
//  Generates PartiQL statements from tracked cell changes.
//

import Foundation
import os
import TableProPluginKit

struct DynamoDBStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DynamoDBStatementGenerator")

    let tableName: String
    let columns: [String]
    let columnTypeNames: [String]
    let keySchema: [(name: String, keyType: String)]

    private var keyColumnNames: Set<String> {
        Set(keySchema.map(\.name))
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
                statements += generateInsert(for: change, insertedRowData: insertedRowData)
            case .update:
                statements += generateUpdate(for: change)
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
    ) -> [(statement: String, parameters: [String?])] {
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

        // Ensure key columns are present
        for key in keySchema {
            guard let val = values[key.name], val != nil, !val!.isEmpty else {
                Self.logger.warning("Skipping INSERT - missing key column '\(key.name)'")
                return []
            }
        }

        var attrs: [String] = []
        for column in columns {
            guard let value = values[column], let val = value else { continue }
            let typeIndex = columns.firstIndex(of: column) ?? 0
            let typeName = typeIndex < columnTypeNames.count ? columnTypeNames[typeIndex] : "S"
            attrs.append("'\(escapePartiQL(column))': \(formatValue(val, typeName: typeName))")
        }

        let quotedTable = "\"\(escapeIdentifier(tableName))\""
        let statement = "INSERT INTO \(quotedTable) VALUE {'\(attrs.joined(separator: ", "))'}"
            .replacingOccurrences(of: "{'", with: "{ '")
            .replacingOccurrences(of: "'}", with: "' }")

        // Correct: build the VALUE { ... } properly
        let attrString = attrs.joined(separator: ", ")
        let correctedStatement = "INSERT INTO \(quotedTable) VALUE { \(attrString) }"

        return [(statement: correctedStatement, parameters: [])]
    }

    // MARK: - UPDATE

    private func generateUpdate(
        for change: PluginRowChange
    ) -> [(statement: String, parameters: [String?])] {
        guard !change.cellChanges.isEmpty else { return [] }

        // Filter out key column changes (DynamoDB does not allow updating key attributes)
        let nonKeyChanges = change.cellChanges.filter { !keyColumnNames.contains($0.columnName) }
        guard !nonKeyChanges.isEmpty else {
            Self.logger.info("Skipping UPDATE - only key columns were changed (not allowed)")
            return []
        }

        guard let whereClause = buildWhereClause(from: change) else {
            Self.logger.warning("Skipping UPDATE - cannot build WHERE clause")
            return []
        }

        var setClauses: [String] = []
        for cellChange in nonKeyChanges {
            let typeIndex = columns.firstIndex(of: cellChange.columnName) ?? 0
            let typeName = typeIndex < columnTypeNames.count ? columnTypeNames[typeIndex] : "S"
            let formattedValue: String
            if let newValue = cellChange.newValue {
                formattedValue = formatValue(newValue, typeName: typeName)
            } else {
                formattedValue = "NULL"
            }
            setClauses.append("\"\(escapeIdentifier(cellChange.columnName))\" = \(formattedValue)")
        }

        let quotedTable = "\"\(escapeIdentifier(tableName))\""
        let statement = "UPDATE \(quotedTable) SET \(setClauses.joined(separator: ", ")) WHERE \(whereClause)"

        return [(statement: statement, parameters: [])]
    }

    // MARK: - DELETE

    private func generateDelete(
        for change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard let whereClause = buildWhereClause(from: change) else {
            Self.logger.warning("Skipping DELETE - cannot build WHERE clause")
            return nil
        }

        let quotedTable = "\"\(escapeIdentifier(tableName))\""
        let statement = "DELETE FROM \(quotedTable) WHERE \(whereClause)"

        return (statement: statement, parameters: [])
    }

    // MARK: - Helpers

    private func buildWhereClause(from change: PluginRowChange) -> String? {
        guard let originalRow = change.originalRow else { return nil }

        var conditions: [String] = []
        for key in keySchema {
            guard let colIndex = columns.firstIndex(of: key.name),
                  colIndex < originalRow.count,
                  let value = originalRow[colIndex]
            else { return nil }

            let typeName = colIndex < columnTypeNames.count ? columnTypeNames[colIndex] : "S"
            conditions.append("\"\(escapeIdentifier(key.name))\" = \(formatValue(value, typeName: typeName))")
        }

        guard !conditions.isEmpty else { return nil }
        return conditions.joined(separator: " AND ")
    }

    private func formatValue(_ value: String, typeName: String) -> String {
        switch typeName {
        case "N":
            // Numbers are unquoted in PartiQL
            if Int64(value) != nil || Double(value) != nil {
                return value
            }
            return "'\(escapePartiQL(value))'"
        case "BOOL":
            let lower = value.lowercased()
            return (lower == "true" || lower == "1") ? "true" : "false"
        case "NULL":
            return "NULL"
        case "S":
            return "'\(escapePartiQL(value))'"
        default:
            // For complex types (L, M, SS, NS, BS), pass through as-is if it looks like JSON
            if value.hasPrefix("[") || value.hasPrefix("{") {
                return value
            }
            return "'\(escapePartiQL(value))'"
        }
    }

    private func escapePartiQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapeIdentifier(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
