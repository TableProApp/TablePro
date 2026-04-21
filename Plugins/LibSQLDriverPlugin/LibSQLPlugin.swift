//
//  LibSQLPlugin.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class LibSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "libSQL / Turso Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "libSQL and Turso database support via Hrana HTTP protocol"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "libSQL"
    static let additionalDatabaseTypeIds = ["Turso"]
    static let databaseDisplayName = "libSQL / Turso"
    static let iconName = "libsql-icon"
    static let defaultPort = 0

    // MARK: - UI/Capability Metadata

    static let connectionMode: ConnectionMode = .apiOnly
    static let requiresAuthentication = false
    static let supportsSSH = false
    static let supportsSSL = false
    static let isDownloadable = true
    static let supportsImport = false
    static let supportsSchemaEditing = true
    static let supportsDropDatabase = false
    static let supportsDatabaseSwitching = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let brandColorHex = "#4FF8D2"
    static let urlSchemes: [String] = ["libsql"]

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN")
    ]

    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue]

    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INTEGER", "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT"],
        "Float": ["REAL", "DOUBLE", "FLOAT", "NUMERIC", "DECIMAL"],
        "String": ["TEXT", "VARCHAR", "CHARACTER", "CHAR", "CLOB", "NVARCHAR", "NCHAR"],
        "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
        "Binary": ["BLOB"],
        "Boolean": ["BOOLEAN"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
            "ON", "AND", "OR", "NOT", "IN", "LIKE", "GLOB", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "TRIGGER",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "IFNULL", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT",
            "AUTOINCREMENT", "WITHOUT", "ROWID", "PRAGMA",
            "REPLACE", "ABORT", "FAIL", "IGNORE", "ROLLBACK",
            "TEMP", "TEMPORARY", "VACUUM", "EXPLAIN", "QUERY", "PLAN"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT", "TOTAL",
            "LENGTH", "SUBSTR", "SUBSTRING", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
            "REPLACE", "INSTR", "PRINTF",
            "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME",
            "ABS", "ROUND", "RANDOM",
            "CAST", "TYPEOF",
            "COALESCE", "IFNULL", "NULLIF", "HEX", "QUOTE"
        ],
        dataTypes: [
            "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC",
            "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
            "UNSIGNED", "BIG", "INT2", "INT8",
            "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NATIVE",
            "NVARCHAR", "CLOB",
            "DOUBLE", "PRECISION", "FLOAT",
            "DECIMAL", "BOOLEAN", "DATE", "DATETIME"
        ],
        tableOptions: [
            "WITHOUT ROWID", "STRICT"
        ],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "databaseUrl",
            label: String(localized: "Database URL"),
            placeholder: "https://your-db.turso.io",
            required: true,
            section: .authentication
        )
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        LibSQLPluginDriver(config: config)
    }
}
