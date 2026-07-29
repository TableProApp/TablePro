//
//  SnowflakeSchemaQueries.swift
//  SnowflakeDriverPlugin
//
//  SQL builders and result parsing for SHOW-based introspection. SHOW commands
//  run against the metadata service and need no running warehouse, unlike
//  INFORMATION_SCHEMA queries.
//

import Foundation

enum SnowflakeSchemaQueries {
    static func showObjects(database: String, schema: String) -> String {
        "SHOW TERSE OBJECTS IN SCHEMA \(qualified(database, schema))"
    }

    static func showPrimaryKeysInSchema(database: String, schema: String) -> String {
        "SHOW PRIMARY KEYS IN SCHEMA \(qualified(database, schema))"
    }

    static func showPrimaryKeysInTable(database: String, schema: String, table: String) -> String {
        "SHOW PRIMARY KEYS IN TABLE \(qualified(database, schema, table))"
    }

    static func showImportedKeys(database: String, schema: String, table: String) -> String {
        "SHOW IMPORTED KEYS IN TABLE \(qualified(database, schema, table))"
    }

    static func showTablesLike(database: String, schema: String, table: String) -> String {
        "SHOW TABLES LIKE '\(escapeLikePattern(table))' IN SCHEMA \(qualified(database, schema))"
    }

    static func bulkColumns(database: String, schema: String) -> String {
        """
        SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COMMENT,
               NUMERIC_PRECISION, NUMERIC_SCALE, CHARACTER_MAXIMUM_LENGTH
        FROM \(quote(database)).INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = '\(escapeLiteral(schema))'
        ORDER BY TABLE_NAME, ORDINAL_POSITION
        """
    }

    static func objectType(forKind kind: String) -> String {
        let upper = kind.uppercased()
        if upper.contains("MATERIALIZED") { return "MATERIALIZED_VIEW" }
        if upper.contains("VIEW") { return "VIEW" }
        return "TABLE"
    }

    static func parseClusterBy(_ clusterBy: String) -> [String] {
        var inner = clusterBy.trimmingCharacters(in: .whitespaces)
        if inner.uppercased().hasPrefix("LINEAR("), inner.hasSuffix(")") {
            inner = String(inner.dropFirst("LINEAR(".count).dropLast())
        }
        return inner
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
    }

    static func isLikelyMultiStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = trimmed.firstIndex(of: ";") else { return false }
        return trimmed.index(after: index) != trimmed.endIndex
    }

    static func escapeLikePattern(_ value: String) -> String {
        escapeLiteral(value)
            .replacingOccurrences(of: "_", with: "\\\\_")
            .replacingOccurrences(of: "%", with: "\\\\%")
    }

    static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func qualified(_ parts: String...) -> String {
        parts.map(quote).joined(separator: ".")
    }
}
