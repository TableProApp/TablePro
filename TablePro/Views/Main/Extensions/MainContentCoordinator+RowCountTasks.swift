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

    /// Drops a finished task's handle, and only its own. A superseded task still reaches its
    /// completion path, so without the token it would clear the successor that replaced it and
    /// leave that successor with nothing able to cancel it.
    internal func clearRowCountTask(for tabId: UUID, token: UUID) {
        guard rowCountTasks[tabId]?.token == token else { return }
        rowCountTasks[tabId] = nil
    }

    internal func cancelRowCountTask(for tabId: UUID) {
        rowCountTasks.removeValue(forKey: tabId)?.task.cancel()
    }

    internal func cancelAllRowCountTasks() {
        for entry in rowCountTasks.values { entry.task.cancel() }
        rowCountTasks.removeAll()
    }
}
