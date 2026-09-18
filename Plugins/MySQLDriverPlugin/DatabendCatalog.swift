//
//  DatabendCatalog.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum DatabendCatalog {
    static func quoteIdentifier(_ name: String) -> String {
        guard name.contains("`") else { return "`\(name)`" }
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    static func columnsQuery(database: String, table: String) -> String {
        """
        SELECT name, data_type, default_kind, default_expression, is_nullable, comment
        FROM system.columns
        WHERE `database` = '\(mysqlEscapeStringLiteral(database))' AND `table` = '\(mysqlEscapeStringLiteral(table))'
        """
    }

    static func allColumnsQuery(database: String) -> String {
        """
        SELECT `table`, name, data_type, default_kind, default_expression, is_nullable, comment
        FROM system.columns
        WHERE `database` = '\(mysqlEscapeStringLiteral(database))'
        """
    }

    static func column(from row: [PluginCellValue], offset: Int = 0) -> PluginColumnInfo? {
        guard let name = row[safe: offset]?.asText,
              let dataType = row[safe: offset + 1]?.asText else { return nil }
        let hasDefault = row[safe: offset + 2]?.asText?.isEmpty == false
        let comment = row[safe: offset + 5]?.asText
        return PluginColumnInfo(
            name: name,
            dataType: dataType.uppercased(),
            isNullable: row[safe: offset + 4]?.asText == "YES",
            defaultValue: hasDefault ? row[safe: offset + 3]?.asText : nil,
            comment: comment?.isEmpty == false ? comment : nil
        )
    }

    static func checkConstraintsQuery(database: String, table: String) -> String {
        """
        SELECT name, expression
        FROM system.constraints
        WHERE `database` = '\(mysqlEscapeStringLiteral(database))' AND `table` = '\(mysqlEscapeStringLiteral(table))'
            AND type = 'check'
        ORDER BY name
        """
    }

    static func tableMetadataQuery(database: String, table: String?) -> String {
        var query = """
            SELECT table_name, table_rows, data_length, index_length, table_comment, engine
            FROM information_schema.tables
            WHERE table_schema = '\(mysqlEscapeStringLiteral(database))'
            """
        if let table {
            query += " AND table_name = '\(mysqlEscapeStringLiteral(table))'"
        }
        return query
    }

    static func tableMetadata(from row: [PluginCellValue]) -> PluginTableMetadata? {
        guard let name = row[safe: 0]?.asText else { return nil }
        let dataSize = (row[safe: 2]?.asText).flatMap { Int64($0) }
        let indexSize = (row[safe: 3]?.asText).flatMap { Int64($0) }
        let totalSize: Int64? = dataSize.map { $0 + (indexSize ?? 0) }
        let comment = row[safe: 4]?.asText
        return PluginTableMetadata(
            tableName: name,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            rowCount: (row[safe: 1]?.asText).flatMap { Int64($0) },
            comment: comment?.isEmpty == false ? comment : nil,
            engine: row[safe: 5]?.asText
        )
    }

    static let allTablesMetadataSQL = """
        SELECT
            table_schema AS `schema`,
            table_name AS name,
            table_type AS kind,
            table_rows AS estimated_rows,
            CONCAT(ROUND((data_length + index_length) / 1024 / 1024, 2), ' MB') AS total_size,
            CONCAT(ROUND(data_length / 1024 / 1024, 2), ' MB') AS data_size,
            CONCAT(ROUND(index_length / 1024 / 1024, 2), ' MB') AS index_size,
            table_comment AS comment
        FROM information_schema.tables
        WHERE table_schema = DATABASE()
        ORDER BY table_name
        """

    static func columnDefinitionSQL(_ column: PluginColumnDefinition) -> String {
        var definition = "\(quoteIdentifier(column.name)) \(column.dataType)"
        definition += column.isNullable ? " NULL" : " NOT NULL"
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            definition += " DEFAULT \(defaultValue)"
        }
        if let comment = column.comment, !comment.isEmpty {
            definition += " COMMENT '\(mysqlEscapeStringLiteral(comment))'"
        }
        return definition
    }

    static func createTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }
        let ifNotExists = definition.ifNotExists ? " IF NOT EXISTS" : ""
        let columns = definition.columns.map { "    \(columnDefinitionSQL($0))" }.joined(separator: ",\n")
        return "CREATE TABLE\(ifNotExists) \(quoteIdentifier(definition.tableName)) (\n\(columns)\n);"
    }

    static func modifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        let tableName = quoteIdentifier(table)
        var statements: [String] = []
        if oldColumn.name != newColumn.name {
            statements.append(
                "ALTER TABLE \(tableName) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) "
                    + "TO \(quoteIdentifier(newColumn.name))"
            )
        }
        if definitionChanged(from: oldColumn, to: newColumn) {
            statements.append("ALTER TABLE \(tableName) MODIFY COLUMN \(columnDefinitionSQL(newColumn))")
        }
        return statements.isEmpty ? nil : statements.joined(separator: ";\n")
    }

    static func createDatabaseSQL(name: String) -> String {
        "CREATE DATABASE \(quoteIdentifier(name))"
    }

    private static func definitionChanged(from old: PluginColumnDefinition, to new: PluginColumnDefinition) -> Bool {
        old.dataType.uppercased() != new.dataType.uppercased()
            || old.isNullable != new.isNullable
            || old.defaultValue != new.defaultValue
            || (old.comment ?? "") != (new.comment ?? "")
    }
}
