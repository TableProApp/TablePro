import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class FakeColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}
    func clear(for tableName: String, connectionId: UUID) {}
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
