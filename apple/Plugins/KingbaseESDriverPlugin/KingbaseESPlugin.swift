import Foundation
import TableProPluginKit

final class KingbaseESPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "KingbaseES Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "KingbaseES database support via libpq"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "KingbaseES"
    static let databaseDisplayName = "KingbaseES"
    static let iconName = "cylinder"
    static let defaultPort = 54_321
    static let isDownloadable = true
    static let urlSchemes = ["kingbase", "kingbase8"]
    static let brandColorHex = "#C9141E"
    static let systemDatabaseNames = PostgreSQLPlugin.systemDatabaseNames
    static let systemSchemaNames = [
        "pg_catalog", "information_schema", "pg_toast", "sys_catalog", "sys", "anon", "dbms_job", "dbms_scheduler",
        "dbms_sql", "kdb_schedule", "perf", "pg_bitmapindex", "src_restrict", "sys_hm", "sysaudit", "sysmac", "wmsys",
        "xlog_record_read"
    ]

    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "usePgpass",
            label: String(localized: "Use ~/.pgpass"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .authentication,
            hidesPassword: true
        ),
        ConnectionField(
            id: "connectionOptions",
            label: String(localized: "Connection Options"),
            fieldType: .text,
            section: .advanced
        )
    ]

    static let supportsSchemaSwitching = PostgreSQLPlugin.supportsSchemaSwitching
    static let postConnectActions = PostgreSQLPlugin.postConnectActions
    static let explainVariants = PostgreSQLPlugin.explainVariants
    static let databaseGroupingStrategy = PostgreSQLPlugin.databaseGroupingStrategy
    static let columnTypesByCategory = PostgreSQLPlugin.columnTypesByCategory
    static let supportsCascadeDrop = PostgreSQLPlugin.supportsCascadeDrop
    static let supportsForeignKeyDisable = PostgreSQLPlugin.supportsForeignKeyDisable
    static let requiresReconnectForDatabaseSwitch = PostgreSQLPlugin.requiresReconnectForDatabaseSwitch
    static let parameterStyle = PostgreSQLPlugin.parameterStyle
    static let supportsDropDatabase = PostgreSQLPlugin.supportsDropDatabase
    static let supportsRenameTable = PostgreSQLPlugin.supportsRenameTable
    static let supportsRenameDatabase = PostgreSQLPlugin.supportsRenameDatabase
    static let supportsRenameSchema = PostgreSQLPlugin.supportsRenameSchema
    static let supportsDropSchema = PostgreSQLPlugin.supportsDropSchema
    static let supportsCreateSchema = PostgreSQLPlugin.supportsCreateSchema
    static let supportsSchemaOwner = PostgreSQLPlugin.supportsSchemaOwner
    static let supportsSchemaPrivileges = PostgreSQLPlugin.supportsSchemaPrivileges
    static let supportsTriggers = PostgreSQLPlugin.supportsTriggers
    static let supportsRoutines = PostgreSQLPlugin.supportsRoutines
    static let supportsDatabaseTriggerBrowse = PostgreSQLPlugin.supportsDatabaseTriggerBrowse
    static let supportsUserDefinedTypeBrowse = PostgreSQLPlugin.supportsUserDefinedTypeBrowse
    static let supportsTriggerEditing = PostgreSQLPlugin.supportsTriggerEditing
    static let structureColumnFields = PostgreSQLPlugin.structureColumnFields
    static let supportsCheckConstraints = PostgreSQLPlugin.supportsCheckConstraints
    static let supportsCheckConstraintEditing = PostgreSQLPlugin.supportsCheckConstraintEditing
    static let supportsGeneratedColumns = PostgreSQLPlugin.supportsGeneratedColumns
    static let sqlDialect = PostgreSQLPlugin.sqlDialect

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        KingbaseESPluginDriver(config: config)
    }
}
