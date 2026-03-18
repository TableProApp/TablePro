//
//  PostgreSQLPlugin.swift
//  PostgreSQLDriverPlugin
//
//  PostgreSQL/Redshift database driver plugin using libpq
//

import Foundation
import os
import TableProPluginKit

// MARK: - Plugin Entry Point

final class PostgreSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "PostgreSQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "PostgreSQL/Redshift support via libpq"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PostgreSQL"
    static let databaseDisplayName = "PostgreSQL"
    static let iconName = "postgresql-icon"
    static let defaultPort = 5432
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "usePgpass",
            label: String(localized: "Use ~/.pgpass"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .authentication,
            hidesPassword: true
        )
    ]
    static let additionalDatabaseTypeIds: [String] = ["Redshift"]

    // MARK: - UI/Capability Metadata

    static let urlSchemes: [String] = ["postgresql", "postgres"]
    static let brandColorHex = "#336791"
    static let systemDatabaseNames: [String] = ["postgres", "template0", "template1"]
    static let supportsSchemaSwitching = true
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["SMALLINT", "INTEGER", "BIGINT", "SERIAL", "BIGSERIAL", "SMALLSERIAL"],
        "Float": ["REAL", "DOUBLE PRECISION", "NUMERIC", "DECIMAL", "MONEY"],
        "String": ["CHARACTER VARYING", "VARCHAR", "CHARACTER", "CHAR", "TEXT", "NAME"],
        "Date": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL", "TIME WITH TIME ZONE", "TIMESTAMP WITH TIME ZONE"],
        "Binary": ["BYTEA"],
        "Boolean": ["BOOLEAN"],
        "JSON": ["JSON", "JSONB"],
        "UUID": ["UUID"],
        "Array": ["ARRAY"],
        "Network": ["INET", "CIDR", "MACADDR", "MACADDR8"],
        "Geometric": ["POINT", "LINE", "LSEG", "BOX", "PATH", "POLYGON", "CIRCLE"],
        "Range": ["INT4RANGE", "INT8RANGE", "NUMRANGE", "TSRANGE", "TSTZRANGE", "DATERANGE"],
        "Text Search": ["TSVECTOR", "TSQUERY"],
        "XML": ["XML"]
    ]

    static let supportsCascadeDrop = true
    static let supportsForeignKeyDisable = false
    static let requiresReconnectForDatabaseSwitch = true

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "ROWS", "ONLY",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT",
            "RETURNING", "WITH", "RECURSIVE", "MATERIALIZED",
            "EXPLAIN", "ANALYZE", "VERBOSE",
            "WINDOW", "OVER", "PARTITION",
            "LATERAL", "ORDINALITY"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "STRING_AGG", "ARRAY_AGG",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "SPLIT_PART",
            "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
            "DATE_TRUNC", "EXTRACT", "AGE", "TO_CHAR", "TO_DATE",
            "ROUND", "CEIL", "CEILING", "FLOOR", "ABS", "MOD", "POW", "POWER", "SQRT",
            "CAST", "TO_NUMBER", "TO_TIMESTAMP",
            "JSON_BUILD_OBJECT", "JSON_AGG", "JSONB_BUILD_OBJECT"
        ],
        dataTypes: [
            "INTEGER", "INT", "SMALLINT", "BIGINT", "SERIAL", "BIGSERIAL", "SMALLSERIAL",
            "DECIMAL", "NUMERIC", "REAL", "DOUBLE", "PRECISION",
            "CHAR", "CHARACTER", "VARCHAR", "TEXT",
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL",
            "BOOLEAN", "BOOL", "JSON", "JSONB", "UUID", "BYTEA", "ARRAY"
        ],
        tableOptions: [
            "INHERITS", "PARTITION BY", "TABLESPACE", "WITH", "WITHOUT OIDS"
        ],
        regexSyntax: .tilde,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    static func driverVariant(for databaseTypeId: String) -> String? {
        switch databaseTypeId {
        case "PostgreSQL": return "PostgreSQL"
        case "Redshift": return "Redshift"
        default: return nil
        }
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        let variant = config.additionalFields["driverVariant"] ?? ""
        if variant == "Redshift" {
            return RedshiftPluginDriver(config: config)
        }
        return PostgreSQLPluginDriver(config: config)
    }
}
