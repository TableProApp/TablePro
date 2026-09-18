//
//  MainContentCoordinator+OperationReporting.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    internal func operationOwner(tabId: UUID) -> OperationOwner {
        .tab(windowId: windowId, tabId: tabId)
    }

    /// Reports work that ended without any completion of its own running.
    ///
    /// Cancellation is the case this exists for. `Task.cancel()` is cooperative, so a cancelled
    /// execution's completion either never resumes or finds its claim already settled and returns
    /// without writing anything. Nothing downstream would otherwise learn the tab stopped being
    /// busy, which is how a cancelled tab kept a spinner and a stale mark.
    internal func reportEndedExecutions(_ ended: [EndedExecution]) {
        for execution in ended {
            let owner = operationOwner(tabId: execution.tabId)
            OperationCompletionReporter.shared.clearDelivered(for: owner)
            OperationUnseenMarker.clear(tabId: execution.tabId, in: tabManager)
        }
    }

    internal func reportOperation(
        kind: TrackedOperationKind,
        claim: TabExecutionClaim,
        databaseName: String?,
        outcome: OperationOutcome
    ) {
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: kind,
                owner: operationOwner(tabId: claim.tabId),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: databaseName,
                elapsed: claim.startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }

    /// A restore load is the app reopening the session, not the user asking for anything, so it
    /// never notifies however long it takes. `TableLoadTrigger` already draws that line for the
    /// diagnostics tracer and it is the same line here.
    internal func reportQueryOperation(
        claim: TabExecutionClaim,
        trigger: TableLoadTrigger,
        outcome: OperationOutcome
    ) {
        guard case .userInitiated = trigger else { return }
        reportOperation(
            kind: .query,
            claim: claim,
            databaseName: operationDatabaseName(tabId: claim.tabId),
            outcome: outcome
        )
    }

    internal func operationDatabaseName(tabId: UUID) -> String? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return browseDatabaseName }
        return scope(for: tab)?.database ?? browseDatabaseName
    }

    internal func reportOperation(
        kind: TrackedOperationKind,
        tabId: UUID,
        startedAt: ContinuousClock.Instant,
        databaseName: String?,
        outcome: OperationOutcome
    ) {
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: kind,
                owner: operationOwner(tabId: tabId),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: databaseName,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}

extension QueryExecutionCoordinator {
    internal func reportOperation(
        kind: TrackedOperationKind,
        claim: TabExecutionClaim,
        outcome: OperationOutcome
    ) {
        parent.reportOperation(
            kind: kind,
            claim: claim,
            databaseName: historyDatabaseName(tabId: claim.tabId),
            outcome: outcome
        )
    }
}
