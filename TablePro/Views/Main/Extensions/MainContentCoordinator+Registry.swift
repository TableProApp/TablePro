//
//  MainContentCoordinator+Registry.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCoordinator {
    static func allActiveCoordinators() -> [MainContentCoordinator] {
        Array(activeCoordinators.values)
    }

    static func coordinator(for windowId: UUID) -> MainContentCoordinator? {
        activeCoordinators.values.first { $0.windowId == windowId }
    }

    static func coordinator(forWindow window: NSWindow) -> MainContentCoordinator? {
        activeCoordinators.values.first { $0.contentWindow === window }
    }

    static func hasAnyUnsavedChanges() -> Bool {
        activeCoordinators.values.contains { coordinator in
            coordinator.changeManager.hasChanges
                || coordinator.tabManager.tabs.contains { $0.pendingChanges.hasChanges }
        }
    }

    static func allTabs(for connectionId: UUID) -> [QueryTab] {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .flatMap { $0.tabManager.tabs }
    }

    static func coordinator(
        forConnection connectionId: UUID,
        tabMatching predicate: (QueryTab) -> Bool
    ) -> MainContentCoordinator? {
        activeCoordinators.values.first { coordinator in
            coordinator.connectionId == connectionId
                && coordinator.tabManager.tabs.contains(where: predicate)
        }
    }
}
