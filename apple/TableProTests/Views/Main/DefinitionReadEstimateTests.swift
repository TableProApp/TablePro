//
//  DefinitionReadEstimateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

// DuckDB keeps its metadata reads on the session driver, so the mock answers them.
@MainActor
struct DefinitionReadEstimateTests {
    private static let keyed = [TestFixtures.makeColumnInfo()]
    private static let keyless = [ColumnInfo(name: "note", dataType: "TEXT", isNullable: true, isPrimaryKey: false)]

    private func makeFixture(
        _ driver: MockDatabaseDriver,
        services: AppServices = .live
    ) -> (CoordinatorFixture, DatabaseScope) {
        let connection = TestFixtures.makeConnection(database: "db", type: .duckdb)
        let fixture = CoordinatorFixture(connection: connection, driver: driver, services: services)
        return (fixture, DatabaseScope(connectionId: connection.id, database: "db", schema: nil))
    }

    private func addTableTab(to fixture: CoordinatorFixture, filtered: Bool = false, exactTotal: Int? = nil) -> UUID {
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        if filtered {
            tab.filterState.filters = [TestFixtures.makeTableFilter()]
            tab.filterState.applied = .checkedRows(of: tab.filterState.filters, logicMode: .and)
        }
        if let exactTotal {
            tab.pagination.totalRowCount = exactTotal
            tab.pagination.isApproximateRowCount = false
        }
        return fixture.addTab(tab).id
    }

    private func settleCount(on fixture: CoordinatorFixture, tabId: UUID) async {
        await fixture.coordinator.rowCountTasks[tabId]?.task.value
    }

    // MARK: - The definition read

    @Test("The definition read sends no row estimate")
    func definitionReadSendsNoEstimate() async throws {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": Self.keyed]
        let (fixture, scope) = makeFixture(driver)

        _ = try await QueryExecutor.fetchTableSchema(scope: scope, tableName: "users", isView: false)

        #expect(driver.fetchApproximateRowCountCallCount == 0)
        withExtendedLifetime(fixture) {}
    }

    @Test("A keyless relation the live catalog lists as a table is not asked whether it is a view")
    func catalogedTableSkipsTheViewCheck() async throws {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": Self.keyless]
        let (fixture, scope) = makeFixture(driver)

        _ = try await QueryExecutor.fetchTableSchema(scope: scope, tableName: "users", isView: false, isCataloged: true)
        #expect(driver.fetchViewRowEditingCalls.isEmpty)

        _ = try await QueryExecutor.fetchTableSchema(scope: scope, tableName: "users", isView: false, isCataloged: false)
        _ = try await QueryExecutor.fetchTableSchema(scope: scope, tableName: "users", isView: true, isCataloged: true)
        #expect(driver.fetchViewRowEditingCalls == ["users", "users"])
        withExtendedLifetime(fixture) {}
    }

    @Test("Keys the schema's read holds answer the definition read without a read of the table's own")
    func listedKeysSkipTheTableRead() async throws {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": Self.keyed]
        let (fixture, scope) = makeFixture(driver)
        let listed = [TestFixtures.makeForeignKeyInfo(column: "role_id", referencedTable: "roles")]

        let answered = try await QueryExecutor.fetchTableSchema(
            scope: scope, tableName: "users", isView: false, listedForeignKeys: { listed }
        )
        #expect(answered.foreignKeys?.map { $0.column } == ["role_id"])
        #expect(driver.fetchForeignKeysCallCount == 0)

        _ = try await QueryExecutor.fetchTableSchema(scope: scope, tableName: "users", isView: false, listedForeignKeys: { nil })
        #expect(driver.fetchForeignKeysCallCount == 1)
        withExtendedLifetime(fixture) {}
    }

    // MARK: - Which relations the catalog vouches for

    private func loadedCatalog(
        tables: [TableInfo],
        scope: DatabaseScope,
        connection: DatabaseConnection
    ) async -> SchemaService {
        let schemaService = SchemaService()
        let catalogDriver = MockDatabaseDriver(connection: connection)
        catalogDriver.tablesToReturn = tables
        await schemaService.load(connectionId: connection.id, driver: catalogDriver, connection: connection, scope: scope)
        return schemaService
    }

    @Test("Only a name the loaded, current catalog lists as a table counts as cataloged")
    func catalogVouchesForListedTablesOnly() async {
        let connection = TestFixtures.makeConnection(database: "db", type: .duckdb)
        let scope = DatabaseScope(connectionId: connection.id, database: "db", schema: nil)
        let schemaService = await loadedCatalog(
            tables: [
                TestFixtures.makeTableInfo(name: "users"),
                TestFixtures.makeTableInfo(name: "users_view", type: .view),
                TestFixtures.makeTableInfo(name: "caf\u{E9}"),
            ],
            scope: scope,
            connection: connection
        )
        let fixture = CoordinatorFixture(
            connection: connection, driver: MockDatabaseDriver(connection: connection),
            services: AppServices.live.reading(catalogFrom: schemaService)
        )
        let coordinator = fixture.coordinator

        #expect(coordinator.catalogListsAsTable("users", in: scope))
        #expect(!coordinator.catalogListsAsTable("users_view", in: scope))
        #expect(!coordinator.catalogListsAsTable("typed_in_sql", in: scope))
        #expect(!coordinator.catalogListsAsTable("users", in: DatabaseScope(connectionId: connection.id, database: "other", schema: nil)))
        #expect(!coordinator.catalogListsAsTable("users", in: scope.sessionBound))
        // Equal as Swift strings, two names to the server.
        #expect(coordinator.catalogListsAsTable("caf\u{E9}", in: scope))
        #expect(!coordinator.catalogListsAsTable("cafe\u{301}", in: scope))
    }

