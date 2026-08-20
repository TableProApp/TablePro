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

    var canUndo: Bool {
        if isUsersRolesTab { return coordinator?.usersRolesActions?.canUndo() ?? false }
        if isStructureMode { return coordinator?.structureActions?.undo != nil }
        return windowUndoManager?.canUndo ?? false
    }

    var canRedo: Bool {
        if isUsersRolesTab { return coordinator?.usersRolesActions?.canRedo() ?? false }
        if isStructureMode { return coordinator?.structureActions?.redo != nil }
        return windowUndoManager?.canRedo ?? false
    }

    var resolvedUndoTitle: String {
        if isUsersRolesTab { return undoMenuTitle }
        guard let manager = windowUndoManager, manager.canUndo else { return String(localized: "Undo") }
        return manager.undoMenuItemTitle
    }

    var resolvedRedoTitle: String {
        if isUsersRolesTab { return redoMenuTitle }
        guard let manager = windowUndoManager, manager.canRedo else { return String(localized: "Redo") }
        return manager.redoMenuItemTitle
    }
}
