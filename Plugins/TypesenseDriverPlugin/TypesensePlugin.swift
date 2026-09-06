//
//  TypesensePlugin.swift
//  TypesenseDriverPlugin
//
//  Typesense driver plugin over the REST API with a request console.
//

import Foundation
import TableProPluginKit

final class TypesensePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Typesense Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Typesense support over the REST API with a request console"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    /// Every string comparison in Typesense ignores case and nothing turns that off. `.driverManaged`
    /// would leave the filter bar's case toggle enabled over a choice the driver cannot honour, so
    /// the style has to say the engine cannot express one.
    static let caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle = .unsupported

    static let databaseTypeId = "Typesense"
    static let databaseDisplayName = "Typesense"
    static let iconName = "typesense-icon"
    static let defaultPort = 8_108
    static let isDownloadable = true

    static let apiKeyFieldId = "typesenseApiKey"
    static let skipTLSVerifyFieldId = "typesenseSkipTLSVerify"

    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let brandColorHex = "#1035BC"
    static let queryLanguageName = "Typesense API"
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
    static let immutableColumns: [String] = ["id"]
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]

    static let columnTypesByCategory: [String: [String]] = [
        "Text": ["string", "string[]", "string*"],
        "Numeric": ["int32", "int32[]", "int64", "int64[]", "float", "float[]"],
        "Boolean": ["bool", "bool[]"],
        "Geo": ["geopoint", "geopoint[]", "geopolygon"],
        "Structured": ["object", "object[]"],
        "Specialized": ["auto", "image"],
    ]

    static let additionalConnectionFields: [ConnectionField] = typesenseConnectionFields()

    static var statementCompletions: [CompletionEntry] { typesenseCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        TypesensePluginDriver(config: config)
    }
}

/// Typesense authenticates with one API key and has no user accounts, so the key replaces both
/// built-in credential rows rather than sitting beside an empty Username.
func typesenseConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: TypesensePlugin.apiKeyFieldId,
            label: String(localized: "API Key"),
            placeholder: "The key the server was started with",
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true),
        ConnectionField(
            id: TypesensePlugin.skipTLSVerifyFieldId,
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        ),
    ]
}

let typesenseCompletions: [CompletionEntry] = [
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
