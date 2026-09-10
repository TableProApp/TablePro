//
//  TableViewCoordinatorPopoverDismissalTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

/// A cell editor holds the display row it was opened from, and a display row is a position rather
/// than an identity. Replacing the rows moves that record elsewhere, so an editor left open across
/// the replacement commits its edit onto whichever record now sits at the position. That is the
/// `Selection indices are display positions` invariant, and the answer is to close the editor.
@Suite("TableViewCoordinator closes editors whose rows were replaced")
@MainActor
struct TableViewCoordinatorPopoverDismissalTests {
    private func makeCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakePopoverDismissalPersister()
        )
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
        ]
        var captured = TableRows(
            rows: rows,
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )
        coordinator.tableRowsProvider = { captured }
        coordinator.tableRowsMutator = { mutation in mutation(&captured) }
        coordinator.updateCache()
        return coordinator
    }

    @Test("Replacing the rows closes an open cell editor")
    func fullReplaceClosesCellEditor() {
        let tableView = NSTableView()
        let coordinator = makeCoordinator()
        coordinator.tableView = tableView
        let editor = CloseCountingPopover()
        coordinator.activeCellEditorPopover = editor

        coordinator.applyFullReplace()

        #expect(coordinator.activeCellEditorPopover == nil)
        #expect(editor.closeCount == 1)
    }

    @Test("Replacing the rows closes an open column value filter")
    func fullReplaceClosesValueFilter() {
        let tableView = NSTableView()
        let coordinator = makeCoordinator()
        coordinator.tableView = tableView
        let filter = CloseCountingPopover()
        coordinator.activeValueFilterPopover = filter

        coordinator.applyFullReplace()

        #expect(coordinator.activeValueFilterPopover == nil)
        #expect(filter.closeCount == 1)
    }

    /// A coordinator detached from its table view still has to drop these, which is why the
    /// dismissal runs before the `tableView` guard rather than after it.
    @Test("Replacing the rows closes editors even with no table view attached")
    func fullReplaceClosesEditorsWithoutATableView() {
        let coordinator = makeCoordinator()
        let editor = CloseCountingPopover()
        coordinator.activeCellEditorPopover = editor

        coordinator.applyFullReplace()

        #expect(coordinator.activeCellEditorPopover == nil)
        #expect(editor.closeCount == 1)
    }

    /// A popped-out JSON editor is a window, so it survives every popover dismissal while still
    /// committing through the display row it was opened from.
    @Test("Replacing the rows closes a popped-out editor window")
    func fullReplaceClosesPoppedOutEditor() {
        let coordinator = makeCoordinator()
        let popOut = JSONViewerWindowController()
        coordinator.activePoppedOutEditor = popOut

        coordinator.applyFullReplace()

        #expect(coordinator.activePoppedOutEditor == nil)
    }

    /// Opening a different cell's editor must not close a window the user deliberately detached:
    /// only a replaced row set invalidates it.
    @Test("Opening another cell editor leaves a popped-out window alone")
    func openingAnotherEditorKeepsThePoppedOutWindow() {
        let coordinator = makeCoordinator()
        let popOut = JSONViewerWindowController()
        coordinator.activePoppedOutEditor = popOut

        coordinator.dismissActiveCellEditorPopover()

        #expect(coordinator.activePoppedOutEditor === popOut)
    }

    /// The array editor is `.applicationDefined`, so nothing closes it on its own. Forgetting the
    /// reference when a second editor opens would strand it on screen with no way to dismiss it.
    ///
    /// `isShown` cannot answer this: it is false for a popover that was never presented, so an
    /// assertion on it passes whether or not anything closed the first editor. Counting the `close`
    /// calls is what actually fails when the dismissal is removed.
    @Test("Opening a second cell editor closes the first instead of forgetting it")
    func openingASecondEditorClosesTheFirst() {
        let coordinator = makeCoordinator()
        let first = CloseCountingPopover()
        first.behavior = .applicationDefined
        let second = CloseCountingPopover()

        coordinator.dismissActiveCellEditorPopover()
        coordinator.activeCellEditorPopover = first
        coordinator.dismissActiveCellEditorPopover()
        coordinator.activeCellEditorPopover = second

        #expect(coordinator.activeCellEditorPopover === second)
        #expect(first.closeCount == 1)
        #expect(second.closeCount == 0)
    }

    @Test("Dismissing clears the slot and closes the editor")
    func dismissClosesAndClearsTheSlot() {
        let coordinator = makeCoordinator()
        let editor = CloseCountingPopover()
        coordinator.activeCellEditorPopover = editor

        coordinator.dismissActiveCellEditorPopover()

        #expect(coordinator.activeCellEditorPopover == nil)
        #expect(editor.closeCount == 1)
    }
}

private final class CloseCountingPopover: NSPopover {
    private(set) var closeCount = 0

    override func close() {
        closeCount += 1
        super.close()
    }
}

private final class FakePopoverDismissalPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}

    func clear(for key: ColumnLayoutTableKey) {}
}
