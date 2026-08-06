//
//  CloudflareR2SQLPlugin.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class CloudflareR2SQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Cloudflare R2 SQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Read-only Cloudflare R2 SQL driver over Apache Iceberg tables in R2"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Cloudflare R2 SQL"
    static let databaseDisplayName = "Cloudflare R2 SQL"
    static let iconName = "cloudflare-r2-sql-icon"
    static let defaultPort = 0

    // MARK: - UI/Capability Metadata

    static let connectionMode: ConnectionMode = .apiOnly
    static let supportsSSH = false
    static let supportsSSL = false
    static let isDownloadable = true
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSchemaEditing = false
    static let supportsTriggers = false
    static let supportsTriggerEditing = false
    static let supportsForeignKeys = false
    static let supportsDropDatabase = false
    static let supportsCascadeDrop = false
    static let supportsForeignKeyDisable = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let supportsHealthMonitor = true
    static let supportsQueryProgress = false
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let schemaEntityName = "Namespace"
    static let containerEntityName = "Bucket"
    static let brandColorHex = "#F6821F"
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "Explain", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "explainJson", label: "Explain (JSON)", sqlPrefix: "EXPLAIN FORMAT JSON")
    ]

    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]

    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INT32", "INT64", "INTEGER"],
        "Float": ["FLOAT32", "FLOAT64", "DECIMAL128"],
        "String": ["STRING", "UTF8"],
        "Date": ["DATE32", "TIMESTAMP"],
        "Binary": ["BINARY"],
        "Boolean": ["BOOLEAN"],
        "Nested": ["ARRAY", "STRUCT", "MAP"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "DISTINCT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "QUALIFY",
            "ORDER", "ASC", "DESC", "LIMIT", "AS", "ON", "USING",
            "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS",
            "AND", "OR", "NOT", "IN", "EXISTS", "LIKE", "BETWEEN", "IS", "NULL",
            "CASE", "WHEN", "THEN", "ELSE", "END",
            "WITH", "UNION", "INTERSECT", "EXCEPT", "ALL",
            "OVER", "PARTITION", "ROWS", "RANGE", "PRECEDING", "FOLLOWING", "CURRENT", "ROW", "UNBOUNDED",
            "SHOW", "NAMESPACES", "DATABASES", "TABLES", "DESCRIBE", "EXPLAIN", "FORMAT", "JSON",
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
            "COALESCE", "NULLIF", "ARROW_CAST", "ARROW_TYPEOF",
            "ARRAY_LENGTH", "ARRAY_MAX", "ARRAY_MIN", "MAP_KEYS", "MAP_VALUES"
        ],
        dataTypes: [
            "BOOLEAN", "INT32", "INT64", "FLOAT32", "FLOAT64", "DECIMAL128",
            "STRING", "UTF8", "DATE32", "TIMESTAMP", "BINARY",
            "ARRAY", "STRUCT", "MAP"
        ],
        regexSyntax: .regexpLike,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    static let additionalConnectionFields: [ConnectionField] = [
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

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        CloudflareR2SQLPluginDriver(config: config)
    }
}
