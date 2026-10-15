import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    /// Rows come only in key order and Bigtable keeps no count, so a column sort is the grid's own
    /// and a count reads every key, only when asked. `_key` stays writable because a new row has
    /// no other way to get one; the driver refuses a change to an existing row's key.
    func bigtablePluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Bigtable", PluginMetadataSnapshot(
                displayName: "Google Cloud Bigtable", iconName: "bigtable-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#4285F4",
                queryLanguageName: "REST", editorLanguage: .javascript,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
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
                    supportsFieldRemoval: true,
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    exactRowCountIsFullScan: true,
                    supportsColumnSort: false,
                    columnsAreSampled: true,
                    supportsPrincipalConnectionLimit: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    containerEntityName: "Instance",
                    defaultPrimaryKeyColumn: "_key",
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: bigtableCompletions,
                    columnTypesByCategory: ["Binary": ["bytes"]]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: bigtableConnectionFields(),
                    category: .wideColumn,
                    tagline: String(localized: "Google Cloud wide-column store for large data"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            ))
        ]
    }
}

private let bigtableCompletions: [CompletionEntry] = [
    CompletionEntry(label: "GET row", insertText: "GET events/user#42"),
    CompletionEntry(label: "SCAN prefix", insertText: "SCAN events/user#?limit=20"),
    CompletionEntry(label: "READ", insertText: "READ events {\"rowsLimit\": \"20\", \"filter\": {\"cellsPerColumnLimitFilter\": 1}}"),
    CompletionEntry(label: "INSERT row", insertText: "INSERT events/user#42 {\"profile:name\": \"Ann\"}"),
    CompletionEntry(label: "PUT cells", insertText: "PUT events/user#42 {\"profile:name\": \"Ann\"}"),
    CompletionEntry(label: "DELETE row", insertText: "DELETE events/user#42"),
    CompletionEntry(label: "DELETE column", insertText: "DELETE events/user#42 profile:name")
]

func bigtableConnectionFields() -> [ConnectionField] {
    let authMethod = "btAuthMethod"
    return [
        ConnectionField(
            id: authMethod,
            label: String(localized: "Auth Method"),
            defaultValue: "serviceAccount",
            fieldType: .dropdown(options: [
                .init(value: "serviceAccount", label: "Service Account Key"),
                .init(value: "adc", label: "Application Default Credentials")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "btServiceAccountJson",
            label: String(localized: "Service Account Key"),
            placeholder: "File path or paste JSON",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: authMethod, values: ["serviceAccount"])
        ).withHidesUsername(true),
        ConnectionField(
            id: "btProjectId",
            label: String(localized: "Project ID"),
            placeholder: "Taken from the key when empty",
            section: .authentication
        ),
        ConnectionField(
            id: "btInstanceId",
            label: String(localized: "Instance ID"),
            placeholder: "The first instance when empty",
            section: .authentication
        ),
        ConnectionField(
            id: "btAppProfileId",
            label: String(localized: "App Profile ID"),
            placeholder: "default",
            section: .advanced
        )
    ]
}
