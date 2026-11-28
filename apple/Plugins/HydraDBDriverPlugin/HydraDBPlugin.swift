import Foundation
import TableProNeo4jCore
import TableProPluginKit

final class HydraDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "HydraDB Driver"
    static let pluginVersion = Bundle(for: HydraDBPlugin.self)
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    static let pluginDescription = "HydraDB over the Bolt protocol with Cypher"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "HydraDB"
    static let databaseDisplayName = "HydraDB"
    static let iconName = "server.rack"
    static let defaultPort = 7_687
    static let isDownloadable = true

    static let connectionMode: ConnectionMode = .network
    static let navigationModel: NavigationModel = .standard
    static let urlSchemes = [String]()
    static let brandColorHex = "#018BFF"
    static let queryLanguageName = "Cypher"
    static let editorLanguage: EditorLanguage = .custom("cypher")
    static let parameterStyle: ParameterStyle = .dollar

    static let supportsSSH = true
    static let supportsSSL = true
    static let sslModesThroughTunnel: [SSLMode] = SSLMode.allCases
    static let supportsImport = false
    static let supportsExport = true
    static let supportsReadOnlyMode = false
    static let supportsHealthMonitor = true
    static let supportsSchemaEditing = false
    static let supportsForeignKeys = false
    static let supportsForeignKeyDisable = false
    static let supportsTriggers = false
    static let supportsRoutines = false
    static let supportsDropDatabase = false
    static let supportsDropSchema = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsRenameColumn = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false

    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let defaultGroupName = "default"
    static let defaultSchemaName = Neo4jEntityKind.node.schemaName
    static let systemDatabaseNames = [String]()
    static let tableEntityName = "Types"
    static let containerEntityName = "Database"
    static let schemaEntityName = "Kind"
    static let defaultPrimaryKeyColumn: String? = Neo4jCypher.idColumn
    static let immutableColumns = [Neo4jCypher.idColumn, Neo4jCypher.labelsColumn, Neo4jCypher.startColumn, Neo4jCypher.endColumn]
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil

    static let columnTypesByCategory: [String: [String]] = hydraDBColumnTypes
    static var statementCompletions: [CompletionEntry] { hydraDBCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        HydraDBPluginDriver(config: config)
    }
}

let hydraDBColumnTypes: [String: [String]] = [
    "Scalar": ["STRING", "INTEGER", "FLOAT", "BOOLEAN"],
    "Structured": ["LIST", "MAP"],
    "Graph": ["NODE", "RELATIONSHIP"]
]

let hydraDBCompletions: [CompletionEntry] = [
    CompletionEntry(label: "MATCH nodes", insertText: "MATCH (n:Label) RETURN n LIMIT 25"),
    CompletionEntry(label: "MATCH relationships", insertText: "MATCH ()-[r:TYPE]->() RETURN r LIMIT 25"),
    CompletionEntry(label: "db.labels", insertText: "CALL db.labels()"),
    CompletionEntry(label: "db.relationshipTypes", insertText: "CALL db.relationshipTypes()")
]
