import Foundation
import TableProPluginKit

final class TrinoPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Trino Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Trino distributed SQL engine support via the REST client protocol"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Trino"
    static let databaseDisplayName = "Trino"
    static let iconName = "trino-icon"
    static let defaultPort = 8_080
    static let isDownloadable = true

    static let connectionMode: ConnectionMode = .network
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let brandColorHex = "#DD5F3B"
    static let queryLanguageName = "SQL"
    static let editorLanguage: EditorLanguage = .sql
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = true
    static let supportsDatabaseSwitching = true
    static let supportsSchemaSwitching = true
    static let requiresReconnectForDatabaseSwitch = false
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let defaultGroupName = "default"
    static let containerEntityName = "Catalog"
    static let schemaEntityName = "Schema"
    static let tableEntityName = "Tables"
    static let defaultSchemaName = ""
    static let systemSchemaNames: [String] = ["information_schema"]
    static let supportsSSH = true
    static let supportsSSL = true
    static let supportsHealthMonitor = true
    static let supportsImport = false
    static let supportsExport = true
    static let supportsReadOnlyMode = true
    static let supportsForeignKeyDisable = false
    static let supportsAddColumn = true
    static let supportsModifyColumn = true
    static let supportsDropColumn = true
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue, .comment]
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]

    static let columnTypesByCategory: [String: [String]] = [
        "Boolean": ["boolean"],
        "Integer": ["tinyint", "smallint", "integer", "bigint"],
        "Floating": ["real", "double", "decimal"],
        "String": ["varchar", "char"],
        "Binary": ["varbinary"],
        "Date/Time": ["date", "time", "timestamp", "time with time zone", "timestamp with time zone"],
        "Complex": ["array", "map", "row", "json"],
        "Other": ["uuid", "ipaddress", "interval year to month", "interval day to second"],
    ]

    static let additionalConnectionFields: [ConnectionField] = [
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

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
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
        paginationStyle: .offsetFetch,
        offsetFetchOrderBy: ""
    )

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "logical", label: "Explain (Logical)", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "distributed", label: "Explain (Distributed)", sqlPrefix: "EXPLAIN (TYPE DISTRIBUTED)"),
        ExplainVariant(id: "io", label: "Explain (IO)", sqlPrefix: "EXPLAIN (TYPE IO)"),
        ExplainVariant(id: "validate", label: "Explain (Validate)", sqlPrefix: "EXPLAIN (TYPE VALIDATE)"),
        ExplainVariant(id: "analyze", label: "Explain Analyze", sqlPrefix: "EXPLAIN ANALYZE"),
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        TrinoPluginDriver(config: config)
    }
}
