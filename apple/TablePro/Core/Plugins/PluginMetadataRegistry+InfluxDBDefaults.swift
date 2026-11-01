import Foundation
import TableProInfluxDBCore
import TableProPluginKit

extension PluginMetadataRegistry {
    func influxDBPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("InfluxDB", PluginMetadataSnapshot(
                displayName: "InfluxDB", iconName: "influxdb-icon", defaultPort: 8_086,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#22ADF6",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
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
                    supportsAddColumn: false,
                    supportsModifyColumn: false,
                    supportsDropColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsPrincipalConnectionLimit: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Measurements",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: InfluxCatalogDecoder.systemDatabaseNames,
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: InfluxCompletions.entries.map {
                        CompletionEntry(label: $0.label, insertText: $0.insertText)
                    },
                    columnTypesByCategory: InfluxCompletions.columnTypesByCategory
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: influxDBConnectionFields(),
                    category: .analytical,
                    tagline: String(localized: "Time series database"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: false
                )
            ))
        ]
    }
}

// Kept identical to `influxDBConnectionFields()` in the plugin.
private func influxDBConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: InfluxConnectionFieldID.token,
            label: String(localized: "Token"),
            placeholder: "API token",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true
        ).withHidesUsername(true),
        ConnectionField(
            id: InfluxConnectionFieldID.organization,
            label: String(localized: "Organization"),
            placeholder: "InfluxDB 2 only, optional with one organization",
            section: .connection
        ),
        ConnectionField(
            id: InfluxConnectionFieldID.skipTLSVerify,
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        )
    ]
}
