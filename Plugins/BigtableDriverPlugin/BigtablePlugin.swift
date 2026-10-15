import Foundation
import TableProBigtableCore
import TableProPluginKit

final class BigtablePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Bigtable Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Google Cloud Bigtable over the REST API"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Bigtable"
    static let databaseDisplayName = "Google Cloud Bigtable"
    static let iconName = "bigtable-icon"
    static let defaultPort = 0
    static let isDownloadable = true

    static let connectionMode: ConnectionMode = .apiOnly
    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = true
    static let brandColorHex = "#4285F4"
    static let queryLanguageName = "REST"
    static let editorLanguage: EditorLanguage = .javascript
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = true
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSSH = false
    static let supportsSSL = false
    static let supportsReadOnlyMode = true
    static let supportsForeignKeyDisable = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false
    static let supportsFieldRemoval = true
    static let databaseGroupingStrategy: GroupingStrategy = .byDatabase
    static let defaultGroupName = "default"
    static let tableEntityName = "Tables"
    static let containerEntityName = "Instance"
    static let defaultSchemaName = ""
    static let defaultPrimaryKeyColumn: String? = BigtableRowSet.keyColumn
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil
    static let caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle = .driverManaged

    static let columnTypesByCategory: [String: [String]] = ["Binary": ["bytes"]]
    static let additionalConnectionFields: [ConnectionField] = bigtableConnectionFields()
    static var statementCompletions: [CompletionEntry] { bigtableCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        BigtablePluginDriver(config: config)
    }
}

func bigtableConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: BigtableFieldID.authMethod,
            label: String(localized: "Auth Method"),
            defaultValue: BigtableAuthMethod.serviceAccount.rawValue,
            fieldType: .dropdown(options: [
                .init(value: BigtableAuthMethod.serviceAccount.rawValue, label: "Service Account Key"),
                .init(value: BigtableAuthMethod.applicationDefault.rawValue, label: "Application Default Credentials")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: BigtableFieldID.serviceAccountJson,
            label: String(localized: "Service Account Key"),
            placeholder: "File path or paste JSON",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: BigtableFieldID.authMethod, values: [BigtableAuthMethod.serviceAccount.rawValue])
        ).withHidesUsername(true),
        ConnectionField(
            id: BigtableFieldID.projectId,
            label: String(localized: "Project ID"),
            placeholder: "Taken from the key when empty",
            section: .authentication
        ),
        ConnectionField(
            id: BigtableFieldID.instanceId,
            label: String(localized: "Instance ID"),
            placeholder: "The first instance when empty",
            section: .authentication
        ),
        ConnectionField(
            id: BigtableFieldID.appProfileId,
            label: String(localized: "App Profile ID"),
            placeholder: "default",
            section: .advanced
        )
    ]
}

let bigtableCompletions: [CompletionEntry] = [
    CompletionEntry(label: "GET row", insertText: "GET events/user#42"),
    CompletionEntry(label: "SCAN prefix", insertText: "SCAN events/user#?limit=20"),
    CompletionEntry(label: "READ", insertText: "READ events {\"rowsLimit\": \"20\", \"filter\": {\"cellsPerColumnLimitFilter\": 1}}"),
    CompletionEntry(label: "INSERT row", insertText: "INSERT events/user#42 {\"profile:name\": \"Ann\"}"),
    CompletionEntry(label: "PUT cells", insertText: "PUT events/user#42 {\"profile:name\": \"Ann\"}"),
    CompletionEntry(label: "DELETE row", insertText: "DELETE events/user#42"),
    CompletionEntry(label: "DELETE column", insertText: "DELETE events/user#42 profile:name")
]
