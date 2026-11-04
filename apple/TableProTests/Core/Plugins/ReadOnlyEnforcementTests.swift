//
//  ReadOnlyEnforcementTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ClickHousePluginStandIn: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock ClickHouse"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed ClickHouse plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "ClickHouse"
    static let databaseDisplayName = "ClickHouse"
    static let iconName = "clickhouse-icon"
    static let defaultPort = 8_123

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

struct ReadOnlyEnforcementTests {
    private static func capabilities(_ databaseType: DatabaseType) -> PluginMetadataSnapshot.CapabilityFlags? {
        PluginMetadataRegistry.shared.builtInDefaults()
            .first { $0.typeId == databaseType.rawValue }?
            .snapshot.capabilities
    }

    private static func curated(_ databaseType: DatabaseType) -> ReadOnlyEnforcement? {
        PluginMetadataRegistry.shared.builtInDefaults()
            .first { $0.typeId == databaseType.rawValue }
            .map { ReadOnlyEnforcement($0.snapshot.capabilities) }
    }

    @Test("Each engine is curated with what this build enforces for external Read Only", arguments: [
        (DatabaseType.postgresql, ReadOnlyEnforcement.sessionDefault),
        (.cockroachdb, .sessionDefault),
        (.pglite, .sessionDefault),
        (.kingbasees, .sessionDefault),
        (.mysql, .sessionDefault),
        (.mariadb, .sessionDefault),
        (.duckdb, .sessionDefault),
        (.sqlite, .engineEnforced),
        (.clickhouse, .engineEnforced),
        (.cloudflareR2SQL, .engineEnforced),
        (.mongodb, .clientGuard),
        (.redis, .clientGuard),
        (.memcached, .clientGuard),
        (.redshift, .loginPrivileges),
        (.tidb, .loginPrivileges),
        (.mssql, .loginPrivileges),
        (.oracle, .loginPrivileges),
        (.trino, .loginPrivileges),
        (.kafka, .loginPrivileges),
    ])
    func curatedClass(databaseType: DatabaseType, expected: ReadOnlyEnforcement) {
        #expect(Self.curated(databaseType) == expected)
    }

    // A MySQL-type connection that is really TiDB, or an older DuckDB plugin, loads a driver without the mode.
    @Test(
        "A live driver without read-only statements leaves only the login behind Read Only",
        arguments: [DatabaseType.mysql, .postgresql, .duckdb, .sqlite, .clickhouse]
    )
    func liveDriverWithoutTheModeDowngrades(databaseType: DatabaseType) throws {
        let capabilities = try #require(Self.capabilities(databaseType))
        #expect(ReadOnlyEnforcement(capabilities, liveDriverRunsReadOnly: false) == .loginPrivileges)
        #expect(ReadOnlyEnforcement(capabilities, liveDriverRunsReadOnly: true) == ReadOnlyEnforcement(capabilities))
        #expect(ReadOnlyEnforcement(capabilities, liveDriverRunsReadOnly: nil) == ReadOnlyEnforcement(capabilities))
    }

    @Test("An engine that cannot write, and a class that never relied on the driver, stay as curated")
    func downgradeLeavesOtherClassesAlone() throws {
        let readOnlyEngine = try #require(Self.capabilities(.cloudflareR2SQL))
        #expect(ReadOnlyEnforcement(readOnlyEngine, liveDriverRunsReadOnly: false) == .engineEnforced)
        let guarded = try #require(Self.capabilities(.mongodb))
        #expect(ReadOnlyEnforcement(guarded, liveDriverRunsReadOnly: false) == .clientGuard)
    }

    @Test("The footer note follows the live driver")
    func footerFollowsTheLiveDriver() {
        #expect(
            ReadOnlyEnforcement.externalClientsNote(for: .mysql, liveDriverRunsReadOnly: false)
                == ReadOnlyEnforcement.loginPrivileges.externalClientsNote(
                    engine: PluginManager.registryDisplayName(of: .mysql)
                )
        )
    }

    @Test("A type with no snapshot depends on the login")
    func unknownTypeDependsOnTheLogin() {
        #expect(ReadOnlyEnforcement(for: DatabaseType(rawValue: "No Such Engine")) == .loginPrivileges)
    }

    @Test("A loaded plugin keeps the curated class of its type")
    func pluginRegistrationKeepsTheCuratedClass() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: ClickHousePluginStandIn.self)
        #expect(ReadOnlyEnforcement(built.capabilities) == .engineEnforced)
    }

    @Test("Every footer note names the engine, and each class says something different")
    func footerNamesTheEngine() {
        let classes: [ReadOnlyEnforcement] = [.engineEnforced, .sessionDefault, .loginPrivileges, .clientGuard]
        let notes = classes.map { $0.externalClientsNote(engine: "Example Engine") }
        for note in notes {
            #expect(note.contains("Example Engine"))
        }
        #expect(Set(notes).count == classes.count)
    }

    @Test("The footer note for a connection type uses that engine's name", arguments: [
        (DatabaseType.postgresql, "PostgreSQL"),
        (.sqlite, "SQLite"),
        (.mssql, "SQL Server"),
        (.mongodb, "MongoDB"),
    ])
    func footerForType(databaseType: DatabaseType, engine: String) {
        let note = ReadOnlyEnforcement.externalClientsNote(for: databaseType)
        #expect(note == ReadOnlyEnforcement(for: databaseType).externalClientsNote(engine: engine))
    }
}
