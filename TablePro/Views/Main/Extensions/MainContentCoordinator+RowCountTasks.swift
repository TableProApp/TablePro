//
//  MainContentCoordinator+RowCountTasks.swift
//  TablePro
//
//  A row count belongs to the tab that asked for it. One shared handle per window meant the
//  second tab to ask dropped the only reference to the first tab's task, leaving it running with
//  nothing able to cancel it, not even teardown, while it held the coordinator alive.
//

import Foundation

extension MainContentCoordinator {
    /// Cancels whatever this tab had running first, because a tab only ever wants its newest count.
    internal func setRowCountTask(_ task: Task<Void, Never>, for tabId: UUID) {
        rowCountTasks[tabId]?.cancel()
        rowCountTasks[tabId] = task
    }

    /// Drops a finished task's handle. The task is already done, so there is nothing to cancel.
    internal func clearRowCountTask(for tabId: UUID) {
        rowCountTasks.removeValue(forKey: tabId)
    }

    internal func cancelRowCountTask(for tabId: UUID) {
        rowCountTasks.removeValue(forKey: tabId)?.cancel()
    }

    internal func cancelAllRowCountTasks() {
        for task in rowCountTasks.values { task.cancel() }
        rowCountTasks.removeAll()
    }
}
