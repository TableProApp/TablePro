//
//  SavedCustomizationsServiceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SavedCustomizationsService")
@MainActor
struct SavedCustomizationsServiceTests {
    private func makeStores() throws -> (FileColumnLayoutPersister, FilterSettingsStorage) {
        let layoutDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-layout-\(UUID().uuidString)", isDirectory: true)
        let filterDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-filter-\(UUID().uuidString)", isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: "sc-\(UUID().uuidString)"))
        return (
            FileColumnLayoutPersister(storageDirectory: layoutDir),
            FilterSettingsStorage(filterStateDirectory: filterDir, defaults: defaults)
        )
    }

    @Test("Lists a table with a saved layout and filters, then resets it")
    func listsAndResets() throws {
        let (layout, filter) = try makeStores()
        let connectionId = UUID()

        var state = ColumnLayoutState()
        state.columnWidths = ["id": 80]
        layout.save(state, for: ColumnLayoutTableKey(
            connectionId: connectionId, databaseName: "shop", schemaName: "public", tableName: "orders"
        ))
        filter.saveLastFilters(
            [TestFixtures.makeTableFilter(column: "id")],
            for: "orders", connectionId: connectionId, databaseName: "shop", schemaName: "public"
        )
        filter.waitForPendingDiskWrites()

        let items = SavedCustomizationsService.all(layoutStore: layout, filterStore: filter)
        #expect(items.count == 1)
        #expect(items.first?.hasLayout == true)
        #expect(items.first?.hasFilters == true)
        #expect(items.first?.scope.displayName == "shop.public.orders")

        let scope = try #require(items.first?.scope)
        SavedCustomizationsService.reset(scope, layoutStore: layout, filterStore: filter)
        filter.waitForPendingDiskWrites()

        #expect(SavedCustomizationsService.all(layoutStore: layout, filterStore: filter).isEmpty)
    }
}
