//
//  PluginMetadataRegistry+TypesenseDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func typesensePluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Typesense", PluginMetadataSnapshot(
                displayName: "Typesense", iconName: "typesense-icon", defaultPort: 8_108,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#1035BC",
                queryLanguageName: "Typesense API", editorLanguage: .javascript,
                connectionMode: .network, supportsDatabaseSwitching: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsOpportunisticTLS: false,
                    supportsCloudflareTunnel: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Collections",
                    containerEntityName: "Cluster",
                    defaultPrimaryKeyColumn: "id",
                    immutableColumns: ["id"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: typesenseCompletions,
                    columnTypesByCategory: typesenseColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: typesenseConnectionFields(),
                    category: .document,
                    tagline: String(localized: "Typo-tolerant open-source search engine"),
                    hidesBuiltInDatabase: true
                )
            )),
        ]
    }
}

private let typesenseCompletions: [CompletionEntry] = [
    CompletionEntry(label: "GET /collections", insertText: "GET /collections"),
    CompletionEntry(label: "GET /collections/:name", insertText: "GET /collections/my-collection"),
    CompletionEntry(
        label: "GET /collections/:name/documents/search",
        insertText: "GET /collections/my-collection/documents/search?q=*&per_page=10"
    ),
    CompletionEntry(
        label: "POST /multi_search",
        insertText: """
        POST /multi_search
        {
          "searches": [
            { "collection": "my-collection", "q": "*", "filter_by": "", "sort_by": "", "per_page": 10 }
          ]
        }
        """
    ),
    CompletionEntry(
        label: "POST /collections",
        insertText: """
        POST /collections
        {
          "name": "my-collection",
          "fields": [
            { "name": "title", "type": "string" }
          ]
        }
        """
    ),
    CompletionEntry(
        label: "POST /collections/:name/documents",
        insertText: """
        POST /collections/my-collection/documents
        {
          "id": "1",
          "title": "Example"
        }
        """
    ),
    CompletionEntry(
        label: "PATCH /collections/:name/documents/:id",
        insertText: """
        PATCH /collections/my-collection/documents/1
        {
          "title": "Updated"
        }
        """
    ),
    CompletionEntry(
        label: "DELETE /collections/:name/documents/:id",
        insertText: "DELETE /collections/my-collection/documents/1"
    ),
    CompletionEntry(
        label: "GET /collections/:name/documents/export",
        insertText: "GET /collections/my-collection/documents/export"
    ),
    CompletionEntry(label: "GET /aliases", insertText: "GET /aliases"),
    CompletionEntry(label: "GET /keys", insertText: "GET /keys"),
    CompletionEntry(label: "GET /health", insertText: "GET /health"),
    CompletionEntry(label: "GET /stats.json", insertText: "GET /stats.json"),
    CompletionEntry(label: "GET /metrics.json", insertText: "GET /metrics.json"),
    CompletionEntry(label: "GET /debug", insertText: "GET /debug"),
]

private let typesenseColumnTypes: [String: [String]] = [
    "Text": ["string", "string[]", "string*"],
    "Numeric": ["int32", "int32[]", "int64", "int64[]", "float", "float[]"],
    "Boolean": ["bool", "bool[]"],
    "Geo": ["geopoint", "geopoint[]", "geopolygon"],
    "Structured": ["object", "object[]"],
    "Specialized": ["auto", "image"],
]

func typesenseConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: "typesenseApiKey",
            label: String(localized: "API Key"),
            placeholder: "The key the server was started with",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true),
        ConnectionField(
            id: "typesenseSkipTLSVerify",
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        ),
    ]
}
