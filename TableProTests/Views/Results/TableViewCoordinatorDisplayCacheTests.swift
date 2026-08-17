//
//  TableViewCoordinatorDisplayCacheTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TableViewCoordinator display cache invalidation")
@MainActor
struct TableViewCoordinatorDisplayCacheTests {
    private func makeCoordinator(
        tableRows: TableRows = TableRows(
            rows: [Row(id: .existing(0), values: [.text("A")])],
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )
    ) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeDisplayCachePersister()
        )
        var captured = tableRows
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

    @Test("Display format changes recompute cached binary values")
    func displayFormatChangesRecomputeBinaryValues() {
        let data = Data([
            0xAF, 0x49, 0x45, 0x3B, 0x7F, 0x2F, 0xFB, 0x58,
            0xFC, 0xD3, 0x2B, 0xD3, 0x99, 0x59, 0x9F, 0xA5,
        ])
        let type = ColumnType.blob(rawType: "BLOB")
        let coordinator = makeCoordinator(tableRows: TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(data)])],
            columns: ["id"],
            columnTypes: [type]
        ))

        let raw = coordinator.displayValue(
            forID: .existing(0), column: 0, rawValue: .bytes(data), columnType: type
        )
        #expect(raw == "0xAF49453B7F2FFB58FCD32BD399599FA5")

        coordinator.updateDisplayFormats([.uuid])
        let formatted = coordinator.displayValue(
            forID: .existing(0), column: 0, rawValue: .bytes(data), columnType: type
        )
        #expect(formatted == "af49453b-7f2f-fb58-fcd3-2bd399599fa5")

        coordinator.updateDisplayFormats([nil])
        let restored = coordinator.displayValue(
            forID: .existing(0), column: 0, rawValue: .bytes(data), columnType: type
        )
        #expect(restored == "0xAF49453B7F2FFB58FCD32BD399599FA5")
    }
}

@MainActor
private final class FakeDisplayCachePersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}

    func clear(for key: ColumnLayoutTableKey) {}
}
