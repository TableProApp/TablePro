import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    /// One plugin serves both types. The Realtime Database is its variant, so its entry here is the
    /// one the app uses even once the plugin loads, which is how it gets its own fields and names.
    func firebasePluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Firestore", PluginMetadataSnapshot(
                displayName: "Cloud Firestore", iconName: "firebase-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#FFA000",
                queryLanguageName: "REST", editorLanguage: .javascript,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
                capabilities: firebaseCapabilities,
                schema: firebaseSchema(tableEntityName: "Collections", primaryKey: "__name__", defaultGroupName: "(default)"),
                editor: firebaseEditor,
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: firebaseConnectionFields(realtimeDatabase: false),
                    category: .document,
                    tagline: String(localized: "Serverless document database from Google"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            )),
            ("Firebase Realtime Database", PluginMetadataSnapshot(
                displayName: "Firebase Realtime Database", iconName: "firebase-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#FFA000",
                queryLanguageName: "REST", editorLanguage: .javascript,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
                capabilities: firebaseCapabilities,
                schema: firebaseSchema(tableEntityName: "Nodes", primaryKey: "$key", defaultGroupName: "default"),
                editor: firebaseEditor,
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: firebaseConnectionFields(realtimeDatabase: true),
                    category: .document,
                    tagline: String(localized: "JSON tree database that syncs in real time"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            ))
        ]
    }

    private var firebaseCapabilities: PluginMetadataSnapshot.CapabilityFlags {
        PluginMetadataSnapshot.CapabilityFlags(
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
            supportsAddColumn: false,
            supportsModifyColumn: false,
            supportsDropColumn: false,
            supportsAddIndex: false,
            supportsDropIndex: false,
            supportsModifyPrimaryKey: false,
            supportsOpportunisticTLS: false,
            supportsPrincipalConnectionLimit: false
        )
    }

    private func firebaseSchema(tableEntityName: String, primaryKey: String, defaultGroupName: String) -> PluginMetadataSnapshot.SchemaInfo {
        PluginMetadataSnapshot.SchemaInfo(
            defaultSchemaName: "",
            defaultGroupName: defaultGroupName,
            tableEntityName: tableEntityName,
            containerEntityName: "Database",
            defaultPrimaryKeyColumn: primaryKey,
            immutableColumns: ["__name__", "$key"],
            systemDatabaseNames: [],
            systemSchemaNames: [],
            fileExtensions: [],
            databaseGroupingStrategy: .byDatabase,
            structureColumnFields: [.name, .type, .nullable]
        )
    }

    private var firebaseEditor: PluginMetadataSnapshot.EditorConfig {
        PluginMetadataSnapshot.EditorConfig(
            sqlDialect: nil,
            statementCompletions: firebaseCompletions,
            columnTypesByCategory: firebaseColumnTypes
        )
    }
}

private let firebaseCompletions: [CompletionEntry] = [
    CompletionEntry(label: "GET collection", insertText: "GET users?pageSize=20"),
    CompletionEntry(label: "GET document", insertText: "GET users/alice"),
    CompletionEntry(
        label: "QUERY",
        insertText: """
        QUERY {
          "structuredQuery": {
            "from": [{"collectionId": "users"}],
            "where": {"fieldFilter": {"field": {"fieldPath": "age"}, "op": "GREATER_THAN", "value": {"integerValue": "30"}}},
            "limit": 20
          }
        }
        """
    ),
    CompletionEntry(label: "PATCH", insertText: "PATCH users/alice?updateMask=age {\"age\": 31}"),
    CompletionEntry(label: "POST", insertText: "POST users {\"name\": \"Bob\"}"),
    CompletionEntry(label: "DELETE", insertText: "DELETE users/alice"),
    CompletionEntry(label: "GET node", insertText: "GET /chats?orderBy=\"$key\"&limitToFirst=20"),
    CompletionEntry(label: "GET shallow", insertText: "GET /?shallow=true"),
    CompletionEntry(label: "PUT node", insertText: "PUT /config/maintenance false")
]

private let firebaseColumnTypes: [String: [String]] = [
    "Text": ["string", "reference"],
    "Numeric": ["integer", "double", "number"],
    "Boolean": ["boolean"],
    "Date": ["timestamp"],
    "Structured": ["map", "array", "object", "geopoint"],
    "Binary": ["bytes"]
]

func firebaseConnectionFields(realtimeDatabase: Bool) -> [ConnectionField] {
    let authMethod = "fbAuthMethod"
    var fields: [ConnectionField] = [
        ConnectionField(
            id: authMethod,
            label: String(localized: "Auth Method"),
            defaultValue: "serviceAccount",
            fieldType: .dropdown(options: [
                .init(value: "serviceAccount", label: "Service Account Key"),
                .init(value: "adc", label: "Application Default Credentials"),
                .init(value: "emulator", label: "Emulator (no credentials)")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "fbServiceAccountJson",
            label: String(localized: "Service Account Key"),
            placeholder: "File path or paste JSON",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: authMethod, values: ["serviceAccount"])
        ).withHidesUsername(true),
        ConnectionField(
            id: "fbProjectId",
            label: String(localized: "Project ID"),
            placeholder: "Taken from the key when empty",
            section: .authentication
        )
    ]
    if realtimeDatabase {
        fields.append(ConnectionField(
            id: "fbDatabaseURL",
            label: String(localized: "Database URL"),
            placeholder: "https://<name>.<region>.firebasedatabase.app",
            section: .authentication
        ))
    } else {
        fields.append(ConnectionField(
            id: "fbDatabaseId",
            label: String(localized: "Database"),
            placeholder: "(default)",
            section: .authentication
        ))
    }
    fields.append(ConnectionField(
        id: "fbEmulatorHost",
        label: String(localized: "Emulator Host"),
        placeholder: realtimeDatabase ? "127.0.0.1:9000" : "127.0.0.1:8080",
        required: true,
        section: .authentication,
        visibleWhen: FieldVisibilityRule(fieldId: authMethod, values: ["emulator"])
    ))
    return fields
}
