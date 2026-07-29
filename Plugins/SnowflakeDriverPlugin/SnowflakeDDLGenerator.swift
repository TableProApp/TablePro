//
//  SnowflakeDDLGenerator.swift
//  SnowflakeDriverPlugin
//
//  Generates ALTER TABLE and CREATE TABLE DDL within Snowflake's documented
//  limits: VARCHAR can only widen, NUMBER can only change precision (same
//  scale), no cross-type changes. Unsupported changes return nil so the app
//  reports them instead of failing server-side.
//

import Foundation
import TableProPluginKit

struct SnowflakeDDLGenerator {
    let qualifiedTable: (String) -> String

    func addColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(qualifiedTable(table)) ADD COLUMN \(columnDefinitionSQL(column))"
    }

    func dropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedTable(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func modifyColumnSQL(table: String, old: PluginColumnDefinition, new: PluginColumnDefinition) -> String? {
        let target = qualifiedTable(table)
        var statements: [String] = []

        if old.name != new.name {
            statements.append(
                "ALTER TABLE \(target) RENAME COLUMN \(quoteIdentifier(old.name)) TO \(quoteIdentifier(new.name))"
            )
        }

        var actions: [String] = []
        let column = quoteIdentifier(new.name)

        if normalizedType(old.dataType) != normalizedType(new.dataType) {
            guard isSupportedTypeChange(from: old.dataType, to: new.dataType) else { return nil }
            actions.append("COLUMN \(column) SET DATA TYPE \(new.dataType)")
        }
        if old.isNullable != new.isNullable {
            actions.append("COLUMN \(column) \(new.isNullable ? "DROP NOT NULL" : "SET NOT NULL")")
        }
        if old.comment != new.comment {
            if let comment = new.comment, !comment.isEmpty {
                actions.append("COLUMN \(column) COMMENT '\(escapeLiteral(comment))'")
            } else {
                actions.append("COLUMN \(column) UNSET COMMENT")
            }
        }
        if old.defaultValue != new.defaultValue, new.defaultValue == nil {
            actions.append("COLUMN \(column) DROP DEFAULT")
        } else if old.defaultValue != new.defaultValue {
            return nil
        }

        if !actions.isEmpty {
            statements.append("ALTER TABLE \(target) ALTER \(actions.joined(separator: ", "))")
        }
        guard !statements.isEmpty else { return nil }
        return statements.joined(separator: ";\n")
    }

    func modifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String]) -> [String]? {
        let target = qualifiedTable(table)
        var statements: [String] = []
        if !oldColumns.isEmpty {
            statements.append("ALTER TABLE \(target) DROP PRIMARY KEY")
        }
        if !newColumns.isEmpty {
            let columns = newColumns.map(quoteIdentifier).joined(separator: ", ")
            statements.append("ALTER TABLE \(target) ADD PRIMARY KEY (\(columns))")
        }
        return statements.isEmpty ? nil : statements
    }

    func createTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }
        var parts = definition.columns.map(columnDefinitionSQL)
        let pkColumns = definition.primaryKeyColumns.isEmpty
            ? definition.columns.filter(\.isPrimaryKey).map(\.name)
            : definition.primaryKeyColumns
        if !pkColumns.isEmpty {
            parts.append("PRIMARY KEY (\(pkColumns.map(quoteIdentifier).joined(separator: ", ")))")
        }
        let ifNotExists = definition.ifNotExists ? "IF NOT EXISTS " : ""
        return "CREATE TABLE \(ifNotExists)\(qualifiedTable(definition.tableName)) (\n  \(parts.joined(separator: ",\n  "))\n)"
    }

    func columnDefinitionSQL(_ column: PluginColumnDefinition) -> String {
        var definition = "\(quoteIdentifier(column.name)) \(column.dataType)"
        if column.autoIncrement {
            definition += " AUTOINCREMENT"
        } else if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            definition += " DEFAULT \(defaultValue)"
        }
        if !column.isNullable {
            definition += " NOT NULL"
        }
        if let comment = column.comment, !comment.isEmpty {
            definition += " COMMENT '\(escapeLiteral(comment))'"
        }
        return definition
    }

    static func isSupportedTypeChange(from oldType: String, to newType: String) -> Bool {
        let old = parse(oldType)
        let new = parse(newType)
        guard old.base == new.base else { return false }

        switch old.base {
        case "VARCHAR", "STRING", "TEXT", "CHAR", "CHARACTER":
            let oldLength = old.arguments.first ?? 16_777_216
            let newLength = new.arguments.first ?? 16_777_216
            return newLength >= oldLength
        case "NUMBER", "DECIMAL", "NUMERIC":
            let oldScale = old.arguments.count > 1 ? old.arguments[1] : 0
            let newScale = new.arguments.count > 1 ? new.arguments[1] : 0
            return oldScale == newScale
        default:
            return false
        }
    }

    private func isSupportedTypeChange(from oldType: String, to newType: String) -> Bool {
        Self.isSupportedTypeChange(from: oldType, to: newType)
    }

    private static func parse(_ type: String) -> (base: String, arguments: [Int]) {
        let upper = type.uppercased().trimmingCharacters(in: .whitespaces)
        guard let parenIndex = upper.firstIndex(of: "("), upper.hasSuffix(")") else {
            return (upper, [])
        }
        let base = String(upper[..<parenIndex])
        let inner = upper[upper.index(after: parenIndex)..<upper.index(before: upper.endIndex)]
        let arguments = inner.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return (base, arguments)
    }

    private func normalizedType(_ type: String) -> String {
        type.uppercased().replacingOccurrences(of: " ", with: "")
    }

    private func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }
}
