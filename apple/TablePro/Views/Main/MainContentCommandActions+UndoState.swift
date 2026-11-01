//
//  MainContentCommandActions+UndoState.swift
//  TablePro
//

import AppKit

// The structure editor's own history, which the window's undo manager never sees.
@MainActor
protocol StructureUndoHistory: AnyObject {
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var undoMenuItemTitle: String { get }
    var redoMenuItemTitle: String { get }
    func undo()
    func redo()
}

extension StructureEditingSession: StructureUndoHistory {}

extension CreateTableDraft: StructureUndoHistory {}

// Users & Roles, the diagram and the structure editor keep their own histories; everything else uses the browse one.
extension MainContentCommandActions {
    private var windowUndoManager: UndoManager? {
        coordinator?.browseUndoManager
    }

    // A Create Table tab keeps its view mode at Data, so it is asked for by tab type.
    private var showsStructureEditor: Bool {
        guard let tab = coordinator?.tabManager.selectedTab else { return false }
        return tab.tabType == .createTable || tab.display.resultsViewMode == .structure
    }

    private var structureHistory: (any StructureUndoHistory)? {
        if let session = coordinator?.activeStructureSession { return session }
        return coordinator?.activeCreateTableDraft
    }

    // The diagram stages on one session per table, so it keeps its own order across them.
    private var selectedDiagram: ERDiagramViewModel? {
        guard let coordinator, let tab = coordinator.tabManager.selectedTab, tab.tabType == .erDiagram else {
            return nil
        }
        return coordinator.erDiagramModels[tab.id]
    }

    private var isDiagramTab: Bool {
        coordinator?.tabManager.selectedTab?.tabType == .erDiagram
    }

    // A field still being typed into has its step waiting rather than registered; the command ends the run first.
    var canUndo: Bool {
        if isUsersRolesTab { return coordinator?.usersRolesActions?.canUndo() ?? false }
        if isDiagramTab { return selectedDiagram?.canUndoStagedEdit ?? false }
        if showsStructureEditor { return structureHistory?.canUndo ?? false }
        if coordinator?.changeManager.hasCoalescedUndoRun == true { return true }
        return windowUndoManager?.canUndo ?? false
    }

    var canRedo: Bool {
        if isUsersRolesTab { return coordinator?.usersRolesActions?.canRedo() ?? false }
        if isDiagramTab { return selectedDiagram?.canRedoStagedEdit ?? false }
        if showsStructureEditor { return structureHistory?.canRedo ?? false }
        return windowUndoManager?.canRedo ?? false
    }

    var resolvedUndoTitle: String {
        if isUsersRolesTab { return undoMenuTitle }
        if isDiagramTab { return String(localized: "Undo") }
        if showsStructureEditor {
            guard let history = structureHistory, history.canUndo else { return String(localized: "Undo") }
            return history.undoMenuItemTitle
        }
        if coordinator?.changeManager.hasCoalescedUndoRun == true {
            return String(localized: "Undo Edit Cell")
        }
        guard let manager = windowUndoManager, manager.canUndo else { return String(localized: "Undo") }
        return manager.undoMenuItemTitle
    }

    var resolvedRedoTitle: String {
        if isUsersRolesTab { return redoMenuTitle }
        if isDiagramTab { return String(localized: "Redo") }
        if showsStructureEditor {
            guard let history = structureHistory, history.canRedo else { return String(localized: "Redo") }
            return history.redoMenuItemTitle
        }
        guard let manager = windowUndoManager, manager.canRedo else { return String(localized: "Redo") }
        return manager.redoMenuItemTitle
    }

    // MARK: - Commands

    func undoChange() {
        coordinator?.endInspectorEditRun()
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.undo()
            return
        }
        if isDiagramTab {
            selectedDiagram?.undoStagedEdit()
            return
        }
        if showsStructureEditor {
            structureHistory?.undo()
            return
        }
        windowUndoManager?.undo()
    }

    func redoChange() {
        coordinator?.endInspectorEditRun()
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.redo()
            return
        }
        if isDiagramTab {
            selectedDiagram?.redoStagedEdit()
            return
        }
        if showsStructureEditor {
            structureHistory?.redo()
            return
        }
        windowUndoManager?.redo()
    }
}
