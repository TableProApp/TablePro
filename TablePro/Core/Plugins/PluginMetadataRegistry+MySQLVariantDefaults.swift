//
//  PluginMetadataRegistry+MySQLVariantDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    static let mysqlVariantExplainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .plainText),
        ExplainVariant(id: "explain-analyze", label: "EXPLAIN ANALYZE", sqlPrefix: "EXPLAIN ANALYZE", format: .plainText),
    ]

    static let databendRowMatchExcludedTypePrefixes = [
        "ARRAY", "MAP", "TUPLE", "VARIANT", "JSON", "BITMAP", "BINARY", "GEOMETRY", "GEOGRAPHY", "VECTOR",
    ]

    static let databendColumnTypes: [String: [String]] = [
        "Integer": [
            "TINYINT", "SMALLINT", "INT", "BIGINT",
            "TINYINT UNSIGNED", "SMALLINT UNSIGNED", "INT UNSIGNED", "BIGINT UNSIGNED",
        ],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL"],
        "String": ["VARCHAR"],
        "Date": ["DATE", "TIMESTAMP", "INTERVAL"],
        "Binary": ["BINARY"],
        "Boolean": ["BOOLEAN"],
        "Semi-structured": ["VARIANT", "ARRAY", "MAP", "TUPLE", "BITMAP"],
        "Spatial": ["GEOMETRY", "GEOGRAPHY"],
    ]

    static func tidbColumnTypes(from mysqlColumnTypes: [String: [String]]) -> [String: [String]] {
        mysqlColumnTypes.filter { $0.key != "Spatial" }
    }

    static func mysqlVariantDefaults(
        dialect: SQLDialectDescriptor,
        mysqlColumnTypes: [String: [String]],
        idleReleaseField: ConnectionField
    ) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("TiDB", PluginMetadataSnapshot(
            displayName: "TiDB", iconName: "tidb-icon", defaultPort: 4_000,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "tidb", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: mysqlVariantExplainVariants, pathFieldRole: .database,
            supportsHealthMonitor: true, urlSchemes: ["tidb"], postConnectActions: [.selectDatabaseFromLastSession],
            brandColorHex: "#DE1A2D",
            queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            structureEditing: SchemaEditingSupport(columnReorder: .alter, foreignKeyEdit: .alter),
            capabilities: PluginMetadataSnapshot.CapabilityFlags(
                supportsSchemaSwitching: false,
                supportsImport: true,
                supportsExport: true,
                supportsSSH: true,
                supportsSSL: true,
                supportsCascadeDrop: false,
                supportsForeignKeyDisable: true,
                supportsReadOnlyMode: true,
                supportsQueryProgress: false,
                requiresReconnectForDatabaseSwitch: false,
                supportsDropDatabase: true,
                supportsRenameTable: true,
                supportsRenameView: true,
                supportsRenameColumn: true,
                supportsTriggers: false,
                supportsTriggerEditing: false,
                supportsCheckConstraints: true,
                supportsCheckConstraintEditing: false,
                supportsGeneratedColumns: true,
                supportsRoutines: false,
                supportsDatabaseTriggerBrowse: false,
                defaultSSLMode: .preferred,
                supportsPrincipalConnectionLimit: false
            ),
            schema: PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: "public",
                defaultGroupName: "main",
                tableEntityName: "Tables",
                containerEntityName: "Database",
                defaultPrimaryKeyColumn: nil,
                immutableColumns: [],
                systemDatabaseNames: ["INFORMATION_SCHEMA", "METRICS_SCHEMA", "PERFORMANCE_SCHEMA", "mysql", "sys"],
                systemSchemaNames: [],
                fileExtensions: [],
                databaseGroupingStrategy: .byDatabase,
                structureColumnFields: [
                    .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                    .onUpdate, .autoIncrement, .comment, .charset, .collation
                ]
            ),
            editor: PluginMetadataSnapshot.EditorConfig(
                sqlDialect: dialect,
                statementCompletions: [],
                columnTypesByCategory: tidbColumnTypes(from: mysqlColumnTypes)
            ),
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: [idleReleaseField],
                category: .relational,
                tagline: String(localized: "Distributed SQL, MySQL-compatible")
            )
        )),
            ("Databend", PluginMetadataSnapshot(
            displayName: "Databend", iconName: "databend-icon", defaultPort: 3_307,
            requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: mysqlVariantExplainVariants, pathFieldRole: .database,
            supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [.selectDatabaseFromLastSession],
            brandColorHex: "#0170FE",
            queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            structureEditing: SchemaEditingSupport(columnReorder: .unsupported, foreignKeyEdit: .unsupported),
            capabilities: PluginMetadataSnapshot.CapabilityFlags(
                supportsSchemaSwitching: false,
                supportsImport: true,
                supportsExport: true,
                supportsSSH: true,
                supportsSSL: true,
                supportsCascadeDrop: false,
                supportsForeignKeyDisable: false,
                supportsReadOnlyMode: true,
                supportsQueryProgress: false,
                requiresReconnectForDatabaseSwitch: false,
                supportsDropDatabase: true,
                supportsRenameTable: true,
                supportsRenameView: true,
                supportsRenameColumn: true,
                supportsAddIndex: false,
                supportsDropIndex: false,
                supportsModifyPrimaryKey: false,
                supportsTriggers: false,
                supportsTriggerEditing: false,
                supportsCheckConstraints: true,
                supportsCheckConstraintEditing: true,
                supportsGeneratedColumns: false,
                supportsRoutines: false,
                supportsDatabaseTriggerBrowse: false,
                defaultSSLMode: .preferred
            ),
            schema: PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: "public",
                defaultGroupName: "main",
                tableEntityName: "Tables",
                containerEntityName: "Database",
                defaultPrimaryKeyColumn: nil,
                immutableColumns: [],
                systemDatabaseNames: ["information_schema", "system"],
                systemSchemaNames: [],
                fileExtensions: [],
                databaseGroupingStrategy: .byDatabase,
                structureColumnFields: [.name, .type, .nullable, .defaultValue, .comment],
                rowMatchExcludedTypePrefixes: databendRowMatchExcludedTypePrefixes
            ),
            editor: PluginMetadataSnapshot.EditorConfig(
                sqlDialect: dialect.withCaseSensitivityStyle(.caseFoldFunction),
                statementCompletions: [],
                columnTypesByCategory: databendColumnTypes
            ),
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: [idleReleaseField],
                category: .analytical,
                tagline: String(localized: "Cloud data warehouse, built in Rust")
            )
        ))
        ]
    }
}
