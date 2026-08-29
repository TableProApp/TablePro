//
//  CellEditorMovementTargetTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class StubLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// Where the inline editor goes when it is left with Tab, Shift+Tab, Up or Down, and what moving
/// the cell cursor there costs. Tab wraps across rows because that is what Tab means; Up and Down
/// hold the column and stop at the ends (#2569).
@Suite("Cell editor movement target")
@MainActor
struct CellEditorMovementTargetTests {
    private struct Grid {
        let coordinator: TableViewCoordinator
        let tableView: KeyHandlingTableView
        let dataColumns: [Int]
    }

    private func makeGrid(rowCount: Int, columnNames: [String]) -> Grid {
        let tableView = KeyHandlingTableView()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        let rowNumberColumn = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        rowNumberColumn.width = 40
        tableView.addTableColumn(rowNumberColumn)

        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: (0..<rowCount).map { row in
                columnNames.indices.map { PluginCellValue.text("r\(row)c\($0)") }
            },
            columns: columnNames,
            columnTypes: columnNames.map { _ in ColumnType.text(rawType: "TEXT") }
        )

        coordinator.tableView = tableView
        tableView.coordinator = coordinator
        coordinator.tableRowsProvider = { rows }
        coordinator.rebuildColumnMetadataCache(from: rows)
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: rows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 100 }
        )
        tableView.dataSource = coordinator
        coordinator.updateCache()
        tableView.reloadData()

        let dataColumns = tableView.tableColumns.indices.filter {
            coordinator.presentsColumn(atTableColumnIndex: $0)
        }
        return Grid(coordinator: coordinator, tableView: tableView, dataColumns: dataColumns)
    }

    private func target(
        _ grid: Grid,
        row: Int,
        column: Int,
        movement: CellEditorMovement
    ) -> (row: Int, column: Int)? {
        grid.coordinator.movementTarget(
            from: (row: row, column: column),
            movement: movement,
            in: grid.tableView
        )
    }

    @Test("The grid harness presents every data column")
    func harnessPresentsEveryDataColumn() {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])

        #expect(grid.dataColumns.count == 2)
        #expect(grid.tableView.numberOfRows == 3)
    }

    @Test("Down steps one row and holds the column")
    func downStepsOneRowAndHoldsTheColumn() throws {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])
        let column = try #require(grid.dataColumns.last)

        let moved = try #require(target(grid, row: 0, column: column, movement: .down))

        #expect(moved.row == 1)
        #expect(moved.column == column)
    }

    @Test("Up steps one row and holds the column")
    func upStepsOneRowAndHoldsTheColumn() throws {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])
        let column = try #require(grid.dataColumns.first)

        let moved = try #require(target(grid, row: 2, column: column, movement: .up))

        #expect(moved.row == 1)
        #expect(moved.column == column)
    }

    @Test("Down on the last row does not wrap")
    func downOnTheLastRowDoesNotWrap() throws {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])
        let column = try #require(grid.dataColumns.first)

        let past = target(grid, row: 2, column: column, movement: .down)
        #expect(past == nil)
    }

    @Test("Up on the first row does not wrap")
    func upOnTheFirstRowDoesNotWrap() throws {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])
        let column = try #require(grid.dataColumns.first)

        let past = target(grid, row: 0, column: column, movement: .up)
        #expect(past == nil)
    }

    @Test("Tab walks the row and wraps onto the next row's first column")
    func tabWalksTheRowAndWraps() throws {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])
        let first = try #require(grid.dataColumns.first)
        let last = try #require(grid.dataColumns.last)

        let within = try #require(target(grid, row: 0, column: first, movement: .tab))
        #expect(within.row == 0)
        #expect(within.column == last)

        let wrapped = try #require(target(grid, row: 0, column: last, movement: .tab))
        #expect(wrapped.row == 1)
        #expect(wrapped.column == first)

        let past = target(grid, row: 2, column: last, movement: .tab)
        #expect(past == nil)
    }

    @Test("Shift+Tab walks back and wraps onto the previous row's last column")
    func backtabWalksBackAndWraps() throws {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])
        let first = try #require(grid.dataColumns.first)
        let last = try #require(grid.dataColumns.last)

        let within = try #require(target(grid, row: 1, column: last, movement: .backtab))
        #expect(within.row == 1)
        #expect(within.column == first)

        let wrapped = try #require(target(grid, row: 1, column: first, movement: .backtab))
        #expect(wrapped.row == 0)
        #expect(wrapped.column == last)

        let past = target(grid, row: 0, column: first, movement: .backtab)
        #expect(past == nil)
    }

    /// A vertical step keeps whatever position it was given, so the row-number column and the
    /// pool's spacers never come into it the way they do for Tab.
    @Test("A vertical step never resolves a column of its own")
    func verticalStepNeverResolvesAColumn() throws {
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name", "email"])
        let middle = grid.dataColumns[1]

        let moved = try #require(target(grid, row: 1, column: middle, movement: .down))

        #expect(moved.column == middle)
    }

    /// Reaching for a cell's accessibility element is what marks the grid active, and an active
    /// grid mounts a view per visible cell. Moving the cursor asked for one every time, so a single
    /// Tab press bought every grid in the session the cost `#2381` removed.
    @Test("Moving the cell cursor leaves the accessibility layout alone")
    func movingTheCursorLeavesAccessibilityAlone() throws {
        let wasActive = DataGridAccessibility.isActive
        DataGridAccessibility.isActive = false
        defer { DataGridAccessibility.isActive = wasActive }
        let grid = makeGrid(rowCount: 3, columnNames: ["id", "name"])
        let column = try #require(grid.dataColumns.first)

        grid.tableView.focusCell(row: 1, column: column)

        #expect(!DataGridAccessibility.isActive)
        #expect(grid.tableView.focusedRow == 1)
        #expect(grid.tableView.focusedColumn == column)
    }
}
