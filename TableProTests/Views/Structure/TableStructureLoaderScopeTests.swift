//
//  TableStructureLoaderScopeTests.swift
//  TableProTests
//
//  The test that would have caught #2026 symptom 1. A structure tab is bound to the
//  database it was opened on. Once the sidebar moved to another database, every
//  structure read resolved its database from ambient session state instead, so
//  `SHOW FULL COLUMNS FROM `t`` ran on the sidebar's database and the tab reported
//  `Table 'B.t' doesn't exist` about its own table.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Captures every scope the loader hands to the metadata layer. A recorded scope that
/// is not the loader's own is the bug.
@MainActor
private final class RecordingMetadataProvider: ScopedMetadataProviding {
    private(set) var requestedScopes: [DatabaseScope] = []
    private(set) var requestedWorkloads: [MetadataConnectionPool.Workload] = []
    private(set) var browseScopeCallCount = 0
    var browseScopeToReturn: DatabaseScope?

    let driver: MockDatabaseDriver

    init(driver: MockDatabaseDriver = MockDatabaseDriver()) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        requestedWorkloads.append(workload)
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        browseScopeCallCount += 1
        return browseScopeToReturn
    }
}

@Suite("TableStructureLoader scope binding", .serialized)
@MainActor
struct TableStructureLoaderScopeTests {
    /// Moves the sidebar to `browseDatabase` so any ambient fallback is visibly wrong.
    private static func makeBrowsingSession(
        browseDatabase: String,
        browseSchema: String? = nil,
        type: DatabaseType = .mysql
    ) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: "saved_default", type: type)
        var session = ConnectionSession(connection: connection)
        session.browseDatabase = browseDatabase
        session.browseSchema = browseSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private static func exerciseEveryRead(_ loader: TableStructureLoader) async throws {
        _ = try await loader.columns()
        _ = try await loader.indexes()
        _ = try await loader.foreignKeys()
        _ = try await loader.triggers()
        _ = try await loader.coreTabs(includingForeignKeys: true, includingTableComment: true)
        _ = try await loader.tableComment()
        _ = try await loader.perform { try await $0.fetchTableDDL(table: "t") }
    }

    @Test("Every structure read runs on the tab's database, never on the browsed one")
    func everyReadUsesTheTabsDatabase() async throws {
        let connection = Self.makeBrowsingSession(browseDatabase: "B")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let browseScope = try #require(DatabaseManager.shared.browseScope(for: connection.id))
        let provider = RecordingMetadataProvider()
        provider.browseScopeToReturn = browseScope

        let tabScope = DatabaseScope(connectionId: connection.id, database: "A", schema: nil)
        let loader = TableStructureLoader(scope: tabScope, tableName: "t", provider: provider)

        try await Self.exerciseEveryRead(loader)

        #expect(provider.requestedScopes.count == 7)
        #expect(provider.requestedScopes.allSatisfy { $0 == tabScope })
        #expect(provider.requestedScopes.allSatisfy { $0.database == "A" })
        #expect(provider.requestedScopes.allSatisfy { $0.schema == nil })
        #expect(provider.requestedScopes.allSatisfy { $0 != browseScope })
        #expect(provider.browseScopeCallCount == 0)
        #expect(provider.requestedWorkloads.allSatisfy { $0 == .interactive })
    }

    @Test("The tab's schema is carried too, not the schema the sidebar is on")
    func everyReadUsesTheTabsSchema() async throws {
        let connection = Self.makeBrowsingSession(
            browseDatabase: "reporting",
            browseSchema: "dbo",
            type: .mssql
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let browseScope = try #require(DatabaseManager.shared.browseScope(for: connection.id))
        #expect(browseScope.schema == "dbo")

        let provider = RecordingMetadataProvider()
        provider.browseScopeToReturn = browseScope

        let tabScope = DatabaseScope(connectionId: connection.id, database: "orders", schema: "sales")
        let loader = TableStructureLoader(scope: tabScope, tableName: "t", provider: provider)

        try await Self.exerciseEveryRead(loader)

        #expect(provider.requestedScopes.count == 7)
        #expect(provider.requestedScopes.allSatisfy { $0.database == "orders" })
        #expect(provider.requestedScopes.allSatisfy { $0.schema == "sales" })
        #expect(provider.requestedScopes.allSatisfy { $0 != browseScope })
    }

    @Test("The loader reads the table it was built for on every call")
    func everyReadTargetsTheLoadersTable() async throws {
        let connection = Self.makeBrowsingSession(browseDatabase: "B")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let provider = RecordingMetadataProvider()
        let tabScope = DatabaseScope(connectionId: connection.id, database: "A", schema: nil)
        let loader = TableStructureLoader(scope: tabScope, tableName: "orders", provider: provider)

        _ = try await loader.columns()
        _ = try await loader.coreTabs(includingForeignKeys: false, includingTableComment: false)

        #expect(provider.driver.fetchColumnsCalls == ["orders", "orders"])
    }

    @Test("The table comment is read for the loader's table on the tab's scope")
    func tableCommentReadsOnTheTabsScope() async throws {
        let connection = Self.makeBrowsingSession(browseDatabase: "B")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let provider = RecordingMetadataProvider()
        provider.driver.tableCommentToReturn = "Customer orders"
        let tabScope = DatabaseScope(connectionId: connection.id, database: "A", schema: nil)
        let loader = TableStructureLoader(scope: tabScope, tableName: "orders", provider: provider)

        let comment = try await loader.tableComment()

        #expect(comment == "Customer orders")
        #expect(provider.requestedScopes == [tabScope])
        #expect(provider.driver.fetchTableMetadataCalls == ["orders"])
    }

    @Test("A comment that fails to load is reported, and the columns still land")
    func failedCommentStillLandsTheColumns() async throws {
        let connection = Self.makeBrowsingSession(browseDatabase: "B")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let provider = RecordingMetadataProvider()
        provider.driver.columnsToReturn["orders"] = [TestFixtures.makeColumnInfo(name: "id", dataType: "INT")]
        provider.driver.fetchTableMetadataError = DatabaseError.queryFailed("permission denied")
        let tabScope = DatabaseScope(connectionId: connection.id, database: "A", schema: nil)
        let loader = TableStructureLoader(scope: tabScope, tableName: "orders", provider: provider)

        let reloaded = try await loader.coreTabs(includingForeignKeys: false, includingTableComment: true)

        #expect(reloaded.columns.map(\.name) == ["id"])
        guard case .failed = reloaded.tableComment else {
            Issue.record("Expected a failed comment, got \(String(describing: reloaded.tableComment))")
            return
        }
    }

    @Test("The comment is not read unless asked for")
    func commentIsReadOnlyWhenAsked() async throws {
        let connection = Self.makeBrowsingSession(browseDatabase: "B")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let provider = RecordingMetadataProvider()
        let tabScope = DatabaseScope(connectionId: connection.id, database: "A", schema: nil)
        let loader = TableStructureLoader(scope: tabScope, tableName: "orders", provider: provider)

        let reloaded = try await loader.coreTabs(includingForeignKeys: false, includingTableComment: false)

        #expect(reloaded.tableComment == nil)
        #expect(provider.driver.fetchTableMetadataCalls.isEmpty)
    }

    @Test("A server-scoped loader passes its own scope through, never the browsed one")
    func serverScopedLoaderNeverFallsBackToTheBrowsedDatabase() async throws {
        let connection = Self.makeBrowsingSession(browseDatabase: "B")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let provider = RecordingMetadataProvider()
        provider.browseScopeToReturn = DatabaseManager.shared.browseScope(for: connection.id)
        let serverScoped = DatabaseScope(connectionId: connection.id, database: "", schema: nil)
        let loader = TableStructureLoader(scope: serverScoped, tableName: "t", provider: provider)

        _ = try await loader.columns()

        #expect(serverScoped.isServerScoped)
        #expect(provider.requestedScopes == [serverScoped])
        #expect(provider.browseScopeCallCount == 0)
    }
}
