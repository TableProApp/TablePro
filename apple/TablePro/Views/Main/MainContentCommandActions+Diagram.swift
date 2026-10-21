//
//  MainContentCommandActions+Diagram.swift
//  TablePro
//

import Foundation

extension MainContentCommandActions {
    private func diagramHoldingWork(in tabId: UUID?, of coordinator: MainContentCoordinator) -> ERDiagramViewModel? {
        guard let tabId, let diagram = coordinator.erDiagramModels[tabId], diagram.holdsUnsavedWork else { return nil }
        return diagram
    }

    // Only staged diagram work is the diagram's to save; anything else falls through to its own save.
    func saveSelectedDiagram() -> Bool {
        guard let coordinator, coordinator.tabManager.selectedTab?.tabType == .erDiagram,
              let diagram = diagramHoldingWork(in: coordinator.tabManager.selectedTabId, of: coordinator)
        else { return false }
        Task { _ = await diagram.applyStagedEdits(coordinator: coordinator) }
        return true
    }

    func applySelectedDiagramEdits(in coordinator: MainContentCoordinator) async -> Bool {
        guard let diagram = diagramHoldingWork(in: coordinator.tabManager.selectedTabId, of: coordinator) else {
            return true
        }
        return await diagram.applyStagedEdits(coordinator: coordinator).allowsClose
    }

    func applyStagedSchemaWork(of tab: QueryTab, in coordinator: MainContentCoordinator) async -> Bool {
        if let session = coordinator.structureSessions[tab.id], session.changeManager.hasChanges {
            guard await session.applyStagedChanges(coordinator: coordinator).allowsClose else { return false }
        }
        if let diagram = diagramHoldingWork(in: tab.id, of: coordinator) {
            return await diagram.applyStagedEdits(coordinator: coordinator).allowsClose
        }
        return true
    }
}
