//
//  BigQueryPlugin.swift
//  BigQueryDriverPlugin
//
//  Google BigQuery driver plugin via REST API with GoogleSQL support.
//

import Foundation
import os
import TableProPluginKit

final class BigQueryPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "BigQuery Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Google BigQuery support via REST API with GoogleSQL"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "BigQuery"
    static let databaseDisplayName = "Google BigQuery"
    static let iconName = "bigquery-icon"
    static let defaultPort = 0
    static let additionalDatabaseTypeIds: [String] = []
    static let systemSchemaNames: [String] = ["INFORMATION_SCHEMA"]
    static let isDownloadable = true
    static let defaultSchemaName = ""

    static let connectionMode: ConnectionMode = .apiOnly
    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = true
    static let urlSchemes: [String] = []
    static let brandColorHex = "#4285F4"
    static let queryLanguageName = "SQL"
    static let editorLanguage: EditorLanguage = .sql
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSSH = false
    static let supportsSSL = false
    static let tableEntityName = "Tables"
    static let supportsForeignKeyDisable = false
    static let supportsReadOnlyMode = true
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let defaultGroupName = "default"
    static let defaultPrimaryKeyColumn: String? = nil
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .comment]

    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "bqAuthMethod",
            label: String(localized: "Auth Method"),
            defaultValue: "serviceAccount",
            fieldType: .dropdown(options: [
                .init(value: "serviceAccount", label: "Service Account Key"),
                .init(value: "adc", label: "Application Default Credentials"),
                .init(value: "oauth", label: "Google Account (OAuth)")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "bqServiceAccountJson",
            label: String(localized: "Service Account Key"),
            placeholder: "File path or paste JSON",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "bqAuthMethod", values: ["serviceAccount"])
        ),
        ConnectionField(
            id: "bqProjectId",
            label: String(localized: "Project ID"),
            placeholder: "my-gcp-project",
            required: true,
            section: .authentication
        ),
        ConnectionField(
            id: "bqLocation",
            label: String(localized: "Location"),
            placeholder: "US, EU, us-central1, etc.",
            section: .authentication
        ),
        ConnectionField(
            id: "bqOAuthClientId",
            label: String(localized: "OAuth Client ID"),
            placeholder: "From GCP Console > Credentials",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "bqAuthMethod", values: ["oauth"])
        ),
        ConnectionField(
            id: "bqOAuthClientSecret",
            label: String(localized: "OAuth Client Secret"),
            placeholder: "Client secret from GCP Console",
            fieldType: .secure,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "bqAuthMethod", values: ["oauth"])
        ),
        ConnectionField(
            id: "bqOAuthRefreshToken",
            label: String(localized: "OAuth Refresh Token"),
            fieldType: .secure,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "bqAuthMethod", values: ["oauth"])
        ),
        ConnectionField(
            id: "bqMaxBytesBilled",
            label: String(localized: "Max Bytes Billed"),
            placeholder: "1000000000",
            fieldType: .number,
            section: .advanced
        )
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
            "DELETE", "CREATE", "DROP", "ALTER", "TABLE", "VIEW", "SCHEMA", "DATABASE",
            "AND", "OR", "NOT", "IN", "BETWEEN", "EXISTS", "IS", "NULL", "LIKE",
            "GROUP", "BY", "ORDER", "ASC", "DESC", "HAVING", "LIMIT", "OFFSET",
            "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "ON",
            "UNION", "ALL", "DISTINCT", "AS", "CASE", "WHEN", "THEN", "ELSE", "END",
            "WITH", "RECURSIVE", "PARTITION", "OVER", "WINDOW", "ROWS", "RANGE",
            "UNNEST", "EXCEPT", "INTERSECT", "MERGE", "USING", "MATCHED",
            "STRUCT", "ARRAY", "TRUE", "FALSE", "CAST", "SAFE_CAST",
            "IF", "IFNULL", "NULLIF", "COALESCE", "ANY_VALUE",
            "QUALIFY", "PIVOT", "UNPIVOT", "TABLESAMPLE"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "APPROX_COUNT_DISTINCT",
            "ARRAY_AGG", "STRING_AGG", "COUNTIF", "LOGICAL_AND", "LOGICAL_OR",
            "CONCAT", "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
            "SUBSTR", "REPLACE", "REGEXP_CONTAINS", "REGEXP_EXTRACT", "REGEXP_REPLACE",
            "STARTS_WITH", "ENDS_WITH", "SPLIT", "FORMAT", "REVERSE",
            "DATE", "TIME", "DATETIME", "TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME",
            "CURRENT_DATETIME", "CURRENT_TIMESTAMP", "DATE_ADD", "DATE_SUB",
            "DATE_DIFF", "DATE_TRUNC", "EXTRACT", "FORMAT_DATE", "FORMAT_TIMESTAMP",
            "PARSE_DATE", "PARSE_TIMESTAMP", "TIMESTAMP_ADD", "TIMESTAMP_SUB",
            "TIMESTAMP_DIFF", "TIMESTAMP_TRUNC", "UNIX_SECONDS", "UNIX_MILLIS",
            "CAST", "SAFE_CAST", "PARSE_JSON", "TO_JSON", "TO_JSON_STRING",
            "JSON_EXTRACT", "JSON_EXTRACT_SCALAR", "JSON_QUERY", "JSON_VALUE",
            "ARRAY_LENGTH", "GENERATE_ARRAY", "GENERATE_DATE_ARRAY",
            "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE",
            "NTILE", "PERCENT_RANK", "CUME_DIST",
            "ABS", "CEIL", "FLOOR", "ROUND", "TRUNC", "MOD", "SIGN", "SQRT", "POW", "LOG",
            "ST_GEOGPOINT", "ST_DISTANCE", "ST_CONTAINS", "ST_INTERSECTS",
            "ML.PREDICT", "ML.EVALUATE", "ML.TRAINING_INFO",
            "NET.IP_FROM_STRING", "NET.SAFE_IP_FROM_STRING", "NET.HOST", "NET.REG_DOMAIN",
            "FARM_FINGERPRINT", "MD5", "SHA256", "SHA512"
        ],
        dataTypes: [
            "STRING", "BYTES", "INT64", "FLOAT64", "NUMERIC", "BIGNUMERIC",
            "BOOL", "TIMESTAMP", "DATE", "TIME", "DATETIME", "INTERVAL",
            "GEOGRAPHY", "JSON", "STRUCT", "ARRAY", "RANGE"
        ],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "dryrun", label: "Dry Run (Cost)", sqlPrefix: "EXPLAIN")
    ]

    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INT64"],
        "Float": ["FLOAT64", "NUMERIC", "BIGNUMERIC"],
        "String": ["STRING"],
        "Binary": ["BYTES"],
        "Boolean": ["BOOL"],
        "Date/Time": ["DATE", "TIME", "DATETIME", "TIMESTAMP", "INTERVAL"],
        "Complex": ["STRUCT", "ARRAY", "JSON"],
        "Geo": ["GEOGRAPHY"],
        "Range": ["RANGE"]
    ]

    static var statementCompletions: [CompletionEntry] {
        [
            CompletionEntry(label: "SELECT", insertText: "SELECT"),
            CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
            CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
            CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
            CompletionEntry(label: "CREATE TABLE", insertText: "CREATE TABLE"),
            CompletionEntry(label: "CREATE VIEW", insertText: "CREATE VIEW"),
            CompletionEntry(label: "DROP TABLE", insertText: "DROP TABLE"),
            CompletionEntry(label: "WHERE", insertText: "WHERE"),
            CompletionEntry(label: "GROUP BY", insertText: "GROUP BY"),
            CompletionEntry(label: "ORDER BY", insertText: "ORDER BY"),
            CompletionEntry(label: "LIMIT", insertText: "LIMIT"),
            CompletionEntry(label: "JOIN", insertText: "JOIN"),
            CompletionEntry(label: "LEFT JOIN", insertText: "LEFT JOIN"),
            CompletionEntry(label: "UNION ALL", insertText: "UNION ALL"),
            CompletionEntry(label: "WITH", insertText: "WITH"),
            CompletionEntry(label: "UNNEST", insertText: "UNNEST"),
            CompletionEntry(label: "STRUCT", insertText: "STRUCT"),
            CompletionEntry(label: "ARRAY", insertText: "ARRAY"),
            CompletionEntry(label: "QUALIFY", insertText: "QUALIFY"),
            CompletionEntry(label: "PARTITION BY", insertText: "PARTITION BY"),
            CompletionEntry(label: "SAFE_CAST", insertText: "SAFE_CAST"),
            CompletionEntry(label: "REGEXP_CONTAINS", insertText: "REGEXP_CONTAINS"),
            CompletionEntry(label: "FORMAT_TIMESTAMP", insertText: "FORMAT_TIMESTAMP"),
            CompletionEntry(label: "ROW_NUMBER", insertText: "ROW_NUMBER"),
            CompletionEntry(label: "APPROX_COUNT_DISTINCT", insertText: "APPROX_COUNT_DISTINCT")
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        BigQueryPluginDriver(config: config)
    }
}
