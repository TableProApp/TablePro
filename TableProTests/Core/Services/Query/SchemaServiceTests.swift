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

@Suite("SchemaService")
@MainActor
struct SchemaServiceTests {
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
        await service.loadSchemaTables(connectionId: connectionId, schema: "sales", driver: driver)
        await service.loadSchemaTables(connectionId: connectionId, schema: "hr", driver: driver)

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
        await service.loadSchemaTables(connectionId: connectionId, schema: "sales", driver: driver)
        await service.loadSchemaTables(connectionId: connectionId, schema: "mirror", driver: driver)

        let matching = service.allLoadedTables(for: connectionId).filter { $0.id == shared.id }
        #expect(matching.count == 1)
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

        service.markLoadFailed(connectionId: connectionId, message: "connect timed out")

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

        service.markLoadFailed(connectionId: connectionId, message: "refresh failed")

        #expect(service.state(for: connectionId) == .loaded(driver.tablesToReturn))
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
