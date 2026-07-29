//
//  SnowflakePlugin.swift
//  SnowflakeDriverPlugin
//
//  Snowflake driver plugin via the Snowflake connector REST protocol.
//  Supports password, key-pair (.p8), external browser SSO, and OAuth token
//  authentication, plus ~/.snowflake/connections.toml integration.
//

import Foundation
import os
import TableProPluginKit

final class SnowflakePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Snowflake Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Snowflake cloud data warehouse support via the connector REST protocol"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Snowflake"
    static let databaseDisplayName = "Snowflake"
    static let iconName = "snowflake-icon"
    static let defaultPort = 443
    static let systemDatabaseNames: [String] = ["SNOWFLAKE", "SNOWFLAKE_SAMPLE_DATA"]
    static let systemSchemaNames: [String] = ["INFORMATION_SCHEMA"]
    static let isDownloadable = true
    static let defaultSchemaName = "PUBLIC"

    static let connectionMode: ConnectionMode = .apiOnly
    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = true
    static let urlSchemes: [String] = []
    static let brandColorHex = "#29B5E8"
    static let queryLanguageName = "SQL"
    static let editorLanguage: EditorLanguage = .sql
    static let supportsForeignKeys = true
    static let supportsSchemaEditing = true
    static let supportsAddColumn = true
    static let supportsModifyColumn = true
    static let supportsDropColumn = true
    static let supportsRenameColumn = true
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = true
    static let supportsHealthMonitor = false
    static let supportsDatabaseSwitching = true
    static let supportsSchemaSwitching = true
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let supportsImport = true
    static let supportsExport = true
    static let supportsSSH = false
    static let supportsSSL = false
    static let tableEntityName = "Tables"
    static let supportsForeignKeyDisable = false
    static let supportsReadOnlyMode = true
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let defaultGroupName = "default"
    static let defaultPrimaryKeyColumn: String? = nil
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue, .comment]
    static let supportsCascadeDrop = true
    static let supportsDropDatabase = true

    static let additionalConnectionFields: [ConnectionField] = [
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

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
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
    )

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "text", label: "Explain (Text)", sqlPrefix: "EXPLAIN USING TEXT")
    ]

    static let columnTypesByCategory: [String: [String]] = [
        "Number": ["NUMBER", "DECIMAL", "INT", "INTEGER", "BIGINT", "SMALLINT", "FLOAT", "DOUBLE", "REAL"],
        "String": ["VARCHAR", "CHAR", "STRING", "TEXT"],
        "Binary": ["BINARY", "VARBINARY"],
        "Boolean": ["BOOLEAN"],
        "Date/Time": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMP_LTZ", "TIMESTAMP_NTZ", "TIMESTAMP_TZ"],
        "Semi-structured": ["VARIANT", "OBJECT", "ARRAY"],
        "Geospatial": ["GEOGRAPHY", "GEOMETRY"]
    ]

    static var statementCompletions: [CompletionEntry] {
        [
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
            CompletionEntry(label: "DECODE", insertText: "DECODE"),
            CompletionEntry(label: "CREATE TABLE", insertText: "CREATE TABLE")
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        SnowflakePluginDriver(config: config)
    }
}
