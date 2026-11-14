import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func weaviatePluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Weaviate", PluginMetadataSnapshot(
                displayName: "Weaviate", iconName: "weaviate-icon", defaultPort: 8_080,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#01B0D3",
                queryLanguageName: "GraphQL", editorLanguage: .javascript,
                connectionMode: .network, supportsDatabaseSwitching: false,
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
                    supportsDropDatabase: false,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsRawFilter: false,
                    supportsPrincipalConnectionLimit: false,
                    dataCommands: weaviateDataCommands
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Collections",
                    containerEntityName: "Cluster",
                    defaultPrimaryKeyColumn: "uuid",
                    immutableColumns: ["uuid", "vector"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: weaviateCompletions,
                    columnTypesByCategory: weaviateColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: weaviateConnectionFields(),
                    category: .document,
                    tagline: String(localized: "Open-source vector database"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            ))
        ]
    }
}

// The object and batch operations of the Weaviate OpenAPI, v1.25.0 to v1.40.5.
private let weaviateDataCommands: Set<String> = [
    "POST /v1/objects",
    "PUT /v1/objects/{className}/{id}", "PATCH /v1/objects/{className}/{id}", "DELETE /v1/objects/{className}/{id}",
    "PUT /v1/objects/{id}", "PATCH /v1/objects/{id}", "DELETE /v1/objects/{id}",
    "POST /v1/objects/{className}/{id}/references/{propertyName}",
    "PUT /v1/objects/{className}/{id}/references/{propertyName}",
    "DELETE /v1/objects/{className}/{id}/references/{propertyName}",
    "POST /v1/objects/{id}/references/{propertyName}",
    "PUT /v1/objects/{id}/references/{propertyName}",
    "DELETE /v1/objects/{id}/references/{propertyName}",
    "POST /v1/batch/objects", "DELETE /v1/batch/objects",
    "POST /v1/batch/references"
]

private let weaviateCompletions: [CompletionEntry] = [
    CompletionEntry(
        label: "Get",
        insertText: """
        {
          Get {
            Article(limit: 10) {
              title
              _additional { id distance }
            }
          }
        }
        """
    ),
    CompletionEntry(
        label: "Near text",
        insertText: """
        {
          Get {
            Article(
              nearText: { concepts: ["search term"] }
              limit: 10
            ) {
              title
              _additional { id distance }
            }
          }
        }
        """
    ),
    CompletionEntry(
        label: "Hybrid",
        insertText: """
        {
          Get {
            Article(
              hybrid: { query: "search term", alpha: 0.5 }
              limit: 10
            ) {
              title
              _additional { id score }
            }
          }
        }
        """
    ),
    CompletionEntry(label: "GET /v1/schema", insertText: "GET /v1/schema"),
    CompletionEntry(label: "GET /v1/meta", insertText: "GET /v1/meta"),
    CompletionEntry(label: "GET /v1/objects", insertText: "GET /v1/objects?class=Article&limit=10")
]

private let weaviateColumnTypes: [String: [String]] = [
    "Text": ["text", "text[]", "string", "string[]", "uuid", "uuid[]"],
    "Numeric": ["int", "int[]", "number", "number[]"],
    "Boolean": ["boolean", "boolean[]"],
    "Date": ["date", "date[]"],
    "Structured": ["object", "object[]", "geoCoordinates", "phoneNumber"],
    "Vector": ["vector"]
]

func weaviateConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: "wvAuthMethod",
            label: String(localized: "Auth Method"),
            defaultValue: "none",
            fieldType: .dropdown(options: [
                .init(value: "none", label: "None"),
                .init(value: "apiKey", label: "API Key")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "wvApiKey",
            label: String(localized: "API Key"),
            placeholder: "Weaviate API key",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true),
        ConnectionField(
            id: "wvSkipTLSVerify",
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        )
    ]
}
