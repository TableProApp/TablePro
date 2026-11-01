//
//  MainContentCoordinator+Structure.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // The selected tab's structure session while its Structure view is on screen. Commands act on it; a session
    // behind the Data view keeps its staged edits for the close prompt but takes no commands.
    var activeStructureSession: StructureEditingSession? {
        guard let tab = tabManager.selectedTab, tab.display.resultsViewMode == .structure else { return nil }
        return structureSessions[tab.id]
    }

    var activeCreateTableDraft: CreateTableDraft? {
        guard let tab = tabManager.selectedTab, tab.tabType == .createTable else { return nil }
        return createTableDrafts[tab.id]
    }

    // Whichever structure editor is on screen, for the inspector.
    var activeStructureEditor: StructureDefinitionEditor? {
        activeStructureSession?.editor ?? activeCreateTableDraft?.editor
    }
}
