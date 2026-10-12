import Foundation
import TableProPluginKit

final class HanaPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "SAP HANA Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "SAP HANA SQL support via SAP/go-hdb"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SAP HANA"
    static let databaseDisplayName = HanaMetadata.displayName
    static let iconName = HanaMetadata.iconName
    static let defaultPort = HanaMetadata.defaultPort
    static let additionalConnectionFields = HanaMetadata.connectionFields
    static let brandColorHex = HanaMetadata.brandColorHex
    static let isDownloadable = true
    static let supportsSSL = true
    static let supportsSSH = false
    static let supportsForeignKeys = true
    static let supportsSchemaEditing = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsRenameColumn = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let supportsImport = false
    static let supportsExport = true
    static let supportsHealthMonitor = true
    static let supportsReadOnlyMode = false
    static let supportsQueryProgress = false
    static let supportsCascadeDrop = false
    static let supportsForeignKeyDisable = false
    static let defaultSchemaName = HanaMetadata.defaultSchemaName
    static let schemaEntityName = HanaMetadata.schemaEntityName
    static let containerEntityName = HanaMetadata.containerEntityName
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let columnTypesByCategory = HanaMetadata.columnTypesByCategory
    static let statementCompletions = HanaMetadata.statementCompletions
    static let sqlDialect: SQLDialectDescriptor? = HanaMetadata.sqlDialect
    static let pathFieldRole: PathFieldRole = .database
    static let urlSchemes = ["hdb"]
    static let systemSchemaNames = HanaMetadata.systemSchemaNames
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue, .comment]
    static let explainVariants = [
        ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN PLAN FOR", format: .indentedText)
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        HanaPluginDriver(config: config)
    }
}
