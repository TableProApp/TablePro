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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false
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
                        ).withDynamicOptions(.awsProfiles),
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
                    ],
                    category: .cloud,
                    tagline: String(localized: "AWS managed key-value/document store")
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true
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
                    databaseGroupingStrategy: .hierarchicalSchema,
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
                    ],
                    category: .analytical,
                    tagline: String(localized: "Google Cloud serverless data warehouse")
                )
            )),
            ("Snowflake", PluginMetadataSnapshot(
                displayName: "Snowflake", iconName: "snowflake-icon", defaultPort: 443,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "text", label: "Explain (Text)", sqlPrefix: "EXPLAIN USING TEXT")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: false, urlSchemes: [],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#29B5E8",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: true,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "PUBLIC",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["SNOWFLAKE", "SNOWFLAKE_SAMPLE_DATA"],
                    systemSchemaNames: ["INFORMATION_SCHEMA"],
                    fileExtensions: [],
                    databaseGroupingStrategy: .hierarchicalSchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: SQLDialectDescriptor(
                        identifierQuote: "\"",
                        keywords: [
                            "ACCOUNT", "ALL", "ALTER", "AND", "ANY", "AS", "ASC",
                            "AT", "BEFORE", "BEGIN", "BETWEEN", "BY", "CALL", "CASE",
                            "CAST", "CHECK", "CLONE", "CLUSTER", "COLUMN", "COMMENT", "COMMIT",
                            "CONNECT", "CONNECTION", "CONSTRAINT", "COPY", "CREATE", "CROSS", "CURRENT",
                            "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "DATABASE", "DELETE", "DESC",
                            "DESCRIBE", "DISTINCT", "DROP", "DYNAMIC", "ELSE", "END", "EXECUTE",
                            "EXISTS", "EXPLAIN", "EXTERNAL", "FALSE", "FILE", "FIRST", "FLATTEN",
                            "FOLLOWING", "FOR", "FORMAT", "FROM", "FULL", "FUNCTION", "GET",
                            "GRANT", "GROUP", "HAVING", "HYBRID", "ICEBERG", "ILIKE", "IMMEDIATE",
                            "IN", "INCREMENT", "INDEX", "INNER", "INSERT", "INTEGRATION", "INTERSECT",
                            "INTERVAL", "INTO", "IS", "JOIN", "LAST", "LATERAL", "LEFT",
                            "LIKE", "LIMIT", "LIST", "LOCALTIME", "LOCALTIMESTAMP", "MASKING", "MATCHED",
                            "MATERIALIZED", "MERGE", "MINUS", "MONITOR", "NATURAL", "NETWORK", "NOT",
                            "NULL", "NULLS", "OF", "OFFSET", "ON", "OR", "ORDER",
                            "ORGANIZATION", "OVER", "OWNERSHIP", "PARTITION", "PIPE", "PIVOT", "POLICY",
                            "PRECEDING", "PROCEDURE", "PUT", "QUALIFY", "RANGE", "RECURSIVE", "REGEXP",
                            "REMOVE", "REPLACE", "RESOURCE", "RESUME", "REVOKE", "RIGHT", "RLIKE",
                            "ROLE", "ROLLBACK", "ROW", "ROWS", "SAMPLE", "SCHEMA", "SECRET",
                            "SECURE", "SELECT", "SEQUENCE", "SERVICE", "SESSION", "SET", "SHARE",
                            "SHOW", "SOME", "STAGE", "START", "STATEMENT", "STORAGE", "STREAM",
                            "STREAMLIT", "SUSPEND", "SWAP", "TABLE", "TABLESAMPLE", "TAG", "TASK",
                            "TEMPORARY", "THEN", "TO", "TOP", "TRANSIENT", "TRIGGER", "TRUE",
                            "TRY_CAST", "UNBOUNDED", "UNDROP", "UNION", "UNIQUE", "UNPIVOT", "UNSET",
                            "UPDATE", "USAGE", "USE", "USING", "VALUES", "VIEW", "WAREHOUSE",
                            "WHEN", "WHERE", "WINDOW", "WITH"
                        ],
                        functions: [
                            "ABS", "ACOS", "ACOSH", "ADD_MONTHS", "ANY_VALUE", "APPROX_COUNT_DISTINCT", "APPROX_PERCENTILE",
                            "APPROX_TOP_K", "APPROXIMATE_JACCARD_INDEX", "APPROXIMATE_SIMILARITY", "ARRAY_AGG", "ARRAY_APPEND", "ARRAY_CAT", "ARRAY_COMPACT",
                            "ARRAY_CONSTRUCT", "ARRAY_CONSTRUCT_COMPACT", "ARRAY_CONTAINS", "ARRAY_DISTINCT", "ARRAY_EXCEPT", "ARRAY_FLATTEN", "ARRAY_GENERATE_RANGE",
                            "ARRAY_INSERT", "ARRAY_INTERSECTION", "ARRAY_MAX", "ARRAY_MIN", "ARRAY_POSITION", "ARRAY_PREPEND", "ARRAY_REMOVE",
                            "ARRAY_REMOVE_AT", "ARRAY_REVERSE", "ARRAY_SIZE", "ARRAY_SLICE", "ARRAY_SORT", "ARRAY_TO_STRING", "ARRAY_UNION_AGG",
                            "ARRAY_UNIQUE_AGG", "ARRAYS_OVERLAP", "ARRAYS_TO_OBJECT", "ARRAYS_ZIP", "AS_ARRAY", "AS_BINARY", "AS_BOOLEAN",
                            "AS_CHAR", "AS_VARCHAR", "AS_DATE", "AS_DECIMAL", "AS_NUMBER", "AS_DOUBLE", "AS_REAL",
                            "AS_INTEGER", "AS_OBJECT", "AS_TIME", "AS_TIMESTAMP", "ASCII", "ASIN", "ASINH",
                            "ATAN", "ATAN2", "ATANH", "AVG", "BASE64_DECODE_BINARY", "BASE64_DECODE_STRING", "BASE64_ENCODE",
                            "BITAND", "BITAND_AGG", "BITNOT", "BITOR", "BITOR_AGG", "BITSHIFTLEFT", "BITSHIFTRIGHT",
                            "BITXOR", "BITXOR_AGG", "BOOLAND", "BOOLAND_AGG", "BOOLNOT", "BOOLOR", "BOOLOR_AGG",
                            "BOOLXOR", "BOOLXOR_AGG", "CAST", "CBRT", "CEIL", "CHARINDEX", "CHECK_JSON",
                            "CHECK_XML", "CHR", "CHAR", "COALESCE", "COLLATE", "COLLATION", "COMPRESS",
                            "CONCAT", "CONCAT_WS", "CONDITIONAL_CHANGE_EVENT", "CONDITIONAL_TRUE_EVENT", "CONTAINS", "CONVERT_TIMEZONE", "CORR",
                            "COS", "COSH", "COT", "COUNT", "COUNT_IF", "COVAR_POP", "COVAR_SAMP",
                            "CUME_DIST", "CURRENT_ACCOUNT", "CURRENT_AVAILABLE_ROLES", "CURRENT_CLIENT", "CURRENT_DATABASE", "CURRENT_DATE", "CURRENT_REGION",
                            "CURRENT_ROLE", "CURRENT_ROLE_TYPE", "CURRENT_SCHEMA", "CURRENT_SCHEMAS", "CURRENT_SECONDARY_ROLES", "CURRENT_SESSION", "CURRENT_STATEMENT",
                            "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_TRANSACTION", "CURRENT_USER", "CURRENT_VERSION", "CURRENT_WAREHOUSE", "DATE_FROM_PARTS",
                            "DATE_PART", "DATE_TRUNC", "DATEADD", "DATEDIFF", "DAYNAME", "DECODE", "DECOMPRESS_BINARY",
                            "DECOMPRESS_STRING", "DECRYPT", "DECRYPT_RAW", "DEGREES", "DENSE_RANK", "DIV0", "DIV0NULL",
                            "EDITDISTANCE", "ENCRYPT", "ENCRYPT_RAW", "ENDSWITH", "EQUAL_NULL", "EXP", "EXTRACT",
                            "FACTORIAL", "FIRST_VALUE", "FLATTEN", "FLOOR", "GENERATOR", "GET", "GET_DDL",
                            "GET_IGNORE_CASE", "GET_PATH", "GETBIT", "GETDATE", "GREATEST", "GREATEST_IGNORE_NULLS", "GROUPING",
                            "GROUPING_ID", "HASH", "HASH_AGG", "HAVERSINE", "HEX_DECODE_BINARY", "HEX_DECODE_STRING", "HEX_ENCODE",
                            "HLL", "HLL_ACCUMULATE", "HLL_COMBINE", "HLL_ESTIMATE", "IFF", "IFNULL", "INITCAP",
                            "INSERT", "IS_ARRAY", "IS_BINARY", "IS_BOOLEAN", "IS_DATE", "IS_DECIMAL", "IS_DOUBLE",
                            "IS_INTEGER", "IS_NULL_VALUE", "IS_OBJECT", "IS_TIME", "IS_TIMESTAMP", "IS_VARCHAR", "JSON_EXTRACT_PATH_TEXT",
                            "KURTOSIS", "LAG", "LAST_DAY", "LAST_VALUE", "LEAD", "LEAST", "LEAST_IGNORE_NULLS",
                            "LEFT", "LENGTH", "LISTAGG", "LN", "LOG", "LOWER", "LPAD",
                            "LTRIM", "MAP_VALUES", "MAX", "MD5", "MD5_HEX", "MD5_BINARY", "MEDIAN",
                            "MIN", "MINHASH", "MINHASH_COMBINE", "MINHASH_ESTIMATE", "MOD", "MODE", "MONTHNAME",
                            "MONTHS_BETWEEN", "NTILE", "NULLIF", "NULLIFZERO", "NVL", "NVL2", "OBJECT_AGG",
                            "OBJECT_CONSTRUCT", "OBJECT_CONSTRUCT_KEEP_NULL", "OBJECT_DELETE", "OBJECT_INSERT", "OBJECT_KEYS", "OBJECT_PICK", "OBJECT_VALUES",
                            "OCTET_LENGTH", "PARSE_JSON", "PARSE_URL", "PARSE_XML", "PERCENTILE_CONT", "PERCENTILE_DISC", "PERCENT_RANK",
                            "PI", "POSITION", "POW", "POWER", "QUOTE", "RADIANS", "RANDOM",
                            "RANK", "RATIO_TO_REPORT", "REGEXP_COUNT", "REGEXP_INSTR", "REGEXP_LIKE", "REGEXP_REPLACE", "REGEXP_SUBSTR",
                            "REPEAT", "REPLACE", "RESULT_SCAN", "REVERSE", "RIGHT", "ROUND", "ROW_NUMBER",
                            "RPAD", "RTRIM", "SEQ1", "SEQ2", "SEQ4", "SEQ8", "SHA1",
                            "SHA1_BINARY", "SHA1_HEX", "SHA2", "SHA2_BINARY", "SHA2_HEX", "SIGN", "SIN",
                            "SINH", "SKEW", "SOUNDEX", "SPACE", "SPLIT", "SPLIT_PART", "SPLIT_TO_TABLE",
                            "SQRT", "SQUARE", "STARTSWITH", "STDDEV", "STDDEV_POP", "STDDEV_SAMP", "STRTOK",
                            "STRTOK_TO_ARRAY", "STRTOK_SPLIT_TO_TABLE", "SUBSTR", "SUBSTRING", "SUM", "SYSDATE", "TAN",
                            "TANH", "TIME_FROM_PARTS", "TIME_SLICE", "TIMEADD", "TIMEDIFF", "TIMEOFDAY", "TIMESTAMP_FROM_PARTS",
                            "TIMESTAMP_LTZ_FROM_PARTS", "TIMESTAMP_NTZ_FROM_PARTS", "TIMESTAMP_TZ_FROM_PARTS", "TIMESTAMPADD", "TIMESTAMPDIFF", "TIMEZONE_OFFSET", "TO_ARRAY",
                            "TO_BINARY", "TO_BOOLEAN", "TO_CHAR", "TO_DATE", "TO_DECIMAL", "TO_DOUBLE", "TO_GEOGRAPHY",
                            "TO_INTEGER", "TO_JSON", "TO_NUMBER", "TO_OBJECT", "TO_TIME", "TO_TIMESTAMP", "TO_TIMESTAMP_LTZ",
                            "TO_TIMESTAMP_NTZ", "TO_TIMESTAMP_TZ", "TO_VARCHAR", "TO_VARIANT", "TO_XML", "TRANSLATE", "TRIM",
                            "TRUNC", "TRUNCATE", "TRY_BASE64_DECODE_STRING", "TRY_CAST", "TRY_HEX_DECODE_STRING", "TRY_PARSE_JSON", "TRY_TO_BINARY",
                            "TRY_TO_BOOLEAN", "TRY_TO_DATE", "TRY_TO_DECIMAL", "TRY_TO_DOUBLE", "TRY_TO_NUMBER", "TRY_TO_TIME", "TRY_TO_TIMESTAMP",
                            "TRY_TO_TIMESTAMP_LTZ", "TRY_TO_TIMESTAMP_NTZ", "TRY_TO_TIMESTAMP_TZ", "TYPEOF", "UNICODE", "UNIFORM", "UPPER",
                            "URL_DECODE_STRING", "URL_ENCODE", "UUID_STRING", "VAR_POP", "VAR_SAMP", "VARIANCE", "VARIANCE_POP",
                            "VARIANCE_SAMP", "WEEK", "WEEKISO", "WEEKOFYEAR", "WIDTH_BUCKET", "XMLGET", "YEAR",
                            "YEAROFWEEK", "ZEROIFNULL", "DAYOFMONTH", "DAYOFWEEK", "DAYOFWEEKISO", "DAYOFYEAR", "HOUR",
                            "MINUTE", "SECOND", "QUARTER", "MONTH"
                        ],
                        dataTypes: [
                            "NUMBER", "DECIMAL", "DEC", "NUMERIC", "INT", "INTEGER", "BIGINT",
                            "SMALLINT", "TINYINT", "BYTEINT", "FLOAT", "FLOAT4", "FLOAT8", "DOUBLE",
                            "REAL", "DECFLOAT", "VARCHAR", "CHAR", "CHARACTER", "STRING", "TEXT",
                            "VARCHAR2", "NVARCHAR", "NVARCHAR2", "NCHAR", "BINARY", "VARBINARY", "BOOLEAN",
                            "DATE", "DATETIME", "TIME", "TIMESTAMP", "TIMESTAMP_LTZ", "TIMESTAMP_NTZ", "TIMESTAMP_TZ",
                            "VARIANT", "OBJECT", "ARRAY", "MAP", "GEOGRAPHY", "GEOMETRY", "VECTOR",
                            "FILE"
                        ],
                        regexSyntax: .regexpLike,
                        booleanLiteralStyle: .truefalse,
                        likeEscapeStyle: .explicit,
                        paginationStyle: .limit
                    ),
                    statementCompletions: [
                        CompletionEntry(label: "SELECT", insertText: "SELECT"),
                        CompletionEntry(label: "SELECT DISTINCT", insertText: "SELECT DISTINCT"),
                        CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
                        CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
                        CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
                        CompletionEntry(label: "MERGE INTO", insertText: "MERGE INTO"),
                        CompletionEntry(label: "COPY INTO", insertText: "COPY INTO"),
                        CompletionEntry(label: "CREATE OR REPLACE TABLE", insertText: "CREATE OR REPLACE TABLE"),
                        CompletionEntry(label: "CREATE OR REPLACE VIEW", insertText: "CREATE OR REPLACE VIEW"),
                        CompletionEntry(label: "CREATE OR REPLACE DYNAMIC TABLE", insertText: "CREATE OR REPLACE DYNAMIC TABLE"),
                        CompletionEntry(label: "CREATE OR REPLACE MATERIALIZED VIEW", insertText: "CREATE OR REPLACE MATERIALIZED VIEW"),
                        CompletionEntry(label: "CREATE OR REPLACE STREAM", insertText: "CREATE OR REPLACE STREAM"),
                        CompletionEntry(label: "CREATE OR REPLACE TASK", insertText: "CREATE OR REPLACE TASK"),
                        CompletionEntry(label: "CREATE OR REPLACE FILE FORMAT", insertText: "CREATE OR REPLACE FILE FORMAT"),
                        CompletionEntry(label: "DROP TABLE", insertText: "DROP TABLE"),
                        CompletionEntry(label: "UNDROP TABLE", insertText: "UNDROP TABLE"),
                        CompletionEntry(label: "SHOW TABLES", insertText: "SHOW TABLES"),
                        CompletionEntry(label: "SHOW SCHEMAS", insertText: "SHOW SCHEMAS"),
                        CompletionEntry(label: "SHOW WAREHOUSES", insertText: "SHOW WAREHOUSES"),
                        CompletionEntry(label: "DESCRIBE TABLE", insertText: "DESCRIBE TABLE"),
                        CompletionEntry(label: "USE DATABASE", insertText: "USE DATABASE"),
                        CompletionEntry(label: "USE SCHEMA", insertText: "USE SCHEMA"),
                        CompletionEntry(label: "USE WAREHOUSE", insertText: "USE WAREHOUSE"),
                        CompletionEntry(label: "USE ROLE", insertText: "USE ROLE"),
                        CompletionEntry(label: "ALTER SESSION SET", insertText: "ALTER SESSION SET"),
                        CompletionEntry(label: "WHERE", insertText: "WHERE"),
                        CompletionEntry(label: "GROUP BY", insertText: "GROUP BY"),
                        CompletionEntry(label: "ORDER BY", insertText: "ORDER BY"),
                        CompletionEntry(label: "QUALIFY", insertText: "QUALIFY"),
                        CompletionEntry(label: "LIMIT", insertText: "LIMIT"),
                        CompletionEntry(label: "JOIN", insertText: "JOIN"),
                        CompletionEntry(label: "LEFT JOIN", insertText: "LEFT JOIN"),
                        CompletionEntry(label: "LATERAL FLATTEN", insertText: "LATERAL FLATTEN"),
                        CompletionEntry(label: "PARSE_JSON", insertText: "PARSE_JSON"),
                        CompletionEntry(label: "TRY_PARSE_JSON", insertText: "TRY_PARSE_JSON"),
                        CompletionEntry(label: "GET_PATH", insertText: "GET_PATH"),
                        CompletionEntry(label: "OBJECT_CONSTRUCT", insertText: "OBJECT_CONSTRUCT"),
                        CompletionEntry(label: "ARRAY_AGG", insertText: "ARRAY_AGG"),
                        CompletionEntry(label: "LISTAGG", insertText: "LISTAGG"),
                        CompletionEntry(label: "DATE_TRUNC", insertText: "DATE_TRUNC"),
                        CompletionEntry(label: "DATEADD", insertText: "DATEADD"),
                        CompletionEntry(label: "DATEDIFF", insertText: "DATEDIFF"),
                        CompletionEntry(label: "CONVERT_TIMEZONE", insertText: "CONVERT_TIMEZONE"),
                        CompletionEntry(label: "TO_TIMESTAMP", insertText: "TO_TIMESTAMP"),
                        CompletionEntry(label: "TRY_TO_NUMBER", insertText: "TRY_TO_NUMBER"),
                        CompletionEntry(label: "ROW_NUMBER", insertText: "ROW_NUMBER"),
                        CompletionEntry(label: "RESULT_SCAN", insertText: "RESULT_SCAN"),
                        CompletionEntry(label: "GENERATOR", insertText: "GENERATOR"),
                        CompletionEntry(label: "ZEROIFNULL", insertText: "ZEROIFNULL"),
                        CompletionEntry(label: "IFF", insertText: "IFF"),
                        CompletionEntry(label: "NVL", insertText: "NVL"),
                        CompletionEntry(label: "DECODE", insertText: "DECODE")
                    ],
                    columnTypesByCategory: [
                        "Number": ["NUMBER", "DECIMAL", "INT", "INTEGER", "BIGINT", "SMALLINT", "FLOAT", "DOUBLE", "REAL"],
                        "String": ["VARCHAR", "CHAR", "STRING", "TEXT"],
                        "Binary": ["BINARY", "VARBINARY"],
                        "Boolean": ["BOOLEAN"],
                        "Date/Time": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMP_LTZ", "TIMESTAMP_NTZ", "TIMESTAMP_TZ"],
                        "Semi-structured": ["VARIANT", "OBJECT", "ARRAY"],
                        "Geospatial": ["GEOGRAPHY", "GEOMETRY"]
                    ]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: snowflakeConnectionFields(),
                    category: .analytical,
                    tagline: String(localized: "Cloud data warehouse")
                )
            ))
        ]
    }
    // swiftlint:enable function_body_length
}

func snowflakeConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: "snowflakeAccount",
            label: String(localized: "Account Identifier"),
            placeholder: "xy12345.us-east-1 or myorg-myaccount",
            required: true,
            section: .authentication
        ),
        ConnectionField(
            id: "snowflakeAuthMethod",
            label: String(localized: "Auth Method"),
            defaultValue: "password",
            fieldType: .dropdown(options: [
                .init(value: "password", label: "Username & Password"),
                .init(value: "keyPair", label: "Key Pair (.p8)"),
                .init(value: "externalBrowser", label: "Single Sign-On (Browser)"),
                .init(value: "oauth", label: "OAuth Token")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "snowflakeUser",
            label: String(localized: "Username"),
            placeholder: "JANE_DOE",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(
                fieldId: "snowflakeAuthMethod",
                values: ["password", "keyPair", "externalBrowser"]
            )
        ),
        ConnectionField(
            id: "snowflakePassword",
            label: String(localized: "Password"),
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "snowflakeAuthMethod", values: ["password"])
        ),
        ConnectionField(
            id: "snowflakeMFAPasscode",
            label: String(localized: "MFA Passcode (TOTP)"),
            placeholder: "Current code from your authenticator, if MFA is enforced",
            fieldType: .secure,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "snowflakeAuthMethod", values: ["password"])
        ),
        ConnectionField(
            id: "snowflakePrivateKeyPath",
            label: String(localized: "Private Key File"),
            placeholder: "~/.snowflake/rsa_key.p8",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "snowflakeAuthMethod", values: ["keyPair"])
        ),
        ConnectionField(
            id: "snowflakePrivateKeyPassphrase",
            label: String(localized: "Private Key Passphrase"),
            placeholder: "Optional",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "snowflakeAuthMethod", values: ["keyPair"])
        ),
        ConnectionField(
            id: "snowflakeOAuthToken",
            label: String(localized: "OAuth Token"),
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "snowflakeAuthMethod", values: ["oauth"])
        ),
        ConnectionField(
            id: "snowflakeWarehouse",
            label: String(localized: "Warehouse"),
            placeholder: "COMPUTE_WH",
            section: .authentication
        ),
        ConnectionField(
            id: "snowflakeSchema",
            label: String(localized: "Schema"),
            placeholder: "PUBLIC",
            section: .authentication
        ),
        ConnectionField(
            id: "snowflakeRole",
            label: String(localized: "Role"),
            placeholder: "Optional (e.g. SYSADMIN)",
            section: .advanced
        ),
        ConnectionField(
            id: "snowflakeConnectionName",
            label: String(localized: "CLI Connection Name"),
            placeholder: "Optional: name in ~/.snowflake/connections.toml",
            section: .advanced
        )
    ]
}
