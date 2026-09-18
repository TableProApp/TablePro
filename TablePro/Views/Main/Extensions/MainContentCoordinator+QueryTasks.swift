//
//  MainContentCoordinator+QueryTasks.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension MainContentCoordinator {
    /// Opens a tab's execution: it ends what that tab was doing, claims it, and mints the driver
    /// lease every statement of the new execution runs under.
    ///
    /// The three are one call because they have to happen in that order and only for this tab.
    /// Every start path used to end whatever the window held instead, so a Run in one tab, a table
    /// opened from the sidebar, a Refresh or an Explain each killed the batch another tab was
    /// running and rolled it back.
    internal func beginTabExecution(for tabId: UUID) -> (claim: TabExecutionClaim, lease: DriverLeaseOwner) {
        supersedeExecution(for: tabId)
        return (tabExecution.claim(tabId), DriverLeaseOwner())
    }

    /// A tab reaching a second execution while the first still holds the handle means the first is
    /// still running, so the displaced entry is ended rather than dropped.
    internal func installQueryTask(
        _ task: Task<Void, Never>,
        owner: TabQueryTaskOwner,
        lease: DriverLeaseOwner
    ) {
        guard let displaced = queryTasks.install(
            TabQueryTask(owner: owner, lease: lease, task: task)
        ) else { return }
        end(displaced, delivery: .background)
    }

    /// Retires the tab's Stop handle, but only for the execution that installed it. A completion
    /// that owns its own tab can still be a stranger to the execution the tab is running now, and
    /// taking that one's handle down would leave a live query with nothing to cancel it.
    ///
    /// It reports nothing: what the titlebar shows is derived from `tabExecution`, so a completion
    /// that cannot retire the handle can no longer leave the window claiming to be busy.
    internal func retireQueryTask(_ owner: TabQueryTaskOwner) {
        _ = queryTasks.retire(owner)
    }

    internal func cancelQueryTask(for tabId: UUID, delivery: DriverCancellationDelivery) {
        guard let entry = queryTasks.remove(tabId: tabId) else { return }
        end(entry, delivery: delivery)
    }

    /// Ends whatever the tab was doing so a new navigation owns it outright. Invalidating before the
    /// new claim is minted is what makes "the user navigated away and no successor ever ran" still
    /// discard the old result, which a counter that only moved on a successful start could not do.
    ///
    /// Removing the entry is also what puts the titlebar back to idle, because the indicator reads
    /// the registry. A retarget need not be followed by a successor, and nothing else would have
    /// lowered a stored flag.
    internal func supersedeExecution(for tabId: UUID) {
        reportEndedExecutions(tabExecution.invalidate(tabId, reason: .supersededNavigation).map { [$0] } ?? [])
        cancelTableLoad(for: tabId)
        cancelRowCountTask(for: tabId)
        cancelQueryTask(for: tabId, delivery: .background)
    }

    /// What Stop and `Cmd+.` do, on the tab the user is looking at and on nothing else.
    ///
    /// The driver cancel goes out inline, because the user is waiting on it, and the claim ends in
    /// the same stretch of main-actor work, so a batch checking `isCurrent` before its commit sees
    /// both or neither. A claim whose commit is already on the wire is spared: `stop` keeps it, and
    /// `isStoppable` is what keeps the button from being offered over it in the first place.
    ///
    /// The task goes with the claim. A script-managed batch whose commit point leaves the phase and
    /// runs on had its entry removed here while `stop` kept the claim, so the statements still to
    /// come had nothing left to cancel them: Stop did nothing for the rest of the run, and the
    /// execution ended as a `preparationAbandoned` anomaly.
    internal func stopExecution(for tabId: UUID) {
        let outcome = tabExecution.stop(tabId)
        if !outcome.keptUninterruptibleClaim {
            cancelQueryTask(for: tabId, delivery: .immediate)
        }
        cancelRowCountTask(for: tabId)
        releaseExactCount(for: tabId)
        reportEndedExecutions(outcome.ended)
        tabManager.mutate(tabId: tabId) { tab in
            tab.pagination.isLoadingMore = false
            tab.pagination.isCountingExact = false
            tab.pagination.isCountPending = false
            tab.pagination.isLoading = false
        }
    }

    /// A window closing ends every tab it hosts, and asks the driver to stop each one's work rather
    /// than only cancelling the Swift task: `Task.cancel()` is cooperative, so a single long
    /// statement runs to completion inside the session gate and every other tab and window on that
    /// connection queues behind it.
    internal func cancelAllQueryTasks() {
        for entry in queryTasks.removeAll() {
            end(entry, delivery: .background)
        }
    }

    /// Reset execution state when a query is cancelled, releasing the tab only if this claim still
    /// owns it. Settling is that gate and it comes first, exactly as `finishFailedQuery` does for
    /// the other way an execution ends early.
    ///
    /// This used to invalidate by tab id, which releases whatever the tab is running now rather
    /// than what this claim started. A cancelled execution unwinding after its successor had
    /// claimed the tab therefore deleted the successor's entry, and the successor's own `settle`
    /// then refused to apply the rows it had just fetched (#2342).
    @MainActor
    internal func resetExecutionState(claim: TabExecutionClaim, executionTime: TimeInterval) {
        guard tabExecution.settle(claim) else { return }
        reportEndedExecutions([
            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
        ])
        retireQueryTask(.claim(claim))
        toolbarState.recordQueryTiming(PluginQueryTiming(total: executionTime), for: claim.tabId)
    }

    /// What the window's Run, Stop and `Cmd+.` read. The window can be busy on a tab the user is
    /// not looking at, and offering Stop for that one would act on the selected tab instead.
    internal var isSelectedTabBusy: Bool {
        guard let tabId = tabManager.selectedTabId else { return false }
        return tabExecution.isBusy(tabId)
    }

    internal var isSelectedTabStoppable: Bool {
        guard let tabId = tabManager.selectedTabId else { return false }
        return tabExecution.isStoppable(tabId)
    }

    private func end(_ entry: TabQueryTask, delivery: DriverCancellationDelivery) {
        entry.task.cancel()
        do {
            try services.databaseManager.cancelRunningQuery(
                owner: entry.lease, on: connectionId, delivery: delivery
            )
        } catch {
            Self.logger.warning("cancelQuery failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
