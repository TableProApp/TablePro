import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SearchPathPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock PostgreSQL"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Moves the session's search path on a schema switch"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PostgreSQL"
    static let databaseDisplayName = "PostgreSQL"
    static let iconName = "postgresql-icon"
    static let defaultPort = 5_432
    static let supportsSchemaSwitching = true
    static let schemaSwitchScopesUnqualifiedNames = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class PreScopePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock PostgreSQL"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A PostgreSQL plugin built before the schema switch scope existed"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PostgreSQL"
    static let databaseDisplayName = "PostgreSQL"
    static let iconName = "postgresql-icon"
    static let defaultPort = 5_432
    static let supportsSchemaSwitching = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@MainActor
struct PluginSchemaSwitchScopeCapabilityTests {
    @Test("A plugin's declaration reaches the snapshot registration builds")
    func declaredCapabilityReachesTheSnapshot() throws {
        let curated = try #require(PluginMetadataRegistry.shared.curatedSnapshot(for: .postgresql))
        let built = PluginMetadataRegistry.metadataSnapshot(
            from: SearchPathPlugin.self, isDownloadable: false, existing: curated
        )
        #expect(built.capabilities.schemaSwitchScopesUnqualifiedNames)
    }

    @Test("A plugin built before the capability existed reads as label-only, whatever the curated entry says")
    func olderPluginReadsAsLabelOnly() throws {
        let curated = try #require(PluginMetadataRegistry.shared.curatedSnapshot(for: .postgresql))
        #expect(curated.capabilities.schemaSwitchScopesUnqualifiedNames)
        let built = PluginMetadataRegistry.metadataSnapshot(
            from: PreScopePlugin.self, isDownloadable: false, existing: curated
        )
        #expect(!built.capabilities.schemaSwitchScopesUnqualifiedNames)
    }

    @Test("Engines whose schema switch moves name resolution say so")
    func sessionScopedEngines() {
        let types: [DatabaseType] = [
            .postgresql, .redshift, .cockroachdb, .pglite, .kingbasees, .oracle, .dameng, .sapHana, .snowflake,
            .duckdb, .trino, .presto, .bigQuery, .starrocks, .surrealdb,
        ]
        for type in types {
            #expect(PluginManager.shared.schemaSwitchScopesUnqualifiedNames(for: type), "\(type.rawValue)")
        }
    }

    @Test("Engines whose schema switch only labels the browsed schema say so")
    func labelOnlyEngines() {
        let types: [DatabaseType] = [.mssql, .spanner, .neo4j, .cloudflareR2SQL]
        for type in types {
            #expect(PluginManager.shared.supportsSchemaSwitching(for: type), "\(type.rawValue)")
            #expect(!PluginManager.shared.schemaSwitchScopesUnqualifiedNames(for: type), "\(type.rawValue)")
        }
    }

    @Test("An engine with no schema switch never reports a scoped one")
    func noSchemaSwitch() {
        for type in [DatabaseType.mysql, .sqlite, .cassandra] {
            #expect(!PluginManager.shared.schemaSwitchScopesUnqualifiedNames(for: type), "\(type.rawValue)")
        }
    }
}
