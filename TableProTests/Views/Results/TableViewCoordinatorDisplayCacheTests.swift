//
//  TableViewCoordinatorDisplayCacheTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

private final class VisibleRectTableView: NSTableView {
    var stubVisibleRect: NSRect = .zero

    override var visibleRect: NSRect {
        stubVisibleRect
    }
}

@Suite("TableViewCoordinator display cache invalidation")
@MainActor
struct TableViewCoordinatorDisplayCacheTests {
    private func makeCoordinator(tableRows: TableRows? = nil) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeDisplayCachePersister()
        )
        var captured = tableRows ?? TableRows(
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

    @Test("Wide-row prewarm formats only requested columns")
    func wideRowPrewarmIsColumnBounded() {
        let columnCount = 500
        let columns = (0..<columnCount).map { "column_\($0)" }
        let values = (0..<columnCount).map { PluginCellValue.text("value_\($0)") }
        let tableRows = TableRows(
            rows: [Row(id: .existing(0), values: ContiguousArray(values))],
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: columnCount)
        )
        let coordinator = makeCoordinator(tableRows: tableRows)
        let visibleColumns = IndexSet([0, 1, 2, 498, 499])

        #expect(
            coordinator.cacheDisplayRow(
                at: 0,
                columnIndices: visibleColumns,
                in: tableRows
            ) == visibleColumns.count
        )
        #expect(
            coordinator.cacheDisplayRow(
                at: 0,
                columnIndices: visibleColumns,
                in: tableRows
            ) == 0
        )
        #expect(
            coordinator.cacheDisplayRow(
                at: 0,
                columnIndices: IndexSet(integer: 250),
                in: tableRows
            ) == 1
        )
    }

    @Test("Viewport lookup returns only visible data columns")
    func viewportColumnLookupIsBounded() {
        let columnCount = 500
        let columns = (0..<columnCount).map { "column_\($0)" }
        let tableRows = TableRows(
            rows: [],
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: columnCount)
        )
        let coordinator = makeCoordinator(tableRows: tableRows)
        coordinator.rebuildColumnMetadataCache(from: tableRows)

        let tableView = VisibleRectTableView()
        let rowNumberColumn = DataGridView.makeRowNumberColumn()
        tableView.addTableColumn(rowNumberColumn)
        for index in 0..<columnCount {
            let column = NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(index))
            column.width = 100
            tableView.addTableColumn(column)
        }
        tableView.frame = NSRect(x: 0, y: 0, width: 50_100, height: 100)

        let firstVisibleRect = tableView.rect(ofColumn: 251)
        let lastVisibleRect = tableView.rect(ofColumn: 253)
        tableView.stubVisibleRect = NSRect(
            x: firstVisibleRect.minX,
            y: 0,
            width: lastVisibleRect.maxX - firstVisibleRect.minX,
            height: 100
        )

        #expect(coordinator.visibleDataColumnIndices(in: tableView) == IndexSet(integersIn: 250...252))

        tableView.stubVisibleRect = NSRect(x: 0, y: 0, width: 250, height: 100)
        let leadingColumns = coordinator.visibleDataColumnIndices(in: tableView)
        #expect(!leadingColumns.isEmpty)
        #expect(leadingColumns.first == 0)
    }
}

@MainActor
private final class FakeDisplayCachePersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}

    func clear(for key: ColumnLayoutTableKey) {}
}
