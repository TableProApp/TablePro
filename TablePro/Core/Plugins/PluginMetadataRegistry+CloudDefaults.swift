//
//  PluginMetadataRegistry+CloudDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    // swiftlint:disable function_body_length
    func cloudPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("DynamoDB", PluginMetadataSnapshot(
                displayName: "Amazon DynamoDB", iconName: "dynamodb-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#4053D6",
                queryLanguageName: "PartiQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: SQLDialectDescriptor(
                        identifierQuote: "\"",
                        keywords: [
                            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUE", "SET",
                            "UPDATE", "DELETE", "AND", "OR", "NOT", "IN", "BETWEEN",
                            "EXISTS", "MISSING", "IS", "NULL", "LIMIT",
                        ],
                        functions: [
                            "begins_with", "contains", "size", "attribute_type",
                            "attribute_exists", "attribute_not_exists",
                        ],
                        dataTypes: ["S", "N", "B", "BOOL", "NULL", "L", "M", "SS", "NS", "BS"]
                    ),
                    statementCompletions: [
                        CompletionEntry(label: "SELECT", insertText: "SELECT"),
                        CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
                        CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
                        CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
                        CompletionEntry(label: "VALUE", insertText: "VALUE"),
                        CompletionEntry(label: "SET", insertText: "SET"),
                        CompletionEntry(label: "WHERE", insertText: "WHERE"),
                        CompletionEntry(label: "begins_with", insertText: "begins_with"),
                        CompletionEntry(label: "contains", insertText: "contains"),
                        CompletionEntry(label: "size", insertText: "size"),
                        CompletionEntry(label: "attribute_type", insertText: "attribute_type"),
                        CompletionEntry(label: "attribute_exists", insertText: "attribute_exists"),
                        CompletionEntry(label: "attribute_not_exists", insertText: "attribute_not_exists"),
                    ],
                    columnTypesByCategory: [
                        "String": ["S"],
                        "Number": ["N"],
                        "Binary": ["B"],
                        "Boolean": ["BOOL"],
                        "Null": ["NULL"],
                        "List": ["L"],
                        "Map": ["M"],
                        "String Set": ["SS"],
                        "Number Set": ["NS"],
                        "Binary Set": ["BS"],
                    ]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "awsAuthMethod",
                            label: String(localized: "Auth Method"),
                            defaultValue: "credentials",
                            fieldType: .dropdown(options: [
                                .init(value: "credentials", label: "Access Key + Secret Key"),
                                .init(value: "profile", label: "AWS Profile"),
                                .init(value: "sso", label: "AWS SSO"),
                            ]),
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "awsAccessKeyId",
                            label: String(localized: "Access Key ID"),
                            placeholder: "AKIA...",
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
                        ),
                        ConnectionField(
                            id: "awsSecretAccessKey",
                            label: String(localized: "Secret Access Key"),
                            placeholder: "wJalr...",
                            fieldType: .secure,
                            section: .authentication,
                            hidesPassword: true,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
                        ),
                        ConnectionField(
                            id: "awsSessionToken",
                            label: String(localized: "Session Token"),
                            placeholder: "Optional (for temporary credentials)",
                            fieldType: .secure,
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
                        ),
                        ConnectionField(
                            id: "awsProfileName",
                            label: String(localized: "Profile Name"),
                            placeholder: "default",
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["profile", "sso"])
                        ),
                        ConnectionField(
                            id: "awsRegion",
                            label: String(localized: "AWS Region"),
                            placeholder: "us-east-1",
                            defaultValue: "us-east-1",
                            fieldType: .text,
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "awsEndpointUrl",
                            label: String(localized: "Custom Endpoint"),
                            placeholder: "http://localhost:8000 (DynamoDB Local)",
                            section: .authentication
                        ),
                    ]
                )
            )),
            ("BigQuery", PluginMetadataSnapshot(
                displayName: "Google BigQuery", iconName: "bigquery-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "dryrun", label: "Dry Run (Cost)", sqlPrefix: "EXPLAIN")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#4285F4",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
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
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: ["INFORMATION_SCHEMA"],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: SQLDialectDescriptor(
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
                            "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD", "FIRST_VALUE",
                            "LAST_VALUE", "NTILE", "PERCENT_RANK", "CUME_DIST",
                            "ABS", "CEIL", "FLOOR", "ROUND", "TRUNC", "MOD", "SIGN", "SQRT", "POW",
                            "LOG", "ST_GEOGPOINT", "ST_DISTANCE", "ST_CONTAINS", "ST_INTERSECTS",
                            "ML.PREDICT", "ML.EVALUATE", "ML.TRAINING_INFO",
                            "NET.IP_FROM_STRING", "NET.SAFE_IP_FROM_STRING", "NET.HOST",
                            "NET.REG_DOMAIN", "FARM_FINGERPRINT", "MD5", "SHA256", "SHA512"
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
                    ),
                    statementCompletions: [
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
                    ],
                    columnTypesByCategory: [
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
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
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
                            id: "bqMaxBytesBilled",
                            label: String(localized: "Max Bytes Billed"),
                            placeholder: "1000000000",
                            fieldType: .number,
                            section: .advanced
                        )
                    ]
                )
            ))
        ]
    }
    // swiftlint:enable function_body_length
}
