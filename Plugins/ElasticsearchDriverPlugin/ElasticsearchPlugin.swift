//
//  ElasticsearchPlugin.swift
//  ElasticsearchDriverPlugin
//
//  Elasticsearch driver plugin via the REST API with a Query DSL console.
//

import Foundation
import TableProPluginKit

final class ElasticsearchPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Elasticsearch Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Elasticsearch support via the REST API with a Query DSL console"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Elasticsearch"
    static let databaseDisplayName = "Elasticsearch"
    static let iconName = "elasticsearch-icon"
    static let defaultPort = 9200
    static let isDownloadable = true

    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let brandColorHex = "#FEC514"
    static let queryLanguageName = "Query DSL"
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
    static let tableEntityName = "Indices"
    static let containerEntityName = "Cluster"
    static let immutableColumns: [String] = ["_id", "_index", "_score"]
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]

    static let columnTypesByCategory: [String: [String]] = [
        "Text": ["text", "keyword", "match_only_text", "search_as_you_type"],
        "Numeric": ["long", "integer", "short", "byte", "double", "float", "half_float", "scaled_float", "unsigned_long"],
        "Boolean": ["boolean"],
        "Date": ["date", "date_nanos"],
        "Binary": ["binary"],
        "Range": ["integer_range", "float_range", "long_range", "double_range", "date_range", "ip_range"],
        "Geo": ["geo_point", "geo_shape", "point", "shape"],
        "Structured": ["object", "nested", "flattened", "join"],
        "Specialized": ["ip", "completion", "token_count", "dense_vector", "rank_feature", "rank_features"],
    ]

    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "esAuthMethod",
            label: String(localized: "Auth Method"),
            defaultValue: "basic",
            fieldType: .dropdown(options: [
                .init(value: "basic", label: "Username & Password"),
                .init(value: "apiKey", label: "API Key"),
                .init(value: "none", label: "None"),
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "esApiKey",
            label: String(localized: "API Key"),
            placeholder: "Base64-encoded API key",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "esAuthMethod", values: ["apiKey"])
        ),
        ConnectionField(
            id: "esSkipTLSVerify",
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        ),
    ]

    static var statementCompletions: [CompletionEntry] {
        [
            CompletionEntry(label: "GET /_search", insertText: "GET /_search\n{\n  \"query\": {\n    \"match_all\": {}\n  }\n}"),
            CompletionEntry(label: "GET /_cat/indices", insertText: "GET /_cat/indices?format=json"),
            CompletionEntry(label: "GET /_cluster/health", insertText: "GET /_cluster/health"),
            CompletionEntry(label: "GET /_mapping", insertText: "GET /_mapping"),
            CompletionEntry(label: "match", insertText: "\"match\": { \"field\": \"value\" }"),
            CompletionEntry(label: "match_all", insertText: "\"match_all\": {}"),
            CompletionEntry(label: "term", insertText: "\"term\": { \"field\": \"value\" }"),
            CompletionEntry(label: "terms", insertText: "\"terms\": { \"field\": [\"a\", \"b\"] }"),
            CompletionEntry(label: "range", insertText: "\"range\": { \"field\": { \"gte\": 0, \"lte\": 100 } }"),
            CompletionEntry(label: "bool", insertText: "\"bool\": {\n  \"must\": [],\n  \"filter\": [],\n  \"must_not\": [],\n  \"should\": []\n}"),
            CompletionEntry(label: "exists", insertText: "\"exists\": { \"field\": \"field\" }"),
            CompletionEntry(label: "aggs", insertText: "\"aggs\": {\n  \"name\": {\n    \"terms\": { \"field\": \"field\" }\n  }\n}"),
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        ElasticsearchPluginDriver(config: config)
    }
}
