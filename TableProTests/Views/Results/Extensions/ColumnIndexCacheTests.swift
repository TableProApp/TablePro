import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class StubColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}
    func clear(for tableName: String, connectionId: UUID) {}
}

@Suite("TableViewCoordinator column index cache")
@MainActor
struct ColumnIndexCacheTests {
    private func makeCoordinator() -> TableViewCoordinator {
        TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubColumnLayoutPersister()
        )
    }

    private func attachColumns(_ tableView: NSTableView, count: Int) {
        tableView.addTableColumn(
            NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        )
        for slot in 0..<count {
            tableView.addTableColumn(
                NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(slot))
            )
        }
    }

    @Test("resolved table column index mirrors the schema-backed column order")
    func resolvesDataColumnToTableColumnIndex() {
        let coordinator = makeCoordinator()
        let tableView = NSTableView()
        attachColumns(tableView, count: 3)
        coordinator.tableView = tableView
        _ = coordinator.rebuildColumnMetadataCache(
            from: TableRows.from(
                queryRows: [],
                columns: ["id", "name", "email"],
                columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: 3)
            )
        )

        #expect(coordinator.tableColumnIndex(for: 0) == 1)
        #expect(coordinator.tableColumnIndex(for: 1) == 2)
        #expect(coordinator.tableColumnIndex(for: 2) == 3)
    }

    @Test("repeated lookups keep returning the same value")
    func lookupsAreStableAcrossCalls() {
        let coordinator = makeCoordinator()
        let tableView = NSTableView()
        attachColumns(tableView, count: 2)
        coordinator.tableView = tableView
        _ = coordinator.rebuildColumnMetadataCache(
            from: TableRows.from(
                queryRows: [],
                columns: ["a", "b"],
                columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: 2)
            )
        )

        let first = coordinator.tableColumnIndex(for: 1)
        for _ in 0..<5 {
            #expect(coordinator.tableColumnIndex(for: 1) == first)
        }
    }

    @Test("invalidate after a column reorder reflects the new layout")
    func invalidateReflectsReorderedColumns() {
        let coordinator = makeCoordinator()
        let tableView = NSTableView()
        attachColumns(tableView, count: 3)
        coordinator.tableView = tableView
        _ = coordinator.rebuildColumnMetadataCache(
            from: TableRows.from(
                queryRows: [],
                columns: ["id", "name", "email"],
                columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: 3)
            )
        )
        #expect(coordinator.tableColumnIndex(for: 0) == 1)

        tableView.moveColumn(1, toColumn: 3)
        coordinator.tableViewColumnDidMove(
            Notification(name: NSTableView.columnDidMoveNotification, object: tableView)
        )

        #expect(coordinator.tableColumnIndex(for: 0) == 3)
        #expect(coordinator.tableColumnIndex(for: 1) == 1)
        #expect(coordinator.tableColumnIndex(for: 2) == 2)
    }

    @Test("schema rebuild drops stale cached indices when columns shrink")
    func schemaRebuildInvalidatesCache() {
        let coordinator = makeCoordinator()
        let tableView = NSTableView()
        attachColumns(tableView, count: 2)
        coordinator.tableView = tableView
        _ = coordinator.rebuildColumnMetadataCache(
            from: TableRows.from(
                queryRows: [],
                columns: ["a", "b"],
                columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: 2)
            )
        )
        #expect(coordinator.tableColumnIndex(for: 1) == 2)

        if let second = tableView.tableColumns.last(where: {
            $0.identifier == ColumnIdentitySchema.slotIdentifier(1)
        }) {
            tableView.removeTableColumn(second)
        }
        _ = coordinator.rebuildColumnMetadataCache(
            from: TableRows.from(
                queryRows: [],
                columns: ["a"],
                columnTypes: [ColumnType.text(rawType: nil)]
            )
        )

        #expect(coordinator.tableColumnIndex(for: 1) == nil)
    }

    @Test("an out-of-range data column resolves to nil")
    func outOfRangeReturnsNil() {
        let coordinator = makeCoordinator()
        let tableView = NSTableView()
        attachColumns(tableView, count: 1)
        coordinator.tableView = tableView
        _ = coordinator.rebuildColumnMetadataCache(
            from: TableRows.from(
                queryRows: [],
                columns: ["only"],
                columnTypes: [ColumnType.text(rawType: nil)]
            )
        )

        #expect(coordinator.tableColumnIndex(for: 5) == nil)
    }
}
