import Foundation
import TableProInfluxDBCore
import TableProPluginKit

enum InfluxDBFieldID {
    static let token = "influxToken"
    static let organization = "influxOrg"
    static let skipTLSVerify = "influxSkipTLSVerify"
}

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
    static let immutableColumns: [String] = [InfluxTypeName.timeColumn]
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .comment]
    static let sqlDialect: SQLDialectDescriptor? = nil

    static let columnTypesByCategory: [String: [String]] = influxDBColumnTypes
    static let additionalConnectionFields: [ConnectionField] = influxDBConnectionFields()
    static var statementCompletions: [CompletionEntry] { influxDBCompletions }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        InfluxDBPluginDriver(config: config)
    }
}

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

let influxDBCompletions: [CompletionEntry] = [
    CompletionEntry(label: "SHOW MEASUREMENTS", insertText: "SHOW MEASUREMENTS"),
    CompletionEntry(label: "SHOW TAG KEYS", insertText: "SHOW TAG KEYS FROM \"measurement\""),
    CompletionEntry(label: "SHOW FIELD KEYS", insertText: "SHOW FIELD KEYS FROM \"measurement\""),
    CompletionEntry(
        label: "SQL: last hour",
        insertText: "SELECT * FROM \"measurement\" WHERE time >= now() - INTERVAL '1 hour' ORDER BY time DESC"
    ),
    CompletionEntry(
        label: "SQL: 5 minute averages",
        insertText: """
        SELECT date_bin(INTERVAL '5 minutes', time) AS bucket, avg("field")
        FROM "measurement"
        WHERE time >= now() - INTERVAL '1 hour'
        GROUP BY bucket
        ORDER BY bucket
        """
    ),
    CompletionEntry(
        label: "InfluxQL: 5 minute averages",
        insertText: "SELECT MEAN(\"field\") FROM \"measurement\" WHERE time > now() - 1h GROUP BY time(5m)"
    ),
    CompletionEntry(
        label: "Flux: last hour",
        insertText: """
        from(bucket: "bucket")
          |> range(start: -1h)
          |> filter(fn: (r) => r._measurement == "measurement")
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
        """
    ),
]

let influxDBColumnTypes: [String: [String]] = [
    "Time": [InfluxTypeName.timestamp],
    "Tag": [InfluxTypeName.tag],
    "Field": [
        InfluxTypeName.float, InfluxTypeName.integer, InfluxTypeName.unsigned,
        InfluxTypeName.string, InfluxTypeName.boolean,
    ],
]
