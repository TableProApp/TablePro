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
}
