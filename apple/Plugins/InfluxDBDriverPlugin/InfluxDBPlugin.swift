import Foundation
import TableProInfluxDBCore
import TableProPluginKit

typealias InfluxDBFieldID = InfluxConnectionFieldID

final class InfluxDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "InfluxDB Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "InfluxDB 2 and 3 over the HTTP API, with SQL, InfluxQL and Flux"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "InfluxDB"
    static let databaseDisplayName = "InfluxDB"
    static let iconName = "influxdb-icon"
    static let defaultPort = 8_086
    static let isDownloadable = true

    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let brandColorHex = "#22ADF6"
    static let queryLanguageName = "SQL"
    static let editorLanguage: EditorLanguage = .sql
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = true
    static let requiresReconnectForDatabaseSwitch = false
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSSH = true
    static let supportsSSL = true
    static let supportsReadOnlyMode = true
    static let supportsHealthMonitor = true
    static let supportsForeignKeyDisable = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "default"
    static let tableEntityName = "Measurements"
    static let containerEntityName = "Database"
    static let systemDatabaseNames: [String] = InfluxCatalogDecoder.systemDatabaseNames
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .comment]
    static let sqlDialect: SQLDialectDescriptor? = nil

    static let columnTypesByCategory: [String: [String]] = InfluxCompletions.columnTypesByCategory
    static let additionalConnectionFields: [ConnectionField] = influxDBConnectionFields()
    static var statementCompletions: [CompletionEntry] {
        InfluxCompletions.entries.map { CompletionEntry(label: $0.label, insertText: $0.insertText) }
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        InfluxDBPluginDriver(config: config)
    }
}

// Kept identical to `influxDBConnectionFields()` in the app's built-in metadata, which the form shows before the
// plugin loads.
func influxDBConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: InfluxDBFieldID.token,
            label: String(localized: "Token"),
            placeholder: "API token",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true),
        ConnectionField(
            id: InfluxDBFieldID.organization,
            label: String(localized: "Organization"),
            placeholder: "InfluxDB 2 only, optional with one organization",
            section: .connection
        ),
        ConnectionField(
            id: InfluxDBFieldID.skipTLSVerify,
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        ),
    ]
}
