import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    func memcachedPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Memcached", PluginMetadataSnapshot(
                displayName: "Memcached", iconName: "memorychip", defaultPort: 11_211,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "memcached", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["memcached"], postConnectActions: [],
                brandColorHex: "#2A7AB0",
                queryLanguageName: "Memcached", editorLanguage: .bash,
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
                    supportsOpportunisticTLS: false,
                    supportsColumnSort: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Keys",
                    containerEntityName: "Server",
                    defaultPrimaryKeyColumn: "Key",
                    immutableColumns: ["Key"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: memcachedCompletions,
                    columnTypesByCategory: ["String": ["String"], "Integer": ["Int64"]]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [],
                    category: .keyValue,
                    tagline: String(localized: "In-memory key-value cache"),
                    hidesBuiltInDatabase: true
                )
            ))
        ]
    }
}

private let memcachedCompletions: [CompletionEntry] = [
    "get", "gets", "gat", "set", "add", "replace", "append", "prepend", "cas", "touch", "delete", "incr", "decr",
].map { CompletionEntry(label: $0, insertText: "\($0) ") } + [
    "flush_all", "stats", "stats items", "stats slabs", "stats settings", "version", "lru_crawler metadump all",
].map { CompletionEntry(label: $0, insertText: $0) }
