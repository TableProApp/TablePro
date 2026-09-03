//
//  PluginMetadataRegistry+CuratedDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the app knows about a database type before its plugin loads.
///
/// The primary type ids here are overwritten by `buildMetadataSnapshot` the moment the plugin
/// registers, so these are the pre-load answer for those. For a variant id they are the whole
/// answer: `registerVariant` keeps the curated entry and ignores the plugin's own statics, which
/// is the only reason MariaDB, Redshift, CockroachDB and PGlite can differ from the plugin that
/// drives them.
extension PluginMetadataRegistry {
    // swiftlint:disable:next function_body_length
    static func curatedDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        let mysqlDialect = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: [
                "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
                "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS", "ALIAS",
                "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
                "ADD", "MODIFY", "CHANGE", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
                "CASE", "WHEN", "THEN", "ELSE", "END", "IF", "IFNULL", "COALESCE",
                "UNION", "INTERSECT", "EXCEPT",
                "FORCE", "USE", "IGNORE", "STRAIGHT_JOIN", "DUAL",
                "SHOW", "DESCRIBE", "EXPLAIN"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT",
                "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
                "TRIM", "LTRIM", "RTRIM", "REPLACE",
                "NOW", "CURDATE", "CURTIME", "DATE", "TIME", "YEAR", "MONTH", "DAY",
                "DATE_ADD", "DATE_SUB", "DATEDIFF", "TIMESTAMPDIFF",
                "ROUND", "CEIL", "FLOOR", "ABS", "MOD", "POW", "SQRT",
                "CAST", "CONVERT"
            ],
            dataTypes: [
                "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
                "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
                "CHAR", "VARCHAR", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT",
                "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB",
                "DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR",
                "ENUM", "SET", "JSON", "BOOL", "BOOLEAN"
            ],
            tableOptions: [
                "ENGINE=InnoDB", "DEFAULT CHARSET=utf8mb4", "COLLATE=utf8mb4_unicode_ci",
                "AUTO_INCREMENT=", "COMMENT=", "ROW_FORMAT="
            ],
            regexSyntax: .regexp,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .implicit,
            paginationStyle: .limit,
            requiresBackslashEscaping: true,
            caseSensitivityStyle: .collationDefined
        )

        let mysqlColumnTypes: [String: [String]] = [
            "Integer": ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT"],
            "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL"],
            "String": ["CHAR", "VARCHAR", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "ENUM", "SET"],
            "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR"],
            "Binary": ["BINARY", "VARBINARY", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB", "BIT"],
            "Boolean": ["BOOLEAN", "BOOL"],
            "JSON": ["JSON"],
            "Spatial": ["GEOMETRY", "POINT", "LINESTRING", "POLYGON"]
        ]

        let postgresqlDialect = SQLDialectDescriptor(
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
            paginationStyle: .limit,
            caseSensitivityStyle: .ilikeOperator
        )

        // Redshift ILIKE only folds ASCII, so it uses LOWER on both sides instead.
        let redshiftDialect = postgresqlDialect.withCaseSensitivityStyle(.caseFoldFunction)

        let postgresqlColumnTypes: [String: [String]] = [
            "Integer": ["SMALLINT", "INTEGER", "BIGINT", "SERIAL", "BIGSERIAL", "SMALLSERIAL"],
            "Float": ["REAL", "DOUBLE PRECISION", "NUMERIC", "DECIMAL", "MONEY"],
            "String": ["CHARACTER VARYING", "VARCHAR", "CHARACTER", "CHAR", "TEXT", "NAME"],
            "Date": [
                "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL",
                "TIME WITH TIME ZONE", "TIMESTAMP WITH TIME ZONE"
            ],
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

        let sqliteDialect = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: [
                "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
                "ON", "AND", "OR", "NOT", "IN", "LIKE", "GLOB", "BETWEEN", "AS",
                "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "TRIGGER",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
                "ADD", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL",
                "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "IFNULL", "NULLIF",
                "UNION", "INTERSECT", "EXCEPT",
                "AUTOINCREMENT", "WITHOUT", "ROWID", "PRAGMA",
                "REPLACE", "ABORT", "FAIL", "IGNORE", "ROLLBACK",
                "TEMP", "TEMPORARY", "VACUUM", "EXPLAIN", "QUERY", "PLAN"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT", "TOTAL",
                "LENGTH", "SUBSTR", "SUBSTRING", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
                "REPLACE", "INSTR", "PRINTF",
                "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME",
                "ABS", "ROUND", "RANDOM",
                "CAST", "TYPEOF",
                "COALESCE", "IFNULL", "NULLIF", "HEX", "QUOTE"
            ],
            dataTypes: [
                "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC",
                "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
                "UNSIGNED", "BIG", "INT2", "INT8",
                "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NATIVE",
                "NVARCHAR", "CLOB",
                "DOUBLE", "PRECISION", "FLOAT",
                "DECIMAL", "BOOLEAN", "DATE", "DATETIME"
            ],
            tableOptions: [
                "WITHOUT ROWID", "STRICT"
            ],
            regexSyntax: .unsupported,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .explicit,
            paginationStyle: .limit,
            caseSensitivityStyle: .collationDefined
        )

        let sqliteColumnTypes: [String: [String]] = [
            "Integer": ["INTEGER", "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT"],
            "Float": ["REAL", "DOUBLE", "FLOAT", "NUMERIC", "DECIMAL"],
            "String": ["TEXT", "VARCHAR", "CHARACTER", "CHAR", "CLOB", "NVARCHAR", "NCHAR"],
            "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
            "Binary": ["BLOB"],
            "Boolean": ["BOOLEAN"]
        ]

        let pgpassField = ConnectionField(
            id: "usePgpass",
            label: String(localized: "Use Password File"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .authentication,
            hidesPassword: true
        )

        let connectionOptionsField = ConnectionField(
            id: "connectionOptions",
            label: String(localized: "Connection Options"),
            placeholder: "--cluster=my-cluster",
            fieldType: .text,
            section: .advanced
        )

        let awsIAMFields = AWSAuthFields.standard() + [AWSAuthFields.rdsEndpointField()]

        let defaults: [(typeId: String, snapshot: PluginMetadataSnapshot)] = [
            ("MySQL", PluginMetadataSnapshot(
                displayName: "MySQL", iconName: "mysql-icon", defaultPort: 3_306,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: false, primaryUrlScheme: "mysql", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["mysql"], postConnectActions: [.selectDatabaseFromLastSession],
                brandColorHex: "#FF9500",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                columnReorder: .alter,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameDatabase: false,
                    supportsRenameSchema: false,
                    supportsRenameColumn: true,
                    supportsTriggers: true,
                    supportsTriggerEditing: true,
                    supportsCheckConstraints: true,
                    supportsCheckConstraintEditing: true,
                    supportsGeneratedColumns: true,
                    supportsRoutines: true,
                    supportsDatabaseTriggerBrowse: true,
                    defaultSSLMode: .preferred
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "mysql", "performance_schema", "sys"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .onUpdate, .autoIncrement, .comment, .charset, .collation
                    ]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mysqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mysqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: awsIAMFields,
                    category: .relational,
                    tagline: String(localized: "Most popular open-source SQL database"),
                    defaultUnixSocketPath: "/var/run/mysqld/mysqld.sock"
                )
            )),
            ("MariaDB", PluginMetadataSnapshot(
                displayName: "MariaDB", iconName: "mariadb-icon", defaultPort: 3_306,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: false, primaryUrlScheme: "mariadb", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["mariadb"], postConnectActions: [.selectDatabaseFromLastSession],
                brandColorHex: "#00B4D8",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                columnReorder: .alter,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameDatabase: false,
                    supportsRenameSchema: false,
                    supportsRenameColumn: true,
                    supportsTriggers: true,
                    supportsTriggerEditing: true,
                    supportsCheckConstraints: true,
                    supportsCheckConstraintEditing: true,
                    supportsGeneratedColumns: true,
                    supportsRoutines: true,
                    supportsDatabaseTriggerBrowse: true,
                    defaultSSLMode: .preferred
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "mysql", "performance_schema", "sys"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .onUpdate, .autoIncrement, .comment, .charset, .collation
                    ]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mysqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mysqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: awsIAMFields,
                    category: .relational,
                    tagline: String(localized: "Open-source fork of MySQL"),
                    defaultUnixSocketPath: "/var/run/mysqld/mysqld.sock"
                )
            )),
            ("PostgreSQL", PluginMetadataSnapshot(
                displayName: "PostgreSQL", iconName: "postgresql-icon", defaultPort: 5_432,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: false, primaryUrlScheme: "postgresql", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["postgresql", "postgres"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#336791",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                columnReorder: .rebuild,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: true,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: true,
                    supportsDropDatabase: true,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameDatabase: true,
                    supportsRenameSchema: true,
                    supportsDropSchema: true,
                    supportsRenameColumn: true,
                    supportsTriggers: true,
                    supportsTriggerEditing: true,
                    supportsCheckConstraints: true,
                    supportsCheckConstraintEditing: true,
                    supportsGeneratedColumns: true,
                    supportsRoutines: true,
                    supportsDatabaseTriggerBrowse: true,
                    supportsUserDefinedTypeBrowse: true,
                    defaultSSLMode: .preferred
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .autoIncrement, .comment
                    ]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: postgresqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: postgresqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [pgpassField, connectionOptionsField] + awsIAMFields,
                    category: .relational,
                    tagline: String(localized: "Advanced object-relational SQL"),
                    defaultUnixSocketPath: "/var/run/postgresql/.s.PGSQL.5432"
                )
            )),
            ("Redshift", PluginMetadataSnapshot(
                displayName: "Redshift", iconName: "redshift-icon", defaultPort: 5_439,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: false,
                isDownloadable: false, primaryUrlScheme: "redshift", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["redshift"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#205B8E",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: true,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: true,
                    supportsDropDatabase: true,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameDatabase: true,
                    supportsRenameSchema: true,
                    supportsDropSchema: true,
                    defaultSSLMode: .preferred
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["padb_harvest"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: redshiftDialect,
                    statementCompletions: [],
                    columnTypesByCategory: postgresqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [pgpassField, connectionOptionsField],
                    category: .analytical,
                    tagline: String(localized: "Amazon's columnar warehouse on Postgres")
                )
            )),
            ("CockroachDB", PluginMetadataSnapshot(
                displayName: "CockroachDB", iconName: "cockroachdb-icon", defaultPort: 26_257,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: false,
                isDownloadable: false, primaryUrlScheme: "cockroachdb", parameterStyle: .dollar,
                navigationModel: .standard,
                explainVariants: [
                    ExplainVariant(
                        id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .cockroachText
                    ),
                    ExplainVariant(
                        id: "analyze",
                        label: "EXPLAIN ANALYZE",
                        sqlPrefix: "EXPLAIN ANALYZE",
                        format: .cockroachText
                    ),
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["cockroachdb", "cockroach"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#6933FF",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: true,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: true,
                    supportsDropDatabase: true,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameDatabase: true,
                    supportsRenameSchema: true,
                    supportsDropSchema: true,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsCheckConstraints: true,
                    supportsCheckConstraintEditing: true,
                    supportsGeneratedColumns: true,
                    defaultSSLMode: .preferred
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["system"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .autoIncrement, .comment
                    ]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: postgresqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: postgresqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [pgpassField, connectionOptionsField],
                    category: .relational,
                    tagline: String(localized: "Distributed SQL, PostgreSQL-compatible")
                )
            )),
            ("PGlite", PluginMetadataSnapshot(
                displayName: "PGlite", iconName: "postgresql-icon", defaultPort: 5_432,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: false, primaryUrlScheme: "pglite", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["pglite"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#F4B942",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
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
                    requiresReconnectForDatabaseSwitch: true,
                    supportsDropDatabase: true,
                    supportsRenameTable: true,
                    supportsRenameView: true,
                    supportsRenameDatabase: false,
                    supportsRenameSchema: true,
                    supportsDropSchema: true,
                    supportsRenameColumn: true,
                    supportsTriggers: true,
                    supportsTriggerEditing: true,
                    supportsCheckConstraints: true,
                    supportsCheckConstraintEditing: true,
                    supportsGeneratedColumns: true,
                    supportsUserDefinedTypeBrowse: true,
                    defaultSSLMode: .disabled,
                    supportsCloudflareTunnel: false,
                    supportsConnectionPooling: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .autoIncrement, .comment
                    ]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: postgresqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: postgresqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [],
                    category: .relational,
                    tagline: String(localized: "Embedded WASM Postgres over a socket server"),
                    hidesBuiltInPassword: true,
                    defaultHost: "127.0.0.1"
                )
            )),
            ("SQLite", PluginMetadataSnapshot(
                displayName: "SQLite", iconName: "sqlite-icon", defaultPort: 0,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: false, primaryUrlScheme: "sqlite", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .filePath,
                supportsHealthMonitor: false, urlSchemes: ["sqlite"], postConnectActions: [],
                brandColorHex: "#003B57",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .fileBased, supportsDatabaseSwitching: false,
                columnReorder: .rebuild,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameTable: true,
                    supportsRenameView: false,
                    supportsRenameDatabase: false,
                    supportsRenameSchema: false,
                    supportsModifyColumn: false,
                    supportsRenameColumn: true,
                    supportsModifyPrimaryKey: false,
                    supportsTriggers: true,
                    supportsTriggerEditing: true,
                    supportsCheckConstraints: true,
                    supportsGeneratedColumns: true,
                    supportsDatabaseTriggerBrowse: true,
                    supportsCloudflareTunnel: false,
                    localFilePathField: .database,
                    supportsRemoteDatabaseFile: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: ["db", "db3", "s3db", "sl3", "sqlite", "sqlite3", "sqlitedb"],
                    fileSignatures: [.magic("SQLite format 3\u{0}")],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .autoIncrement, .comment
                    ]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: sqliteDialect,
                    statementCompletions: [],
                    columnTypesByCategory: sqliteColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    category: .relational,
                    tagline: String(localized: "Embedded zero-config SQL database")
                )
            ))
        ]
        return defaults
    }
}
