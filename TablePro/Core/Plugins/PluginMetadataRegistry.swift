//
//  PluginMetadataRegistry.swift
//  TablePro
//
//  Thread-safe, non-actor metadata cache populated at compile time.
//  All static plugin metadata is served from here, eliminating metatype
//  dispatch on dynamically loaded bundles (which can crash due to
//  missing witness table entries).
//

import Foundation
import TableProPluginKit

struct PluginMetadataSnapshot: Sendable {
    let displayName: String
    let iconName: String
    let defaultPort: Int
    let requiresAuthentication: Bool
    let supportsForeignKeys: Bool
    let supportsSchemaEditing: Bool
    let isDownloadable: Bool
    let primaryUrlScheme: String
    let parameterStyle: ParameterStyle
    let navigationModel: NavigationModel
    let explainVariants: [ExplainVariant]
    let pathFieldRole: PathFieldRole
    let supportsHealthMonitor: Bool
    let urlSchemes: [String]
    let postConnectActions: [PostConnectAction]
    let brandColorHex: String
    let queryLanguageName: String
    let editorLanguage: EditorLanguage
    let connectionMode: ConnectionMode
    let supportsDatabaseSwitching: Bool
    let supportsColumnReorder: Bool

    let capabilities: CapabilityFlags
    let schema: SchemaInfo
    let editor: EditorConfig
    let connection: ConnectionConfig

    struct CapabilityFlags: Sendable {
        let supportsSchemaSwitching: Bool
        let supportsImport: Bool
        let supportsExport: Bool
        let supportsSSH: Bool
        let supportsSSL: Bool
        let supportsCascadeDrop: Bool
        let supportsForeignKeyDisable: Bool
        let supportsReadOnlyMode: Bool
        let supportsQueryProgress: Bool
        let requiresReconnectForDatabaseSwitch: Bool
        let supportsDropDatabase: Bool
        // `var` with defaults so existing call sites compile without passing these fields
        var supportsAddColumn: Bool = true
        var supportsModifyColumn: Bool = true
        var supportsDropColumn: Bool = true
        var supportsRenameColumn: Bool = false
        var supportsAddIndex: Bool = true
        var supportsDropIndex: Bool = true
        var supportsModifyPrimaryKey: Bool = true

        static let defaults = CapabilityFlags(
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
            supportsDropDatabase: false,
            supportsAddColumn: true,
            supportsModifyColumn: true,
            supportsDropColumn: true,
            supportsRenameColumn: false,
            supportsAddIndex: true,
            supportsDropIndex: true,
            supportsModifyPrimaryKey: true
        )
    }

    struct SchemaInfo: Sendable {
        let defaultSchemaName: String
        let defaultGroupName: String
        let tableEntityName: String
        let defaultPrimaryKeyColumn: String?
        let immutableColumns: [String]
        let systemDatabaseNames: [String]
        let systemSchemaNames: [String]
        let fileExtensions: [String]
        let databaseGroupingStrategy: GroupingStrategy
        let structureColumnFields: [StructureColumnField]

        static let defaults = SchemaInfo(
            defaultSchemaName: "public",
            defaultGroupName: "main",
            tableEntityName: "Tables",
            defaultPrimaryKeyColumn: nil,
            immutableColumns: [],
            systemDatabaseNames: [],
            systemSchemaNames: [],
            fileExtensions: [],
            databaseGroupingStrategy: .byDatabase,
            structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
        )
    }

    struct EditorConfig: Sendable {
        let sqlDialect: SQLDialectDescriptor?
        let statementCompletions: [CompletionEntry]
        let columnTypesByCategory: [String: [String]]

        static let defaults = EditorConfig(
            sqlDialect: nil,
            statementCompletions: [],
            columnTypesByCategory: [
                "Integer": ["INTEGER", "INT", "SMALLINT", "BIGINT", "TINYINT"],
                "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL"],
                "String": ["VARCHAR", "CHAR", "TEXT", "NVARCHAR", "NCHAR"],
                "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
                "Binary": ["BLOB", "BINARY", "VARBINARY"],
                "Boolean": ["BOOLEAN", "BOOL"],
                "JSON": ["JSON"]
            ]
        )
    }

    struct ConnectionConfig: Sendable {
        let additionalConnectionFields: [ConnectionField]

        static let defaults = ConnectionConfig(
            additionalConnectionFields: []
        )
    }

    func withIconName(_ newIconName: String) -> PluginMetadataSnapshot {
        PluginMetadataSnapshot(
            displayName: displayName, iconName: newIconName, defaultPort: defaultPort,
            requiresAuthentication: requiresAuthentication, supportsForeignKeys: supportsForeignKeys,
            supportsSchemaEditing: supportsSchemaEditing, isDownloadable: isDownloadable,
            primaryUrlScheme: primaryUrlScheme, parameterStyle: parameterStyle,
            navigationModel: navigationModel, explainVariants: explainVariants,
            pathFieldRole: pathFieldRole, supportsHealthMonitor: supportsHealthMonitor,
            urlSchemes: urlSchemes, postConnectActions: postConnectActions,
            brandColorHex: brandColorHex, queryLanguageName: queryLanguageName,
            editorLanguage: editorLanguage, connectionMode: connectionMode,
            supportsDatabaseSwitching: supportsDatabaseSwitching,
            supportsColumnReorder: supportsColumnReorder,
            capabilities: capabilities, schema: schema, editor: editor, connection: connection
        )
    }
}

