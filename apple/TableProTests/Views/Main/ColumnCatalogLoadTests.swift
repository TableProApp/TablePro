import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import Testing

@MainActor
struct ColumnCatalogLoadTests {
    private static let users = TestFixtures.makeTableInfo(name: "users")

    private static func column(_ name: String, key: Bool = false) -> ColumnInfo {
        TestFixtures.makeColumnInfo(name: name, isPrimaryKey: key)
    }

    @MainActor
    private struct Harness {
        let fixture: CoordinatorFixture
        let driver: MockDatabaseDriver
        let scope: DatabaseScope
        let catalog: SQLSchemaProvider

        var coordinator: MainContentCoordinator { fixture.coordinator }
        var key: String { coordinator.schemaColumnsKey("users", scope: scope) }
    }

    private func makeHarness(seeded: Bool) async throws -> Harness {
        let connection = TestFixtures.makeConnection(database: "db", type: .duckdb)
        let driver = MockDatabaseDriver(connection: connection)
        driver.bulkColumnReadIsComplete = true
        driver.tablesToReturn = [Self.users]
        driver.allColumnsToReturn = ["users": [Self.column("id", key: true), Self.column("name")]]
        driver.columnsToReturn = ["users": [Self.column("id", key: true), Self.column("name")]]
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        let scope = try #require(fixture.coordinator.browseScope)
        let catalog = SchemaProviderRegistry.shared.getOrCreate(for: scope)
        await catalog.resetForDatabase("db", tables: [Self.users], driver: driver)
        if seeded {
            await catalog.seedColumnCatalog()
            await catalog.waitForEagerColumnLoad()
        }
        return Harness(fixture: fixture, driver: driver, scope: scope, catalog: catalog)
    }

    private func tearDown(_ harness: Harness) {
        SchemaProviderRegistry.shared.clear(for: harness.fixture.connection.id)
    }

    @Test("A table the catalog holds opens without reading its columns, and the list waits to be confirmed")
    func catalogHitSkipsTheColumnRead() async throws {
        let harness = try await makeHarness(seeded: true)
        defer { tearDown(harness) }

        let read = await harness.coordinator.loadSchemaColumns(for: "users", scope: harness.scope)

        #expect(read == nil)
        #expect(harness.driver.fetchColumnsCallCount == 0)
        let entry = try #require(harness.coordinator.schemaColumns.cached(harness.key))
        #expect(entry.columns == ["id", "name"])
        #expect(entry.primaryKeys == ["id"])
        #expect(!entry.isVerified)
    }

    @Test("A window's own column read fills the shared catalog")
    func ownReadFillsTheCatalog() async throws {
        let harness = try await makeHarness(seeded: false)
        defer { tearDown(harness) }

        _ = await harness.coordinator.loadSchemaColumns(for: "users", scope: harness.scope)

        #expect(harness.driver.fetchColumnsCallCount == 1)
        #expect(harness.coordinator.schemaColumns.cached(harness.key)?.isVerified == true)
        let shared = await harness.catalog.catalogColumns(forTable: "users", schema: nil)
        #expect(shared?.map(\.name) == ["id", "name"])
    }

    @Test("A temporary table never takes its columns from the shared catalog")
    func sessionBoundTableReadsItsOwnColumns() async throws {
        let harness = try await makeHarness(seeded: true)
        defer { tearDown(harness) }

        _ = await harness.coordinator.loadSchemaColumns(for: "users", scope: harness.scope.sessionBound)

        #expect(harness.driver.fetchColumnsCallCount == 1)
        let key = harness.coordinator.schemaColumnsKey("users", scope: harness.scope.sessionBound)
        #expect(harness.coordinator.schemaColumns.cached(key)?.isVerified == true)
    }

    @Test("A transaction end keeps the column lists to be confirmed, while a definition change drops them")
    func transactionEndKeepsTheLists() async throws {
        let harness = try await makeHarness(seeded: false)
        defer { tearDown(harness) }
        let connectionId = harness.fixture.connection.id
        _ = await harness.coordinator.loadSchemaColumns(for: "users", scope: harness.scope)

        harness.coordinator.applyCatalogChange(
            CatalogChange(connectionId: connectionId, kinds: [.objects, .schemas], isTransactionEndOnly: true)
        )
        #expect(harness.coordinator.schemaColumns.cached(harness.key)?.isVerified == false)

        harness.coordinator.applyCatalogChange(CatalogChange(connectionId: connectionId, kinds: .tables))
        #expect(harness.coordinator.schemaColumns.cached(harness.key) == nil)
    }

