import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct PluginMetadataRegistryStarRocksTests {
    @Test("StarRocks is offered before installation and resolves to its own registry plugin")
    func registryIdentity() throws {
        let registry = PluginMetadataRegistry.shared
        #expect(registry.allRegisteredTypeIds().contains("StarRocks"))
        #expect(registry.pluginTypeId(for: "StarRocks") == "StarRocks")
        #expect(DatabaseType.starrocks.pluginTypeId == "StarRocks")
        #expect(DatabaseType.starrocks.isDownloadablePlugin)
        let snapshot = try #require(registry.snapshot(forRegisteredTypeId: "StarRocks"))
        #expect(snapshot.defaultPort == 9_030)
        #expect(snapshot.schema.databaseGroupingStrategy == .hierarchicalSchema)
        #expect(snapshot.capabilities.supportsSchemaSwitching)
        #expect(!snapshot.supportsForeignKeys)
    }

    @Test("A pooled StarRocks connection keeps the catalog.database field and switches after connecting")
    func poolKeepsTheConfiguredScope() {
        #expect(DatabaseType.starrocks.authenticationIsDatabaseScoped)
        let plan = MetadataConnectionPool.planConnection(
            configuredDatabase: "glue.lakehouse",
            targetDatabase: "ice",
            authenticationIsDatabaseScoped: DatabaseType.starrocks.authenticationIsDatabaseScoped
        )
        #expect(plan == MetadataConnectionPool.ConnectionPlan(connectDatabase: "glue.lakehouse", switchDatabase: "ice"))
    }

    @Test("A keyless match compares FLOAT through its text and refuses the types it cannot compare")
    func rowMatching() throws {
        let snapshot = try #require(PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: "StarRocks"))
        #expect(snapshot.schema.rowMatchTextTypePrefixes == ["FLOAT"])
        #expect(snapshot.schema.rowMatchExcludedTypePrefixes.contains("VARBINARY"))
    }

    @Test("A DELETE on a duplicate key table reports 0 rows, so a keyless save is not held to its count")
    func rowCountsAreNotMeaningful() {
        #expect(!DataWriteRowCounts.areMeaningful(for: .starrocks))
    }

    @Test("A StarRocks URL keeps the catalog.database path and routes to StarRocks")
    func connectionURL() throws {
        let parsed = try ConnectionURLParser.parse("starrocks://root:pass@fe.local:19030/glue.lakehouse").get()
        #expect(parsed.type == .starrocks)
        #expect(parsed.host == "fe.local")
        #expect(parsed.port == 19_030)
        #expect(parsed.database == "glue.lakehouse")
        #expect(parsed.username == "root")
    }
}
