//
//  PluginMetadataRegistry+DuckDBDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProUtilities

extension PluginMetadataRegistry {
    func duckdbPluginDefaults(
        dialect: SQLDialectDescriptor,
        columnTypes: [String: [String]]
    ) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("DuckDB", PluginMetadataSnapshot(
                displayName: "DuckDB", iconName: "duckdb-icon", defaultPort: 9_494,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "duckdb", parameterStyle: .dollar,
                navigationModel: .standard,
                explainVariants: [
                    ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .indentedText),
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: false, urlSchemes: ["duckdb", "quack"],
                postConnectActions: [.selectSchemaFromLastSession],
                brandColorHex: "#FFD900",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
                structureEditing: SchemaEditingSupport(foreignKeyEdit: .alter),
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: true,
                    supportsExport: true,
                    // Remote mode dials a TCP server, so a forward can carry it. TLS is Quack's own model, set in
                    // the Remote fields, so the built-in SSL section never applies.
                    supportsSSH: true,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameColumn: true,
                    // httpfs checks a server against the system CA bundle when no CA is given, so a URL asking
                    // for TLS with no mode means a verified connection, never Required's unchecked one.
                    verifiesServerWithSystemTrust: true,
                    requestedTLSVerifiesIdentity: true,
                    supportsConnectionPooling: false,
                    localFilePathField: .additionalField("duckdbFilePath"),
                    serverEndpointFields: ServerEndpointFields(hostFieldId: "duckdbHost", portFieldId: "duckdbPort"),
                    fieldsRequiringDriverSupport: ["duckdbSSLMode"],
                    newDatabaseFileExtensions: ["duckdb", "ddb"],
                    readOnlyEnforcement: .sessionDefault
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "main",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["system", "temp"],
                    systemSchemaNames: [],
                    fileExtensions: ["duckdb", "ddb", "parquet", "csv", "tsv", "json", "ndjson"],
                    // Only DuckDB's own storage. The data formats above are recognised by name
                    // alone, because `duckdb_open` picks their reader from the extension and
                    // refuses a Parquet file called anything else.
                    // `DUCK` sits behind the header's eight-byte checksum, followed by the storage
                    // version as a little-endian `uint64`. Four bytes on their own are not enough
                    // to name a format, and `SELECT 'DUCK';` spells them at exactly that offset,
                    // so the version's high six bytes have to be zero as well. Storage versions
                    // are still in the sixties, and a version past 65535 would cost recognition by
                    // content rather than break it.
                    fileSignatures: [.magic("DUCK", at: 8).andZeroes(at: 14, count: 6)],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: dialect,
                    statementCompletions: [],
                    columnTypesByCategory: columnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: Self.duckdbConnectionFields,
                    category: .analytical,
                    tagline: String(localized: "Embedded and remote analytical SQL"),
                    hidesBuiltInPassword: true,
                    hidesBuiltInDatabase: true
                )
            ))
        ]
    }
}
