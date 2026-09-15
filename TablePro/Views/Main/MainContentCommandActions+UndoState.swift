//
//  MainContentCommandActions+UndoState.swift
//  TablePro
//

import AppKit

/// A connection hosts three undo domains, picked by the active tab: Users & Roles and
/// the structure editor keep their own histories, and everything else registers on
/// the window's `UndoManager`, which `TabWindowController` resolves to the selected
/// connection's own history. Availability and the menu title both have to follow
/// whichever one is live, so they resolve through the same branch the commands do.
extension MainContentCommandActions {
    private var windowUndoManager: UndoManager? {
        coordinator?.contentWindow?.undoManager
    }

    private var isStructureMode: Bool {
        coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure
    }

    /// A field still being typed into has an undo step waiting rather than registered, and the menu
    /// has to offer it: the command ends the run before it reaches the undo manager.
    var canUndo: Bool {
        if isUsersRolesTab { return coordinator?.usersRolesActions?.canUndo() ?? false }
        if isStructureMode { return coordinator?.structureActions?.undo != nil }
        if coordinator?.changeManager.hasCoalescedUndoRun == true { return true }
        return windowUndoManager?.canUndo ?? false
    }

    var canRedo: Bool {
        if isUsersRolesTab { return coordinator?.usersRolesActions?.canRedo() ?? false }
        if isStructureMode { return coordinator?.structureActions?.redo != nil }
        return windowUndoManager?.canRedo ?? false
    }

    var resolvedUndoTitle: String {
        if isUsersRolesTab { return undoMenuTitle }
        if coordinator?.changeManager.hasCoalescedUndoRun == true {
            return String(localized: "Undo Edit Cell")
        }
        guard let manager = windowUndoManager, manager.canUndo else { return String(localized: "Undo") }
        return manager.undoMenuItemTitle
    }

    var resolvedRedoTitle: String {
        if isUsersRolesTab { return redoMenuTitle }
        guard let manager = windowUndoManager, manager.canRedo else { return String(localized: "Redo") }
        return manager.redoMenuItemTitle
    }

    // MARK: - Commands

    /// A Create Table tab keeps its `resultsViewMode` at `.data`, so it needs its own arm. Without
    /// one, Cmd+Z in the visual table editor reached the window's undo manager, which owns none of
    /// the draft, and the grid's own undo had no caller at all.
    func undoChange() {
        coordinator?.endInspectorEditRun()
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.undo()
            return
        }
        if coordinator?.tabManager.selectedTab?.tabType == .createTable {
            coordinator?.createTableActions?.undo?()
            return
        }
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.undo?()
            return
        }
        coordinator?.contentWindow?.undoManager?.undo()
    }

    func redoChange() {
        coordinator?.endInspectorEditRun()
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.redo()
            return
        }
        if coordinator?.tabManager.selectedTab?.tabType == .createTable {
            coordinator?.createTableActions?.redo?()
            return
        }
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.redo?()
            return
        }
        coordinator?.contentWindow?.undoManager?.redo()
    }
}
