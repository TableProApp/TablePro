//
//  PluginMetadataRegistry+R2SQLDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func r2SQLPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Cloudflare R2 SQL", PluginMetadataSnapshot(
                displayName: "Cloudflare R2 SQL", iconName: "cloudflare-r2-sql-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: r2SQLExplainVariants,
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#F6821F",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsCloudflareTunnel: false,
                    pagination: .leadingRowsOnly(maximumRows: 10_000),
                    isEngineReadOnly: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Bucket",
                    schemaEntityName: "Namespace",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .hierarchicalSchema,
                    structureColumnFields: [.name, .type, .nullable, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: r2SQLDialect,
                    statementCompletions: r2SQLCompletions,
                    columnTypesByCategory: r2SQLColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: r2SQLConnectionFields(),
                    category: .cloud,
                    tagline: String(localized: "Read-only SQL over Iceberg tables in R2")
                )
            ))
        ]
    }

    private func r2SQLConnectionFields() -> [ConnectionField] {
        [
            ConnectionField(
                id: "r2AccountId",
                label: String(localized: "Account ID"),
                placeholder: "Cloudflare Account ID",
                required: true,
                section: .authentication
            ),
            ConnectionField(
                id: "r2Bucket",
                label: String(localized: "Bucket"),
                placeholder: "my-bucket",
                required: true,
                section: .authentication
            )
        ]
    }
}

private let r2SQLExplainVariants: [ExplainVariant] = [
    ExplainVariant(id: "explain", label: "Explain", sqlPrefix: "EXPLAIN"),
    ExplainVariant(id: "explainJson", label: "Explain (JSON)", sqlPrefix: "EXPLAIN FORMAT JSON")
]

private let r2SQLCompletions: [CompletionEntry] = [
    CompletionEntry(label: "SELECT", insertText: "SELECT * FROM namespace.table LIMIT 100"),
    CompletionEntry(label: "SHOW NAMESPACES", insertText: "SHOW NAMESPACES"),
    CompletionEntry(label: "SHOW TABLES", insertText: "SHOW TABLES IN namespace"),
    CompletionEntry(label: "DESCRIBE", insertText: "DESCRIBE namespace.table"),
    CompletionEntry(label: "EXPLAIN", insertText: "EXPLAIN SELECT * FROM namespace.table LIMIT 10")
]

private let r2SQLColumnTypes: [String: [String]] = [
    "Integer": ["TINYINT", "SMALLINT", "INT", "BIGINT"],
    "Float": ["REAL", "DOUBLE", "DECIMAL"],
    "String": ["TEXT"],
    "Date": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ"],
    "Binary": ["BINARY"],
    "Boolean": ["BOOLEAN"],
    "Nested": ["ARRAY", "STRUCT", "MAP"]
]

private let r2SQLDialect = SQLDialectDescriptor(
    identifierQuote: "\"",
    keywords: [
        "SELECT", "DISTINCT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "QUALIFY",
        "ORDER", "ASC", "DESC", "NULLS", "FIRST", "LAST", "LIMIT", "AS", "ON", "USING",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS",
        "AND", "OR", "NOT", "IN", "EXISTS", "LIKE", "ILIKE", "ESCAPE", "BETWEEN", "IS", "NULL",
        "CASE", "WHEN", "THEN", "ELSE", "END",
        "WITH", "UNION", "INTERSECT", "EXCEPT", "ALL",
        "OVER", "PARTITION", "ROWS", "RANGE", "PRECEDING", "FOLLOWING", "CURRENT", "ROW", "UNBOUNDED",
        "SHOW", "NAMESPACES", "DATABASES", "SCHEMAS", "TABLES", "DESCRIBE", "EXPLAIN", "FORMAT", "JSON",
        "TRUE", "FALSE", "CAST"
    ],
    functions: [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "MEDIAN",
        "APPROX_DISTINCT", "APPROX_PERCENTILE_CONT", "APPROX_TOP_K", "PERCENTILE_CONT",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "PERCENT_RANK", "CUME_DIST", "NTILE",
        "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
        "ABS", "CEIL", "FLOOR", "ROUND", "POWER", "SQRT", "LN", "LOG", "EXP",
        "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM", "SUBSTR", "SUBSTRING",
        "REPLACE", "CONCAT", "SPLIT_PART", "STARTS_WITH", "ENDS_WITH", "REGEXP_LIKE",
        "DATE_TRUNC", "DATE_PART", "EXTRACT", "TO_TIMESTAMP", "NOW",
        "COALESCE", "NULLIF", "GET_FIELD", "ARRAY_LENGTH", "MAP_KEYS", "MAP_VALUES", "MAP_EXTRACT"
    ],
    dataTypes: [
        "BOOLEAN", "TINYINT", "SMALLINT", "INT", "BIGINT", "REAL", "DOUBLE", "DECIMAL",
        "TEXT", "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "BINARY", "ARRAY", "STRUCT", "MAP"
    ],
    regexSyntax: .regexpLike,
    booleanLiteralStyle: .truefalse,
    likeEscapeStyle: .explicit,
    paginationStyle: .limit
)