    @Test("A confirmed list that changes the page's columns loads the page again, and an unchanged one does not")
    func confirmedListReloadsOnlyWhenItChangesTheSelection() async throws {
        let harness = try await makeHarness(seeded: true)
        defer { tearDown(harness) }
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table)
        tab.tableContext.tableName = "users"
        tab.columnLayout.hiddenColumns = ["name"]
        harness.fixture.addTab(tab)
        _ = await harness.coordinator.loadSchemaColumns(for: "users", scope: harness.scope)
        let claim = TabExecutionClaim(tabId: tab.id, epoch: 1, startedAt: .now)
        let epoch = harness.coordinator.schemaColumns.verificationEpoch

        harness.coordinator.adoptVerifiedColumns(
            [Self.column("id", key: true), Self.column("name")], of: "users", in: harness.scope, readBy: claim, epoch: epoch
        )
        #expect(harness.coordinator.schemaColumns.cached(harness.key)?.isVerified == true)
        #expect(harness.coordinator.columnScopeRequeryTask == nil)

        harness.coordinator.schemaColumns.markAllUnverified()
        harness.coordinator.adoptVerifiedColumns(
            [Self.column("id", key: true), Self.column("name"), Self.column("email")],
            of: "users", in: harness.scope, readBy: claim, epoch: epoch + 1
        )
        #expect(harness.coordinator.schemaColumns.cached(harness.key)?.columns == ["id", "name", "email"])
        #expect(harness.coordinator.columnScopeRequeryTask != nil)
        harness.coordinator.columnScopeRequeryTask?.cancel()
    }

    @Test("A read that began before a transaction ended confirms nothing")
    func readBeforeATransactionEndConfirmsNothing() async throws {
        let harness = try await makeHarness(seeded: true)
        defer { tearDown(harness) }
        _ = await harness.coordinator.loadSchemaColumns(for: "users", scope: harness.scope)
        let epoch = harness.coordinator.schemaColumns.verificationEpoch
        harness.coordinator.schemaColumns.markAllUnverified()

        harness.coordinator.adoptVerifiedColumns(
            [Self.column("id", key: true)], of: "users", in: harness.scope,
            readBy: TabExecutionClaim(tabId: UUID(), epoch: 1, startedAt: .now), epoch: epoch
        )

        #expect(harness.coordinator.schemaColumns.cached(harness.key)?.columns == ["id", "name"])
        #expect(harness.coordinator.schemaColumns.cached(harness.key)?.isVerified == false)
    }

    @Test("A page the server refuses over a column the catalog still listed reads the columns afresh and loads once more")
    func refusedPageOverAStaleListLoadsAgain() async throws {
        let harness = try await makeHarness(seeded: false)
        defer { tearDown(harness) }
        harness.driver.columnsToReturn = ["users": [Self.column("id", key: true), Self.column("name")]]
        harness.coordinator.schemaColumns.store(
            SchemaColumnStore.Entry(columns: ["id", "gone", "name"], primaryKeys: ["id"], columnTypes: [:], isVerified: false),
            for: harness.key
        )
        harness.driver.failsStatementContaining = ("gone", DatabaseError.queryFailed("Unknown column 'gone'"))
        var tab = QueryTab(title: "users", query: "", tabType: .table)
        tab.tableContext.tableName = "users"
        tab.columnLayout.hiddenColumns = ["name"]
        harness.fixture.addTab(tab)
        harness.coordinator.filterCoordinator.rebuildTableQuery(at: 0)
        #expect(harness.coordinator.tabManager.tabs[0].content.query.contains("gone"))

        harness.coordinator.executeTableTabQueryDirectly(onTab: tab.id, viewport: .keepPlace)

        try await waitUntil {
            harness.coordinator.schemaColumns.cached(harness.key)?.isVerified == true
                && !harness.coordinator.tabExecution.isExecuting(tab.id)
                && harness.coordinator.tabManager.tabs[0].execution.lastExecutedAt != nil
        }
        let settled = harness.coordinator.tabManager.tabs[0]
        #expect(settled.execution.errorMessage == nil)
        #expect(!settled.content.query.contains("gone"))
        #expect(harness.driver.fetchColumnsCallCount == 1)
    }
}
