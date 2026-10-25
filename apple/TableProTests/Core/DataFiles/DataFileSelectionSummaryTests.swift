//
//  DataFileSelectionSummaryTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProNumberFormatting
import TableProPluginKit
import TableProTabular
import TableProTestSupport
import Testing

@MainActor
struct DataFileSelectionSummaryTests {
    // The grid's controller computes the summary, so the test mounts it in a window and holds both.
    @MainActor
    private final class MountedGrid {
        let controller: DataFileController
        let grid: DataGridViewController
        let window: NSWindow

        init(controller: DataFileController) {
            self.controller = controller
            grid = DataGridViewController(model: controller.gridModel)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = grid.view
            grid.view.layoutSubtreeIfNeeded()
        }

        var tracker: SelectionSummaryTracker { grid.selectionSummaryTracker }
        var summary: SelectionSummary? { controller.selectionSummary.summary }

        func tearDown() {
            grid.dismantle()
            window.contentView = nil
        }
    }

    private let undoManager = UndoManager()

    private func mount(_ text: String) async throws -> MountedGrid {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataFileSelectionSummaryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("figures.csv")
        try Data(text.utf8).write(to: url)
        let controller = DataFileController()
        controller.undoManager = undoManager
        let kind = try #require(DataFileKind.classify(url))
        controller.load(url: url, kind: kind)
        await controller.waitForPendingWork()
        #expect(controller.loadState == .loaded)

        let grid = MountedGrid(controller: controller)
        // The grid attaches its summary on the turn after it mounts.
        try await waitUntil(timeout: .seconds(5)) { grid.tracker.state === controller.selectionSummary }
        return grid
    }

    private static func firstColumn(rows: ClosedRange<Int>) -> GridSelection {
        .single(
            GridRect(rows: rows, columns: 0...0),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: 0),
            active: GridCoord(row: rows.upperBound, displayColumn: 0)
        )
    }

    @Test("the window's own column rules are used, so an empty CSV cell is Empty and an integer column is summed")
    func dataFilePolicyIsConsulted() async throws {
        let grid = try await mount("n,label\n1,a\n,b\n3,c\n")
        defer { grid.tearDown() }
        let id = try #require(grid.controller.columnNames.ids.first)
        #expect(grid.controller.kind(of: id) == .integer)
        #expect(grid.controller.tableRows.rows[1].values[0] == .text(""))

        grid.controller.gridModel.setSelection(Self.firstColumn(rows: 0...2))
        await grid.tracker.pendingTask?.value

        #expect(grid.summary?.emptyCount == 1)
        #expect(grid.summary?.valueCount == 2)
        #expect(grid.summary?.numbers?.sum.decimal == 4)
    }

    @Test("overriding a text column to Integer sums it, and setting it back to automatic stops")
    func kindOverridePublishesNewFigures() async throws {
        let grid = try await mount("code,label\n007,a\n010,b\n3,c\n")
        defer { grid.tearDown() }
        let id = try #require(grid.controller.columnNames.ids.first)
        #expect(grid.controller.kind(of: id) == .text)
        grid.controller.gridModel.setSelection(Self.firstColumn(rows: 0...2))
        await grid.tracker.pendingTask?.value
        #expect(grid.summary?.valueCount == 3)
        #expect(grid.summary?.numbers == nil)

        grid.controller.setKindOverride(.integer, for: id)
        await grid.tracker.pendingTask?.value
        #expect(grid.summary?.numbers?.count == 3)
        #expect(grid.summary?.numbers?.sum.decimal == 20)

        grid.controller.setKindOverride(nil, for: id)
        await grid.tracker.pendingTask?.value
        #expect(grid.summary?.numbers == nil)
        #expect(grid.summary?.valueCount == 3)
    }

    // The kind override is not an undo step of its own; an undo puts back the kinds an earlier edit captured.
    @Test("undoing back past a kind override leaves no figures computed under the override")
    func undoPastKindOverrideLeavesNoStaleFigures() async throws {
        let grid = try await mount("code,label\n007,a\n010,b\n3,c\n")
        defer { grid.tearDown() }
        let id = try #require(grid.controller.columnNames.ids.first)
        grid.controller.setCell(pageRow: 0, column: 1, text: "z")
        grid.controller.gridModel.setSelection(Self.firstColumn(rows: 0...2))
        grid.controller.setKindOverride(.integer, for: id)
        await grid.tracker.pendingTask?.value
        #expect(grid.summary?.numbers?.sum.decimal == 20)

        undoManager.undo()
        await grid.controller.waitForPendingWork()
        await grid.tracker.pendingTask?.value

        #expect(grid.controller.kind(of: id) == .text)
        #expect(grid.summary?.numbers == nil)
        #expect(grid.tracker.currentSummary?.numbers == nil)
    }

    @Test("the status bar's row count follows the grid's selection")
    func selectedRowsFollowTheGrid() async throws {
        let grid = try await mount("n,label\n1,a\n2,b\n3,c\n")
        defer { grid.tearDown() }

        grid.controller.gridModel.setSelection(Self.firstColumn(rows: 1...2))
        #expect(grid.controller.selectedRowIndices == [1, 2])

        grid.controller.gridModel.clearSelection()
        #expect(grid.controller.selectedRowIndices.isEmpty)
    }
}
