//
//  TabRun.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// One execution on one tab, from claim to settle. Every run kind goes through it, so a lifecycle fix lands once.
@MainActor
struct TabRun {
    let tabId: UUID
    let claim: TabExecutionClaim
    let lease: DriverLeaseOwner
    let scope: DatabaseScope
    let connection: DatabaseConnection
    private weak var coordinator: MainContentCoordinator?

    // Supersedes whatever the tab was running: refusing a busy tab is the entry point's job, before any prompt.
    static func begin(
        onTab tabId: UUID,
        parameters: [QueryParameter] = [],
        in coordinator: MainContentCoordinator
    ) -> TabRun? {
        guard let tab = coordinator.tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        if let missing = parameters.first(where: { !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            coordinator.tabManager.mutate(tabId: tabId) {
                $0.execution.errorMessage = String(format: String(localized: "Missing value for parameter: %@"), ":\(missing.name)")
            }
            return nil
        }
        // Claimed before the scope is known, so a load that cannot start still ends the one it replaces.
        let (claim, lease) = coordinator.beginTabExecution(for: tabId)
        coordinator.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        guard let scope = coordinator.scope(for: tab) else {
            guard coordinator.tabExecution.settle(claim) else { return nil }
            coordinator.tabManager.mutate(tabId: tabId) { tab in
                tab.execution.errorMessage = String(localized: "Not connected to database")
                tab.pagination.isLoading = false
            }
            return nil
        }
        return TabRun(
            tabId: tabId,
            claim: claim,
            lease: lease,
            scope: scope,
            connection: coordinator.connection,
            coordinator: coordinator
        )
    }

    func launch(_ work: @escaping @MainActor (TabRun) async -> Void) {
        guard let coordinator else { return }
        let run = self
        // Held to the end: the strategies reach the coordinator through unowned references while a closed window's run unwinds.
        let task = Task { [coordinator] in
            await work(run)
            withExtendedLifetime(coordinator) {}
        }
        coordinator.installQueryTask(task, owner: .claim(claim), lease: lease)
    }

    // The run's authority to write: true only while its claim still owned the tab.
    func settle() -> Bool {
        guard let coordinator, coordinator.tabExecution.settle(claim) else { return false }
        coordinator.retireQueryTask(.claim(claim))
        return true
    }

    // A run that still owns what the tab shows; its claim may already be settled.
    var ownsContent: Bool {
        coordinator?.tabExecution.ownsContent(claim) ?? false
    }

    func reportCancelled() {
        coordinator?.reportEndedExecutions([
            EndedExecution(tabId: tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
        ])
    }

    func report(_ kind: TrackedOperationKind, _ outcome: OperationOutcome, trigger: TableLoadTrigger = .userInitiated) {
        guard case .userInitiated = trigger, let coordinator else { return }
        coordinator.reportOperation(
            kind: kind,
            claim: claim,
            databaseName: coordinator.operationDatabaseName(tabId: tabId),
            outcome: outcome
        )
    }

    @discardableResult
    func recordHistory(_ entry: RunHistoryEntry) -> Task<Bool, Never>? {
        coordinator?.queryExecutionCoordinator.recordRunHistory(entry, tabId: tabId)
    }
}

struct RunHistoryEntry {
    var id = UUID()
    let query: String
    // A statement of a script is filed with its terminator; a single run keeps the text as typed.
    var terminates = false
    // Nil takes the tab's: a table tab's SQL is the app's own browse, not something the user typed.
    var source: QueryHistorySource?
    let executionTime: TimeInterval
    let rowCount: Int
    var failure: String?
    var planCapture: QueryPlanCapture?
    var timing: PluginQueryTiming?
}
