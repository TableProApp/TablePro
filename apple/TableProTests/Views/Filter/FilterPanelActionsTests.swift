//
//  FilterPanelActionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct FilterPanelActionsTests {
    private let undoManager = UndoManager()
    private let paris = TableFilter(columnName: "city", filterOperator: .equal, value: "Paris")
    private let nameC = TableFilter(columnName: "name", filterOperator: .equal, value: "C")

    private func opened() async throws -> DataFileController {
        let csv = "name,city\nA,Paris\nB,London\nC,Paris\n"
        let (controller, _) = try await DataFileFixture.open(
            data: Data(csv.utf8),
            fileExtension: "csv",
            undoManager: undoManager
        )
        return controller
    }

    private func names(_ controller: DataFileController) -> [String] {
        controller.tableRows.rows.map { row in
            guard case .text(let text) = row.values[0] else { return "" }
            return text
        }
    }

    private func unchecked(_ filter: TableFilter) -> TableFilter {
        var row = filter
        row.isEnabled = false
        return row
    }

    @Test("Apply Only This Filter runs one row, even an unchecked one, and Apply goes back to the checked rows")
    func applyAloneThenChecked() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        let nameB = unchecked(TableFilter(columnName: "name", filterOperator: .equal, value: "B"))
        controller.filterState.filters = [paris, nameB]

        actions.applyCheckedFilters()
        await controller.waitForPendingWork()
        #expect(names(controller) == ["A", "C"])
        #expect(controller.filterState.status == .applied)

        actions.applyFilterAlone(nameB.id)
        await controller.waitForPendingWork()
        #expect(names(controller) == ["B"])
        #expect(controller.filterState.aloneFilterID == nameB.id)
        #expect(controller.filterState.status == .appliedAlone)
        #expect(controller.filterState.filters.map { $0.isEnabled } == [true, false])

        actions.applyCheckedFilters()
        await controller.waitForPendingWork()
        #expect(names(controller) == ["A", "C"])
        #expect(controller.filterState.aloneFilterID == nil)
    }

    @Test("Return runs the checked rows, or the row applied alone with its edited value")
    func applyInCurrentModeKeepsTheMode() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        controller.filterState.filters = [paris, nameC]

        actions.applyFiltersInCurrentMode()
        await controller.waitForPendingWork()
        #expect(names(controller) == ["C"])

        actions.applyFilterAlone(paris.id)
        await controller.waitForPendingWork()
        #expect(names(controller) == ["A", "C"])

        controller.filterState.filters[0].value = "London"
        #expect(controller.filterState.status == .changesNotApplied)
        actions.applyFiltersInCurrentMode()
        await controller.waitForPendingWork()

        #expect(names(controller) == ["B"])
        #expect(controller.filterState.aloneFilterID == paris.id)
    }

    @Test("A row the file cannot evaluate refuses to run alone and leaves what runs")
    func unrunnableRowRefusesToRunAlone() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        let raw = unchecked(TableFilter.rawCondition("city = 'Paris'"))
        controller.filterState.filters = [paris, raw]
        actions.applyCheckedFilters()
        await controller.waitForPendingWork()
        let running = controller.filterState.applied

        actions.applyFilterAlone(raw.id)
        await controller.waitForPendingWork()

        #expect(controller.filterState.applied == running)
        #expect(controller.statusMessage == String(localized: "This file cannot filter rows with these conditions."))
        #expect(names(controller) == ["A", "C"])
    }

    @Test("Turn Off shows every row and keeps the rows and the bar")
    func turnOffKeepsTheRows() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        controller.filterState.filters = [paris]
        controller.filterState.isVisible = true
        actions.applyCheckedFilters()
        await controller.waitForPendingWork()
        #expect(names(controller) == ["A", "C"])

        actions.turnOffFilters()
        await controller.waitForPendingWork()

        #expect(names(controller) == ["A", "B", "C"])
        #expect(!controller.filterState.isFiltering)
        #expect(controller.filterState.filters == [paris])
        #expect(controller.filterState.isVisible)
        #expect(controller.filterState.status == .notApplied)
    }

    @Test("Removing a running row reruns what was running without it, never the draft")
    func removingARunningRowRerunsTheRest() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        controller.filterState.filters = [paris, nameC]
        actions.applyCheckedFilters()
        await controller.waitForPendingWork()
        #expect(names(controller) == ["C"])

        controller.filterState.filters[0].value = "London"
        actions.removeFilter(nameC.id)
        await controller.waitForPendingWork()

        #expect(names(controller) == ["A", "C"])
        #expect(controller.filterState.applied?.filters == [paris])
        #expect(controller.filterState.filters.map { $0.value } == ["London"])
        #expect(controller.filterState.status == .changesNotApplied)
    }

    @Test("Removing a row that is not running changes no rows and runs nothing")
    func removingARowThatIsNotRunningRunsNothing() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        let idle = unchecked(nameC)
        controller.filterState.filters = [paris, idle]
        actions.applyCheckedFilters()
        await controller.waitForPendingWork()
        let running = controller.filterState.applied
        controller.gridModel.selectCell(GridCoord(row: 1, displayColumn: 0))
        let selection = controller.gridModel.selection
        #expect(selection != .empty)

        actions.removeFilter(idle.id)
        await controller.waitForPendingWork()

        #expect(controller.filterState.filters == [paris])
        #expect(controller.filterState.applied == running)
        #expect(names(controller) == ["A", "C"])
        // A rerun clears the grid's selection.
        #expect(controller.gridModel.selection == selection)
    }

    @Test("Removing the row applied alone stops filtering and keeps the other rows")
    func removingTheAloneRowStopsFiltering() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        controller.filterState.filters = [paris, nameC]
        controller.filterState.isVisible = true
        actions.applyFilterAlone(paris.id)
        await controller.waitForPendingWork()
        #expect(names(controller) == ["A", "C"])

        actions.removeFilter(paris.id)
        await controller.waitForPendingWork()

        #expect(names(controller) == ["A", "B", "C"])
        #expect(!controller.filterState.isFiltering)
        #expect(controller.filterState.filters == [nameC])
        #expect(controller.filterState.isVisible)
    }

    @Test("Removing the last row shows every row and hides the bar")
    func removingTheLastRowHidesTheBar() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        controller.filterState.filters = [paris]
        controller.filterState.isVisible = true
        actions.applyCheckedFilters()
        await controller.waitForPendingWork()

        actions.removeFilter(paris.id)
        await controller.waitForPendingWork()

        #expect(names(controller) == ["A", "B", "C"])
        #expect(controller.filterState.filters.isEmpty)
        #expect(!controller.filterState.isFiltering)
        #expect(!controller.filterState.isVisible)
    }

    @Test("Remove All Filters deletes every row, shows every row and hides the bar")
    func removeAllHidesTheBar() async throws {
        let controller = try await opened()
        let actions: any FilterPanelActions = controller
        controller.filterState.filters = [paris, nameC]
        controller.filterState.isVisible = true
        actions.applyCheckedFilters()
        await controller.waitForPendingWork()
        #expect(names(controller) == ["C"])

        actions.removeAllFilters()
        await controller.waitForPendingWork()

        #expect(names(controller) == ["A", "B", "C"])
        #expect(controller.filterState.filters.isEmpty)
        #expect(!controller.filterState.isFiltering)
        #expect(!controller.filterState.isVisible)
    }
}
