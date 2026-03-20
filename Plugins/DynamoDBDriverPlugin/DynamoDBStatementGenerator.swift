//
//  DynamoDBStatementGenerator.swift
//  DynamoDBDriverPlugin
//
//  Generates PartiQL statements from tracked cell changes.
//

import Foundation
import os
import TableProPluginKit

internal enum DynamoDBStatementError: LocalizedError {
    case invalidNumber(value: String)
    case invalidBoolean(value: String)
    case unsupportedBinaryType

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let value):
            return "Invalid number value: '\(value)'"
        case .invalidBoolean(let value):
            return "Invalid boolean value: '\(value)'. Expected true/false/1/0."
        case .unsupportedBinaryType:
            return "Binary types (B, BS) cannot be expressed as PartiQL literals. Use parameter binding instead."
        }
    }
}

internal struct DynamoDBStatementGenerator {
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
    ) throws -> [(statement: String, parameters: [String?])] {
        var statements: [(statement: String, parameters: [String?])] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                statements += try generateInsert(for: change, insertedRowData: insertedRowData)
            case .update:
                statements += try generateUpdate(for: change)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = try generateDelete(for: change) {
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
    ) throws -> [(statement: String, parameters: [String?])] {
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

        for key in keySchema {
            guard let val = values[key.name], let unwrapped = val, !unwrapped.isEmpty else {
                Self.logger.warning("Skipping INSERT - missing key column '\(key.name)'")
                return []
            }
        }

        var attrs: [String] = []
        for column in columns {
            guard let value = values[column], let val = value else { continue }
            let typeIndex = columns.firstIndex(of: column) ?? 0
            let typeName = typeIndex < columnTypeNames.count ? columnTypeNames[typeIndex] : "S"
            attrs.append("'\(escapePartiQL(column))': \(try formatValue(val, typeName: typeName))")
        }

        let quotedTable = "\"\(escapeIdentifier(tableName))\""
        let attrString = attrs.joined(separator: ", ")
        let statement = "INSERT INTO \(quotedTable) VALUE { \(attrString) }"

        return [(statement: statement, parameters: [])]
    }

    // MARK: - UPDATE

    private func generateUpdate(
        for change: PluginRowChange
    ) throws -> [(statement: String, parameters: [String?])] {
        guard !change.cellChanges.isEmpty else { return [] }

        let nonKeyChanges = change.cellChanges.filter { !keyColumnNames.contains($0.columnName) }
        guard !nonKeyChanges.isEmpty else {
            Self.logger.info("Skipping UPDATE - only key columns were changed (not allowed)")
            return []
        }

        guard let whereClause = try buildWhereClause(from: change) else {
            Self.logger.warning("Skipping UPDATE - cannot build WHERE clause")
            return []
        }

        var setClauses: [String] = []
        for cellChange in nonKeyChanges {
            let typeIndex = columns.firstIndex(of: cellChange.columnName) ?? 0
            let typeName = typeIndex < columnTypeNames.count ? columnTypeNames[typeIndex] : "S"
            let formattedValue: String
            if let newValue = cellChange.newValue {
                formattedValue = try formatValue(newValue, typeName: typeName)
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
    ) throws -> (statement: String, parameters: [String?])? {
        guard let whereClause = try buildWhereClause(from: change) else {
            Self.logger.warning("Skipping DELETE - cannot build WHERE clause")
            return nil
        }

        let quotedTable = "\"\(escapeIdentifier(tableName))\""
        let statement = "DELETE FROM \(quotedTable) WHERE \(whereClause)"

        return (statement: statement, parameters: [])
    }

    // MARK: - Helpers

    private func buildWhereClause(from change: PluginRowChange) throws -> String? {
        guard let originalRow = change.originalRow else { return nil }

        var conditions: [String] = []
        for key in keySchema {
            guard let colIndex = columns.firstIndex(of: key.name),
                  colIndex < originalRow.count,
                  let value = originalRow[colIndex]
            else { return nil }

            let typeName = colIndex < columnTypeNames.count ? columnTypeNames[colIndex] : "S"
            conditions.append(
                "\"\(escapeIdentifier(key.name))\" = \(try formatValue(value, typeName: typeName))"
            )
        }

        guard !conditions.isEmpty else { return nil }
        return conditions.joined(separator: " AND ")
    }

    private func formatValue(_ value: String, typeName: String) throws -> String {
        switch typeName {
        case "N":
            if Int64(value) != nil || Double(value) != nil {
                return value
            }
            throw DynamoDBStatementError.invalidNumber(value: value)
        case "BOOL":
            let lower = value.lowercased()
            switch lower {
            case "true", "1":
                return "true"
            case "false", "0":
                return "false"
            default:
                throw DynamoDBStatementError.invalidBoolean(value: value)
            }
        case "NULL":
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.lowercased() == "null" {
                return "NULL"
            }
            return "'\(escapePartiQL(value))'"
        case "SS":
            return try formatStringSet(value)
        case "NS":
            return try formatNumberSet(value)
        case "B", "BS":
            throw DynamoDBStatementError.unsupportedBinaryType
        case "S":
            return "'\(escapePartiQL(value))'"
        default:
            if value.hasPrefix("[") || value.hasPrefix("{") {
                return value
            }
            return "'\(escapePartiQL(value))'"
        }
    }

    private func formatStringSet(_ value: String) throws -> String {
        guard let data = value.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return "<<'\(escapePartiQL(value))'>>"
        }
        let elements = array.map { "'\(escapePartiQL($0))'" }
        return "<<\(elements.joined(separator: ", "))>>"
    }

    private func formatNumberSet(_ value: String) throws -> String {
        guard let data = value.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw DynamoDBStatementError.invalidNumber(value: value)
        }
        var elements: [String] = []
        for element in array {
            let str = "\(element)"
            guard Int64(str) != nil || Double(str) != nil else {
                throw DynamoDBStatementError.invalidNumber(value: str)
            }
            elements.append(str)
        }
        return "<<\(elements.joined(separator: ", "))>>"
    }

    private func escapePartiQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapeIdentifier(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
