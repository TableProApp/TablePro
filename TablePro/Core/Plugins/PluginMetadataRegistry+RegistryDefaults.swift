//
//  PluginMetadataRegistry+RegistryDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    // swiftlint:disable function_body_length
    func registryPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        let (
            clickhouseDialect, clickhouseColumnTypes, mssqlDialect, mssqlColumnTypes,
            oracleDialect, oracleColumnTypes, duckdbDialect, duckdbColumnTypes,
            cassandraDialect, cassandraColumnTypes, mongoCompletions, mongoColumnTypes,
            etcdCompletions, redisCompletions, redisColumnTypes, d1Dialect, d1ColumnTypes
        ) = registryDefaultIngredients()

        return [
            ("MongoDB", PluginMetadataSnapshot(
                displayName: "MongoDB", iconName: "mongodb-icon", defaultPort: 27_017,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "mongodb", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["mongodb", "mongodb+srv"], postConnectActions: [],
                brandColorHex: "#00ED63",
                queryLanguageName: "MQL", editorLanguage: .javascript,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Collections",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: "_id",
                    immutableColumns: ["_id"],
                    systemDatabaseNames: ["admin", "local", "config"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: mongoCompletions,
                    columnTypesByCategory: mongoColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "mongoHosts",
                            label: "Hosts",
                            placeholder: "localhost:27017",
                            fieldType: .hostList,
                            section: .connection
                        ),
                        ConnectionField(
                            id: "mongoAuthSource", label: "Auth Database", placeholder: "admin"
                        ),
                        ConnectionField(
                            id: "mongoReadPreference",
                            label: "Read Preference",
                            fieldType: .dropdown(options: [
                                .init(value: "", label: "Default"),
                                .init(value: "primary", label: "Primary"),
                                .init(value: "primaryPreferred", label: "Primary Preferred"),
                                .init(value: "secondary", label: "Secondary"),
                                .init(value: "secondaryPreferred", label: "Secondary Preferred"),
                                .init(value: "nearest", label: "Nearest")
                            ])
                        ),
                        ConnectionField(
                            id: "mongoWriteConcern",
                            label: "Write Concern",
                            fieldType: .dropdown(options: [
                                .init(value: "", label: "Default"),
                                .init(value: "majority", label: "Majority"),
                                .init(value: "1", label: "1"),
                                .init(value: "2", label: "2"),
                                .init(value: "3", label: "3")
                            ])
                        )
                    ],
                    category: .document,
                    tagline: String(localized: "JSON-style document database")
                )
            )),
            ("Redis", PluginMetadataSnapshot(
                displayName: "Redis", iconName: "redis-icon", defaultPort: 6_379,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "redis", parameterStyle: .questionMark,
                navigationModel: .inPlace, explainVariants: [], pathFieldRole: .databaseIndex,
                supportsHealthMonitor: true, urlSchemes: ["redis", "rediss"],
                postConnectActions: [.selectDatabaseFromConnectionField(fieldId: "redisDatabase")],
                brandColorHex: "#DC382D",
                queryLanguageName: "Redis CLI", editorLanguage: .bash,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "db0",
                    tableEntityName: "Keys",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: "Key",
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: redisCompletions,
                    columnTypesByCategory: redisColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "redisDatabase",
                            label: String(localized: "Database Index"),
                            defaultValue: "0",
                            fieldType: .stepper(range: ConnectionField.IntRange(0...15))
                        )
                    ],
                    category: .keyValue,
                    tagline: String(localized: "In-memory data store and cache")
                )
            )),
            ("SQL Server", PluginMetadataSnapshot(
                displayName: "SQL Server", iconName: "mssql-icon", defaultPort: 1_433,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "sqlserver", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["sqlserver", "mssql"],
                postConnectActions: [.selectDatabaseFromLastSession, .selectSchemaFromLastSession],
                brandColorHex: "#E34517",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
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
                    supportsRenameColumn: true,
                    defaultSSLMode: .preferred
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "dbo",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["master", "tempdb", "model", "msdb"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mssqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mssqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "mssqlAuthMethod",
                            label: String(localized: "Authentication"),
                            defaultValue: "sql",
                            fieldType: .dropdown(options: [
                                .init(value: "sql", label: "SQL Server Authentication"),
                                .init(value: "windows", label: "Windows Authentication (Kerberos)")
                            ]),
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "mssqlKerberosPrincipal",
                            label: String(localized: "Kerberos Principal"),
                            placeholder: "user@REALM.COM",
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "mssqlAuthMethod", values: ["windows"])
                        ).withHidesUsername(true),
                        ConnectionField(
                            id: "mssqlKerberosPassword",
                            label: String(localized: "Password"),
                            fieldType: .secure,
                            section: .authentication,
                            hidesPassword: true,
                            visibleWhen: FieldVisibilityRule(fieldId: "mssqlAuthMethod", values: ["windows"])
                        ),
                        ConnectionField(
                            id: "mssqlSchema", label: "Schema", placeholder: "dbo", defaultValue: "dbo"
                        )
                    ],
                    category: .relational,
                    tagline: String(localized: "Microsoft's enterprise SQL database")
                )
            )),
            ("Teradata", PluginMetadataSnapshot(
                displayName: "Teradata", iconName: "teradata-icon", defaultPort: 1_025,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "teradata", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: false, urlSchemes: ["teradata"],
                postConnectActions: [.selectDatabaseFromLastSession],
                brandColorHex: "#F37440",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameColumn: false,
                    defaultSSLMode: .disabled
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["DBC", "Sys", "SysAdmin", "SystemFe", "SYSLIB", "SYSUDTLIB", "TDStats", "PUBLIC", "All", "Default"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: SQLDialectDescriptor(
                        identifierQuote: "\"",
                        keywords: [
                            "SELECT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "ORDER", "TOP", "QUALIFY",
                            "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "ON", "AND", "OR", "NOT",
                            "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "VIEW",
                            "DATABASE", "USER", "MACRO", "VOLATILE", "MULTISET", "SET", "AS", "SAMPLE",
                            "HELP", "SHOW", "EXPLAIN", "COLLECT", "STATISTICS", "LOCKING", "FOR", "ACCESS",
                        ],
                        functions: [
                            "COUNT", "SUM", "AVG", "MIN", "MAX", "CAST", "TRIM", "SUBSTRING",
                            "COALESCE", "NULLIFZERO", "ZEROIFNULL", "OREPLACE", "OTRANSLATE",
                            "CURRENT_DATE", "CURRENT_TIMESTAMP", "EXTRACT", "ADD_MONTHS",
                        ],
                        dataTypes: [
                            "BYTEINT", "SMALLINT", "INTEGER", "BIGINT", "DECIMAL", "NUMBER", "FLOAT",
                            "CHAR", "VARCHAR", "CLOB", "BYTE", "VARBYTE", "BLOB",
                            "DATE", "TIME", "TIMESTAMP", "INTERVAL", "PERIOD", "JSON", "XML",
                        ],
                        autoLimitStyle: .top
                    ),
                    statementCompletions: [],
                    columnTypesByCategory: [
                        "Integer": ["BYTEINT", "SMALLINT", "INTEGER", "BIGINT"],
                        "Float": ["FLOAT", "DECIMAL", "NUMBER"],
                        "String": ["CHAR", "VARCHAR", "CLOB"],
                        "Date": ["DATE", "TIME", "TIMESTAMP"],
                        "Binary": ["BYTE", "VARBYTE", "BLOB"],
                    ]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "teradataLogMech", label: "Logon Mechanism", placeholder: "TD2", defaultValue: "TD2"),
                        ConnectionField(
                            id: "teradataTMode", label: "Transaction Mode", placeholder: "DEFAULT", defaultValue: "DEFAULT"),
                    ],
                    category: .relational,
                    tagline: String(localized: "Teradata Vantage data warehouse")
                )
            )),
            ("Oracle", PluginMetadataSnapshot(
                displayName: "Oracle", iconName: "oracle-icon", defaultPort: 1_521,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "oracle", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .serviceName,
                supportsHealthMonitor: true, urlSchemes: ["oracle"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#C3160B",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameColumn: true,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Schema",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "SYS", "SYSTEM", "OUTLN", "DBSNMP", "APPQOSSYS", "WMSYS", "XDB"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .hierarchicalSchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: oracleDialect,
                    statementCompletions: [],
                    columnTypesByCategory: oracleColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "oracleServiceName", label: "Service Name", placeholder: "ORCL"
                        )
                    ],
                    category: .relational,
                    tagline: String(localized: "Enterprise SQL with PL/SQL")
                )
            )),
            ("ClickHouse", PluginMetadataSnapshot(
                displayName: "ClickHouse", iconName: "clickhouse-icon", defaultPort: 8_123,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "clickhouse", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN"),
                    ExplainVariant(id: "pipeline", label: "Pipeline", sqlPrefix: "EXPLAIN PIPELINE"),
                    ExplainVariant(id: "ast", label: "AST", sqlPrefix: "EXPLAIN AST"),
                    ExplainVariant(id: "syntax", label: "Syntax", sqlPrefix: "EXPLAIN SYNTAX"),
                    ExplainVariant(id: "estimate", label: "Estimate", sqlPrefix: "EXPLAIN ESTIMATE")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["clickhouse", "ch"], postConnectActions: [.selectDatabaseFromLastSession],
                brandColorHex: "#FFD100",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: true,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "INFORMATION_SCHEMA", "system"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: clickhouseDialect,
                    statementCompletions: [],
                    columnTypesByCategory: clickhouseColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    category: .analytical,
                    tagline: String(localized: "Column-oriented OLAP for big data")
                )
            )),
            ("DuckDB", PluginMetadataSnapshot(
                displayName: "DuckDB", iconName: "duckdb-icon", defaultPort: 9_494,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "duckdb", parameterStyle: .dollar,
                navigationModel: .standard,
                explainVariants: [
                    ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN"),
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: false, urlSchemes: ["duckdb", "quack"], postConnectActions: [],
                brandColorHex: "#FFD900",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
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
                    supportsRenameColumn: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "pg_catalog"],
                    systemSchemaNames: [],
                    fileExtensions: ["duckdb", "ddb"],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: duckdbDialect,
                    statementCompletions: [],
                    columnTypesByCategory: duckdbColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: Self.duckdbConnectionFields,
                    category: .analytical,
                    tagline: String(localized: "Embedded and remote analytical SQL"),
                    hidesBuiltInPassword: true
                )
            )),
            ("Beancount", PluginMetadataSnapshot(
                displayName: "Beancount", iconName: "beancount-icon", defaultPort: 0,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "beancount", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .filePath,
                supportsHealthMonitor: false, urlSchemes: ["beancount"], postConnectActions: [],
                brandColorHex: "#3F7D20",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .fileBased, supportsDatabaseSwitching: false,
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
                    supportsDropDatabase: false,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Ledger Tables",
                    containerEntityName: "Ledger",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [
                        "id", "transaction_id", "date", "flag", "payee", "narration",
                        "account", "amount", "commodity", "cost_number", "cost_currency",
                        "currency", "currencies", "name", "open_date", "path"
                    ],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: ["beancount"],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: SQLDialectDescriptor(
                        identifierQuote: "\"",
                        keywords: [
                            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER",
                            "ON", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
                            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
                            "WITH", "UNION", "INTERSECT", "EXCEPT",
                            "CASE", "WHEN", "THEN", "ELSE", "END", "NULL", "IS",
                            "ASC", "DESC", "DISTINCT"
                        ],
                        functions: ["COUNT", "SUM", "AVG", "MAX", "MIN", "ROUND", "DATE", "STRFTIME"],
                        dataTypes: ["INTEGER", "TEXT", "DATE", "DECIMAL"],
                        regexSyntax: .unsupported,
                        booleanLiteralStyle: .numeric,
                        likeEscapeStyle: .explicit,
                        paginationStyle: .limit
                    ),
                    statementCompletions: [],
                    columnTypesByCategory: [
                        "Integer": ["INTEGER"],
                        "String": ["TEXT"],
                        "Date": ["DATE"],
                        "Decimal": ["DECIMAL"]
                    ]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    category: .analytical,
                    tagline: String(localized: "Plain-text accounting ledgers")
                )
            )),
            ("Cassandra", PluginMetadataSnapshot(
                displayName: "Cassandra / ScyllaDB", iconName: "cassandra-icon", defaultPort: 9_042,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "cassandra", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["cassandra", "cql", "scylladb", "scylla"],
                postConnectActions: [],
                brandColorHex: "#26A0D8",
                queryLanguageName: "CQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsModifyColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsClientKeyPassphrase: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    containerEntityName: "Keyspace",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "system", "system_schema", "system_auth",
                        "system_distributed", "system_traces", "system_virtual_schema"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: cassandraDialect,
                    statementCompletions: [],
                    columnTypesByCategory: cassandraColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "sslCaCertPath",
                            label: "CA Certificate",
                            placeholder: "/path/to/ca-cert.pem",
                            section: .advanced
                        )
                    ],
                    category: .wideColumn,
                    tagline: String(localized: "Distributed wide-column store")
                )
            )),
            ("ScyllaDB", PluginMetadataSnapshot(
                displayName: "ScyllaDB", iconName: "scylladb-icon", defaultPort: 9_042,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "scylladb", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["scylladb", "scylla"],
                postConnectActions: [],
                brandColorHex: "#6B2EE3",
                queryLanguageName: "CQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsModifyColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsClientKeyPassphrase: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    containerEntityName: "Keyspace",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "system", "system_schema", "system_auth",
                        "system_distributed", "system_traces", "system_virtual_schema"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: cassandraDialect,
                    statementCompletions: [],
                    columnTypesByCategory: cassandraColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "sslCaCertPath",
                            label: "CA Certificate",
                            placeholder: "/path/to/ca-cert.pem",
                            section: .advanced
                        )
                    ],
                    category: .wideColumn,
                    tagline: String(localized: "C++ rewrite of Cassandra, faster")
                )
            )),
            ("etcd", PluginMetadataSnapshot(
                displayName: "etcd", iconName: "etcd-icon", defaultPort: 2_379,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "etcd", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["etcd", "etcds"], postConnectActions: [],
                brandColorHex: "#419EDA",
                queryLanguageName: "etcdctl", editorLanguage: .bash,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Keys",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: "Key",
                    immutableColumns: ["Version", "ModRevision", "CreateRevision"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: etcdCompletions,
                    columnTypesByCategory: ["String": ["string"]]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "etcdKeyPrefix",
                            label: String(localized: "Key Prefix Root"),
                            placeholder: "/",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdTlsMode",
                            label: String(localized: "TLS Mode"),
                            fieldType: .dropdown(options: [
                                .init(value: "Disabled", label: "Disabled"),
                                .init(value: "Required", label: String(localized: "Required (skip verify)")),
                                .init(value: "VerifyCA", label: String(localized: "Verify CA")),
                                .init(value: "VerifyIdentity", label: String(localized: "Verify Identity")),
                            ]),
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdCaCertPath",
                            label: String(localized: "CA Certificate"),
                            placeholder: "/path/to/ca.pem",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdClientCertPath",
                            label: String(localized: "Client Certificate"),
                            placeholder: "/path/to/client.pem",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdClientKeyPath",
                            label: String(localized: "Client Key"),
                            placeholder: "/path/to/client-key.pem",
                            section: .advanced
                        ),
                    ],
                    category: .coordination,
                    tagline: String(localized: "Distributed key-value store for service discovery")
                )
            )),
            ("Cloudflare D1", PluginMetadataSnapshot(
                displayName: "Cloudflare D1", iconName: "cloudflare-d1-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "d1", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["d1"], postConnectActions: [],
                brandColorHex: "#F6821F",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "main",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: d1Dialect,
                    statementCompletions: [],
                    columnTypesByCategory: d1ColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "cfAccountId",
                            label: String(localized: "Account ID"),
                            placeholder: "Cloudflare Account ID",
                            required: true,
                            section: .authentication
                        )
                    ],
                    category: .cloud,
                    tagline: String(localized: "Serverless SQLite at the edge")
                )
            )),
            ("libSQL", PluginMetadataSnapshot(
                displayName: "libSQL / Turso", iconName: "libsql-icon", defaultPort: 0,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "libsql", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["libsql"], postConnectActions: [],
                brandColorHex: "#4FF8D2",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsModifyColumn: false,
                    supportsRenameColumn: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "main",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: d1Dialect,
                    statementCompletions: [],
                    columnTypesByCategory: d1ColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "libsqlMode",
                            label: String(localized: "Connection Mode"),
                            defaultValue: "remote",
                            fieldType: .dropdown(options: [
                                ConnectionField.DropdownOption(
                                    value: "remote",
                                    label: String(localized: "Remote (Turso)")
                                ),
                                ConnectionField.DropdownOption(
                                    value: "local",
                                    label: String(localized: "Local File")
                                )
                            ]),
                            section: .authentication,
                            hidesPassword: true
                        ),
                        ConnectionField(
                            id: "databaseUrl",
                            label: String(localized: "Database URL"),
                            placeholder: "https://your-db.turso.io",
                            required: true,
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "libsqlMode", values: ["remote"])
                        ),
                        ConnectionField(
                            id: "libsqlFilePath",
                            label: String(localized: "Database File"),
                            placeholder: "/path/to/database.db",
                            required: true,
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "libsqlMode", values: ["local"])
                        )
                    ],
                    category: .cloud,
                    tagline: String(localized: "Distributed SQLite by Turso")
                )
            )),
        ] + cloudPluginDefaults() + elasticsearchPluginDefaults() + surrealDBPluginDefaults()
    }
    // swiftlint:enable function_body_length
}
