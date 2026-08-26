//
//  DataGridRowIdentityTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopRowIdentityPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// `insertRows(at:)` and `removeRows(at:)` move an already-built row view to its new slot without
/// asking the delegate for it again, so an index captured when the view was mounted names a
/// different row from then on. Measured: after `removeRows(at: [1])` the view at display row 1 still
/// carried 2 and an insert left two views both claiming 0, which sent a double-click to the wrong
/// row and had an accessibility cell speak one row's value under another row's number.
@Suite("Data grid row identity", .serialized)
@MainActor
struct DataGridRowIdentityTests {
    private struct Grid {
        let window: NSWindow
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator
        let rowCount: Box

        var rowViews: [DataGridRowView] {
            (0 ..< tableView.numberOfRows).compactMap {
                tableView.rowView(atRow: $0, makeIfNecessary: false) as? DataGridRowView
            }
        }
    }

    /// The provider is read on every access, so the row count has to live somewhere the test can
    /// move before it tells the table view about the mutation, exactly as the coordinator does.
    private final class Box {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    private static func rows(count: Int) -> TableRows {
        TableRows.from(
            queryRows: (0 ..< count).map { [.text("id-\($0)"), .text("name-\($0)")] },
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
    }

    private func makeGrid(rowCount: Int = 5) -> Grid {
        let box = Box(rowCount)
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopRowIdentityPersister()
        )
        coordinator.tableRowsProvider = { Self.rows(count: box.value) }
        coordinator.rebuildColumnMetadataCache(from: Self.rows(count: box.value))
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 21
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 120 }
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        tableView.reloadData()
        window.layoutIfNeeded()
        for row in 0 ..< tableView.numberOfRows {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
        }
        return Grid(window: window, tableView: tableView, coordinator: coordinator, rowCount: box)
    }

    @Test("Every mounted row reports its own display row before any mutation")
    func rowsStartCorrect() {
        let grid = makeGrid()
        #expect(grid.rowViews.map(\.rowIndex) == Array(0 ..< 5))
    }

    @Test("Removing a row above a mounted one moves its index down")
    func removeShiftsTheRowsBelow() throws {
        let grid = makeGrid()
        let third = try #require(grid.tableView.rowView(atRow: 2, makeIfNecessary: false) as? DataGridRowView)
        #expect(third.rowIndex == 2)

        grid.rowCount.value = 4
        grid.coordinator.updateCache()
        grid.tableView.removeRows(at: IndexSet(integer: 1), withAnimation: [])

        #expect(third.rowIndex == 1)
        #expect(grid.rowViews.map(\.rowIndex) == Array(0 ..< 4))
    }

    @Test("Inserting a row above a mounted one moves its index up")
    func insertShiftsTheRowsBelow() throws {
        let grid = makeGrid()
        let first = try #require(grid.tableView.rowView(atRow: 0, makeIfNecessary: false) as? DataGridRowView)
        #expect(first.rowIndex == 0)

        grid.rowCount.value = 6
        grid.coordinator.updateCache()
        grid.tableView.insertRows(at: IndexSet(integer: 0), withAnimation: [])

        #expect(first.rowIndex == 1)
        #expect(grid.rowViews.map(\.rowIndex) == Array(0 ..< 6))
    }

    /// A row view outside any table keeps the index it was handed, which is the shape the copy tests
    /// build and the only case the stored seed still answers for.
    @Test("A row view in no table falls back to the index it was given")
    func detachedRowKeepsItsSeededIndex() {
        let rowView = DataGridRowView()
        rowView.rowIndex = 7
        #expect(rowView.rowIndex == 7)
    }

    /// The accessibility cell is a real mounted view, so an incremental mutation moves it the same
    /// way and it used to keep speaking the row it was built for.
    @Test("An accessibility cell moved by a removal speaks its new row")
    func accessibilityCellFollowsTheRemoval() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let grid = makeGrid()
        grid.tableView.reloadData()
        grid.window.layoutIfNeeded()

        let dataColumn = try #require(grid.coordinator.tableColumnIndex(for: 0))
        let cell = try #require(
            grid.tableView.view(atColumn: dataColumn, row: 2, makeIfNecessary: true)
                as? DataGridCellAccessibilityView
        )
        #expect(cell.accessibilityValue() as? String == "id-2")
        #expect(cell.accessibilityRowIndexRange().location == 2)

        grid.rowCount.value = 4
        grid.coordinator.updateCache()
        grid.tableView.removeRows(at: IndexSet(integer: 1), withAnimation: [])

        #expect(cell.accessibilityRowIndexRange().location == 1)
        #expect(cell.accessibilityValue() as? String == "id-1")
    }
}
