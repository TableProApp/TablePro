//
//  MainContentCoordinator+RowCountTasks.swift
//  TablePro
//
//  A row count belongs to the tab that asked for it, so its handle is keyed by tab. The token
//  carried alongside is what stops a task that is finishing from clearing the slot a successor
//  has already taken, the same discipline `tableLoadTasks` uses.
//

import Foundation

extension MainContentCoordinator {
    /// Cancels whatever this tab had running first, because a tab only ever wants its newest count.
    internal func setRowCountTask(_ task: Task<Void, Never>, token: UUID, for tabId: UUID) {
        rowCountTasks[tabId]?.task.cancel()
        rowCountTasks[tabId] = (token, task)
    }

    /// Claims the `isCountingExact` spinner for one user-requested count.
    ///
    /// The task slot cannot answer this, because every page turn launches an automatic count that
    /// takes the slot over. Cancelling through `Cmd+.` releases the claim, so the count the user
    /// starts next owns the spinner and a late predecessor cannot stop it.
    internal func claimExactCount(for tabId: UUID, token: UUID) {
        exactCountOwners[tabId] = token
    }

    internal func releaseExactCount(for tabId: UUID, token: UUID) -> Bool {
        guard exactCountOwners[tabId] == token else { return false }
        exactCountOwners.removeValue(forKey: tabId)
        return true
    }

    internal func releaseAllExactCounts() {
        exactCountOwners.removeAll()
    }

    /// Drops a finished task's handle, and only its own, reporting whether it was still the owner.
    /// A superseded task still reaches its completion path, so without the token it would clear the
    /// successor that replaced it and leave that successor with nothing able to cancel it. The
    /// answer is what lets the caller release the tab's `isCountPending` without releasing a
    /// successor's.
    @discardableResult
    internal func clearRowCountTask(for tabId: UUID, token: UUID) -> Bool {
        guard rowCountTasks[tabId]?.token == token else { return false }
        rowCountTasks[tabId] = nil
        return true
    }

    /// Takes back the pending mark raised when phase 2 was committed to, for an attempt that will
    /// never reach the count. Only the paths that abandoned the work call this; a superseded attempt
    /// must not, because its successor has raised a mark of its own.
    internal func releaseCountPending(for tabId: UUID) {
        tabManager.mutate(tabId: tabId) { $0.pagination.isCountPending = false }
    }

    /// Cancelling is a way out too, so the tab stops reporting a count that will never land.
    internal func cancelRowCountTask(for tabId: UUID) {
        rowCountTasks.removeValue(forKey: tabId)?.task.cancel()
        tabManager.mutate(tabId: tabId) { $0.pagination.isCountPending = false }
    }

    internal func cancelAllRowCountTasks() {
        let cancelled = Array(rowCountTasks.keys)
        for entry in rowCountTasks.values { entry.task.cancel() }
        rowCountTasks.removeAll()
        for tabId in cancelled {
            tabManager.mutate(tabId: tabId) { $0.pagination.isCountPending = false }
        }
    }
}
