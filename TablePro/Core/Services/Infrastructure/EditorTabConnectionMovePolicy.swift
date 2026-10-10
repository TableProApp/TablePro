//
//  EditorTabConnectionMovePolicy.swift
//  TablePro
//

import Foundation

/// Whether a tab may move to another connection. Unlike a detach, the last tab and a tab whose
/// connection is down may move: the source is only left empty, and nothing is read from it.
internal enum EditorTabConnectionMovePolicy {
    internal static func canMove(tabType: TabType, isBusy: Bool, hasPendingGridEdits: Bool) -> Bool {
        /// Every other tab type names an object of the connection it was opened on.
        guard tabType == .query else { return false }
        /// The running query's claim and completion belong to the source coordinator.
        guard !isBusy else { return false }
        /// Grid edits live on the source coordinator and would be left behind.
        return !hasPendingGridEdits
    }
}

extension MainContentCoordinator {
    internal func canMoveTabToConnection(_ tabId: UUID) -> Bool {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return false }
        return EditorTabConnectionMovePolicy.canMove(
            tabType: tab.tabType,
            isBusy: tabExecution.isBusy(tabId) || tab.pagination.isBusy,
            hasPendingGridEdits: holdsWorkThatStaysBehind(tab)
        )
    }

    /// A dirty file buffer lives in `content` and moves with the tab, so it is the one kind of
    /// unsaved work `savability` counts that does not block a move.
    private func holdsWorkThatStaysBehind(_ tab: QueryTab) -> Bool {
        var withoutFile = tab
        withoutFile.content.sourceFileURL = nil
        return savability(of: withoutFile) != .nothingAtRisk
    }
}
