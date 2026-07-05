//
//  PluginMetadataRegistry+ElasticsearchDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func elasticsearchPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Elasticsearch", PluginMetadataSnapshot(
                displayName: "Elasticsearch", iconName: "elasticsearch-icon", defaultPort: 9_200,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#FEC514",
                queryLanguageName: "Query DSL", editorLanguage: .javascript,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Indices",
                    containerEntityName: "Cluster",
                    defaultPrimaryKeyColumn: "_id",
                    immutableColumns: ["_id", "_index", "_score"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: elasticsearchCompletions,
                    columnTypesByCategory: elasticsearchColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: elasticsearchConnectionFields(),
                    category: .document,
                    tagline: String(localized: "Search and analytics engine")
                )
            )),
        ]
    }
}

private let elasticsearchCompletions: [CompletionEntry] = [
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

private let elasticsearchColumnTypes: [String: [String]] = [
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

func elasticsearchConnectionFields() -> [ConnectionField] {
    [
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
}
