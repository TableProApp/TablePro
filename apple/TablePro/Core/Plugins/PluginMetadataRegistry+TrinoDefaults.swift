//
//  PluginMetadataRegistry+TrinoDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func trinoPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Trino", PluginMetadataSnapshot(
                displayName: "Trino", iconName: "trino-icon", defaultPort: 8_080,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "trino", parameterStyle: .questionMark,
                navigationModel: .standard,
                explainVariants: Self.trinoExplainVariants,
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["trino"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#DD5F3B",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameSchema: true,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    defaultSSLMode: .disabled,
                    supportsOpportunisticTLS: false,
                    tlsImpliedPorts: [443],
                    verifiesServerWithSystemTrust: true,
                    requestedTLSVerifiesIdentity: true
                ),
                schema: Self.trinoSchemaInfo,
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: Self.trinoDialect(paginationStyle: .offsetFetch),
                    statementCompletions: [],
                    columnTypesByCategory: Self.trinoColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: Self.trinoConnectionFields,
                    category: .analytical,
                    tagline: String(localized: "Distributed SQL query engine for data lakes")
                )
            )),
            ("Presto", PluginMetadataSnapshot(
                displayName: "Presto", iconName: "presto-icon", defaultPort: 8_080,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "presto", parameterStyle: .questionMark,
                navigationModel: .standard,
                explainVariants: Self.trinoExplainVariants,
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["presto"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#5890FF",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                structureEditing: SchemaEditingSupport(structureEdits: .presto),
                // A variant takes no capability from its plugin, so the ones the Trino plugin declares are restated.
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameSchema: true,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    defaultSSLMode: .disabled,
                    supportsOpportunisticTLS: false,
                    tlsImpliedPorts: [443],
                    verifiesServerWithSystemTrust: true,
                    requestedTLSVerifiesIdentity: true,
                    // OFFSET is off by default (offset_clause_enabled), and the grammar takes neither
                    // FETCH NEXT nor LIMIT before OFFSET.
                    pagination: .leadingRowsOnly(maximumRows: nil)
                ),
                schema: Self.trinoSchemaInfo,
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: Self.trinoDialect(paginationStyle: .limit),
                    statementCompletions: [],
                    columnTypesByCategory: Self.trinoColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: Self.trinoConnectionFields,
                    category: .analytical,
                    tagline: String(localized: "PrestoDB distributed SQL query engine")
                )
            )),
        ]
    }

    private static let trinoExplainVariants = [
        ExplainVariant(id: "logical", label: "Explain (Logical)", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "distributed", label: "Explain (Distributed)", sqlPrefix: "EXPLAIN (TYPE DISTRIBUTED)"),
        ExplainVariant(id: "io", label: "Explain (IO)", sqlPrefix: "EXPLAIN (TYPE IO)"),
        ExplainVariant(id: "validate", label: "Explain (Validate)", sqlPrefix: "EXPLAIN (TYPE VALIDATE)"),
        ExplainVariant(id: "analyze", label: "Explain Analyze", sqlPrefix: "EXPLAIN ANALYZE"),
    ]

    private static let trinoSchemaInfo = PluginMetadataSnapshot.SchemaInfo(
        defaultSchemaName: "",
        defaultGroupName: "default",
        tableEntityName: "Tables",
        containerEntityName: "Catalog",
        defaultPrimaryKeyColumn: nil,
        immutableColumns: [],
        systemDatabaseNames: [],
        systemSchemaNames: ["information_schema"],
        fileExtensions: [],
        databaseGroupingStrategy: .hierarchicalSchema,
        structureColumnFields: [.name, .type, .nullable, .comment]
    )

    private static let trinoColumnTypes: [String: [String]] = [
        "Boolean": ["boolean"],
        "Integer": ["tinyint", "smallint", "integer", "bigint"],
        "Floating": ["real", "double", "decimal"],
        "String": ["varchar", "char"],
        "Binary": ["varbinary"],
        "Date/Time": ["date", "time", "timestamp", "time with time zone", "timestamp with time zone"],
        "Complex": ["array", "map", "row", "json"],
        "Other": ["uuid", "ipaddress", "interval year to month", "interval day to second"],
    ]

    private static func trinoDialect(paginationStyle: SQLDialectDescriptor.PaginationStyle) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [
                "SELECT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH",
                "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON", "USING", "NATURAL",
                "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS", "DISTINCT", "ALL",
                "UNION", "INTERSECT", "EXCEPT", "WITH", "RECURSIVE", "VALUES", "UNNEST", "LATERAL",
                "INSERT", "INTO", "UPDATE", "SET", "DELETE", "MERGE", "CREATE", "ALTER", "DROP",
                "TABLE", "VIEW", "SCHEMA", "CATALOG", "IF", "EXISTS", "REPLACE", "COMMENT",
                "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "TRY_CAST", "IS", "NULL", "TRUE", "FALSE",
                "ASC", "DESC", "NULLS", "FIRST", "LAST", "OVER", "PARTITION", "WINDOW",
                "ROWS", "RANGE", "GROUPS", "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT", "ROW",
                "GROUPING", "SETS", "CUBE", "ROLLUP", "QUALIFY",
                "SHOW", "CATALOGS", "SCHEMAS", "TABLES", "COLUMNS", "DESCRIBE", "EXPLAIN", "ANALYZE",
                "USE", "PREPARE", "EXECUTE", "DEALLOCATE", "RESET", "SESSION",
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MIN", "MAX", "ARRAY_AGG", "APPROX_DISTINCT", "ARBITRARY",
                "CARDINALITY", "ELEMENT_AT", "CONTAINS", "FILTER", "TRANSFORM", "REDUCE", "ZIP",
                "MAP", "MAP_KEYS", "MAP_VALUES", "MAP_FROM_ENTRIES", "SLICE", "SEQUENCE", "FLATTEN",
                "JSON_EXTRACT", "JSON_EXTRACT_SCALAR", "JSON_PARSE", "JSON_FORMAT", "JSON_ARRAY_LENGTH",
                "REGEXP_LIKE", "REGEXP_REPLACE", "REGEXP_EXTRACT", "REGEXP_EXTRACT_ALL", "REGEXP_SPLIT",
                "SUBSTR", "SUBSTRING", "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM", "SPLIT",
                "SPLIT_PART", "CONCAT", "REPLACE", "REVERSE", "POSITION", "STRPOS", "FORMAT",
                "COALESCE", "NULLIF", "GREATEST", "LEAST", "IF", "TRY", "NOW",
                "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "AT_TIMEZONE", "WITH_TIMEZONE",
                "DATE_TRUNC", "DATE_ADD", "DATE_DIFF", "DATE_FORMAT", "DATE_PARSE", "PARSE_DATETIME",
                "FROM_UNIXTIME", "TO_UNIXTIME", "FROM_ISO8601_TIMESTAMP", "EXTRACT",
                "ROW_NUMBER", "RANK", "DENSE_RANK", "PERCENT_RANK", "CUME_DIST", "NTILE",
                "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
                "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "POWER", "SQRT", "CBRT", "LN", "LOG10",
                "LOG2", "EXP", "MOD", "SIGN", "TRUNCATE", "WIDTH_BUCKET",
            ],
            dataTypes: [
                "BOOLEAN", "TINYINT", "SMALLINT", "INTEGER", "INT", "BIGINT", "REAL", "DOUBLE",
                "DECIMAL", "VARCHAR", "CHAR", "VARBINARY", "JSON", "DATE", "TIME", "TIMESTAMP",
                "INTERVAL", "ARRAY", "MAP", "ROW", "IPADDRESS", "UUID", "HYPERLOGLOG",
            ],
            regexSyntax: .regexpLike,
            booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit,
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: "",
            caseSensitivityStyle: .regexFlag,
            textCastTypeName: nil,
            functionNamesAreCaseInsensitive: true,
            typeNamesAreCaseInsensitive: true
        )
    }

    private static let trinoConnectionFields = [
        ConnectionField(
            id: "trinoAuthMethod",
            label: String(localized: "Auth Method"),
            defaultValue: "password",
            fieldType: .dropdown(options: [
                .init(value: "password", label: "Username & Password"),
                .init(value: "jwt", label: "JWT Access Token"),
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "trinoJwtToken",
            label: String(localized: "Access Token"),
            placeholder: "JWT bearer token",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "trinoAuthMethod", values: ["jwt"])
        ),
        ConnectionField(
            id: "trinoSchema",
            label: String(localized: "Schema"),
            placeholder: "Default schema (optional)",
            section: .connection
        ),
        ConnectionField(
            id: "trinoTimeZone",
            label: String(localized: "Time Zone"),
            placeholder: "Optional (e.g. America/New_York)",
            section: .advanced
        ),
    ]
}
