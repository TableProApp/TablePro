//
//  LiveMessageSessions.swift
//  TablePro
//

import Foundation

// Every live tab's subscription, by the tab that shows it. Closing the tab is what ends it.
@MainActor
internal final class LiveMessageSessions {
    static let shared = LiveMessageSessions()

    private struct Entry {
        let controller: LiveMessageController
        let connectionId: UUID
    }

    private var entries: [UUID: Entry] = [:]

    func register(_ controller: LiveMessageController, tabId: UUID, connectionId: UUID) {
        entries[tabId] = Entry(controller: controller, connectionId: connectionId)
    }

    func controller(forTab tabId: UUID) -> LiveMessageController? {
        entries[tabId]?.controller
    }

    func end(tabId: UUID) {
        entries.removeValue(forKey: tabId)?.controller.stop()
    }

    // Before the connection's transport goes, so no subscription keeps redialing through a closed tunnel.
    func end(connectionId: UUID) {
        let tabIds = entries.filter { $0.value.connectionId == connectionId }.map(\.key)
        end(tabIds: tabIds)
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
        let ending = entries.values.map(\.controller)
        entries.removeAll()
        for controller in ending {
            controller.stop()
        }
    }
}
