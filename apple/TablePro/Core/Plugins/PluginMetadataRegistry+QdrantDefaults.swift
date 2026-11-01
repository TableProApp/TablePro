import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func qdrantPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Qdrant", PluginMetadataSnapshot(
                displayName: "Qdrant", iconName: "qdrant-icon", defaultPort: 6_333,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#DC244C",
                queryLanguageName: "REST", editorLanguage: .javascript,
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
                    verifiesServerWithSystemTrust: true,
                    columnsAreSampled: true,
                    supportsPrincipalConnectionLimit: false
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
                    statementCompletions: qdrantCompletions,
                    columnTypesByCategory: qdrantColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: qdrantConnectionFields(),
                    category: .document,
                    tagline: String(localized: "Open-source vector search engine"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            ))
        ]
    }
}

private let qdrantCompletions: [CompletionEntry] = [
    CompletionEntry(label: "GET /collections", insertText: "GET /collections"),
    CompletionEntry(label: "GET /collections/{name}", insertText: "GET /collections/docs"),
    CompletionEntry(
        label: "POST /points/scroll",
        insertText: """
        POST /collections/docs/points/scroll
        {"limit": 10, "with_payload": true}
        """
    ),
    CompletionEntry(
        label: "POST /points/query",
        insertText: """
        POST /collections/docs/points/query
        {"query": [0.1, 0.2, 0.3, 0.4], "limit": 10, "with_payload": true}
        """
    ),
    CompletionEntry(
        label: "POST /points/count",
        insertText: """
        POST /collections/docs/points/count
        {"exact": true}
        """
    ),
    CompletionEntry(
        label: "POST /facet",
        insertText: """
        POST /collections/docs/facet
        {"key": "city"}
        """
    )
]

private let qdrantColumnTypes: [String: [String]] = [
    "Text": ["keyword", "text", "string", "uuid"],
    "Numeric": ["integer", "float"],
    "Boolean": ["bool"],
    "Date": ["datetime"],
    "Structured": ["geo", "object", "array", "json"],
    "Vector": ["vector", "multivector", "sparse_vector"]
]

private func qdrantConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: "qdApiKey",
            label: String(localized: "API Key"),
            placeholder: "Qdrant API key",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true)
    ]
}
