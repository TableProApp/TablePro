//
//  PluginMetadataRegistry+CuratedDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLVocabulary
import TableProUtilities

/// What the app knows about a database type before its plugin loads.
///
/// The primary type ids here are overwritten by `buildMetadataSnapshot` the moment the plugin
/// registers, so these are the pre-load answer for those, apart from an explain list the plugin
/// leaves empty, which keeps the one here. For a variant id they are the whole
/// answer: `registerVariant` keeps the curated entry and ignores the plugin's own statics, which
/// is the only reason MariaDB, TiDB, Databend, OceanBase, Redshift, CockroachDB and PGlite can differ from
/// the plugin that drives them.
extension PluginMetadataRegistry {
    /// SQLite's own extensions. libSQL and Turso name a new local file with them too, since the file
    /// their driver creates is a SQLite database.
    static let sqliteFileExtensions = ["db", "db3", "s3db", "sl3", "sqlite", "sqlite3", "sqlitedb"]

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
            functions: SQLEngineVocabulary.mySQL.functions,
            dataTypes: SQLEngineVocabulary.mySQL.dataTypes,
            tableOptions: SQLEngineVocabulary.mySQL.tableOptions,
            regexSyntax: .regexp,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .implicit,
            paginationStyle: .limit,
            requiresBackslashEscaping: true,
            caseSensitivityStyle: .collationDefined,
            operators: SQLEngineVocabulary.mySQL.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
            textCastTypeName: nil,
            functionNamesAreCaseInsensitive: SQLEngineVocabulary.mySQL.functionNamesAreCaseInsensitive,
            typeNamesAreCaseInsensitive: true
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
            functions: SQLEngineVocabulary.postgreSQL.functions,
            dataTypes: SQLEngineVocabulary.postgreSQL.dataTypes,
            tableOptions: SQLEngineVocabulary.postgreSQL.tableOptions,
            regexSyntax: .tilde,
            booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit,
            paginationStyle: .limit,
            caseSensitivityStyle: .ilikeOperator,
            operators: SQLEngineVocabulary.postgreSQL.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
            textCastTypeName: nil,
            functionNamesAreCaseInsensitive: SQLEngineVocabulary.postgreSQL.functionNamesAreCaseInsensitive,
            typeNamesAreCaseInsensitive: true
        )

        // Redshift ILIKE only folds ASCII, so it uses LOWER on both sides instead.
        let redshiftDialect = postgresqlDialect
            .withVocabulary(.redshift)
            .withCaseSensitivityStyle(.caseFoldFunction)

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
            functions: SQLEngineVocabulary.sqlite.functions,
            dataTypes: SQLEngineVocabulary.sqlite.dataTypes,
            tableOptions: SQLEngineVocabulary.sqlite.tableOptions,
            regexSyntax: .unsupported,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .explicit,
            paginationStyle: .limit,
            caseSensitivityStyle: .collationDefined,
            operators: SQLEngineVocabulary.sqlite.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
            textCastTypeName: nil,
            functionNamesAreCaseInsensitive: SQLEngineVocabulary.sqlite.functionNamesAreCaseInsensitive,
            typeNamesAreCaseInsensitive: true
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
            label: String(localized: "Use ~/.pgpass"),
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

        // Connector/C's GSSAPI plugin signs in to MariaDB only, so MySQL gets no Kerberos.
        let mariadbAuthFields = KerberosAuthFields.standardWithAWS() + [AWSAuthFields.rdsEndpointField()]

        let redshiftIAMFields = AWSAuthFields.standard() + [
            ConnectionField(
                id: RedshiftIAMSignIn.endpointFieldId,
                label: String(localized: "Redshift Endpoint"),
                placeholder: "my-cluster.abc123.us-east-1.redshift.amazonaws.com",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: ["accessKey", "profile", "sso"])
            )
        ]

        /// Cloud SQL signs IAM principals in to MySQL and PostgreSQL only, so SQL Server and the
        /// MySQL and PostgreSQL forks keep the AWS-only picker.
        let cloudIAMFields = GoogleCloudSQLAuthFields.standardWithAWS() + [AWSAuthFields.rdsEndpointField()]

        let postgresqlAuthFields = KerberosAuthFields.standardWithAWSAndGoogleCloud() + [
            KerberosAuthFields.gssEncryptionField(),
            AWSAuthFields.rdsEndpointField()
        ]

        /// The MySQL plugin's types only. PostgreSQL shares the IAM fields and must not pick this up:
        /// its driver holds no releasable resource, so the setting would do nothing.
        let mysqlIdleReleaseField = ConnectionField(
            id: "mysqlIdleReleaseMinutes",
            label: String(localized: "Release the Server Connection After (minutes, 0 to keep it)"),
            defaultValue: "0",
            fieldType: .stepper(range: ConnectionField.IntRange(0...240)),
            section: .advanced
        )

        let mysqlEncodingField = ConnectionField(
            id: "mysqlConnectionEncoding",
            label: String(localized: "Encoding"),
            fieldType: .dropdown(options: [
                .init(value: "", label: "UTF-8"),
                .init(value: "utf8ViaLatin1", label: String(localized: "UTF-8 via Latin 1"))
            ]),
            section: .advanced
        )

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
                structureEditing: SchemaEditingSupport(columnReorder: .alter, foreignKeyEdit: .alter),
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
                    defaultSSLMode: .preferred,
                    browsingRequiresSelectedDatabase: true,
                    binaryLengthFunction: "OCTET_LENGTH"
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "information_schema", "mysql", "performance_schema", "sys",
                        "INFORMATION_SCHEMA", "PERFORMANCE_SCHEMA"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .onUpdate, .autoIncrement, .comment, .charset, .collation
                    ],
                    rowMatchTextTypePrefixes: mysqlRowMatchTextTypePrefixes
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mysqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mysqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: cloudIAMFields + [mysqlIdleReleaseField, mysqlEncodingField],
                    category: .relational,
                    tagline: String(localized: "Most popular open-source SQL database"),
                    defaultUnixSocketPath: "/var/run/mysqld/mysqld.sock",
                    defaultLocalSocketPath: MySQLLocalSocket.defaultPath
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
                structureEditing: SchemaEditingSupport(columnReorder: .alter, foreignKeyEdit: .alter),
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
                    defaultSSLMode: .preferred,
                    browsingRequiresSelectedDatabase: true,
                    binaryLengthFunction: "OCTET_LENGTH"
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "information_schema", "mysql", "performance_schema", "sys",
                        "INFORMATION_SCHEMA", "PERFORMANCE_SCHEMA"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .onUpdate, .autoIncrement, .comment, .charset, .collation
                    ],
                    rowMatchTextTypePrefixes: mysqlRowMatchTextTypePrefixes
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mysqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mysqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: mariadbAuthFields + [mysqlIdleReleaseField, mysqlEncodingField],
                    category: .relational,
                    tagline: String(localized: "Open-source fork of MySQL"),
                    defaultUnixSocketPath: "/var/run/mysqld/mysqld.sock",
                    defaultLocalSocketPath: MySQLLocalSocket.defaultPath
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
                structureEditing: SchemaEditingSupport(
                    columnReorder: .rebuild, foreignKeyEdit: .alter, structureEdits: .postgreSQL
                ),
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
                    supportsCreateSchema: true,
                    supportsSchemaOwner: true,
                    supportsSchemaPrivileges: true,
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
                    systemSchemaNames: ["pg_catalog", "information_schema", "pg_toast"],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .autoIncrement, .comment
                    ],
                    identifierRules: .postgreSQL
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: postgresqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: postgresqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [pgpassField, connectionOptionsField] + postgresqlAuthFields,
                    category: .relational,
                    tagline: String(localized: "Advanced object-relational SQL"),
                    defaultUnixSocketPath: "/var/run/postgresql/.s.PGSQL.5432",
                    defaultLocalSocketPath: PostgreSQLLocalSocket.defaultDirectory
                )
            )),
            ("Redshift", PluginMetadataSnapshot(
                displayName: "Redshift", iconName: "redshift-icon", defaultPort: 5_439,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: false,
                isDownloadable: false, primaryUrlScheme: "redshift", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: redshiftExplainVariants, pathFieldRole: .database,
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
                    supportsCreateSchema: true,
                    supportsSchemaOwner: true,
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
                    systemSchemaNames: ["pg_catalog", "information_schema", "pg_toast"],
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
                    additionalConnectionFields: [pgpassField, connectionOptionsField] + redshiftIAMFields,
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
                    supportsCreateSchema: true,
                    supportsSchemaOwner: true,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsCheckConstraints: true,
                    supportsCheckConstraintEditing: false,
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
                    systemSchemaNames: ["pg_catalog", "information_schema", "pg_toast"],
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
                structureEditing: SchemaEditingSupport(
                    columnReorder: .rebuild, foreignKeyEdit: .alter, structureEdits: .postgreSQL
                ),
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
                    supportsCreateSchema: true,
                    supportsSchemaOwner: true,
                    supportsSchemaPrivileges: true,
                    supportsRenameColumn: true,
                    supportsTriggers: true,
                    supportsTriggerEditing: true,
                    supportsCheckConstraints: true,
                    supportsCheckConstraintEditing: true,
                    supportsGeneratedColumns: true,
                    supportsUserDefinedTypeBrowse: true,
                    defaultSSLMode: .disabled,
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
                    systemSchemaNames: ["pg_catalog", "information_schema", "pg_toast"],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [
                        .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                        .autoIncrement, .comment
                    ],
                    identifierRules: .postgreSQL
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
                structureEditing: SchemaEditingSupport(columnReorder: .rebuild, foreignKeyEdit: .rebuild),
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
                    localFilePathField: .database,
                    newDatabaseFileExtensions: Self.sqliteFileExtensions,
                    supportsRemoteDatabaseFile: true,
                    supportsRemoteDatabaseSession: true
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
                    fileExtensions: Self.sqliteFileExtensions,
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
                    additionalConnectionFields: [.attachedDatabases(), .loadableExtensions()],
                    category: .relational,
                    tagline: String(localized: "Embedded zero-config SQL database")
                )
            ))
        ]
        return defaults + mysqlVariantDefaults(
            dialect: mysqlDialect, mysqlColumnTypes: mysqlColumnTypes, idleReleaseField: mysqlIdleReleaseField
        ) + defaults.filter { $0.typeId == "PostgreSQL" }.flatMap { kingbaseESDefaults(postgreSQL: $0.snapshot) }
    }
}

