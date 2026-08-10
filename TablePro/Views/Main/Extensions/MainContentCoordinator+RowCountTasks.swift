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
