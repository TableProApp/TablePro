import Foundation
import TableProPluginKit

final class MemcachedPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Memcached Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Memcached support over the text protocol"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Memcached"
    static let databaseDisplayName = "Memcached"
    static let iconName = "memorychip"
    static let defaultPort = 11_211
    static let isDownloadable = true

    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let urlSchemes: [String] = ["memcached"]
    static let brandColorHex = "#2A7AB0"
    static let queryLanguageName = "Memcached"
    static let editorLanguage: EditorLanguage = .bash
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let supportsSSL = true
    static let tableEntityName = "Keys"
    static let supportsForeignKeyDisable = false
    static let supportsReadOnlyMode = true
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "default"
    static let defaultPrimaryKeyColumn: String? = "Key"
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil
    static let caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle = .driverManaged
    static let columnTypesByCategory: [String: [String]] = ["String": ["String"], "Integer": ["Int64"]]

    /// The one table the sidebar shows. Memcached has no namespaces, so every key lives in it.
    static let keysTable = "keys"

    static var statementCompletions: [CompletionEntry] {
        [
            CompletionEntry(label: "get", insertText: "get "),
            CompletionEntry(label: "gets", insertText: "gets "),
            CompletionEntry(label: "gat", insertText: "gat "),
            CompletionEntry(label: "set", insertText: "set "),
            CompletionEntry(label: "add", insertText: "add "),
            CompletionEntry(label: "replace", insertText: "replace "),
            CompletionEntry(label: "append", insertText: "append "),
            CompletionEntry(label: "prepend", insertText: "prepend "),
            CompletionEntry(label: "cas", insertText: "cas "),
            CompletionEntry(label: "touch", insertText: "touch "),
            CompletionEntry(label: "delete", insertText: "delete "),
            CompletionEntry(label: "incr", insertText: "incr "),
            CompletionEntry(label: "decr", insertText: "decr "),
            CompletionEntry(label: "flush_all", insertText: "flush_all"),
            CompletionEntry(label: "stats", insertText: "stats"),
            CompletionEntry(label: "stats items", insertText: "stats items"),
            CompletionEntry(label: "stats slabs", insertText: "stats slabs"),
            CompletionEntry(label: "stats settings", insertText: "stats settings"),
            CompletionEntry(label: "version", insertText: "version"),
            CompletionEntry(label: "lru_crawler metadump all", insertText: "lru_crawler metadump all"),
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MemcachedPluginDriver(config: config)
    }
}
