//
//  QueryTabGridLayoutScopeTests.swift
//  TableProTests
//
//  D3: a temporary table's grid saved its widths under the permanent table of the same name.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QueryTabGridLayoutScopeTests {
    private let fixture = CoordinatorFixture()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QueryTabGridLayoutScopeTests-\(UUID().uuidString)", isDirectory: true)

    private var tableKey: ColumnLayoutTableKey {
        ColumnLayoutTableKey(connectionId: fixture.connection.id, databaseName: "shop", schemaName: nil, tableName: "orders")
    }

    private func openTable(isTemporary: Bool) throws -> UUID {
        try fixture.tabManager.addTableTab(
            tableName: "orders",
            databaseName: "shop",
            isTemporary: isTemporary,
            allowsDuplicate: true
        )
        return try #require(fixture.tabManager.selectedTabId)
    }

    private func widen(_ store: QueryTabGridStateStore, column: String, to width: CGFloat) {
        var layout = store.columnLayout
        layout.columnWidths[column] = width
        store.columnLayout = layout
        store.flushPendingLayout()
    }

    @Test("A temporary table's grid is ephemeral and never writes the permanent table's saved layout")
    func temporaryTableIsEphemeral() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        let temporary = try openTable(isTemporary: true)
        let store = QueryTabGridStateStore(tabId: temporary, coordinator: fixture.coordinator, persister: persister)

        widen(store, column: "id", to: 240)

        #expect(store.layoutScope == .ephemeral)
        #expect(persister.load(for: tableKey) == nil)
        #expect(fixture.tabManager.tabs.first { $0.id == temporary }?.columnLayout.columnWidths["id"] == 240)
    }

    @Test("The permanent table of the same name keeps its own saved layout")
    func permanentTableSavesUnderItsKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        let permanent = try openTable(isTemporary: false)
        let temporary = try openTable(isTemporary: true)
        let permanentStore = QueryTabGridStateStore(tabId: permanent, coordinator: fixture.coordinator, persister: persister)
        let temporaryStore = QueryTabGridStateStore(tabId: temporary, coordinator: fixture.coordinator, persister: persister)

        widen(permanentStore, column: "id", to: 120)
        widen(temporaryStore, column: "id", to: 300)

        #expect(permanentStore.layoutScope == .table(tableKey))
        #expect(persister.load(for: tableKey)?.columnWidths["id"] == 120)
        #expect(permanentStore.columnLayout.columnWidths["id"] == 120)
    }

    @Test("The model a temporary table's tab gets is ephemeral")
    func temporaryTabModelIsEphemeral() throws {
        let temporary = try openTable(isTemporary: true)
        let permanent = try openTable(isTemporary: false)

        #expect(fixture.coordinator.gridModel(forTab: temporary).store.layoutScope == .ephemeral)
        #expect(fixture.coordinator.gridModel(forTab: permanent).store.layoutScope == .table(tableKey))
    }

    @Test("A query tab's grid is ephemeral")
    func queryTabIsEphemeral() throws {
        fixture.tabManager.addTab(initialQuery: "SELECT * FROM orders")
        let query = try #require(fixture.tabManager.selectedTabId)

        #expect(fixture.coordinator.gridModel(forTab: query).store.layoutScope == .ephemeral)
    }
}
