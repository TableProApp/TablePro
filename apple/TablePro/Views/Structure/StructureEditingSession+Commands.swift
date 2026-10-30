//
//  StructureEditingSession+Commands.swift
//  TablePro
//

import AppKit
import Foundation

// What the menu bar, the toolbar and the keyboard ask of a structure tab. The coordinator calls these on the
// selected tab's session, so they work whether or not a view is mounted.
internal extension StructureEditingSession {
    var hasChanges: Bool { changeManager.hasChanges }

    var pendingChangeCount: Int { changeManager.getChangesArray().count }

    // MARK: - Undo

    var canUndo: Bool { changeManager.canUndo }
    var canRedo: Bool { changeManager.canRedo }
    var undoMenuItemTitle: String { changeManager.undoMenuItemTitle }
    var redoMenuItemTitle: String { changeManager.redoMenuItemTitle }

    func undo() {
        guard canUndo else { return }
        commitOpenEdits()
        changeManager.undo()
        editor.refresh()
    }

    func redo() {
        guard canRedo else { return }
        commitOpenEdits()
        changeManager.redo()
        editor.refresh()
    }

    private func commitOpenEdits() {
        editor.commitPendingEdits()
    }

    // MARK: - Rows

    private var takesRowCommands: Bool { pane == .definition && hasBaseline }

    var canAddRow: Bool { takesRowCommands && editor.canAdd(editor.commandSection) }
    var canRemoveRows: Bool { takesRowCommands && editor.canRemoveSelection(in: editor.commandSection) }
    var canPasteRows: Bool { takesRowCommands && editor.canPaste }

    func addRow() {
        guard canAddRow else { return }
        editor.add(editor.commandSection)
    }

    func removeSelectedRows() {
        guard canRemoveRows else { return }
        editor.removeSelection(in: editor.commandSection)
    }

    func duplicateSelectedRows() {
        guard takesRowCommands else { return }
        editor.duplicateSelection()
    }

    func copySelectedRows() {
        guard pane == .definition else { return }
        editor.copySelection()
    }

    func pasteRows() {
        guard canPasteRows else { return }
        editor.paste()
    }

    // MARK: - Discard

    func discardChanges() {
        for section in StructureSection.allCases {
            editor.adapter(for: section).model.discardEditing()
        }
        changeManager.discardChanges()
        editor.refresh()
        if settleOwedRefetch() {
            Task { await load() }
        }
    }

    func discardChangesAfterConfirming() {
        guard hasChanges else { return }
        let count = pendingChangeCount
        Task {
            let message = count == 1
                ? String(localized: "The change to this table's structure will be lost.")
                : String(format: String(localized: "%d changes to this table's structure will be lost."), count)
            guard await confirmDiscard(message: message) else { return }
            discardChanges()
        }
    }

    func confirmDiscard(message: String) async -> Bool {
        await AlertHelper.confirmDestructive(
            title: String(localized: "Discard Changes?"),
            message: message,
            confirmButton: String(localized: "Discard Changes"),
            cancelButton: String(localized: "Cancel"),
            window: coordinator?.contentWindow
        )
    }

    // MARK: - Preview and save

    // Preview checks what Save checks, so the statements it shows are the ones Save would run.
    func previewChanges() {
        editor.commitPendingEdits()
        guard hasChanges, let coordinator else {
            coordinator?.toolbarState.previewStatements = []
            return
        }
        guard changeManager.canCommit else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Some Changes Are Incomplete"),
                message: changeManager.validationSummary,
                window: coordinator.contentWindow
            )
            return
        }
        Task { await previewStagedChanges(coordinator: coordinator) }
    }

    func save() {
        Task { _ = await applyStagedChanges(coordinator: coordinator) }
    }
}
