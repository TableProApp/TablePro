//
//  OperationUnseenMarker.swift
//  TablePro
//

import AppKit
import Foundation

// The in-app channel: it needs no notification permission and outlives a missed banner.
@MainActor
internal enum OperationUnseenMarker {
    internal static func mark(_ owner: OperationOwner, outcome: TabUnseenOutcome) {
        guard case .tab(_, let tabId) = owner else { return }
        guard let coordinator = coordinator(owning: tabId) else { return }
        coordinator.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.unseenOutcome = outcome
        }
    }

    internal static func outcome(of outcome: OperationOutcome) -> TabUnseenOutcome? {
        switch outcome {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return nil
        }
    }

    internal static func clear(tabId: UUID, in tabManager: QueryTabManager) {
        guard tabManager.tabs.contains(where: { $0.id == tabId && $0.execution.unseenOutcome != nil })
        else { return }
        tabManager.mutate(tabId: tabId) { tab in
            tab.execution.unseenOutcome = nil
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
