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

    @Test("MongoDB keeps its database-scoped authentication when its plugin registers")
    func mongoDBKeepsDatabaseScopedAuthentication() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockMongoDBPlugin.self)

        #expect(built.capabilities.authenticationIsDatabaseScoped == true)
    }

    @Test("A plugin with no curated entry falls back to the defaults")
    func unknownPluginUsesTheStructDefaults() {
        let registry = PluginMetadataRegistry.shared
        #expect(registry.snapshot(forTypeId: MockUnknownPlugin.databaseTypeId) == nil)

        let built = registry.buildMetadataSnapshot(from: MockUnknownPlugin.self)

        #expect(built.capabilities.supportsConnectionPooling == true)
        #expect(built.capabilities.authenticationIsDatabaseScoped == false)
    }
}
