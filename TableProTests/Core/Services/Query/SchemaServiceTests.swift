//
//  SchemaServiceTests.swift
//  TableProTests
//
//  Tests for SchemaService aggregation across per-schema table lists.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct SchemaServiceTests {
    private func unnamedDatabase(_ connectionId: UUID) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "", schema: nil)
    }

    @Test("allLoadedTables unions tables across loaded per-schema lists")
    func allLoadedTablesUnionsPerSchema() async {
        let connectionId = UUID()
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
        await service.loadSchemaObjects(schema: "sales", in: unnamedDatabase(connectionId), driver: driver)
        await service.loadSchemaObjects(schema: "hr", in: unnamedDatabase(connectionId), driver: driver)

        let names = Set(service.allLoadedTables(for: connectionId).map(\.name))
        #expect(names == ["orders", "leads", "employees"])
    }

    @Test("allLoadedTables deduplicates tables that share an id across schema states")
    func allLoadedTablesDeduplicatesById() async {
        let connectionId = UUID()
        let driver = MockDatabaseDriver()
        let shared = TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales")
        driver.schemaTablesToReturn = [
            "sales": [shared],
            "mirror": [shared]
        ]

        let service = SchemaService()
        await service.loadSchemaObjects(schema: "sales", in: unnamedDatabase(connectionId), driver: driver)
        await service.loadSchemaObjects(schema: "mirror", in: unnamedDatabase(connectionId), driver: driver)

        let matching = service.allLoadedTables(for: connectionId).filter { $0.id == shared.id }
        #expect(matching.count == 1)
    }

    @Test("allLoadedTables keeps two tables whose names differ only in where a period sits")
    func allLoadedTablesKeepsDottedNamesApart() async {
        let connectionId = UUID()
        let driver = MockDatabaseDriver()
        driver.schemaTablesToReturn = [
            "a": [TableInfo(name: "b.c", type: .table, rowCount: 0, schema: "a")],
            "a.b": [TableInfo(name: "c", type: .table, rowCount: 0, schema: "a.b")]
        ]

        let service = SchemaService()
        await service.loadSchemaObjects(schema: "a", in: unnamedDatabase(connectionId), driver: driver)
        await service.loadSchemaObjects(schema: "a.b", in: unnamedDatabase(connectionId), driver: driver)

        let loaded = service.allLoadedTables(for: connectionId)
        #expect(loaded.count == 2)
        #expect(Set(loaded.map(\.schema)) == ["a", "a.b"])
    }

    @Test("allLoadedTables is empty for a connection with no loaded state")
    func allLoadedTablesEmptyWhenNothingLoaded() {
        let service = SchemaService()
        #expect(service.allLoadedTables(for: UUID()).isEmpty)
    }

    @Test("markLoadFailed surfaces a failed state for spinners to resolve")
    func markLoadFailedSetsFailedState() {
        let service = SchemaService()
        let connectionId = UUID()

        service.markLoadFailed(connectionId: connectionId, message: "connect timed out", scope: nil)

        #expect(service.state(for: connectionId) == .failed("connect timed out"))
    }

    @Test("markLoadFailed keeps already-loaded tables instead of replacing them")
    func markLoadFailedKeepsLoadedTables() async {
        let connectionId = UUID()
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let service = SchemaService()
        await service.reload(
            connectionId: connectionId,
            driver: driver,
            connection: TestFixtures.makeConnection()
        )

        service.markLoadFailed(connectionId: connectionId, message: "refresh failed", scope: nil)

        #expect(service.state(for: connectionId) == .loaded(driver.tablesToReturn))
    }

    @Test("A failed refresh of the database already loaded keeps its tables")
    func failureForTheLoadedScopeKeepsTables() async {
        let connection = TestFixtures.makeConnection()
        let scope = DatabaseScope(connectionId: connection.id, database: "sales", schema: nil)
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let service = SchemaService()
        await service.reload(connectionId: connection.id, driver: driver, connection: connection, scope: scope)

        service.markLoadFailed(connectionId: connection.id, message: "refresh failed", scope: scope)

        #expect(service.state(for: connection.id) == .loaded(driver.tablesToReturn))
        #expect(service.loadedScope(for: connection.id) == scope)
    }

    /// MySQL switches database in place, so the tables of the database being left were still loaded
    /// when the new one failed to load, and the sidebar listed them under the new name with no error.
    @Test("A failure for a newly selected database replaces the tables of the one being left")
    func failureForAnotherScopeReplacesTables() async {
        let connection = TestFixtures.makeConnection()
        let sales = DatabaseScope(connectionId: connection.id, database: "sales", schema: nil)
        let billing = DatabaseScope(connectionId: connection.id, database: "billing", schema: nil)
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let service = SchemaService()
        await service.reload(connectionId: connection.id, driver: driver, connection: connection, scope: sales)

        service.markLoadFailed(connectionId: connection.id, message: "Access denied", scope: billing)

        #expect(service.state(for: connection.id) == .failed("Access denied"))
        #expect(service.loadedScope(for: connection.id) == nil)
    }

    @Test("A table fetch that fails for a newly selected database reports the failure")
    func failedLoadForAnotherScopeReportsFailure() async {
        let connection = TestFixtures.makeConnection()
        let sales = DatabaseScope(connectionId: connection.id, database: "sales", schema: nil)
        let billing = DatabaseScope(connectionId: connection.id, database: "billing", schema: nil)
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let service = SchemaService()
        await service.reload(connectionId: connection.id, driver: driver, connection: connection, scope: sales)

        driver.fetchTablesError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Access denied"])
        await service.reload(connectionId: connection.id, driver: driver, connection: connection, scope: billing)

        #expect(service.state(for: connection.id) == .failed("Access denied"))
        #expect(service.loadedScope(for: connection.id) == nil)
    }

    @Test("A table fetch that fails on refresh of the same database keeps its tables")
    func failedRefreshOfTheSameScopeKeepsTables() async {
        let connection = TestFixtures.makeConnection()
        let sales = DatabaseScope(connectionId: connection.id, database: "sales", schema: nil)
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let service = SchemaService()
        await service.reload(connectionId: connection.id, driver: driver, connection: connection, scope: sales)

        driver.fetchTablesError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out"])
        await service.reload(connectionId: connection.id, driver: driver, connection: connection, scope: sales)

        #expect(service.state(for: connection.id) == .loaded(driver.tablesToReturn))
        #expect(service.loadedScope(for: connection.id) == sales)
    }

    @Test("Tables and the other object kinds settle a failure by the same rule")
    func tableFailureRuleMatchesSideObjects() {
        let tables = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let pairs: [(SchemaState, MetadataLoadState<[TableInfo]>)] = [
            (.idle, .idle),
            (.loading, .loading),
            (.loaded(tables), .loaded(tables)),
            (.failed("old"), .failed("old"))
        ]
        for (schemaState, metadataState) in pairs {
            for discarding in [false, true] {
                let settledTables = schemaState.settled(byFailure: "new", discardingValue: discarding)
                let settledObjects = metadataState.settled(by: .failed("new"), discardingValue: discarding)
                switch (settledTables, settledObjects) {
                case (.loaded(let left), .loaded(let right)):
                    #expect(left == right)
                case (.failed(let left), .failed(let right)):
                    #expect(left == right)
                default:
                    Issue.record("Rules disagree for \(schemaState), discarding \(discarding)")
                }
            }
        }
    }

    @Test("hierarchical load lists schemas")
    func hierarchicalLoadListsSchemas() async {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["HR", "SALES"]
        let connection = TestFixtures.makeConnection(type: .oracle)
        let service = SchemaService()

        await service.reload(connectionId: connection.id, driver: driver, connection: connection)

        #expect(service.state(for: connection.id) == .loaded([]))
        #expect(service.schemas(for: connection.id) == ["HR", "SALES"])
    }

    @Test("hierarchical schema list failure surfaces a failed state")
    func hierarchicalFailureSetsFailedState() async {
        let driver = MockDatabaseDriver()
        driver.fetchSchemasError = DatabaseError.connectionFailed("schema list failed")
        let connection = TestFixtures.makeConnection(type: .oracle)
        let service = SchemaService()

        await service.reload(connectionId: connection.id, driver: driver, connection: connection)

        var isFailed = false
        if case .failed = service.state(for: connection.id) {
            isFailed = true
        }
        #expect(isFailed)
    }

    @Test("refresh without a session surfaces a failed state")
    func refreshWithoutSessionSetsFailedState() async {
        let service = SchemaService()
        let connectionId = UUID()

        await service.refresh(connectionId: connectionId)

        var isFailed = false
        if case .failed = service.state(for: connectionId) {
            isFailed = true
        }
        #expect(isFailed)
    }
}
