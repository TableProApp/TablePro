import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func hanaPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("SAP HANA", PluginMetadataSnapshot(
                displayName: "SAP HANA", iconName: "cylinder", defaultPort: 443,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "hdb", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN PLAN FOR", format: .indentedText)
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["hdb"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#0FAAFF",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: false,
                structureEditing: SchemaEditingSupport(),
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsDropSchema: false,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    defaultSSLMode: .verifyIdentity,
                    supportsOpportunisticTLS: false,
                    tlsImpliedPorts: [443],
                    verifiesServerWithSystemTrust: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Schema",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: hanaSystemSchemaNames,
                    fileExtensions: [],
                    databaseGroupingStrategy: .hierarchicalSchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .comment],
                    rowMatchExcludedTypePrefixes: hanaRowMatchExcludedTypePrefixes
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: hanaDialect,
                    statementCompletions: hanaCompletions,
                    columnTypesByCategory: hanaColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: hanaConnectionFields(),
                    category: .relational,
                    tagline: String(localized: "SAP's in-memory SQL database")
                )
            )),
        ]
    }
}

private let hanaSystemSchemaNames = [
    "SYS", "SYS_DATABASES", "_SYS_AFL", "_SYS_AUDIT", "_SYS_BI", "_SYS_BIC", "_SYS_DATA_ANONYMIZATION", "_SYS_DI",
    "_SYS_EPM", "_SYS_PLAN_STABILITY", "_SYS_REPO", "_SYS_RT", "_SYS_SECURITY", "_SYS_SQL_ANALYZER",
    "_SYS_STATISTICS", "_SYS_TASK", "_SYS_TELEMETRY", "_SYS_WORKLOAD_REPLAY", "_SYS_XS"
]

private let hanaRowMatchExcludedTypePrefixes = ["BLOB", "CLOB", "NCLOB", "TEXT", "BINTEXT", "ST_"]

private let hanaColumnTypes: [String: [String]] = [
    "Integer": ["TINYINT", "SMALLINT", "INTEGER", "BIGINT"],
    "Float": ["DECIMAL", "SMALLDECIMAL", "REAL", "DOUBLE"],
    "String": ["CHAR", "NCHAR", "VARCHAR", "NVARCHAR", "CLOB", "NCLOB"],
    "Date": ["DATE", "TIME", "SECONDDATE", "TIMESTAMP"],
    "Binary": ["BLOB", "VARBINARY"],
    "Boolean": ["BOOLEAN"],
    "Other": ["ALPHANUM", "SHORTTEXT", "TEXT", "ST_GEOMETRY"]
]

private let hanaCompletions = [
    CompletionEntry(label: "SELECT", insertText: "SELECT * FROM \"SCHEMA\".\"TABLE\""),
    CompletionEntry(label: "CREATE TABLE", insertText: "CREATE TABLE \"SCHEMA\".\"TABLE\" (\n    \"id\" INTEGER\n)"),
    CompletionEntry(label: "ALTER TABLE", insertText: "ALTER TABLE \"SCHEMA\".\"TABLE\""),
    CompletionEntry(label: "EXPLAIN PLAN", insertText: "EXPLAIN PLAN FOR SELECT * FROM \"SCHEMA\".\"TABLE\""),
    CompletionEntry(label: "SELECT TOP", insertText: "SELECT TOP 100 * FROM \"SCHEMA\".\"TABLE\"")
]

private let hanaDialect = SQLDialectDescriptor(
    identifierQuote: "\"",
    keywords: [
        "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS",
        "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "IS", "NULL", "AS",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "TOP", "OFFSET", "UNION", "ALL", "DISTINCT",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "MERGE", "CREATE", "ALTER", "DROP",
        "TABLE", "VIEW", "INDEX", "SCHEMA", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE",
        "CONSTRAINT", "ADD", "COLUMN", "RENAME", "CASE", "WHEN", "THEN", "ELSE", "END", "WITH",
        "EXPLAIN", "PLAN", "FOR", "BEGIN", "COMMIT", "ROLLBACK"
    ],
    functions: [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST", "CONVERT", "TO_DATE",
        "TO_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_SCHEMA", "LENGTH",
        "SUBSTRING", "LOWER", "UPPER", "TRIM", "REPLACE", "ROUND", "ABS"
    ],
    dataTypes: Set(hanaColumnTypes.values.flatMap { $0 }),
    tableOptions: ["PARTITION BY", "UNLOAD PRIORITY", "AUTO MERGE"],
    regexSyntax: .unsupported,
    booleanLiteralStyle: .truefalse,
    likeEscapeStyle: .explicit,
    paginationStyle: .limit,
    autoLimitStyle: .limit,
    caseSensitivityStyle: .caseFoldFunction,
    textCastTypeName: nil,
    functionNamesAreCaseInsensitive: true,
    lexicalFeatures: [.dollarAndHashInIdentifiers]
)

private func hanaConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: "hanaTLSServerName",
            label: String(localized: "TLS Server Name"),
            placeholder: String(localized: "Leave empty unless the certificate names another host"),
            section: .advanced
        )
    ]
}
