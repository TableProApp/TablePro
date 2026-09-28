//
//  PluginMetadataRegistryCuratedCapabilityTests.swift
//  TableProTests
//
//  A capability with no DriverPlugin static is curated per type. buildMetadataSnapshot has to
//  carry it over from the built-in entry, or loading the plugin resets it to the struct default
//  and the curated value never reaches the app (#2108).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class MockDuckDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock DuckDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed DuckDB plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"
    static let databaseDisplayName = "DuckDB"
    static let iconName = "duckdb-icon"
    static let defaultPort = 9_494

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockMongoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MongoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed MongoDB plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MongoDB"
    static let databaseDisplayName = "MongoDB"
    static let iconName = "mongodb-icon"
    static let defaultPort = 27_017

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockSpannerPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Spanner"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed Spanner plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Spanner"
    static let databaseDisplayName = "Google Cloud Spanner"
    static let iconName = "spanner-icon"
    static let defaultPort = 0
    static let defaultSchemaName = "(default)"

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockMySQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MySQL"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the bundled MySQL plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MySQL"
    static let databaseDisplayName = "MySQL"
    static let iconName = "mysql-icon"
    static let defaultPort = 3_306

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockDynamoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock DynamoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed DynamoDB plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DynamoDB"
    static let databaseDisplayName = "Amazon DynamoDB"
    static let iconName = "dynamodb-icon"
    static let defaultPort = 0

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockUnknownPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Unknown"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A plugin type the app has no curated entry for"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "NoCuratedEntryDB"
    static let databaseDisplayName = "No Curated Entry"
    static let iconName = "cylinder.fill"
    static let defaultPort = 1_234

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@Suite("PluginMetadataRegistry curated capabilities", .serialized)
struct PluginMetadataRegistryCuratedCapabilityTests {
    @Test("DuckDB stays unpoolable when its plugin registers")
    func duckDBKeepsItsPoolingOptOut() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDuckDBPlugin.self)

        #expect(
            built.capabilities.supportsConnectionPooling == false,
            "A second duckdb_open is a different database, so metadata must stay on the session driver (#2108)"
        )
    }

    @Test("DuckDB keeps its file signatures when its plugin registers")
    func duckDBKeepsItsFileSignatures() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDuckDBPlugin.self)

        #expect(
            built.schema.fileSignatures == [.magic("DUCK", at: 8).andZeroes(at: 14, count: 6)],
            "No DriverPlugin declares a signature, so loading the plugin would otherwise erase it"
        )
    }

    @Test("MongoDB keeps its database-scoped authentication when its plugin registers")
    func mongoDBKeepsDatabaseScopedAuthentication() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockMongoDBPlugin.self)

        #expect(built.capabilities.authenticationIsDatabaseScoped == true)
    }

    @Test("MongoDB keeps its sampled columns and its structure matrix when its plugin registers")
    func mongoDBKeepsSampledColumnsAndStructureMatrix() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockMongoDBPlugin.self)

        #expect(
            built.capabilities.columnsAreSampled == true,
            "A structure sync would read a field missing from one sample as a field to remove"
        )
        #expect(StructureEditEligibility.allows(.renameColumn, on: .table, matrix: built.structureEditing.structureEdits))
        #expect(StructureEditEligibility.allows(.dropColumn, on: .table, matrix: built.structureEditing.structureEdits))
    }

    @Test("DynamoDB keeps its billed-scan count when its plugin registers")
    func dynamoDBKeepsItsBilledScanCount() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDynamoDBPlugin.self)

        #expect(
            built.capabilities.exactRowCountIsBilledScan == true,
            "Every automatic count would be a Scan of the whole table that AWS bills for"
        )
    }

    @Test("MySQL keeps browsing only inside a selected database when its plugin registers")
    func mySQLKeepsBrowsingRequiresSelectedDatabase() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockMySQLPlugin.self)

        #expect(built.capabilities.browsingRequiresSelectedDatabase == true)
    }

    /// A MySQL-protocol session opened with no database has none at all, so it lists nothing until
    /// one is chosen. Databend's session falls back to its `default` database instead.
    @Test("Only the MySQL engines with no default database require a selected database to browse")
    func browsingRequiresSelectedDatabasePerEngine() {
        let registry = PluginMetadataRegistry.shared

        for typeId in ["MySQL", "MariaDB", "TiDB", "OceanBase"] {
            #expect(
                registry.snapshot(forRegisteredTypeId: typeId)?.capabilities.browsingRequiresSelectedDatabase == true,
                "\(typeId)"
            )
        }
        for typeId in ["Databend", "PostgreSQL", "ClickHouse"] {
            #expect(
                (registry.snapshot(forRegisteredTypeId: typeId)?.capabilities.browsingRequiresSelectedDatabase ?? false)
                    == false,
                "\(typeId)"
            )
        }
    }

    @Test("Spanner keeps its implicit schema when its plugin registers")
    func spannerKeepsItsImplicitSchema() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockSpannerPlugin.self)

        #expect(built.schema.implicitSchemaName == "(default)")
        #expect(built.schema.defaultSchemaName == "(default)")
    }

    @Test("An engine with a named default schema declares no implicit schema")
    func duckDBHasNoImplicitSchema() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDuckDBPlugin.self)

        #expect(built.schema.implicitSchemaName == nil)
    }

    @Test("A plugin with no curated entry falls back to the defaults")
    func unknownPluginUsesTheStructDefaults() {
        let registry = PluginMetadataRegistry.shared
        #expect(registry.snapshot(forRegisteredTypeId: MockUnknownPlugin.databaseTypeId) == nil)

        let built = registry.buildMetadataSnapshot(from: MockUnknownPlugin.self)

        #expect(built.capabilities.supportsConnectionPooling == true)
        #expect(built.capabilities.authenticationIsDatabaseScoped == false)
        #expect(built.capabilities.browsingRequiresSelectedDatabase == false)
        #expect(built.capabilities.exactRowCountIsBilledScan == false)
        #expect(built.capabilities.columnsAreSampled == false)
        #expect(built.schema.implicitSchemaName == nil)
    }
}
