//
//  ExportTriggerListingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Shaped like Oracle: a schema-wide list it answers, with the Compare flag left false on purpose.
private final class SchemaTriggerListDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var schemas: [String?] = []

    var triggerListReads: [String?] { lock.withLock { schemas } }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        lock.withLock { schemas.append(schema) }
        return [
            PluginTriggerInfo(name: "ORDERS_BI", table: "ORDERS", timing: "BEFORE", event: "INSERT", statement: "BEGIN NULL; END;")
        ]
    }
}

private final class NoTriggerListDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    var executedQueries: [String] { lock.withLock { queries } }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { queries.append(query) }
        return .empty
    }
}

struct ExportTriggerListingTests {
    private func load(_ driver: any PluginDatabaseDriver) async -> [ExportObjectItem] {
        await ExportObjectLoader.loadObjects(
            request: .init(containerName: "SALES", schema: "SALES", kinds: [.table, .trigger]),
            tables: [TableInfo(name: "ORDERS", type: .table, rowCount: nil)],
            driver: PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .oracle), pluginDriver: driver)
        )
    }

    @Test("Triggers reach the export from a driver whose Compare flag stays false")
    func triggersListedWithoutTheCompareFlag() async {
        let driver = SchemaTriggerListDriver()
        let items = await load(driver)

        #expect(!driver.providesBulkTriggerFetch)
        #expect(driver.triggerListReads == ["SALES"])
        let trigger = items.first { $0.kind == .trigger }
        #expect(trigger?.name == "ORDERS_BI")
        #expect(trigger?.parentTable == "ORDERS")
        #expect(items.contains { $0.name == "ORDERS" && $0.kind == .table })
    }

    @Test("A driver with no schema-wide trigger list adds no triggers and runs no query")
    func driverWithoutTriggerListReadsNothing() async {
        let driver = NoTriggerListDriver()
        let items = await load(driver)

        #expect(items.map(\.kind) == [.table])
        #expect(driver.executedQueries.isEmpty)
    }
}