extension SQLOperatorDescriptor {
    init?(vocabulary entry: SQLEngineVocabulary.Operator) {
        guard let category = Category(rawValue: entry.category),
              let placement = Placement(rawValue: entry.placement) else { return nil }
        self.init(
            symbol: entry.symbol,
            summary: entry.summary,
            category: category,
            placement: placement,
            appliesToTypes: entry.appliesToTypes
        )
    }
}

private extension SQLDialectDescriptor {
    func withVocabulary(_ vocabulary: SQLEngineVocabulary) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: identifierQuote,
            keywords: keywords,
            functions: vocabulary.functions,
            dataTypes: vocabulary.dataTypes,
            tableOptions: vocabulary.tableOptions,
            regexSyntax: regexSyntax,
            booleanLiteralStyle: booleanLiteralStyle,
            likeEscapeStyle: likeEscapeStyle,
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: offsetFetchOrderBy,
            requiresBackslashEscaping: requiresBackslashEscaping,
            autoLimitStyle: autoLimitStyle,
            caseSensitivityStyle: caseSensitivityStyle,
            caseFoldFunction: caseFoldFunction,
            operators: vocabulary.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
            textCastTypeName: textCastTypeName,
            functionNamesAreCaseInsensitive: vocabulary.functionNamesAreCaseInsensitive,
            lexicalFeatures: lexicalFeatures,
            typeNamesAreCaseInsensitive: typeNamesAreCaseInsensitive
        )
    }
}
