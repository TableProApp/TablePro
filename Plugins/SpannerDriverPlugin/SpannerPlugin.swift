import Foundation
import TableProPluginKit
import TableProSpannerCore

final class SpannerPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Spanner Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Google Cloud Spanner support via REST API"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Spanner"
    static let databaseDisplayName = "Google Cloud Spanner"
    static let iconName = "spanner-icon"
    static let defaultPort = 0
    static let systemSchemaNames: [String] = ["INFORMATION_SCHEMA", "SPANNER_SYS", "information_schema", "spanner_sys", "pg_catalog"]
    static let isDownloadable = true
    static let defaultSchemaName = SpannerSchemaName.defaultToken

    static let connectionMode: ConnectionMode = .apiOnly
    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = true
    static let urlSchemes: [String] = []
    static let brandColorHex = "#1A73E8"
    static let queryLanguageName = "SQL"
    static let editorLanguage: EditorLanguage = .sql
    static let supportsForeignKeys = true
    static let supportsRoutines = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSSH = false
    static let supportsSSL = false
    static let tableEntityName = "Tables"
    static let containerEntityName = "Schema"
    static let supportsForeignKeyDisable = false
    static let supportsReadOnlyMode = true
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let defaultGroupName = "default"
    static let defaultPrimaryKeyColumn: String? = nil
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue]

    static let additionalConnectionFields: [ConnectionField] = SpannerConnectionFields.all

    static let sqlDialect: SQLDialectDescriptor? = SpannerSQLDialect.googleSQL

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN", format: .indentedText)
    ]

    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INT64"],
        "Float": ["FLOAT32", "FLOAT64", "NUMERIC"],
        "String": ["STRING", "JSON"],
        "Binary": ["BYTES"],
        "Boolean": ["BOOL"],
        "Date/Time": ["DATE", "TIMESTAMP"],
        "Complex": ["ARRAY", "STRUCT"],
        "Other": ["UUID"]
    ]

    static var statementCompletions: [CompletionEntry] {
        [
            CompletionEntry(label: "SELECT", insertText: "SELECT"),
            CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
            CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
            CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
            CompletionEntry(label: "CREATE TABLE", insertText: "CREATE TABLE"),
            CompletionEntry(label: "CREATE INDEX", insertText: "CREATE INDEX"),
            CompletionEntry(label: "DROP TABLE", insertText: "DROP TABLE"),
            CompletionEntry(label: "ALTER TABLE", insertText: "ALTER TABLE"),
            CompletionEntry(label: "WHERE", insertText: "WHERE"),
            CompletionEntry(label: "GROUP BY", insertText: "GROUP BY"),
            CompletionEntry(label: "ORDER BY", insertText: "ORDER BY"),
            CompletionEntry(label: "LIMIT", insertText: "LIMIT"),
            CompletionEntry(label: "JOIN", insertText: "JOIN"),
            CompletionEntry(label: "LEFT JOIN", insertText: "LEFT JOIN"),
            CompletionEntry(label: "UNION ALL", insertText: "UNION ALL"),
            CompletionEntry(label: "WITH", insertText: "WITH"),
            CompletionEntry(label: "THEN RETURN", insertText: "THEN RETURN"),
            CompletionEntry(label: "INTERLEAVE IN PARENT", insertText: "INTERLEAVE IN PARENT"),
            CompletionEntry(label: "PRIMARY KEY", insertText: "PRIMARY KEY")
        ]
    }

    static let supportsDropDatabase = false

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        SpannerPluginDriver(config: config)
    }
}

internal enum SpannerConnectionFields {
    static let all: [ConnectionField] = [
        ConnectionField(
            id: "spAuthMethod",
            label: String(localized: "Auth Method"),
            defaultValue: "serviceAccount",
            fieldType: .dropdown(options: [
                .init(value: "serviceAccount", label: "Service Account Key"),
                .init(value: "adc", label: "Application Default Credentials"),
                .init(value: "oauth", label: "Google Account (OAuth)"),
                .init(value: "emulator", label: "Emulator (no credentials)")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "spServiceAccountJson",
            label: String(localized: "Service Account Key"),
            placeholder: "File path or paste JSON",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "spAuthMethod", values: ["serviceAccount"])
        ),
        ConnectionField(
            id: "spProjectId",
            label: String(localized: "Project ID"),
            placeholder: "my-gcp-project",
            required: true,
            section: .authentication
        ),
        ConnectionField(
            id: "spInstanceId",
            label: String(localized: "Instance ID"),
            placeholder: "my-instance",
            required: true,
            section: .authentication
        ),
        ConnectionField(
            id: "spDatabaseId",
            label: String(localized: "Database"),
            placeholder: "my-database",
            required: true,
            section: .authentication
        ),
        ConnectionField(
            id: "spOAuthClientId",
            label: String(localized: "OAuth Client ID"),
            placeholder: "From GCP Console > Credentials",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "spAuthMethod", values: ["oauth"])
        ),
        ConnectionField(
            id: "spOAuthClientSecret",
            label: String(localized: "OAuth Client Secret"),
            placeholder: "Client secret from GCP Console",
            fieldType: .secure,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "spAuthMethod", values: ["oauth"])
        ),
        ConnectionField(
            id: "spOAuthRefreshToken",
            label: String(localized: "OAuth Refresh Token"),
            fieldType: .secure,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "spAuthMethod", values: ["oauth"])
        ),
        ConnectionField(
            id: "spEndpoint",
            label: String(localized: "REST Endpoint"),
            placeholder: "https://spanner.googleapis.com",
            section: .advanced
        )
    ]
}

internal enum SpannerSQLDialect {
    static let googleSQL = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
            "DELETE", "CREATE", "DROP", "ALTER", "TABLE", "VIEW", "SCHEMA", "INDEX",
            "AND", "OR", "NOT", "IN", "BETWEEN", "EXISTS", "IS", "NULL", "LIKE",
            "GROUP", "BY", "ORDER", "ASC", "DESC", "HAVING", "LIMIT", "OFFSET",
            "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "ON",
            "UNION", "ALL", "DISTINCT", "AS", "CASE", "WHEN", "THEN", "ELSE", "END",
            "WITH", "TRUE", "FALSE", "CAST", "PRIMARY", "KEY", "INTERLEAVE", "PARENT",
            "RETURNING", "RETURN"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MIN", "MAX",
            "CONCAT", "LENGTH", "LOWER", "UPPER", "TRIM", "SUBSTR", "REPLACE",
            "STARTS_WITH", "ENDS_WITH", "FORMAT",
            "CURRENT_DATE", "CURRENT_TIMESTAMP", "DATE_ADD", "DATE_SUB",
            "TIMESTAMP_ADD", "TIMESTAMP_SUB", "EXTRACT",
            "CAST", "SAFE_CAST", "TO_JSON", "PARSE_JSON",
            "ARRAY_LENGTH", "ARRAY_AGG",
            "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD",
            "ABS", "CEIL", "FLOOR", "ROUND", "MOD", "SQRT", "POW"
        ],
        dataTypes: [
            "STRING", "BYTES", "INT64", "FLOAT32", "FLOAT64", "NUMERIC",
            "BOOL", "TIMESTAMP", "DATE", "JSON", "ARRAY", "STRUCT", "UUID"
        ],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .implicit,
        paginationStyle: .limit,
        caseSensitivityStyle: .caseFoldFunction
    )
}