    @Test("Before the catalog loads, or while a kept one waits for its refresh, nothing counts as cataloged")
    func unloadedOrKeptCatalogVouchesForNothing() async {
        let connection = TestFixtures.makeConnection(database: "db", type: .duckdb)
        let scope = DatabaseScope(connectionId: connection.id, database: "db", schema: nil)
        let unloaded = CoordinatorFixture(
            connection: connection, driver: MockDatabaseDriver(connection: connection),
            services: AppServices.live.reading(catalogFrom: SchemaService())
        )
        #expect(!unloaded.coordinator.catalogListsAsTable("users", in: scope))

        let schemaService = await loadedCatalog(tables: [TestFixtures.makeTableInfo(name: "users")], scope: scope, connection: connection)
        schemaService.show(scope: DatabaseScope(connectionId: connection.id, database: "other", schema: nil), type: .duckdb)
        schemaService.markAllStale(connectionId: connection.id)
        schemaService.show(scope: scope, type: .duckdb)
        #expect(!schemaService.isCatalogCurrent(for: connection.id))
        let kept = CoordinatorFixture(connection: connection, services: AppServices.live.reading(catalogFrom: schemaService))
        #expect(!kept.coordinator.catalogListsAsTable("users", in: scope))
    }

    // MARK: - The estimate is the count's read

    @Test("Keys land while the row estimate is still on the wire")
    func keysLandBeforeTheEstimate() async {
        let driver = MockDatabaseDriver()
        let gate = AsyncGate()
        driver.approximateRowCountGate = gate
        driver.approximateRowCountToReturn = 5_000_000
        let (fixture, _) = makeFixture(driver)
        let tabId = addTableTab(to: fixture)
        let schemaTask = Task<FetchedTableSchema, Error> { FetchedTableSchema(columns: Self.keyed, foreignKeys: []) }

        fixture.coordinator.launchPhase2Work(
            tableName: "users", tabId: tabId, connectionType: .duckdb, schemaTask: schemaTask
        )
        await gate.arrived(1)

        let held = fixture.tabManager.tabs.first { $0.id == tabId }
        #expect(held?.tableContext.primaryKeyColumns == ["id"])
        #expect(held?.pagination.totalRowCount == nil)

        await gate.open()
        await settleCount(on: fixture, tabId: tabId)
        let settled = fixture.tabManager.tabs.first { $0.id == tabId }
        #expect(settled?.pagination.totalRowCount == 5_000_000)
        #expect(settled?.pagination.isApproximateRowCount == true)
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("A count after a definition read reads the estimate once and shows it before counting")
    func countReadsTheEstimateOnce() async {
        let driver = MockDatabaseDriver()
        driver.approximateRowCountToReturn = 900
        let (fixture, _) = makeFixture(driver)
        let tabId = addTableTab(to: fixture)

        fixture.coordinator.queryExecutionCoordinator.resolveRowCount(
            tableName: "users", tabId: tabId, connectionType: .duckdb, readsEstimate: true
        )
        await settleCount(on: fixture, tabId: tabId)

        #expect(driver.fetchApproximateRowCountCallCount == 1)
        let tab = fixture.tabManager.tabs.first { $0.id == tabId }
        #expect(tab?.pagination.totalRowCount == 900)
    }

    @Test("A filtered load, a tab holding an exact total, and a count with no definition read send no estimate read")
    func noEstimateReadWhereNothingShowsIt() async {
        let driver = MockDatabaseDriver()
        driver.approximateRowCountToReturn = 5_000_000
        let (fixture, _) = makeFixture(driver)
        let coordinator = fixture.coordinator.queryExecutionCoordinator!

        let filtered = addTableTab(to: fixture, filtered: true)
        coordinator.resolveRowCount(tableName: "users", tabId: filtered, connectionType: .duckdb, readsEstimate: true)
        await settleCount(on: fixture, tabId: filtered)

        let counted = addTableTab(to: fixture, exactTotal: 42)
        coordinator.resolveRowCount(tableName: "users", tabId: counted, connectionType: .duckdb, readsEstimate: true)
        await settleCount(on: fixture, tabId: counted)

        let paged = addTableTab(to: fixture)
        coordinator.resolveRowCount(tableName: "users", tabId: paged, connectionType: .duckdb, readsEstimate: false)
        await settleCount(on: fixture, tabId: paged)

        #expect(driver.fetchApproximateRowCountCallCount == 0)
    }
}
