//
//  PluginMetadataRegistry+TursoDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    /// The curated snapshot for Turso.
    ///
    /// Turso is served by the libSQL plugin, which declares it in `additionalDatabaseTypeIds`.
    /// Until that plugin is installed there was nothing to answer for the type, so Turso was
    /// absent from the New Connection picker and there was no way to create the connection that
    /// would trigger the install. Installing libSQL then registered Turso from the plugin's own
    /// snapshot, which gave it libSQL's icon and libSQL's tagline: two rows describing the same
    /// thing in the same words.
    ///
    /// ScyllaDB is the precedent. It is an alias of Cassandra in `reverseTypeIndex` and carries a
    /// curated entry of its own all the same, because an alias still needs a name, an icon and a
    /// tagline that are its own. Every other alias does the same. Turso was the only one that
    /// did not, which is why it was the only type missing from `allRegisteredTypeIds()`.
    ///
    /// The connection fields are libSQL's exactly, including the local-file mode. The driver
    /// reads `libsqlMode` and treats anything but `local` as remote, so a narrower list would
    /// still connect, but `ConnectionStorage` and `ConnectionExportService` derive Keychain
    /// migration and export redaction from this list and a Turso connection saved in local mode
    /// already exists in the field.
    func tursoPluginDefaults(
        dialect: SQLDialectDescriptor,
        columnTypes: [String: [String]]
    ) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Turso", PluginMetadataSnapshot(
                displayName: "Turso", iconName: "libsql-icon", defaultPort: 0,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "turso", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(
                        id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN", format: .sqliteQueryPlan
                    )
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["turso"], postConnectActions: [],
                brandColorHex: "#4FF8D2",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                columnReorder: .rebuild,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsModifyColumn: false,
                    supportsRenameColumn: true,
                    localFilePathField: .additionalField("libsqlFilePath")
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "main",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: dialect,
                    statementCompletions: [],
                    columnTypesByCategory: columnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "libsqlMode",
                            label: String(localized: "Connection Mode"),
                            defaultValue: "remote",
                            fieldType: .dropdown(options: [
                                ConnectionField.DropdownOption(
                                    value: "remote",
                                    label: String(localized: "Remote (Turso)")
                                ),
                                ConnectionField.DropdownOption(
                                    value: "local",
                                    label: String(localized: "Local File")
                                )
                            ]),
                            section: .authentication,
                            hidesPassword: true
                        ),
                        ConnectionField(
                            id: "databaseUrl",
                            label: String(localized: "Database URL"),
                            placeholder: "https://your-db.turso.io",
                            required: true,
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "libsqlMode", values: ["remote"])
                        ),
                        ConnectionField(
                            id: "libsqlFilePath",
                            label: String(localized: "Database File"),
                            placeholder: "/path/to/database.db",
                            required: true,
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "libsqlMode", values: ["local"])
                        )
                    ],
                    category: .cloud,
                    tagline: String(localized: "Hosted libSQL over HTTP")
                )
            )),
        ]
    }
}
