//
//  PluginMetadataRegistry+SurrealDBDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func surrealDBPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("SurrealDB", PluginMetadataSnapshot(
                displayName: "SurrealDB", iconName: "surrealdb-icon", defaultPort: 8_000,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "surrealdb", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: surrealDBExplainVariants,
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["surrealdb"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#FF00A0",
                queryLanguageName: "SurrealQL", editorLanguage: .custom("surrealql"),
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
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
                    supportsDropDatabase: true,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Namespace",
                    schemaEntityName: "Database",
                    defaultPrimaryKeyColumn: "id",
                    immutableColumns: ["id"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: surrealDBCompletions,
                    columnTypesByCategory: surrealDBColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: surrealDBConnectionFields(),
                    category: .document,
                    tagline: String(localized: "Multi-model database with SurrealQL")
                )
            )),
        ]
    }
}

private let surrealDBExplainVariants: [ExplainVariant] = [
    ExplainVariant(id: "explain", label: "Explain", sqlPrefix: "EXPLAIN"),
    ExplainVariant(id: "explainFull", label: "Explain Full", sqlPrefix: "EXPLAIN FULL"),
]

private let surrealDBCompletions: [CompletionEntry] = [
    CompletionEntry(label: "SELECT", insertText: "SELECT * FROM table LIMIT 100"),
    CompletionEntry(label: "CREATE", insertText: "CREATE table SET field = value"),
    CompletionEntry(label: "UPDATE", insertText: "UPDATE table:id SET field = value"),
    CompletionEntry(label: "UPSERT", insertText: "UPSERT table:id SET field = value"),
    CompletionEntry(label: "DELETE", insertText: "DELETE table:id"),
    CompletionEntry(label: "RELATE", insertText: "RELATE from:id->edge->to:id SET field = value"),
    CompletionEntry(label: "USE", insertText: "USE NS namespace DB database"),
    CompletionEntry(label: "INFO FOR DB", insertText: "INFO FOR DB"),
    CompletionEntry(label: "INFO FOR TABLE", insertText: "INFO FOR TABLE table"),
    CompletionEntry(label: "DEFINE TABLE", insertText: "DEFINE TABLE table SCHEMAFULL"),
    CompletionEntry(label: "DEFINE FIELD", insertText: "DEFINE FIELD field ON table TYPE string"),
    CompletionEntry(label: "DEFINE INDEX", insertText: "DEFINE INDEX name ON table FIELDS field UNIQUE"),
    CompletionEntry(label: "REMOVE TABLE", insertText: "REMOVE TABLE table"),
    CompletionEntry(label: "count", insertText: "SELECT count() AS total FROM table GROUP ALL"),
]

private let surrealDBColumnTypes: [String: [String]] = [
    "Integer": ["int"],
    "Float": ["float", "decimal", "number"],
    "String": ["string", "uuid"],
    "Date": ["datetime", "duration"],
    "Binary": ["bytes"],
    "Boolean": ["bool"],
    "Structured": ["object", "array", "set", "geometry", "record", "any"],
]

func surrealDBConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: "sdbAuthLevel",
            label: String(localized: "Auth Level"),
            defaultValue: "root",
            fieldType: .dropdown(options: [
                .init(value: "root", label: String(localized: "Root")),
                .init(value: "namespace", label: String(localized: "Namespace")),
                .init(value: "database", label: String(localized: "Database")),
                .init(value: "record", label: String(localized: "Record Access")),
                .init(value: "token", label: String(localized: "Token")),
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "sdbToken",
            label: String(localized: "Token"),
            placeholder: "JWT",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "sdbAuthLevel", values: ["token"])
        ),
        ConnectionField(
            id: "sdbAccess",
            label: String(localized: "Access Method"),
            placeholder: "user",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "sdbAuthLevel", values: ["record"])
        ),
        ConnectionField(
            id: "sdbDatabase",
            label: String(localized: "Database"),
            placeholder: String(localized: "The database this user belongs to"),
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "sdbAuthLevel", values: ["database", "record"])
        ),
        ConnectionField(
            id: "sdbSkipTLSVerify",
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        ),
    ]
}
