//
//  TableViewCoordinatorDisplayCacheTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TableViewCoordinator display cache invalidation")
@MainActor
struct TableViewCoordinatorDisplayCacheTests {
    private func makeCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeDisplayCachePersister()
        )
        var captured = TableRows(
            rows: [Row(id: .existing(0), values: [.text("A")])],
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )
        coordinator.tableRowsProvider = { captured }
        coordinator.tableRowsMutator = { mutation in mutation(&captured) }
        coordinator.updateCache()
        return coordinator
    }

    private func value(_ text: String) -> PluginCellValue { .text(text) }

    @Test("Cache returns the stale value for a reused RowID until it is invalidated")
    func invalidationClearsStaleContent() {
        let coordinator = makeCoordinator()
        let column = 0
        let type: ColumnType = .text(rawType: nil)

        let primed = coordinator.displayValue(forID: .existing(0), column: column, rawValue: value("A"), columnType: type)
        #expect(primed == "A")

        let stale = coordinator.displayValue(forID: .existing(0), column: column, rawValue: value("B"), columnType: type)
        #expect(stale == "A")

        coordinator.invalidateDisplayCache()

        let fresh = coordinator.displayValue(forID: .existing(0), column: column, rawValue: value("B"), columnType: type)
        #expect(fresh == "B")
    }
}

@MainActor
private final class FakeDisplayCachePersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}

    func clear(for key: ColumnLayoutTableKey) {}
}
