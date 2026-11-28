//
//  PluginMetadataRegistry+HydraDBDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    // Kept identical to `HydraDBPlugin`, so the type is in the New Connection picker before the plugin is installed.
    func hydraDBPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("HydraDB", PluginMetadataSnapshot(
                displayName: "HydraDB", iconName: "server.rack", defaultPort: 7_687,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true,
                urlSchemes: [],
                postConnectActions: [],
                brandColorHex: "#018BFF",
                queryLanguageName: "Cypher", editorLanguage: .custom("cypher"),
                connectionMode: .network, supportsDatabaseSwitching: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
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
                    supportsDropSchema: false,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    columnsAreSampled: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "Labels",
                    defaultGroupName: "default",
                    tableEntityName: "Types",
                    containerEntityName: "Database",
                    schemaEntityName: "Kind",
                    defaultPrimaryKeyColumn: "<id>",
                    immutableColumns: ["<id>", "<labels>", "<start>", "<end>"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: hydraDBCompletions,
                    columnTypesByCategory: hydraDBColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [],
                    category: .other,
                    tagline: String(localized: "Graph database queried with Cypher")
                )
            ))
        ]
    }
}

private let hydraDBColumnTypes: [String: [String]] = [
    "Scalar": ["STRING", "INTEGER", "FLOAT", "BOOLEAN"],
    "Structured": ["LIST", "MAP"],
    "Graph": ["NODE", "RELATIONSHIP"]
]

private let hydraDBCompletions: [CompletionEntry] = [
    CompletionEntry(label: "MATCH nodes", insertText: "MATCH (n:Label) RETURN n LIMIT 25"),
    CompletionEntry(label: "MATCH relationships", insertText: "MATCH ()-[r:TYPE]->() RETURN r LIMIT 25"),
    CompletionEntry(label: "db.labels", insertText: "CALL db.labels()"),
    CompletionEntry(label: "db.relationshipTypes", insertText: "CALL db.relationshipTypes()")
]
