//
//  MySQLPlugin.swift
//  MySQLDriverPlugin
//
//  MySQL/MariaDB database driver plugin using libmariadb (MariaDB Connector/C)
//

import CMariaDB
import Foundation
import os
import TableProPluginKit

// MARK: - Plugin Entry Point

final class MySQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "MySQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "MySQL/MariaDB support via libmariadb"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MySQL"
    static let databaseDisplayName = "MySQL"
    static let iconName = "mysql-icon"
    static let defaultPort = 3306
    static let additionalConnectionFields: [ConnectionField] = []
    static let additionalDatabaseTypeIds: [String] = ["MariaDB"]

    // MARK: - UI/Capability Metadata

    static let urlSchemes: [String] = ["mysql"]
    static let brandColorHex = "#FF9500"
    static let systemDatabaseNames: [String] = ["information_schema", "mysql", "performance_schema", "sys"]
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT"],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL"],
        "String": ["CHAR", "VARCHAR", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "ENUM", "SET"],
        "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR"],
        "Binary": ["BINARY", "VARBINARY", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB", "BIT"],
        "Boolean": ["BOOLEAN", "BOOL"],
        "JSON": ["JSON"],
        "Spatial": ["GEOMETRY", "POINT", "LINESTRING", "POLYGON"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS", "ALIAS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "CHANGE", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "CASE", "WHEN", "THEN", "ELSE", "END", "IF", "IFNULL", "COALESCE",
            "UNION", "INTERSECT", "EXCEPT",
            "FORCE", "USE", "IGNORE", "STRAIGHT_JOIN", "DUAL",
            "SHOW", "DESCRIBE", "EXPLAIN"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE",
            "NOW", "CURDATE", "CURTIME", "DATE", "TIME", "YEAR", "MONTH", "DAY",
            "DATE_ADD", "DATE_SUB", "DATEDIFF", "TIMESTAMPDIFF",
            "ROUND", "CEIL", "FLOOR", "ABS", "MOD", "POW", "SQRT",
            "CAST", "CONVERT"
        ],
        dataTypes: [
            "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
            "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
            "CHAR", "VARCHAR", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT",
            "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB",
            "DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR",
            "ENUM", "SET", "JSON", "BOOL", "BOOLEAN"
        ],
        tableOptions: [
            "ENGINE=InnoDB", "DEFAULT CHARSET=utf8mb4", "COLLATE=utf8mb4_unicode_ci",
            "AUTO_INCREMENT=", "COMMENT=", "ROW_FORMAT="
        ],
        regexSyntax: .regexp,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit,
        paginationStyle: .limit,
        requiresBackslashEscaping: true
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MySQLPluginDriver(config: config)
    }
}
