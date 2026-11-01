import Foundation
import TableProPluginKit
import TableProQdrantCore

final class QdrantPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Qdrant Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Qdrant support over the REST API"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Qdrant"
    static let databaseDisplayName = "Qdrant"
    static let iconName = "qdrant-icon"
    static let defaultPort = QdrantConnectionSettings.defaultPort
    static let isDownloadable = true

    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let brandColorHex = "#DC244C"
    static let queryLanguageName = "REST"
    static let editorLanguage: EditorLanguage = .javascript
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSSH = true
    static let supportsSSL = true
    static let supportsReadOnlyMode = true
    static let supportsForeignKeyDisable = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "default"
    static let tableEntityName = "Collections"
    static let containerEntityName = "Cluster"
    static let immutableColumns: [String] = [QdrantSchema.idColumn]
    static let defaultPrimaryKeyColumn: String? = QdrantSchema.idColumn
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil

    static let columnTypesByCategory: [String: [String]] = qdrantColumnTypes

    static let additionalConnectionFields: [ConnectionField] = qdrantConnectionFields()

    static var statementCompletions: [CompletionEntry] { qdrantCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        QdrantPluginDriver(config: config)
    }
}

func qdrantConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: QdrantFieldID.apiKey,
            label: String(localized: "API Key"),
            placeholder: "Qdrant API key",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true)
    ]
}

let qdrantCompletions: [CompletionEntry] = [
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

let qdrantColumnTypes: [String: [String]] = [
    "Text": ["keyword", "text", "string", "uuid"],
    "Numeric": ["integer", "float"],
    "Boolean": ["bool"],
    "Date": ["datetime"],
    "Structured": ["geo", "object", "array", "json"],
    "Vector": ["vector", "multivector", "sparse_vector"]
]
