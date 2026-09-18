import Foundation
import TableProPluginKit
import TableProWeaviateCore

final class WeaviatePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Weaviate Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Weaviate support over the REST API with a GraphQL console"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Weaviate"
    static let databaseDisplayName = "Weaviate"
    static let iconName = "weaviate-icon"
    static let defaultPort = WeaviateConnectionSettings.defaultPort
    static let isDownloadable = true

    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let brandColorHex = "#01B0D3"
    static let queryLanguageName = "GraphQL"
    static let editorLanguage: EditorLanguage = .javascript
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSSH = false
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
    static let immutableColumns: [String] = WeaviateSchema.immutableColumns
    static let defaultPrimaryKeyColumn: String? = WeaviateSchema.uuidColumn
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil

    static let columnTypesByCategory: [String: [String]] = weaviateColumnTypes

    static let additionalConnectionFields: [ConnectionField] = weaviateConnectionFields()

    static var statementCompletions: [CompletionEntry] { weaviateCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        WeaviatePluginDriver(config: config)
    }
}

func weaviateConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: WeaviateFieldID.authMethod,
            label: String(localized: "Auth Method"),
            defaultValue: WeaviateAuthMethod.none.rawValue,
            fieldType: .dropdown(options: [
                .init(value: WeaviateAuthMethod.none.rawValue, label: "None"),
                .init(value: WeaviateAuthMethod.apiKey.rawValue, label: "API Key")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: WeaviateFieldID.apiKey,
            label: String(localized: "API Key"),
            placeholder: "Weaviate API key",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true),
        ConnectionField(
            id: WeaviateFieldID.skipTLSVerify,
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        )
    ]
}

let weaviateCompletions: [CompletionEntry] = [
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

let weaviateColumnTypes: [String: [String]] = [
    "Text": ["text", "text[]", "string", "string[]", "uuid", "uuid[]"],
    "Numeric": ["int", "int[]", "number", "number[]"],
    "Boolean": ["boolean", "boolean[]"],
    "Date": ["date", "date[]"],
    "Structured": ["object", "object[]", "geoCoordinates", "phoneNumber"],
    "Vector": ["vector"]
]
