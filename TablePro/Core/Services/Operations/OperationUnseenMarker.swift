//
//  OperationUnseenMarker.swift
//  TablePro
//

import AppKit
import Foundation

/// Puts the "finished while you were away" mark on a tab, and takes it off again.
///
/// This is the channel that does not depend on notification permission, on the per-kind toggles,
/// or on the user having caught a banner. Every client that shipped notifications without an
/// in-app marker left users with no way to tell which tab had finished once the banner faded.
@MainActor
internal enum OperationUnseenMarker {
    internal static func mark(_ owner: OperationOwner) {
        guard case .tab(_, let tabId) = owner else { return }
        guard let coordinator = coordinator(owning: tabId) else { return }
        coordinator.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.finishedUnseenAt = Date()
        }
    }

    internal static func clear(tabId: UUID, in tabManager: QueryTabManager) {
        guard tabManager.tabs.contains(where: { $0.id == tabId && $0.execution.finishedUnseenAt != nil })
        else { return }
        tabManager.mutate(tabId: tabId) { tab in
            tab.execution.finishedUnseenAt = nil
        }
    }

    private static func coordinator(owning tabId: UUID) -> MainContentCoordinator? {
        for window in NSApp.windows {
            guard let controller = window.contentViewController as? MainSplitViewController else { continue }
            for workspace in controller.workspaces.workspaces {
                guard let coordinator = workspace.sessionState?.coordinator,
                      coordinator.tabManager.tabs.contains(where: { $0.id == tabId })
                else { continue }
                return coordinator
            }
        }
        return nil
    }
}
