//
//  PluginMetadataRegistry+StarRocksDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    static let starRocksExplainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .plainText),
        ExplainVariant(id: "logical", label: "EXPLAIN LOGICAL", sqlPrefix: "EXPLAIN LOGICAL", format: .plainText),
        ExplainVariant(id: "verbose", label: "EXPLAIN VERBOSE", sqlPrefix: "EXPLAIN VERBOSE", format: .plainText),
        ExplainVariant(id: "costs", label: "EXPLAIN COSTS", sqlPrefix: "EXPLAIN COSTS", format: .plainText),
    ]

    static let starRocksColumnTypes: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INT", "BIGINT", "LARGEINT"],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL"],
        "String": ["CHAR", "VARCHAR", "STRING"],
        "Date": ["DATE", "DATETIME"],
        "Binary": ["BINARY", "VARBINARY"],
        "Boolean": ["BOOLEAN"],
        "Semi-structured": ["JSON", "ARRAY", "MAP", "STRUCT"],
        "Aggregate": ["BITMAP", "HLL", "PERCENTILE"],
    ]

    static let starRocksRowMatchExcludedTypePrefixes = [
        "ARRAY", "MAP", "STRUCT", "JSON", "BITMAP", "HLL", "PERCENTILE", "BINARY", "VARBINARY",
    ]

    // Measured on 4.1.7: `f = 1.1` misses a FLOAT holding 1.1, `CONCAT(f) = '1.1'` finds it.
    static let starRocksRowMatchTextTypePrefixes = ["FLOAT"]

    static func starRocksDefaults(
        dialect: SQLDialectDescriptor,
        idleReleaseField: ConnectionField
    ) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [("StarRocks", PluginMetadataSnapshot(
            displayName: "StarRocks", iconName: "starrocks-icon", defaultPort: 9_030,
            requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
            isDownloadable: true, primaryUrlScheme: "starrocks", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: starRocksExplainVariants, pathFieldRole: .database,
            supportsHealthMonitor: true, urlSchemes: ["starrocks"],
            postConnectActions: [.selectDatabaseFromLastSession, .selectSchemaFromLastSession],
            brandColorHex: "#01808F",
            queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            structureEditing: SchemaEditingSupport(columnReorder: .unsupported, foreignKeyEdit: .unsupported),
            capabilities: PluginMetadataSnapshot.CapabilityFlags(
                supportsSchemaSwitching: true,
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
                supportsRenameTable: false,
                supportsRenameView: false,
                supportsRenameColumn: false,
                supportsAddIndex: false,
                supportsDropIndex: false,
                supportsModifyPrimaryKey: false,
                supportsTriggers: false,
                supportsTriggerEditing: false,
                supportsCheckConstraints: false,
                supportsCheckConstraintEditing: false,
                supportsGeneratedColumns: false,
                supportsRoutines: false,
                supportsDatabaseTriggerBrowse: false,
                defaultSSLMode: .preferred,
                // The Database field is `catalog.database`, so a pooled connection keeps it and switches after.
                authenticationIsDatabaseScoped: true
            ),
            schema: PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: "",
                defaultGroupName: "default",
                tableEntityName: "Tables",
                containerEntityName: "Catalog",
                defaultPrimaryKeyColumn: nil,
                immutableColumns: [],
                systemDatabaseNames: [],
                systemSchemaNames: ["_statistics_", "information_schema", "sys"],
                fileExtensions: [],
                databaseGroupingStrategy: .hierarchicalSchema,
                structureColumnFields: [.name, .type, .nullable, .defaultValue, .comment],
                rowMatchExcludedTypePrefixes: starRocksRowMatchExcludedTypePrefixes,
                rowMatchTextTypePrefixes: starRocksRowMatchTextTypePrefixes
            ),
            editor: PluginMetadataSnapshot.EditorConfig(
                sqlDialect: dialect,
                statementCompletions: [],
                columnTypesByCategory: starRocksColumnTypes
            ),
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: [idleReleaseField],
                category: .analytical,
                tagline: String(localized: "Lakehouse analytics, MySQL protocol")
            )
        ))]
    }
}
