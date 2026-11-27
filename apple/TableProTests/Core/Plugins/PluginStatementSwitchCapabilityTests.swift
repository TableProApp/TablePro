import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class PerRequestDatabasePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock ClickHouse"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Names its database on every request"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "ClickHouse"
    static let databaseDisplayName = "ClickHouse"
    static let iconName = "clickhouse-icon"
    static let defaultPort = 8_123
    static let statementsCanSwitchDatabase = false

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class PreCapabilityPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock ClickHouse"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A plugin built before the capability existed"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "ClickHouse"
    static let databaseDisplayName = "ClickHouse"
    static let iconName = "clickhouse-icon"
    static let defaultPort = 8_123

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@MainActor
struct PluginStatementSwitchCapabilityTests {
    @Test("A plugin that does not declare the capability can be moved by a statement")
    func defaultIsTrue() throws {
        let curated = try #require(PluginMetadataRegistry.shared.curatedSnapshot(for: .clickhouse))
        #expect(!curated.capabilities.statementsCanSwitchDatabase)
        let built = PluginMetadataRegistry.metadataSnapshot(
            from: PreCapabilityPlugin.self, isDownloadable: false, existing: curated
        )
        #expect(built.capabilities.statementsCanSwitchDatabase)
    }

    @Test("A plugin's declaration reaches the snapshot registration builds")
    func declaredCapabilityReachesTheSnapshot() throws {
        let curated = try #require(PluginMetadataRegistry.shared.curatedSnapshot(for: .clickhouse))
        let built = PluginMetadataRegistry.metadataSnapshot(
            from: PerRequestDatabasePlugin.self, isDownloadable: false, existing: curated
        )
        #expect(!built.capabilities.statementsCanSwitchDatabase)
    }

    @Test("Engines that name their database per request or per session object say no statement moves it")
    func perRequestEngines() {
        let types: [DatabaseType] = [
            .clickhouse, .neo4j, .surrealdb, .bigtable, .firestore, .firebaseRealtimeDatabase, .influxdb, .cloudflareD1,
        ]
        for type in types {
            #expect(!PluginManager.shared.statementsCanSwitchDatabase(for: type), "\(type.rawValue)")
        }
    }

    @Test("Engines a statement can move keep the default")
    func sessionEngines() {
        let types: [DatabaseType] = [.mysql, .mariadb, .mssql, .mongodb, .trino, .presto, .cassandra, .snowflake]
        for type in types {
            #expect(PluginManager.shared.statementsCanSwitchDatabase(for: type), "\(type.rawValue)")
        }
    }
}
