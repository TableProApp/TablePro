//
//  SortableHeaderResizeZoneTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class ResizeZoneLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// A hidden column's header rect is zero, so its trailing edge is x = 0 and it reads as a divider
/// at the header's leading edge: the resize cursor appeared over the row-number heading and the
/// header swallowed the clicks landing there.
@Suite("Sortable header resize zone", .serialized)
@MainActor
struct SortableHeaderResizeZoneTests {
    private struct Grid {
        let window: NSWindow
        let coordinator: TableViewCoordinator
        let header: SortableHeaderView
    }

    private func makeGrid(columns: [String], hidden: Set<String> = [], columnWidth: CGFloat = 120) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: ResizeZoneLayoutPersister()
        )
        let queryRows = [columns.map { PluginCellValue.text($0) }]
        let tableRows = TableRows.from(
            queryRows: queryRows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 21
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView

        let header = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        header.coordinator = coordinator
        tableView.headerView = header

        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: hidden,
            widthCalculator: { _, _ in columnWidth }
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        return Grid(window: window, coordinator: coordinator, header: header)
    }

    private func point(x: CGFloat, in grid: Grid) -> NSPoint {
        NSPoint(x: x, y: grid.header.bounds.midY)
    }

    @Test("The header's leading edge is not a resize zone when a column is hidden")
    func theLeadingEdgeIsNotAResizeZone() throws {
        let grid = makeGrid(columns: ["id", "name", "email"], hidden: ["name"])

        #expect(!grid.header.isInResizeZone(point: point(x: 0, in: grid)))
        #expect(!grid.header.isInResizeZone(point: point(x: 2, in: grid)))
    }

    /// Surplus slots need no user action: a narrower result in a grid that held a wider one leaves them.
    @Test("Slots left over from a wider result are not resize zones")
    func surplusPoolSlotsAreNotResizeZones() throws {
        let grid = makeGrid(columns: ["a", "b", "c", "d", "e", "f"])
        let tableView = try #require(grid.coordinator.tableView)
        let narrower = TableRows.from(
            queryRows: [[.text("a"), .text("b")]],
            columns: ["a", "b"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        grid.coordinator.tableRowsProvider = { narrower }
        grid.coordinator.rebuildColumnMetadataCache(from: narrower)
        grid.coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: grid.coordinator.identitySchema,
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 120 }
        )
        tableView.layoutSubtreeIfNeeded()

        #expect(!grid.header.isInResizeZone(point: point(x: 0, in: grid)))
        #expect(!grid.header.isInResizeZone(point: point(x: 2, in: grid)))
    }

    @Test("A presented column's trailing edge is still a resize zone")
    func aPresentedColumnEdgeIsAResizeZone() throws {
        let grid = makeGrid(columns: ["id", "name", "email"])
        let tableView = try #require(grid.coordinator.tableView)
        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let edge = grid.header.headerRect(ofColumn: firstData).maxX
        #expect(edge > 0)

        #expect(grid.header.isInResizeZone(point: point(x: edge, in: grid)))
    }

    /// The middle of a heading is where a click sorts.
    @Test("The middle of a column heading is not a resize zone")
    func theMiddleOfAHeadingIsNotAResizeZone() throws {
        let grid = makeGrid(columns: ["id", "name", "email"])
        let firstData = try #require(grid.coordinator.firstPresentedColumnIndex())
        let rect = grid.header.headerRect(ofColumn: firstData)

        #expect(!grid.header.isInResizeZone(point: point(x: rect.midX, in: grid)))
    }

    @Test("The row-number column's trailing edge is not a resize zone")
    func theRowNumberColumnEdgeIsNotAResizeZone() throws {
        let grid = makeGrid(columns: ["id", "name"])
        let tableView = try #require(grid.coordinator.tableView)
        let rowNumber = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        #expect(rowNumber >= 0)
        let edge = grid.header.headerRect(ofColumn: rowNumber).maxX

        #expect(!grid.header.isInResizeZone(point: point(x: edge, in: grid)))
    }
}
