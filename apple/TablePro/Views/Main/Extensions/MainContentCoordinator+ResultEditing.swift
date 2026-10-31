//
//  MainContentCoordinator+ResultEditing.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    // A query tab can show a result its table context no longer describes, so it asks the result's own
    // origin, fail-closed (#2243). A table tab has one result and only a view there explains a refusal.
    var activeResultEditRefusal: ResultEditRefusal? {
        guard let tab = tabManager.selectedTab else { return nil }
        guard tab.tabType == .query else { return tab.tableContext.viewEditRefusal }
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
        // A claimed execution replaces these rows and clears whatever was staged on them meanwhile, as the data files grid does when busy.
        return tab.tableContext.isEditable
            && tab.tableContext.allowsRowEditing
            && !safeModeLevel.blocksAllWrites
            && activeResultEditRefusal == nil
            && !tabExecution.isExecuting(tab.id)
    }

    // A query tab learns its result reads a view from the result's origin; a table tab from its context.
    var activeViewWriteTarget: PluginViewWriteTarget? {
        guard let tab = tabManager.selectedTab else { return nil }
        guard tab.tabType == .query else { return tab.tableContext.viewWriteTarget }
        guard let origin = tab.display.activeResultSet?.origin else { return nil }
        return origin.viewRowEditing?.writeTarget(keyedOn: origin.primaryKeyColumns)
    }

    // A view can allow updates while the server refuses inserts or deletes through it.
    func canEditActiveResult(_ operation: PluginViewWriteOperations) -> Bool {
        guard canEditActiveResult else { return false }
        return (activeViewWriteTarget?.operations ?? .all).contains(operation)
    }
}
