import Foundation

/// The single answer to "would closing or quitting destroy something the user cannot get back".
/// The close path (one tab) and the quit path (every tab of every connection) previously each
/// carried their own partial version of this and had drifted apart.
extension MainContentCoordinator {
    var hasPendingDestructiveTableOps: Bool {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return false }
        return !session.pendingTruncates.isEmpty || !session.pendingDeletes.isEmpty
    }

    var hasSidebarEdits: Bool {
        rightPanelState?.editState.hasEdits ?? false
    }

    /// Work that is only recoverable by saving it. A scratch query tab is deliberately absent:
    /// its text is captured into `RecentlyClosedTabStore` on close, so losing it is undoable and
    /// warrants no alert.
    func hasUnsavedWork(in tab: QueryTab?) -> Bool {
        guard let tab else { return false }
        if tab.tabType == .usersRoles {
            return usersRolesActions?.hasChanges() ?? false
        }
        return tab.content.isFileDirty || tab.pendingChanges.hasChanges
    }

    func hasUnsavedWorkInSelectedTab() -> Bool {
        changeManager.hasChanges
            || hasPendingDestructiveTableOps
            || hasSidebarEdits
            || hasUnsavedWork(in: tabManager.selectedTab)
    }

    func hasAnyUnsavedWork() -> Bool {
        changeManager.hasChanges
            || hasPendingDestructiveTableOps
            || hasSidebarEdits
            || tabManager.tabs.contains { hasUnsavedWork(in: $0) }
    }

    /// Tabs resolved against live view state (cursor offset, sort column names) so a reopened tab
    /// comes back where the user left it.
    func tabsForRecoveryCapture() -> [QueryTab] {
        tabManager.tabs.map { enrichedForPersistence($0) }
    }
}
