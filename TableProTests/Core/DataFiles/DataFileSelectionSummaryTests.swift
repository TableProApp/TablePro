//
//  DataFileSelectionSummaryTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProNumberFormatting
import TableProPluginKit
import TableProTabular
import Testing

@MainActor
private final class DataFileSummaryLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
struct DataFileSelectionSummaryTests {
    /// The coordinator holds its delegate and its table view weakly, so the test holds them.
    @MainActor
    private struct MountedGrid {
        let controller: DataFileController
        let delegate: DataFileGridDelegate
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator

        var tracker: SelectionSummaryTracker { coordinator.selectionSummaryTracker }
        var summary: SelectionSummary? { controller.selectionSummary.summary }
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

        let delegate = DataFileGridDelegate(controller: controller)
        let view = DataGridView(
            tableRowsProvider: { [controller] in controller.tableRows },
            changeManager: controller.anyChangeManager,
            isEditable: controller.isEditable,
            delegate: delegate,
            layoutPersister: DataFileSummaryLayoutPersister(),
            selectedRowIndices: .constant([]),
            sortState: .constant(SortState()),
            columnLayout: .constant(ColumnLayoutState()),
            selectionSummary: controller.selectionSummary
        )
        let coordinator = view.makeCoordinator()
        coordinator.tableRowsProvider = { [controller] in controller.tableRows }
        delegate.dataGridAttach(tableViewCoordinator: coordinator)

        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        let tableRows = controller.tableRows
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.updateCache()
        tableView.reloadData()
        return MountedGrid(controller: controller, delegate: delegate, tableView: tableView, coordinator: coordinator)
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
        let id = try #require(grid.controller.columnNames.ids.first)
        #expect(grid.controller.kind(of: id) == .integer)
        #expect(grid.controller.tableRows.rows[1].values[0] == .text(""))

        grid.coordinator.selectionController.update(Self.firstColumn(rows: 0...2))
        await grid.tracker.pendingTask?.value

        #expect(grid.summary?.emptyCount == 1)
        #expect(grid.summary?.valueCount == 2)
        #expect(grid.summary?.numbers?.sum.decimal == 4)
        withExtendedLifetime(grid) {}
    }

    @Test("overriding a text column to Integer sums it, and setting it back to automatic stops")
    func kindOverridePublishesNewFigures() async throws {
        let grid = try await mount("code,label\n007,a\n010,b\n3,c\n")
        let id = try #require(grid.controller.columnNames.ids.first)
        #expect(grid.controller.kind(of: id) == .text)
        grid.coordinator.selectionController.update(Self.firstColumn(rows: 0...2))
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
        withExtendedLifetime(grid) {}
    }

    /// The kind override is not an undo step of its own; an undo puts back the kinds an earlier edit
    /// captured, and it reloads the page, which drops the cell selection with it.
    @Test("undoing back past a kind override leaves no figures computed under the override")
    func undoPastKindOverrideLeavesNoStaleFigures() async throws {
        let grid = try await mount("code,label\n007,a\n010,b\n3,c\n")
        let id = try #require(grid.controller.columnNames.ids.first)
        grid.controller.setCell(pageRow: 0, column: 1, text: "z")
        grid.coordinator.selectionController.update(Self.firstColumn(rows: 0...2))
        grid.controller.setKindOverride(.integer, for: id)
        await grid.tracker.pendingTask?.value
        #expect(grid.summary?.numbers?.sum.decimal == 20)

        undoManager.undo()
        await grid.controller.waitForPendingWork()
        await grid.tracker.pendingTask?.value

        #expect(grid.controller.kind(of: id) == .text)
        #expect(grid.summary?.numbers == nil)
        #expect(grid.tracker.currentSummary?.numbers == nil)
        withExtendedLifetime(grid) {}
    }
}
