//
//  PluginMetadataRegistry+Neo4jDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    /// Kept identical to `Neo4jPlugin`: the type has to be in the New Connection picker before
    /// the registry plugin is installed.
    func neo4jPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Neo4j", PluginMetadataSnapshot(
                displayName: "Neo4j", iconName: "neo4j-icon", defaultPort: 7_687,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "neo4j", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true,
                urlSchemes: ["neo4j", "neo4j+s", "neo4j+ssc", "bolt", "bolt+s", "bolt+ssc"],
                postConnectActions: [],
                brandColorHex: "#018BFF",
                queryLanguageName: "Cypher", editorLanguage: .custom("cypher"),
                connectionMode: .network, supportsDatabaseSwitching: true,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
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
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "Labels",
                    defaultGroupName: "neo4j",
                    tableEntityName: "Types",
                    containerEntityName: "Database",
                    schemaEntityName: "Kind",
                    defaultPrimaryKeyColumn: "<id>",
                    immutableColumns: ["<id>", "<labels>", "<start>", "<end>"],
                    systemDatabaseNames: ["system"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: neo4jCompletions,
                    columnTypesByCategory: neo4jColumnTypes
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

private let neo4jColumnTypes: [String: [String]] = [
    "Scalar": ["STRING", "INTEGER", "FLOAT", "BOOLEAN", "BYTES"],
    "Temporal": ["DATE", "LOCAL TIME", "ZONED TIME", "LOCAL DATETIME", "ZONED DATETIME", "DURATION"],
    "Spatial": ["POINT"],
    "Structured": ["LIST", "MAP"],
    "Graph": ["NODE", "RELATIONSHIP", "PATH"]
]

private let neo4jCompletions: [CompletionEntry] = [
    CompletionEntry(label: "MATCH nodes", insertText: "MATCH (n:Label) RETURN n LIMIT 25"),
    CompletionEntry(label: "MATCH relationships", insertText: "MATCH (a)-[r:TYPE]->(b) RETURN a, r, b LIMIT 25"),
    CompletionEntry(label: "MATCH path", insertText: "MATCH p = (a)-[*1..3]->(b) RETURN p LIMIT 25"),
    CompletionEntry(label: "CREATE node", insertText: "CREATE (n:Label {name: 'value'}) RETURN n"),
    CompletionEntry(label: "MERGE node", insertText: "MERGE (n:Label {id: 1}) RETURN n"),
    CompletionEntry(label: "SHOW DATABASES", insertText: "SHOW DATABASES"),
    CompletionEntry(label: "SHOW INDEXES", insertText: "SHOW INDEXES"),
    CompletionEntry(label: "SHOW CONSTRAINTS", insertText: "SHOW CONSTRAINTS"),
    CompletionEntry(label: "db.labels", insertText: "CALL db.labels()"),
    CompletionEntry(label: "db.relationshipTypes", insertText: "CALL db.relationshipTypes()"),
    CompletionEntry(label: "db.schema.visualization", insertText: "CALL db.schema.visualization()")
]
