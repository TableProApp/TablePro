//
//  TableViewCoordinatorLayoutTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class FakeColumnLayoutPersister: ColumnLayoutPersisting {
    var stored: [String: ColumnLayoutState] = [:]

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? {
        stored[key.tableName]
    }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {
        stored[key.tableName] = layout
    }

    func clear(for key: ColumnLayoutTableKey) {
        stored.removeValue(forKey: key.tableName)
    }
}

@Suite("TableViewCoordinator.savedColumnLayout")
@MainActor
struct TableViewCoordinatorLayoutTests {
    private func makeCoordinator(
        tabType: TabType?,
        connectionId: UUID?,
        tableName: String?,
        persister: ColumnLayoutPersisting
    ) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: persister
        )
        coordinator.tabType = tabType
        coordinator.connectionId = connectionId
        coordinator.tableName = tableName
        return coordinator
    }

    private func nonEmptyLayout() -> ColumnLayoutState {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 60]
        return layout
    }

    @Test("Table tab returns persisted layout when present, ignoring binding")
    func tableTabPrefersPersister() {
        let persister = FakeColumnLayoutPersister()
        let stored = nonEmptyLayout()
        persister.stored["users"] = stored
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: persister
        )

        var binding = ColumnLayoutState()
        binding.columnWidths = ["other": 999]

        let resolved = coordinator.savedColumnLayout(binding: binding)
        #expect(resolved?.columnWidths == ["id": 60])
    }

    @Test("Table tab falls back to binding when persister has nothing")
    func tableTabFallsBackToBinding() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        let resolved = coordinator.savedColumnLayout(binding: nonEmptyLayout())
        #expect(resolved?.columnWidths == ["id": 60])
    }

    @Test("Table tab returns nil when both persister and binding are empty")
    func tableTabBothEmptyReturnsNil() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        #expect(coordinator.savedColumnLayout(binding: ColumnLayoutState()) == nil)
    }

    @Test("Query tab drops a stale saved column order so new columns keep their query position")
    func queryTabDropsStaleColumnOrder() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        var binding = ColumnLayoutState()
        binding.columnWidths = ["id": 60, "business_model": 120]
        binding.columnOrder = ["id", "business_model"]

        var expected = ColumnLayoutState()
        expected.columnWidths = ["id": 60, "business_model": 120]

        #expect(coordinator.savedColumnLayout(binding: binding) == expected)
    }

    @Test("Query tab keeps remembered widths when there is no saved order")
    func queryTabKeepsWidths() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )

        var expected = ColumnLayoutState()
        expected.columnWidths = ["id": 60]

        #expect(coordinator.savedColumnLayout(binding: nonEmptyLayout()) == expected)
    }

    @Test("Query tab returns nil when binding is empty")
    func queryTabEmptyReturnsNil() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        #expect(coordinator.savedColumnLayout(binding: ColumnLayoutState()) == nil)
    }

    @Test("Table tab without connectionId or tableName falls back to binding")
    func tableTabMissingIdentitySkipsPersister() {
        let persister = FakeColumnLayoutPersister()
        persister.stored["users"] = nonEmptyLayout()
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: nil,
            tableName: nil,
            persister: persister
        )

        var binding = ColumnLayoutState()
        binding.columnWidths = ["fallback": 42]

        let resolved = coordinator.savedColumnLayout(binding: binding)
        #expect(resolved?.columnWidths == ["fallback": 42])
    }

    @Test("resolvedColumnLayout merges live widths on top of a saved layout")
    func resolvedMergesLiveWidthsOntoSaved() {
        let persister = FakeColumnLayoutPersister()
        var saved = ColumnLayoutState()
        saved.columnWidths = ["id": 60, "name": 100]
        persister.stored["users"] = saved
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: persister
        )

        let resolved = coordinator.resolvedColumnLayout(
            binding: ColumnLayoutState(),
            liveWidths: ["name": 250]
        )
        #expect(resolved?.columnWidths == ["id": 60, "name": 250])
    }

    @Test("resolvedColumnLayout returns nil with no saved layout so widths recompute after a reset")
    func resolvedReturnsNilWhenNothingSaved() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        #expect(
            coordinator.resolvedColumnLayout(binding: ColumnLayoutState(), liveWidths: ["name": 250]) == nil
        )
    }

    @Test("Live widths are kept on a same-table reload but discarded on a table switch")
    func liveWidthsGatedByTableIdentity() {
        let connectionId = UUID()
        let tableA = ColumnLayoutTableKey(connectionId: connectionId, databaseName: "db", schemaName: "public", tableName: "a")
        let tableB = ColumnLayoutTableKey(connectionId: connectionId, databaseName: "db", schemaName: "public", tableName: "b")
        let live: [String: CGFloat] = ["id": 120, "name": 240]

        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: tableA, current: tableA, liveWidths: live) == live)
        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: tableA, current: tableB, liveWidths: live).isEmpty)
        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: nil, current: tableA, liveWidths: live).isEmpty)
        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: nil, current: nil, liveWidths: live) == live)
    }
}
