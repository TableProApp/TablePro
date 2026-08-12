//
//  SchemaServiceTests.swift
//  TableProTests
//
//  Tests for SchemaService aggregation across per-schema table lists, and for the scope
//  keying that keeps two windows of one connection from sharing one object list (#2088).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SchemaService")
@MainActor
struct SchemaServiceTests {
    private func makeScope(
        _ connectionId: UUID = UUID(),
        database: String = "app",
        schema: String? = nil
    ) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    @Test("allLoadedTables unions tables across loaded per-schema lists")
    func allLoadedTablesUnionsPerSchema() async {
        let scope = makeScope()
        let driver = MockDatabaseDriver()
        driver.schemaTablesToReturn = [
            "sales": [
                TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales"),
                TableInfo(name: "leads", type: .table, rowCount: 0, schema: "sales")
            ],
            "hr": [
                TableInfo(name: "employees", type: .table, rowCount: 0, schema: "hr")
            ]
        ]

        let service = SchemaService()
        await service.loadSchemaTables(scope: scope, schema: "sales", driver: driver)
        await service.loadSchemaTables(scope: scope, schema: "hr", driver: driver)

        let names = Set(service.allLoadedTables(for: scope).map(\.name))
        #expect(names == ["orders", "leads", "employees"])
    }

    @Test("allLoadedTables deduplicates tables that share an id across schema states")
    func allLoadedTablesDeduplicatesById() async {
        let scope = makeScope()
        let driver = MockDatabaseDriver()
        let shared = TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales")
        driver.schemaTablesToReturn = [
            "sales": [shared],
            "mirror": [shared]
        ]

        let service = SchemaService()
        await service.loadSchemaTables(scope: scope, schema: "sales", driver: driver)
        await service.loadSchemaTables(scope: scope, schema: "mirror", driver: driver)

        let matching = service.allLoadedTables(for: scope).filter { $0.id == shared.id }
        #expect(matching.count == 1)
    }

    @Test("allLoadedTables is empty for a scope with no loaded state")
    func allLoadedTablesEmptyWhenNothingLoaded() {
        let service = SchemaService()
        #expect(service.allLoadedTables(for: makeScope()).isEmpty)
    }

    @Test("markLoadFailed surfaces a failed state for spinners to resolve")
    func markLoadFailedSetsFailedState() {
        let service = SchemaService()
        let scope = makeScope()

        service.markLoadFailed(scope: scope, message: "connect timed out")

        #expect(service.state(for: scope) == .failed("connect timed out"))
    }

    @Test("markLoadFailed keeps already-loaded tables instead of replacing them")
    func markLoadFailedKeepsLoadedTables() async {
        let scope = makeScope()
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let service = SchemaService()
        await service.reload(
            scope: scope,
            driver: driver,
            connection: TestFixtures.makeConnection()
        )

        service.markLoadFailed(scope: scope, message: "refresh failed")

        #expect(service.state(for: scope) == .loaded(driver.tablesToReturn))
    }

    @Test("hierarchical load lists schemas")
    func hierarchicalLoadListsSchemas() async {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["HR", "SALES"]
        let connection = TestFixtures.makeConnection(type: .oracle)
        let scope = makeScope(connection.id)
        let service = SchemaService()

        await service.reload(scope: scope, driver: driver, connection: connection)

        #expect(service.state(for: scope) == .loaded([]))
        #expect(service.schemas(for: scope) == ["HR", "SALES"])
    }

    @Test("hierarchical schema list failure surfaces a failed state")
    func hierarchicalFailureSetsFailedState() async {
        let driver = MockDatabaseDriver()
        driver.fetchSchemasError = DatabaseError.connectionFailed("schema list failed")
        let connection = TestFixtures.makeConnection(type: .oracle)
        let scope = makeScope(connection.id)
        let service = SchemaService()

        await service.reload(scope: scope, driver: driver, connection: connection)

        var isFailed = false
        if case .failed = service.state(for: scope) {
            isFailed = true
        }
        #expect(isFailed)
    }

    @Test("two databases of one connection keep separate object lists")
    func scopesOfOneConnectionAreIndependent() async {
        let connection = TestFixtures.makeConnection()
        let first = makeScope(connection.id, database: "shop")
        let second = makeScope(connection.id, database: "inventory")
        let service = SchemaService()

        let shopDriver = MockDatabaseDriver()
        shopDriver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        await service.load(scope: first, driver: shopDriver, connection: connection)

        let inventoryDriver = MockDatabaseDriver()
        inventoryDriver.tablesToReturn = [TableInfo(name: "parts", type: .table, rowCount: 0, schema: nil)]
        await service.load(scope: second, driver: inventoryDriver, connection: connection)

        #expect(service.tables(for: first).map(\.name) == ["orders"])
        #expect(service.tables(for: second).map(\.name) == ["parts"])
    }

    @Test("two schemas of one database keep separate object lists")
    func schemasOfOneDatabaseAreIndependent() async {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let sales = makeScope(connection.id, database: "shop", schema: "sales")
        let hr = makeScope(connection.id, database: "shop", schema: "hr")
        let service = SchemaService()

        let salesDriver = MockDatabaseDriver()
        salesDriver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales")]
        await service.load(scope: sales, driver: salesDriver, connection: connection)

        #expect(service.tables(for: sales).map(\.name) == ["orders"])
        #expect(service.tables(for: hr).isEmpty)
        #expect(service.state(for: hr) == .idle)
    }

    @Test("invalidating a connection clears every scope it loaded")
    func invalidateConnectionClearsEveryScope() async {
        let connection = TestFixtures.makeConnection()
        let first = makeScope(connection.id, database: "shop")
        let second = makeScope(connection.id, database: "inventory")
        let other = makeScope(database: "shop")
        let service = SchemaService()
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]

        await service.load(scope: first, driver: driver, connection: connection)
        await service.load(scope: second, driver: driver, connection: connection)
        await service.load(scope: other, driver: driver, connection: TestFixtures.makeConnection())

        await service.invalidate(connectionId: connection.id)

        #expect(service.tables(for: first).isEmpty)
        #expect(service.tables(for: second).isEmpty)
        #expect(!service.hasLoadedContent(for: first))
        #expect(!service.hasLoadedContent(for: second))
        #expect(service.tables(for: other).map(\.name) == ["orders"])
    }

    @Test("invalidating one scope leaves the connection's other scopes loaded")
    func invalidateScopeLeavesSiblingsLoaded() async {
        let connection = TestFixtures.makeConnection()
        let first = makeScope(connection.id, database: "shop")
        let second = makeScope(connection.id, database: "inventory")
        let service = SchemaService()
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]

        await service.load(scope: first, driver: driver, connection: connection)
        await service.load(scope: second, driver: driver, connection: connection)

        await service.invalidate(scope: first)

        #expect(service.tables(for: first).isEmpty)
        #expect(service.tables(for: second).map(\.name) == ["orders"])
    }
}
