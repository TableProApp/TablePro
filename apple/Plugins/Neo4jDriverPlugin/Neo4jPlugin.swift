import Foundation
import TableProNeo4jCore
import TableProPluginKit

final class Neo4jPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Neo4j Driver"
    static let pluginVersion = Bundle(for: Neo4jPlugin.self)
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    static let pluginDescription = "Neo4j over the Bolt protocol with Cypher"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Neo4j"
    static let databaseDisplayName = "Neo4j"
    static let iconName = "neo4j-icon"
    static let defaultPort = 7_687
    static let isDownloadable = true

    static let connectionMode: ConnectionMode = .network
    static let navigationModel: NavigationModel = .standard
    static let urlSchemes = ["neo4j", "neo4j+s", "neo4j+ssc", "bolt", "bolt+s", "bolt+ssc"]
    static let brandColorHex = "#018BFF"
    static let queryLanguageName = "Cypher"
    static let editorLanguage: EditorLanguage = .custom("cypher")
    static let parameterStyle: ParameterStyle = .dollar

    static let supportsSSH = true
    static let supportsSSL = true
    static let supportsImport = false
    static let supportsExport = true
    static let supportsReadOnlyMode = true
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

    static let supportsDatabaseSwitching = true
    static let supportsSchemaSwitching = true
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let defaultGroupName = "neo4j"
    static let defaultSchemaName = Neo4jEntityKind.node.schemaName
    static let systemDatabaseNames = ["system"]
    static let tableEntityName = "Types"
    static let containerEntityName = "Database"
    static let schemaEntityName = "Kind"
    static let defaultPrimaryKeyColumn: String? = Neo4jCypher.idColumn
    static let immutableColumns = [Neo4jCypher.idColumn, Neo4jCypher.labelsColumn, Neo4jCypher.startColumn, Neo4jCypher.endColumn]
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil

    static let columnTypesByCategory: [String: [String]] = neo4jColumnTypes
    static var statementCompletions: [CompletionEntry] { neo4jCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        Neo4jPluginDriver(config: config)
    }
}

let neo4jColumnTypes: [String: [String]] = [
    "Scalar": ["STRING", "INTEGER", "FLOAT", "BOOLEAN", "BYTES"],
    "Temporal": ["DATE", "LOCAL TIME", "ZONED TIME", "LOCAL DATETIME", "ZONED DATETIME", "DURATION"],
    "Spatial": ["POINT"],
    "Structured": ["LIST", "MAP"],
    "Graph": ["NODE", "RELATIONSHIP", "PATH"]
]

let neo4jCompletions: [CompletionEntry] = [
    CompletionEntry(label: "MATCH nodes", insertText: "MATCH (n:Label) RETURN n LIMIT 25"),
    CompletionEntry(label: "MATCH relationships", insertText: "MATCH (a)-[r:TYPE]->(b) RETURN a, r, b LIMIT 25"),
    CompletionEntry(label: "MATCH path", insertText: "MATCH p = (a)-[*1..3]->(b) RETURN p LIMIT 25"),
    CompletionEntry(label: "CREATE node", insertText: "CREATE (n:Label {name: 'value'}) RETURN n"),
    CompletionEntry(label: "MERGE node", insertText: "MERGE (n:Label {id: 1}) RETURN n"),
    CompletionEntry(label: "SHOW DATABASES", insertText: "SHOW DATABASES"),
    CompletionEntry(label: "SHOW INDEXES", insertText: "SHOW INDEXES"),
    CompletionEntry(label: "SHOW CONSTRAINTS", insertText: "SHOW CONSTRAINTS"),
    CompletionEntry(label: "db.labels", insertText: "CALL db.labels()"),
    CompletionEntry(label: "db.relationshipTypes", insertText: "CALL db.relationshipTypes()"),
    CompletionEntry(label: "db.schema.visualization", insertText: "CALL db.schema.visualization()")
]
