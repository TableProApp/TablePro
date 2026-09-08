import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class FakeColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class SelectionBox {
    var value: Set<Int> = []
    private(set) var writeCount = 0

    func binding() -> Binding<Set<Int>> {
        Binding(get: { self.value }, set: { newValue in
            self.value = newValue
            self.writeCount += 1
        })
    }
}

private final class StubTableView: NSTableView {
    var stubbedSelection = IndexSet()
    override var selectedRowIndexes: IndexSet { stubbedSelection }
}

@Suite("DataGridView+Selection.tableViewSelectionDidChange")
@MainActor
struct DataGridSelectionTests {
    private func makeCoordinator(box: SelectionBox) -> TableViewCoordinator {
        TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: box.binding(),
            delegate: nil,
            layoutPersister: FakeColumnLayoutPersister()
        )
    }

    private func notifySelectionChange(_ coordinator: TableViewCoordinator, rows: IndexSet) {
        let tableView = StubTableView()
        tableView.stubbedSelection = rows
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: tableView)
        )
    }

    @Test("mouse selection updates the row binding even while a programmatic selection is in flight")
    func mouseSelectionUpdatesBindingDuringProgrammaticSelection() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)
        coordinator.isApplyingProgrammaticRowSelection = true

        notifySelectionChange(coordinator, rows: IndexSet(integer: 5))

        #expect(box.value == [5])
    }

    @Test("keyboard selection updates the row binding")
    func keyboardSelectionUpdatesBinding() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)

        notifySelectionChange(coordinator, rows: IndexSet(integer: 2))

        #expect(box.value == [2])
    }

    @Test("deselecting all rows clears the row binding")
    func emptySelectionClearsBinding() {
        let box = SelectionBox()
        box.value = [4]
        let coordinator = makeCoordinator(box: box)

        notifySelectionChange(coordinator, rows: IndexSet())

        #expect(box.value.isEmpty)
    }

    @Test("an unchanged selection does not rewrite the row binding")
    func unchangedSelectionDoesNotRewriteBinding() {
        let box = SelectionBox()
        box.value = [3]
        let coordinator = makeCoordinator(box: box)

        notifySelectionChange(coordinator, rows: IndexSet(integer: 3))

        #expect(box.writeCount == 0)
    }
}

@Suite("DataGridView+Selection published row selection")
@MainActor
struct PublishedRowSelectionTests {
    private func makeCoordinator(box: SelectionBox) -> TableViewCoordinator {
        TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: box.binding(),
            delegate: nil,
            layoutPersister: FakeColumnLayoutPersister()
        )
    }

    @Test("a cell range publishes every row it covers, not the anchor row")
    func cellRangePublishesEveryCoveredRow() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)

        coordinator.selectionController.update(
            .single(
                GridRect(rows: 1...6, columns: 0...0),
                anchor: GridCoord(row: 1, column: 0),
                active: GridCoord(row: 6, column: 0)
            )
        )
        coordinator.publishRowSelection(rowSelection: [1])

        #expect(box.value == [1, 2, 3, 4, 5, 6])
        #expect(coordinator.currentRowSelection() == [1, 2, 3, 4, 5, 6])
    }

    @Test("two discontiguous cells publish both of their rows")
    func discontiguousCellsPublishBothRows() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)

        coordinator.selectionController.update(
            GridSelection(
                rectangles: [GridRect(cell: GridCoord(row: 3, column: 0)), GridRect(cell: GridCoord(row: 17, column: 2))],
                activeCell: GridCoord(row: 17, column: 2),
                anchor: GridCoord(row: 3, column: 0)
            )
        )
        coordinator.publishRowSelection(rowSelection: [17])

        #expect(box.value == [3, 17])
    }

    @Test("with no cell selection the row selection is published unchanged")
    func rowSelectionPublishesUnchanged() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)

        coordinator.publishRowSelection(rowSelection: [2, 3])

        #expect(box.value == [2, 3])
    }

    @Test("clearing the cell selection falls back to the row selection")
    func clearingCellSelectionFallsBack() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)

        coordinator.selectionController.update(
            .single(
                GridRect(rows: 4...9, columns: 0...0),
                anchor: GridCoord(row: 4, column: 0),
                active: GridCoord(row: 9, column: 0)
            )
        )
        coordinator.publishRowSelection(rowSelection: [4])
        #expect(box.value == [4, 5, 6, 7, 8, 9])

        coordinator.selectionController.clear()
        coordinator.publishRowSelection(rowSelection: [4])

        #expect(box.value == [4])
    }

    @Test("publishing records what it wrote so an unchanged value is not written twice")
    func publishRecordsWhatItWrote() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)

        #expect(coordinator.lastPublishedRowSelection == nil)

        coordinator.publishRowSelection(rowSelection: [8])
        #expect(coordinator.lastPublishedRowSelection == [8])
        let afterFirst = box.writeCount

        coordinator.publishRowSelection(rowSelection: [8])
        #expect(box.writeCount == afterFirst)
    }

    @Test("the grid selection controller publishes through its change hook")
    func selectionControllerHookPublishes() {
        let box = SelectionBox()
        let coordinator = makeCoordinator(box: box)
        coordinator.selectionController.onSelectionChange = { [weak coordinator] _ in
            coordinator?.publishRowSelection()
        }

        coordinator.selectionController.update(
            .single(
                GridRect(rows: 2...5, columns: 1...3),
                anchor: GridCoord(row: 2, column: 1),
                active: GridCoord(row: 5, column: 3)
            )
        )

        #expect(box.value == [2, 3, 4, 5])
    }
}
