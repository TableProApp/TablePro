import Foundation
import TableProPluginKit

@objc(KafkaPlugin)
public final class KafkaPlugin: NSObject, DriverPlugin {
    public static let pluginName = "Kafka Driver"
    public static let pluginVersion = KafkaClientInfo.version
    public static let pluginDescription = "Apache Kafka topic and message browser"
    public static let capabilities: [PluginCapability] = [.databaseDriver]

    public static let databaseTypeId = "Kafka"
    public static let databaseDisplayName = "Kafka"
    public static let iconName = "kafka-icon"
    public static let defaultPort = 9_092

    static let singleDatabaseName = "cluster"

    public static var additionalConnectionFields: [ConnectionField] {
        KafkaConnectionField.fields()
    }

    public func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        KafkaPluginDriver(config: config)
    }

    // MARK: - Capability metadata

    public static let brandColorHex = "#231F20"
    public static let queryLanguageName = "KafkaQL"

    /// `EditorLanguage` is `@frozen`, so a literal `.kafka` case would be an ABI break for
    /// every already-built plugin. `.custom` is the extension point, and it costs only
    /// syntax highlighting, which a five-keyword command language does not need.
    public static let editorLanguage: EditorLanguage = .custom("kafkaql")

    public static let connectionMode: ConnectionMode = .network
    public static let requiresAuthentication = false
    public static let navigationModel: NavigationModel = .standard
    public static let urlSchemes = ["kafka"]

    /// A cluster has one flat namespace of topics. Naming the levels honestly is what keeps
    /// the sidebar from promising a hierarchy Kafka does not have.
    public static let tableEntityName = "Topics"
    public static let containerEntityName = "Cluster"
    public static let defaultGroupName = singleDatabaseName
    public static let defaultSchemaName = ""
    public static let databaseGroupingStrategy: GroupingStrategy = .byDatabase
    public static let supportsDatabaseSwitching = false
    public static let supportsSchemaSwitching = false

    public static let systemDatabaseNames: [String] = []

    public static let supportsForeignKeys = false
    public static let supportsTriggers = false
    public static let supportsRoutines = false
    public static let supportsSchemaEditing = false
    public static let supportsImport = false
    public static let supportsExport = true
    public static let supportsHealthMonitor = true
    public static let supportsSSH = true
    public static let supportsSSL = true
    public static let supportsQueryProgress = false
    public static let supportsCascadeDrop = false
    public static let supportsForeignKeyDisable = false
    public static let supportsDropDatabase = false
    public static let supportsDropSchema = false
    public static let isDownloadable = true

    /// A Kafka message is immutable and the log has no update or per-row delete, so every
    /// structural edit is declined. The grid learns the same thing a second way, from the
    /// external-table type each topic carries, which is what refuses an edit before the user
    /// types rather than after they press Save.
    public static let supportsAddColumn = false
    public static let supportsModifyColumn = false
    public static let supportsDropColumn = false
    public static let supportsRenameColumn = false
    public static let supportsAddIndex = false
    public static let supportsDropIndex = false
    public static let supportsModifyPrimaryKey = false
    public static let supportsReadOnlyMode = true

    public static let sqlDialect: SQLDialectDescriptor? = nil
    public static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]

    public static let statementCompletions: [CompletionEntry] = [
        CompletionEntry(label: "CONSUME", insertText: "CONSUME \"topic\" FROM NEWEST LIMIT 100"),
        CompletionEntry(label: "CONSUME FROM OLDEST", insertText: "CONSUME \"topic\" FROM OLDEST LIMIT 100"),
        CompletionEntry(label: "CONSUME FROM OFFSET", insertText: "CONSUME \"topic\" FROM OFFSET 0 LIMIT 100"),
        CompletionEntry(label: "CONSUME FROM TIME", insertText: "CONSUME \"topic\" FROM TIME \"2026-01-01T00:00:00Z\" LIMIT 100"),
        CompletionEntry(label: "CONSUME PARTITION", insertText: "CONSUME \"topic\" PARTITION (0) FROM NEWEST LIMIT 100"),
        CompletionEntry(label: "PRODUCE", insertText: "PRODUCE INTO \"topic\" KEY \"k\" VALUE \"v\""),
        CompletionEntry(label: "SHOW TOPICS", insertText: "SHOW TOPICS"),
        CompletionEntry(label: "SHOW BROKERS", insertText: "SHOW BROKERS"),
        CompletionEntry(label: "SHOW GROUPS", insertText: "SHOW GROUPS"),
        CompletionEntry(label: "SHOW CLUSTER", insertText: "SHOW CLUSTER"),
        CompletionEntry(label: "DESCRIBE GROUP", insertText: "DESCRIBE GROUP \"group\""),
        CompletionEntry(label: "DESCRIBE TOPIC", insertText: "DESCRIBE TOPIC \"topic\"")
    ]

    public static let columnTypesByCategory: [String: [String]] = [
        "Message": ["TEXT", "BLOB", "JSON"],
        "Coordinates": ["INTEGER", "BIGINT", "TIMESTAMP"]
    ]
}
