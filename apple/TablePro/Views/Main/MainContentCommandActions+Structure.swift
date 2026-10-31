//
//  MainContentCommandActions+Structure.swift
//  TablePro
//

import Foundation

// Structure commands go to the selected tab's own session or Create Table draft, which hold their edits mounted or not.
extension MainContentCommandActions {
    // MARK: - Save and discard

    // From Data, only when no grid edit is ahead of it: Save stays live after the user leaves Structure.
    var stagedStructureSession: StructureEditingSession? {
        guard let coordinator,
              let tab = coordinator.tabManager.selectedTab,
              let session = coordinator.structureSessions[tab.id],
              session.hasChanges else { return nil }
        if tab.display.resultsViewMode == .structure { return session }
        return hasDataWork ? nil : session
    }

    var canDiscardChanges: Bool { discardTarget != nil }

    func discardChanges() {
        switch discardTarget {
        case .structure(let session):
            session.discardChangesAfterConfirming()
        case .data:
            Task { await discardDataWorkAfterConfirming() }
        case nil:
            break
        }
    }

    private enum DiscardTarget {
        case structure(StructureEditingSession)
        case data
    }

    // Create Table has no saved state to return to.
    private var discardTarget: DiscardTarget? {
        guard let tab = coordinator?.tabManager.selectedTab,
              tab.tabType == .table || tab.tabType == .query else { return nil }
        if let session = stagedStructureSession { return .structure(session) }
        return hasDataWork ? .data : nil
    }

    private func discardDataWorkAfterConfirming() async {
        let confirmed = await AlertHelper.confirmDestructive(
            title: String(localized: "Discard Changes?"),
            message: String(localized: "The changes you have not saved will be lost."),
            confirmButton: String(localized: "Discard Changes"),
            cancelButton: String(localized: "Cancel"),
            window: closeAnchorWindow
        )
        guard confirmed else { return }
        discardDataWork()
    }

    // MARK: - Rows

    var canAddSchemaRow: Bool {
        if let session = coordinator?.activeStructureSession { return session.canAddRow }
        return coordinator?.activeCreateTableDraft?.canAddRow ?? false
    }

    var canRemoveSchemaRows: Bool {
        if let session = coordinator?.activeStructureSession { return session.canRemoveRows }
        return coordinator?.activeCreateTableDraft?.canRemoveRows ?? false
    }

    var canPasteSchemaRows: Bool {
        if let session = coordinator?.activeStructureSession { return session.canPasteRows }
        guard let draft = coordinator?.activeCreateTableDraft, draft.canAddRow else { return false }
        return draft.editor.canPaste
    }

    func addSchemaRow() {
        if let session = coordinator?.activeStructureSession {
            session.addRow()
        } else {
            coordinator?.activeCreateTableDraft?.addRow()
        }
    }

    func removeSchemaRows() {
        if let session = coordinator?.activeStructureSession {
            session.removeSelectedRows()
        } else {
            coordinator?.activeCreateTableDraft?.removeSelectedRows()
        }
    }

    func duplicateSchemaRows() {
        if let session = coordinator?.activeStructureSession {
            session.duplicateSelectedRows()
        } else if let draft = coordinator?.activeCreateTableDraft, draft.canAddRow {
            draft.editor.duplicateSelection()
        }
    }

    func copySchemaRows() {
        if let session = coordinator?.activeStructureSession {
            session.copySelectedRows()
        } else {
            coordinator?.activeCreateTableDraft?.editor.copySelection()
        }
    }

    func pasteSchemaRows() {
        if let session = coordinator?.activeStructureSession {
            session.pasteRows()
        } else if canPasteSchemaRows {
            coordinator?.activeCreateTableDraft?.editor.paste()
        }
    }
}
