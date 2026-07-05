//
//  TableViewCoordinatorRowCountCacheTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TableViewCoordinator cachedRowCount sync")
@MainActor
struct TableViewCoordinatorRowCountCacheTests {
    private func makeCoordinator(rows: ContiguousArray<Row>) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeRowCountPersister()
        )
        var captured = TableRows(rows: rows, columns: ["c"])
        coordinator.tableRowsProvider = { captured }
        coordinator.tableRowsMutator = { mutation in mutation(&captured) }
        coordinator.updateCache()
        return coordinator
    }

    @Test("cachedRowCount tracks provider after initial load")
    func cacheMatchesProviderOnLoad() {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
            Row(id: .existing(2), values: [.text("c")]),
        ]
        let coordinator = makeCoordinator(rows: rows)

        #expect(coordinator.cachedRowCount == 3)
        #expect(coordinator.cachedRowCount == coordinator.tableRowsProvider().count)
    }

    @Test("updateCache picks up appended rows")
    func updateCacheReflectsAppendedRows() {
        let coordinator = makeCoordinator(rows: [])

        coordinator.tableRowsMutator { rows in
            _ = rows.appendInsertedRow(values: [.text("a")])
            _ = rows.appendInsertedRow(values: [.text("b")])
        }
        coordinator.updateCache()

        #expect(coordinator.cachedRowCount == 2)
        #expect(coordinator.cachedRowCount == coordinator.tableRowsProvider().count)
    }

    @Test("updateCache picks up removed rows")
    func updateCacheReflectsRemovedRows() {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
            Row(id: .existing(2), values: [.text("c")]),
        ]
        let coordinator = makeCoordinator(rows: rows)

        coordinator.tableRowsMutator { rows in
            _ = rows.remove(rowIDs: [.existing(1)])
        }
        coordinator.updateCache()

        #expect(coordinator.cachedRowCount == 2)
        #expect(coordinator.cachedRowCount == coordinator.tableRowsProvider().count)
    }

    @Test("updateCache reflects full replace")
    func updateCacheReflectsFullReplace() {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
        ]
        let coordinator = makeCoordinator(rows: rows)

        coordinator.tableRowsMutator { rows in
            _ = rows.replace(rows: [[.text("x")], [.text("y")], [.text("z")], [.text("w")]])
        }
        coordinator.updateCache()

        #expect(coordinator.cachedRowCount == 4)
        #expect(coordinator.cachedRowCount == coordinator.tableRowsProvider().count)
    }

    @Test("numberOfRows serves cachedRowCount when unsorted")
    func numberOfRowsServesCacheWhenUnsorted() {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
        ]
        let coordinator = makeCoordinator(rows: rows)
        let tableView = NSTableView()

        #expect(coordinator.numberOfRows(in: tableView) == 2)
        #expect(coordinator.numberOfRows(in: tableView) == coordinator.tableRowsProvider().count)
    }

    @Test("numberOfRows serves sortedIDs count when sorted")
    func numberOfRowsServesSortedIDsCountWhenSorted() {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
            Row(id: .existing(2), values: [.text("c")]),
        ]
        let coordinator = makeCoordinator(rows: rows)
        let tableView = NSTableView()
        coordinator.sortedIDs = [.existing(2), .existing(0)]
        coordinator.updateCache()

        #expect(coordinator.numberOfRows(in: tableView) == 2)
    }

    @Test("sortedIDs count takes precedence over cachedRowCount fallback")
    func sortedIDsCountPrecedesCache() {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
            Row(id: .existing(2), values: [.text("c")]),
        ]
        let coordinator = makeCoordinator(rows: rows)

        coordinator.sortedIDs = [.existing(2), .existing(0)]
        coordinator.updateCache()

        #expect(coordinator.cachedRowCount == 2)
    }

    @Test("releaseData zeroes cachedRowCount")
    func releaseDataZeroesCache() {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
        ]
        let coordinator = makeCoordinator(rows: rows)
        #expect(coordinator.cachedRowCount == 2)

        coordinator.releaseData()

        #expect(coordinator.cachedRowCount == 0)
    }
}

@MainActor
private final class FakeRowCountPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}

    func clear(for tableName: String, connectionId: UUID) {}
}
