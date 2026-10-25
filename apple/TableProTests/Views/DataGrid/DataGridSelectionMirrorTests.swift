//
//  DataGridSelectionMirrorTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct DataGridSelectionMirrorTests {
    private static func block(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> GridSelection {
        .single(
            GridRect(rows: rows, columns: columns),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: columns.lowerBound),
            active: GridCoord(row: rows.upperBound, displayColumn: columns.upperBound)
        )
    }

    // MARK: - Tables to the model

    @Test("A row the table selects natively becomes the model's selection")
    func nativeRowSelectionReachesModel() async throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        grid.main.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        try await waitUntil { grid.model.selectedRowIDs == [.existing(2)] }
        #expect(grid.model.selection.rectangles == [GridRect(rows: 2...2, columns: 0...2)])
        #expect(grid.frozen.selectedRowIndexes == IndexSet(integer: 2))
    }

    @Test("A row selected natively with no cursor seeds the cursor on a data column")
    func nativeSelectionSeedsDataColumn() async throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        #expect(grid.model.selection.isEmpty)

        grid.main.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        try await waitUntil { grid.model.selection.activeCell != nil }
        #expect(grid.model.selection.activeCell == GridCoord(row: 0, displayColumn: 0))
        #expect(grid.model.activeCell?.column.name == "id")
    }

    @Test("Deselecting every row natively clears the model's selection")
    func nativeDeselectClearsModel() async throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.selectRows([.existing(4)])
        #expect(grid.main.selectedRowIndexes == IndexSet(integer: 4))

        grid.main.deselectAll(nil)

        try await waitUntil { grid.model.selection.isEmpty }
        #expect(grid.frozen.selectedRowIndexes.isEmpty)
    }

    @Test("A native selection change that moves nothing writes nothing")
    func unchangedNativeSelectionWritesNothing() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.selectRows([.existing(3)])
        let revision = grid.model.selectionRevision

        grid.controller.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: grid.main)
        )

        #expect(grid.model.selectionRevision == revision)
        #expect(grid.model.selectedRowIDs == [.existing(3)])
    }

    // MARK: - The model to the tables

    @Test("A cell range selects every row it covers in both tables")
    func cellRangeSelectsEveryCoveredRow() {
        let grid = HostedDataGrid(rows: GridFixtureRows.wide(rows: 20, columns: 3))
        defer { grid.close() }

        grid.model.setSelection(Self.block(rows: 1...6, columns: 0...0))

        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 1...6))
        #expect(grid.frozen.selectedRowIndexes == IndexSet(integersIn: 1...6))
        #expect(grid.model.selectedRowIDs == (1...6).map { RowID.existing($0) })
    }

    @Test("Two cells on distant rows select both rows")
    func discontiguousCellsSelectBothRows() {
        let grid = HostedDataGrid(rows: GridFixtureRows.wide(rows: 20, columns: 3))
        defer { grid.close() }

        grid.model.setSelection(GridSelection(
            rectangles: [GridRect(cell: GridCoord(row: 3, displayColumn: 0)), GridRect(cell: GridCoord(row: 17, displayColumn: 2))],
            activeCell: GridCoord(row: 17, displayColumn: 2),
            anchor: GridCoord(row: 3, displayColumn: 0)
        ))

        #expect(grid.main.selectedRowIndexes == IndexSet([3, 17]))
        #expect(grid.model.selectedRowIDs == [.existing(3), .existing(17)])
    }

    @Test("Mirroring the model into the tables never feeds back into the model")
    func mirroringDoesNotFeedBack() {
        let grid = HostedDataGrid(rows: GridFixtureRows.wide(rows: 20, columns: 3))
        defer { grid.close() }
        let range = Self.block(rows: 4...9, columns: 1...2)

        grid.model.setSelection(range)

        #expect(grid.model.selection == range)
        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 4...9))
    }

    @Test("Clearing a cell range clears the rows in both tables")
    func clearingRangeClearsTables() {
        let grid = HostedDataGrid(rows: GridFixtureRows.wide(rows: 20, columns: 3))
        defer { grid.close() }
        grid.model.setSelection(Self.block(rows: 4...9, columns: 0...0))

        grid.model.clearSelection()

        #expect(grid.main.selectedRowIndexes.isEmpty)
        #expect(grid.frozen.selectedRowIndexes.isEmpty)
    }

    // MARK: - Announcement

    @Test("The selection announcement counts overlapping cells once")
    func announcementCountsUniqueCells() {
        let selection = GridSelection(
            rectangles: [GridRect(rows: 0...4, columns: 0...0), GridRect(rows: 2...6, columns: 0...0)],
            activeCell: GridCoord(row: 6, displayColumn: 0),
            anchor: GridCoord(row: 2, displayColumn: 0)
        )
        let expected = String(
            format: String(localized: "%d cells selected, rows %d to %d, columns %d to %d"),
            7, 1, 7, 1, 1
        )

        #expect(selection.uniqueCellCount == 7)
        #expect(DataGridViewController.accessibilityAnnouncement(for: selection) == expected)
        #expect(DataGridViewController.accessibilityAnnouncement(for: .empty) == String(localized: "Cell selection cleared"))
    }
}
