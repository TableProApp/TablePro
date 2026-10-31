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

    /// Redshift's EXPLAIN takes VERBOSE and nothing else: no FORMAT, no ANALYZE. It answers one
    /// text row per plan line.
    static let redshiftExplainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .plainText),
        ExplainVariant(id: "verbose", label: "EXPLAIN VERBOSE", sqlPrefix: "EXPLAIN VERBOSE", format: .plainText),
    ]

    static let oceanbaseExplainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .plainText),
    ]

    /// Measured on StarRocks 4.1.7. No `EXPLAIN ANALYZE`: it colors its report with terminal escape
    /// codes, which a plain-text plan shows as `[0m` throughout.
    static let starrocksExplainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .plainText),
        ExplainVariant(id: "logical", label: "EXPLAIN LOGICAL", sqlPrefix: "EXPLAIN LOGICAL", format: .plainText),
        ExplainVariant(id: "verbose", label: "EXPLAIN VERBOSE", sqlPrefix: "EXPLAIN VERBOSE", format: .plainText),
        ExplainVariant(id: "costs", label: "EXPLAIN COSTS", sqlPrefix: "EXPLAIN COSTS", format: .plainText),
    ]

    /// A grid reads every cell back as text and a keyless save compares that text to the stored
    /// value. Measured on MySQL 8.4.11 and OceanBase CE 4.4.2.1, on these three types it does not
    /// compare equal to what it was read from, so the save matched no row and was reported as a
    /// success: a `FLOAT` holding 1.1 reads back `1.1`, which the server parses into a different
    /// double than the single it widens; `0.1 + 0.2` in a `DOUBLE` reads back `0.3`; and a `JSON`
    /// column never equals a string. Every other MySQL type measured round-trips, and `BIT` breaks
    /// if it is added, because `CONCAT` renders it as raw bytes where the driver decodes a decimal.
    static let mysqlRowMatchTextTypePrefixes = ["FLOAT", "DOUBLE", "JSON"]

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
            tidbVariant(dialect: dialect, mysqlColumnTypes: mysqlColumnTypes, idleReleaseField: idleReleaseField),
            databendVariant(dialect: dialect, idleReleaseField: idleReleaseField),
            oceanbaseVariant(dialect: dialect, mysqlColumnTypes: mysqlColumnTypes, idleReleaseField: idleReleaseField),
            starrocksVariant(dialect: dialect, idleReleaseField: idleReleaseField),
        ]
    }

    static let starrocksColumnTypes: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INT", "BIGINT", "LARGEINT"],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL"],
        "String": ["CHAR", "VARCHAR", "STRING"],
        "Date": ["DATE", "DATETIME"],
        "Binary": ["BINARY", "VARBINARY"],
        "Boolean": ["BOOLEAN"],
        "Semi-structured": ["JSON", "ARRAY", "MAP", "STRUCT"],
        "Aggregate": ["BITMAP", "HLL", "PERCENTILE"],
    ]

    static let starrocksRowMatchExcludedTypePrefixes = [
        "ARRAY", "MAP", "STRUCT", "JSON", "BITMAP", "HLL", "PERCENTILE", "BINARY", "VARBINARY",
    ]

    /// Catalogs fill the database level and a catalog's databases the schema level, the shape Trino
    /// has. The Database field takes `catalog.database`, as StarRocks's own clients write it.
    private static func starrocksVariant(
        dialect: SQLDialectDescriptor,
        idleReleaseField: ConnectionField
    ) -> (typeId: String, snapshot: PluginMetadataSnapshot) {
        ("StarRocks", PluginMetadataSnapshot(
            displayName: "StarRocks", iconName: "starrocks-icon", defaultPort: 9_030,
            requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
            isDownloadable: false, primaryUrlScheme: "", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: starrocksExplainVariants, pathFieldRole: .database,
            supportsHealthMonitor: true, urlSchemes: [],
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
                defaultSSLMode: .preferred
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
                rowMatchExcludedTypePrefixes: starrocksRowMatchExcludedTypePrefixes
            ),
            editor: PluginMetadataSnapshot.EditorConfig(
                sqlDialect: dialect,
                statementCompletions: [],
                columnTypesByCategory: starrocksColumnTypes
            ),
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: [idleReleaseField],
                category: .analytical,
                tagline: String(localized: "Lakehouse analytics, MySQL protocol")
        )
        ))
    }

    private static func tidbVariant(
        dialect: SQLDialectDescriptor,
        mysqlColumnTypes: [String: [String]],
        idleReleaseField: ConnectionField
    ) -> (typeId: String, snapshot: PluginMetadataSnapshot) {
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
                browsingRequiresSelectedDatabase: true,
                supportsPrincipalConnectionLimit: false
            ),
            schema: PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: "public",
                defaultGroupName: "main",
                tableEntityName: "Tables",
                containerEntityName: "Database",
                defaultPrimaryKeyColumn: nil,
                immutableColumns: [],
                systemDatabaseNames: [
                    "INFORMATION_SCHEMA", "METRICS_SCHEMA", "PERFORMANCE_SCHEMA", "mysql", "sys",
                    "information_schema", "performance_schema"
                ],
                systemSchemaNames: [],
                fileExtensions: [],
                databaseGroupingStrategy: .byDatabase,
                structureColumnFields: [
                    .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                    .onUpdate, .autoIncrement, .comment, .charset, .collation
                ],
                rowMatchTextTypePrefixes: mysqlRowMatchTextTypePrefixes
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
        ))
    }

    private static func databendVariant(
        dialect: SQLDialectDescriptor,
        idleReleaseField: ConnectionField
    ) -> (typeId: String, snapshot: PluginMetadataSnapshot) {
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
    }

    private static func oceanbaseVariant(
        dialect: SQLDialectDescriptor,
        mysqlColumnTypes: [String: [String]],
        idleReleaseField: ConnectionField
    ) -> (typeId: String, snapshot: PluginMetadataSnapshot) {
        ("OceanBase", PluginMetadataSnapshot(
            displayName: "OceanBase", iconName: "oceanbase-icon", defaultPort: 2_881,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "oceanbase", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: oceanbaseExplainVariants, pathFieldRole: .database,
            supportsHealthMonitor: true, urlSchemes: ["oceanbase"], postConnectActions: [.selectDatabaseFromLastSession],
            brandColorHex: "#006AFF",
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
                supportsTriggers: true,
                supportsTriggerEditing: false,
                supportsCheckConstraints: true,
                supportsCheckConstraintEditing: false,
                supportsGeneratedColumns: true,
                supportsRoutines: true,
                supportsDatabaseTriggerBrowse: true,
                defaultSSLMode: .preferred,
                browsingRequiresSelectedDatabase: true,
                supportsPrincipalConnectionLimit: true
            ),
            schema: PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: "public",
                defaultGroupName: "main",
                tableEntityName: "Tables",
                containerEntityName: "Database",
                defaultPrimaryKeyColumn: nil,
                immutableColumns: [],
                systemDatabaseNames: [
                    "information_schema", "mysql", "oceanbase", "__recyclebin", "__public",
                    "SYS", "LBACSYS", "ORAAUDITOR"
                ],
                systemSchemaNames: [],
                fileExtensions: [],
                databaseGroupingStrategy: .byDatabase,
                structureColumnFields: [
                    .name, .type, .nullable, .defaultValue, .generated, .generationExpression,
                    .onUpdate, .autoIncrement, .comment, .charset, .collation
                ],
                rowMatchTextTypePrefixes: mysqlRowMatchTextTypePrefixes
            ),
            editor: PluginMetadataSnapshot.EditorConfig(
                sqlDialect: dialect,
                statementCompletions: [],
                columnTypesByCategory: mysqlColumnTypes
            ),
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: [idleReleaseField],
                category: .relational,
                tagline: String(localized: "Distributed HTAP, MySQL-compatible")
        )
        ))
    }
}
