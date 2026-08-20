//
//  MainContentCoordinator+ResultEditing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Why the rows on screen cannot be written back, or nil when they can.
    ///
    /// Only a query tab holds more than one result, so only a query tab can be showing rows that
    /// its own table context no longer describes. A table tab has exactly one result and keeps the
    /// gate it always had.
    ///
    /// This is fail-closed on purpose: a result that never captured where its rows came from
    /// refuses the edit instead of borrowing whichever table the tab ran last (#2243).
    var activeResultEditRefusal: ResultEditRefusal? {
        guard let tab = tabManager.selectedTab, tab.tabType == .query else { return nil }
        return ResultEditability.refusal(
            for: tab.display.activeResultSet?.origin,
            currentDatabaseName: scope(for: tab)?.database ?? browseDatabaseName
        )
    }

    /// The one answer to "may the rows on screen be written to".
    ///
    /// The grid, the row inspector and the Edit menu each used to decide this for themselves and
    /// each checked a different subset, so a result the grid refused stayed writable from the other
    /// two. They all read this now.
    var canEditActiveResult: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        return tab.tableContext.isEditable
            && !tab.tableContext.isView
            && !safeModeLevel.blocksAllWrites
            && activeResultEditRefusal == nil
    }
}
