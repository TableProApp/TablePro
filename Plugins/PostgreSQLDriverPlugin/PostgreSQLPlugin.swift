//
//  PostgreSQLPlugin.swift
//  PostgreSQLDriverPlugin
//
//  PostgreSQL/Redshift database driver plugin using libpq
//

import Foundation
import os
import TableProPluginKit

// MARK: - Plugin Entry Point

final class PostgreSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "PostgreSQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "PostgreSQL, Redshift, CockroachDB, and PGlite support via libpq"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PostgreSQL"
    static let databaseDisplayName = "PostgreSQL"
    static let iconName = "postgresql-icon"
    static let defaultPort = 5_432
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "usePgpass",
            label: String(localized: "Use ~/.pgpass"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .authentication,
            hidesPassword: true
        )
    ] + AWSAuthFields.standard() + [
        AWSAuthFields.rdsEndpointField(),
        ConnectionField(
            id: "connectionOptions",
            label: String(localized: "Connection Options"),
            placeholder: "--cluster=my-cluster",
            fieldType: .text,
            section: .advanced
        )
    ]
    static let additionalDatabaseTypeIds: [String] = ["Redshift", "CockroachDB", "PGlite"]

    // MARK: - UI/Capability Metadata

    static let urlSchemes: [String] = ["postgresql", "postgres"]
    static let brandColorHex = "#336791"
    static let systemDatabaseNames: [String] = PostgreSQLSystemDatabases.postgreSQL
    static let supportsSchemaSwitching = true
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(
            id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN (FORMAT JSON)", format: .postgresJson
        ),
        ExplainVariant(
            id: "analyze",
            label: "EXPLAIN ANALYZE",
            sqlPrefix: "EXPLAIN (ANALYZE, FORMAT JSON)",
            format: .postgresJson
        ),
    ]
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["SMALLINT", "INTEGER", "BIGINT", "SERIAL", "BIGSERIAL", "SMALLSERIAL"],
        "Float": ["REAL", "DOUBLE PRECISION", "NUMERIC", "DECIMAL", "MONEY"],
        "String": ["CHARACTER VARYING", "VARCHAR", "CHARACTER", "CHAR", "TEXT", "NAME"],
        "Date": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL", "TIME WITH TIME ZONE", "TIMESTAMP WITH TIME ZONE"],
        "Binary": ["BYTEA"],
        "Boolean": ["BOOLEAN"],
        "JSON": ["JSON", "JSONB"],
        "UUID": ["UUID"],
        "Array": ["ARRAY"],
        "Network": ["INET", "CIDR", "MACADDR", "MACADDR8"],
        "Geometric": ["POINT", "LINE", "LSEG", "BOX", "PATH", "POLYGON", "CIRCLE"],
        "Range": ["INT4RANGE", "INT8RANGE", "NUMRANGE", "TSRANGE", "TSTZRANGE", "DATERANGE"],
        "Text Search": ["TSVECTOR", "TSQUERY"],
        "XML": ["XML"]
    ]

    static let supportsCascadeDrop = true
    static let supportsForeignKeyDisable = false
    static let requiresReconnectForDatabaseSwitch = true
    static let parameterStyle: ParameterStyle = .dollar
    static let supportsDropDatabase = true
    static let supportsDropSchema = true
    static let supportsTriggers = true
    static let supportsRoutines = true
    static let supportsDatabaseTriggerBrowse = true
    static let supportsTriggerEditing = true
    static let structureColumnFields: [StructureColumnField] =
        [.name, .type, .nullable, .defaultValue, .generated, .generationExpression, .comment]

    static let supportsCheckConstraints = true
    static let supportsCheckConstraintEditing = true
    static let supportsGeneratedColumns = true

    static let sqlDialect: SQLDialectDescriptor? = PostgreSQLDialect.descriptor

    static func driverVariant(for databaseTypeId: String) -> String? {
        switch databaseTypeId {
        case "PostgreSQL": return "PostgreSQL"
        case "Redshift": return "Redshift"
        case "CockroachDB": return "CockroachDB"
        case "PGlite": return "PGlite"
        default: return nil
        }
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        let variant = config.additionalFields["driverVariant"] ?? ""
        switch variant {
        case "Redshift": return RedshiftPluginDriver(config: config)
        case "CockroachDB": return CockroachPluginDriver(config: config)
        case "PGlite": return PGlitePluginDriver(config: config)
        default: return PostgreSQLPluginDriver(config: config)
        }
    }
}
