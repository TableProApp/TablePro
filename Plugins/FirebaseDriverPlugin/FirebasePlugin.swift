import Foundation
import TableProFirebaseCore
import TableProPluginKit

final class FirebasePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Firebase Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Cloud Firestore and Firebase Realtime Database over their REST APIs"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Firestore"
    static let realtimeDatabaseTypeId = "Firebase Realtime Database"
    static let additionalDatabaseTypeIds: [String] = ["Firebase Realtime Database"]
    static let databaseDisplayName = "Cloud Firestore"
    static let iconName = "firebase-icon"
    static let defaultPort = 0
    static let isDownloadable = true

    static func driverVariant(for databaseTypeId: String) -> String? {
        databaseTypeId == realtimeDatabaseTypeId ? FirebaseVariant.realtimeDatabase.rawValue : nil
    }

    static let connectionMode: ConnectionMode = .apiOnly
    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = true
    static let brandColorHex = "#FFA000"
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
    static let supportsDocumentEditing = true
    static let supportsFieldRemoval = true
    static let databaseGroupingStrategy: GroupingStrategy = .byDatabase
    static let defaultGroupName = FirebaseConnectionSettings.defaultFirestoreDatabase
    static let tableEntityName = "Collections"
    static let containerEntityName = "Database"
    static let defaultSchemaName = ""
    static let immutableColumns: [String] = [FirebaseColumns.documentName, FirebaseColumns.key]
    static let defaultPrimaryKeyColumn: String? = FirebaseColumns.documentName
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil

    static let columnTypesByCategory: [String: [String]] = firebaseColumnTypes
    static let additionalConnectionFields: [ConnectionField] = firebaseConnectionFields(variant: .firestore)
    static var statementCompletions: [CompletionEntry] { firebaseCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        FirebasePluginDriver(config: config)
    }
}

enum FirebaseColumns {
    static let documentName = FirestoreQueryBuilder.nameField
    static let key = RealtimeDatabaseQueryPlanner.keyColumn
    static let value = RealtimeDatabaseQueryPlanner.valueColumn
}

func firebaseConnectionFields(variant: FirebaseVariant) -> [ConnectionField] {
    var fields: [ConnectionField] = [
        ConnectionField(
            id: FirebaseFieldID.authMethod,
            label: String(localized: "Auth Method"),
            defaultValue: FirebaseAuthMethod.serviceAccount.rawValue,
            fieldType: .dropdown(options: [
                .init(value: FirebaseAuthMethod.serviceAccount.rawValue, label: "Service Account Key"),
                .init(value: FirebaseAuthMethod.applicationDefault.rawValue, label: "Application Default Credentials"),
                .init(value: FirebaseAuthMethod.emulator.rawValue, label: "Emulator (no credentials)")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: FirebaseFieldID.serviceAccountJson,
            label: String(localized: "Service Account Key"),
            placeholder: "File path or paste JSON",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: FirebaseFieldID.authMethod, values: [FirebaseAuthMethod.serviceAccount.rawValue])
        ).withHidesUsername(true),
        ConnectionField(
            id: FirebaseFieldID.projectId,
            label: String(localized: "Project ID"),
            placeholder: "Taken from the key when empty",
            section: .authentication
        )
    ]
    switch variant {
    case .firestore:
        fields.append(ConnectionField(
            id: FirebaseFieldID.firestoreDatabase,
            label: String(localized: "Database"),
            placeholder: FirebaseConnectionSettings.defaultFirestoreDatabase,
            section: .authentication
        ))
    case .realtimeDatabase:
        fields.append(ConnectionField(
            id: FirebaseFieldID.databaseURL,
            label: String(localized: "Database URL"),
            placeholder: "https://<name>.<region>.firebasedatabase.app",
            section: .authentication
        ))
    }
    fields.append(ConnectionField(
        id: FirebaseFieldID.emulatorHost,
        label: String(localized: "Emulator Host"),
        placeholder: variant == .firestore ? "127.0.0.1:8080" : "127.0.0.1:9000",
        required: true,
        section: .authentication,
        visibleWhen: FieldVisibilityRule(fieldId: FirebaseFieldID.authMethod, values: [FirebaseAuthMethod.emulator.rawValue])
    ))
    return fields
}

let firebaseCompletions: [CompletionEntry] = [
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

let firebaseColumnTypes: [String: [String]] = [
    "Text": ["string", "reference"],
    "Numeric": ["integer", "double", "number"],
    "Boolean": ["boolean"],
    "Date": ["timestamp"],
    "Structured": ["map", "array", "object", "geopoint"],
    "Binary": ["bytes"]
]
