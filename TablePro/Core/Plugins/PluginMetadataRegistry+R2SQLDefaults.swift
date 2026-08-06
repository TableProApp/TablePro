//
//  PluginMetadataRegistry+R2SQLDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func r2SQLPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Cloudflare R2 SQL", PluginMetadataSnapshot(
                displayName: "Cloudflare R2 SQL", iconName: "cloudflare-r2-sql-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: r2SQLExplainVariants,
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#F6821F",
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
                    supportsDropDatabase: false,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsRenameColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsCloudflareTunnel: false,
                    supportsOffsetPagination: false,
                    isEngineReadOnly: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Bucket",
                    schemaEntityName: "Namespace",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .hierarchicalSchema,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: r2SQLCompletions,
                    columnTypesByCategory: r2SQLColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: r2SQLConnectionFields(),
                    category: .cloud,
                    tagline: String(localized: "Read-only SQL over Iceberg tables in R2")
                )
            )),
        ]
    }

    private func r2SQLConnectionFields() -> [ConnectionField] {
        [
            ConnectionField(
                id: "r2AccountId",
                label: String(localized: "Account ID"),
                placeholder: "Cloudflare Account ID",
                required: true,
                section: .authentication
            ),
            ConnectionField(
                id: "r2Bucket",
                label: String(localized: "Bucket"),
                placeholder: "my-bucket",
                required: true,
                section: .authentication
            ),
        ]
    }
}

private let r2SQLExplainVariants: [ExplainVariant] = [
    ExplainVariant(id: "explain", label: "Explain", sqlPrefix: "EXPLAIN"),
    ExplainVariant(id: "explainJson", label: "Explain (JSON)", sqlPrefix: "EXPLAIN FORMAT JSON"),
]

private let r2SQLCompletions: [CompletionEntry] = [
    CompletionEntry(label: "SELECT", insertText: "SELECT * FROM namespace.table LIMIT 100"),
    CompletionEntry(label: "SHOW NAMESPACES", insertText: "SHOW NAMESPACES"),
    CompletionEntry(label: "SHOW TABLES", insertText: "SHOW TABLES IN namespace"),
    CompletionEntry(label: "DESCRIBE", insertText: "DESCRIBE namespace.table"),
    CompletionEntry(label: "EXPLAIN", insertText: "EXPLAIN SELECT * FROM namespace.table LIMIT 10"),
    CompletionEntry(label: "COUNT", insertText: "SELECT COUNT(*) AS total FROM namespace.table"),
    CompletionEntry(label: "QUALIFY", insertText: "QUALIFY ROW_NUMBER() OVER (ORDER BY column) <= 10"),
    CompletionEntry(label: "WITH", insertText: "WITH cte AS (SELECT * FROM namespace.table LIMIT 100) SELECT * FROM cte"),
]

private let r2SQLColumnTypes: [String: [String]] = [
    "Integer": ["INT32", "INT64"],
    "Float": ["FLOAT32", "FLOAT64", "DECIMAL128"],
    "String": ["STRING"],
    "Date": ["DATE32", "TIMESTAMP"],
    "Binary": ["BINARY"],
    "Boolean": ["BOOLEAN"],
    "Nested": ["ARRAY", "STRUCT", "MAP"],
]
