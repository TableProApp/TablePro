//
//  LiveMessageSessions.swift
//  TablePro
//

import Foundation

// Every live tab's subscription, by the tab that shows it. Closing the tab is what ends it.
@MainActor
internal final class LiveMessageSessions {
    static let shared = LiveMessageSessions()

    private var controllers: [UUID: LiveMessageController] = [:]

    var hasActiveSessions: Bool {
        controllers.values.contains { !$0.hasEnded }
    }

    func register(_ controller: LiveMessageController, tabId: UUID) {
        controllers[tabId] = controller
    }

    func controller(forTab tabId: UUID) -> LiveMessageController? {
        controllers[tabId]
    }

    func end(tabId: UUID) {
        controllers.removeValue(forKey: tabId)?.stop()
    }

    func end(tabIds: [UUID]) {
        for tabId in tabIds {
            end(tabId: tabId)
        }
    }

    // The module went off or the app is quitting. With `closingTabs`, every window drops its live tabs too.
    func endAll(closingTabs: Bool = false) {
        if closingTabs {
            for coordinator in MainContentCoordinator.activeCoordinators.values {
                coordinator.closeLiveMessageTabs()
            }
        }
        let ending = controllers.values
        controllers.removeAll()
        for controller in ending {
            controller.stop()
        }
    }
}