final class PluginMetadataRegistry: @unchecked Sendable {
    static let shared = PluginMetadataRegistry()

    private let lock = NSLock()
    private var snapshots: [String: PluginMetadataSnapshot] = [:]
    private var schemeIndex: [String: String] = [:]
    private var reverseTypeIndex: [String: String] = [:]

    private init() {
        registerBuiltInDefaults()
    }

    // swiftlint:disable function_body_length
    private func registerBuiltInDefaults() {
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
            requiresBackslashEscaping: true
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
            paginationStyle: .limit
        )

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
            paginationStyle: .limit
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
                supportsColumnReorder: true,
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
                    supportsRenameColumn: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "mysql", "performance_schema", "sys"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment, .charset, .collation]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mysqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mysqlColumnTypes
                ),
                connection: .defaults
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
                supportsColumnReorder: true,
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
                    supportsRenameColumn: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "mysql", "performance_schema", "sys"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment, .charset, .collation]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mysqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mysqlColumnTypes
                ),
                connection: .defaults
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
                supportsColumnReorder: false,
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
                    supportsRenameColumn: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["postgres", "template0", "template1"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: postgresqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: postgresqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [pgpassField]
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
                supportsColumnReorder: false,
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
                    supportsDropDatabase: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["postgres", "template0", "template1"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: postgresqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: postgresqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [pgpassField]
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
                    supportsModifyColumn: false,
                    supportsRenameColumn: true,
                    supportsModifyPrimaryKey: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: ["db", "sqlite", "sqlite3"],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: sqliteDialect,
                    statementCompletions: [],
                    columnTypesByCategory: sqliteColumnTypes
                ),
                connection: .defaults
            ))
        ]
        // swiftlint:enable function_body_length
        let allDefaults = defaults + registryPluginDefaults()
        for entry in allDefaults {
            snapshots[entry.typeId] = entry.snapshot
            for scheme in entry.snapshot.urlSchemes {
                schemeIndex[scheme.lowercased()] = entry.typeId
            }
        }

        // Built-in type aliases: multi-type plugins where an alias maps to a primary plugin type ID
        reverseTypeIndex["MariaDB"] = "MySQL"
        reverseTypeIndex["Redshift"] = "PostgreSQL"
        reverseTypeIndex["ScyllaDB"] = "Cassandra"
    }

    func register(snapshot: PluginMetadataSnapshot, forTypeId typeId: String, preserveIcon: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        var resolved = snapshot
        if preserveIcon, let existingIcon = snapshots[typeId]?.iconName {
            resolved = snapshot.withIconName(existingIcon)
        }
        snapshots[typeId] = resolved
        for scheme in resolved.urlSchemes {
            schemeIndex[scheme.lowercased()] = typeId
        }
    }

    func unregister(typeId: String) {
        lock.lock()
        defer { lock.unlock() }
        if let snapshot = snapshots.removeValue(forKey: typeId) {
            for scheme in snapshot.urlSchemes {
                schemeIndex.removeValue(forKey: scheme.lowercased())
            }
        }
    }

    func snapshot(forTypeId typeId: String) -> PluginMetadataSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[typeId]
    }

    func typeId(forUrlScheme scheme: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return schemeIndex[scheme.lowercased()]
    }

    func databaseType(forUrlScheme scheme: String) -> DatabaseType? {
        guard let typeId = typeId(forUrlScheme: scheme) else { return nil }
        return DatabaseType(rawValue: typeId)
    }

    // MARK: - Dynamic Type Registration

    /// Registers an alias type ID that maps to a primary type ID.
    /// Used for multi-type plugins (e.g., MariaDB → MySQL, Redshift → PostgreSQL).
    func registerTypeAlias(_ aliasTypeId: String, primaryTypeId: String) {
        lock.lock()
        defer { lock.unlock() }
        reverseTypeIndex[aliasTypeId] = primaryTypeId
    }

    /// Returns all registered type IDs (sorted for deterministic UI ordering).
    func allRegisteredTypeIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(snapshots.keys).sorted()
    }

    /// Resolves a database type raw value to its plugin type ID for driver lookup.
    /// For multi-type plugins (MySQL serves MariaDB), maps the alias to the primary.
    /// Does NOT remap for snapshot lookups — use snapshot(forTypeId:) directly.
    func pluginTypeId(for rawValue: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return reverseTypeIndex[rawValue] ?? rawValue
    }

    /// Checks if a type ID is registered (has a snapshot).
    func hasType(_ typeId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[typeId] != nil
    }

    // MARK: - Snapshot Builder

    /// Builds a PluginMetadataSnapshot from a DriverPlugin's protocol properties.
    /// Used by PluginManager to self-register plugins at load time.
    func buildMetadataSnapshot(
        from driverType: any DriverPlugin.Type,
        isDownloadable: Bool = false
    ) -> PluginMetadataSnapshot {
        let parameterStyle = driverType.parameterStyle
        let schemes = driverType.urlSchemes
        let primaryScheme = schemes.first ?? driverType.databaseTypeId.lowercased()

        // Preserve supportsColumnReorder from existing built-in snapshot.
        // Cannot read from driverType directly — stale plugins without the
        // property crash with EXC_BAD_INSTRUCTION (missing witness table entry).
        let existingSnapshot = snapshot(forTypeId: driverType.databaseTypeId)

        return PluginMetadataSnapshot(
            displayName: driverType.databaseDisplayName,
            iconName: driverType.iconName,
            defaultPort: driverType.defaultPort,
            requiresAuthentication: driverType.requiresAuthentication,
            supportsForeignKeys: driverType.supportsForeignKeys,
            supportsSchemaEditing: driverType.supportsSchemaEditing,
            isDownloadable: isDownloadable,
            primaryUrlScheme: primaryScheme,
            parameterStyle: parameterStyle,
            navigationModel: driverType.navigationModel,
            explainVariants: driverType.explainVariants,
            pathFieldRole: driverType.pathFieldRole,
            supportsHealthMonitor: driverType.supportsHealthMonitor,
            urlSchemes: schemes,
            postConnectActions: driverType.postConnectActions,
            brandColorHex: driverType.brandColorHex,
            queryLanguageName: driverType.queryLanguageName,
            editorLanguage: driverType.editorLanguage,
            connectionMode: driverType.connectionMode,
            supportsDatabaseSwitching: driverType.supportsDatabaseSwitching,
            supportsColumnReorder: existingSnapshot?.supportsColumnReorder ?? false,
            capabilities: PluginMetadataSnapshot.CapabilityFlags(
                supportsSchemaSwitching: driverType.supportsSchemaSwitching,
                supportsImport: driverType.supportsImport,
                supportsExport: driverType.supportsExport,
                supportsSSH: driverType.supportsSSH,
                supportsSSL: driverType.supportsSSL,
                supportsCascadeDrop: driverType.supportsCascadeDrop,
                supportsForeignKeyDisable: driverType.supportsForeignKeyDisable,
                supportsReadOnlyMode: driverType.supportsReadOnlyMode,
                supportsQueryProgress: driverType.supportsQueryProgress,
                requiresReconnectForDatabaseSwitch: driverType.requiresReconnectForDatabaseSwitch,
                supportsDropDatabase: driverType.supportsDropDatabase,
                supportsAddColumn: driverType.supportsAddColumn,
                supportsModifyColumn: driverType.supportsModifyColumn,
                supportsDropColumn: driverType.supportsDropColumn,
                supportsRenameColumn: driverType.supportsRenameColumn,
                supportsAddIndex: driverType.supportsAddIndex,
                supportsDropIndex: driverType.supportsDropIndex,
                supportsModifyPrimaryKey: driverType.supportsModifyPrimaryKey
            ),
            schema: PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: driverType.defaultSchemaName,
                defaultGroupName: driverType.defaultGroupName,
                tableEntityName: driverType.tableEntityName,
                defaultPrimaryKeyColumn: driverType.defaultPrimaryKeyColumn,
                immutableColumns: driverType.immutableColumns,
                systemDatabaseNames: driverType.systemDatabaseNames,
                systemSchemaNames: driverType.systemSchemaNames,
                fileExtensions: driverType.fileExtensions,
                databaseGroupingStrategy: driverType.databaseGroupingStrategy,
                structureColumnFields: driverType.structureColumnFields
            ),
            editor: PluginMetadataSnapshot.EditorConfig(
                sqlDialect: driverType.sqlDialect,
                statementCompletions: driverType.statementCompletions,
                columnTypesByCategory: driverType.columnTypesByCategory
            ),
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: driverType.additionalConnectionFields
            )
        )
    }

    func allFileExtensions() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: String] = [:]
        for (typeId, snapshot) in snapshots {
            for ext in snapshot.schema.fileExtensions {
                let key = ext.lowercased()
                if result[key] == nil {
                    result[key] = typeId
                }
            }
        }
        return result
    }

    func allUrlSchemes() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return schemeIndex
    }
}
