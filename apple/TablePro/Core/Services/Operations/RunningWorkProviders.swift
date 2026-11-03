//
//  RunningWorkProviders.swift
//  TablePro
//

import Foundation

@MainActor
internal enum RunningWorkProviders {
    internal static let live: [@MainActor () -> [RunningWork]] = [
        { queries(in: WindowManager.shared.hostedCoordinators()) },
        { agentReplies(in: AgentSessionRegistry.shared.sessions) },
        { CompareSyncRunRegistry.shared.runningWork() }
    ]

    // A table tab loading rows is navigation, not work the user started; only an editor tab's run counts.
    internal static func queries(in coordinators: [MainContentCoordinator]) -> [RunningWork] {
        var seen: Set<UUID> = []
        var items: [RunningWork] = []
        for coordinator in coordinators {
            for tab in coordinator.tabManager.tabs
            where tab.tabType == .query && coordinator.tabExecution.isBusy(tab.id) && seen.insert(tab.id).inserted {
                let tabId = tab.id
                items.append(RunningWork(
                    kind: .query,
                    subject: tab.title,
                    connectionName: coordinator.connection.name,
                    connectionIds: [coordinator.connectionId],
                    windowId: coordinator.windowId,
                    tabId: tabId,
                    cancel: { [weak coordinator] in coordinator?.stopExecution(for: tabId) }
                ))
            }
        }
        return items
    }

    internal static func agentReplies(in sessions: [AgentSession]) -> [RunningWork] {
        sessions.filter(\.status.isBusy).map { session in
            RunningWork(
                id: session.id,
                kind: .agentReply,
                subject: session.displayTitle,
                connectionName: DatabaseManager.shared.session(for: session.connectionId)?.connection.name
                    ?? ConnectionStorage.shared.loadConnection(id: session.connectionId)?.name
                    ?? "",
                connectionIds: [session.connectionId],
                cancel: { [weak session] in session?.stop() }
            )
        }
    }
}
