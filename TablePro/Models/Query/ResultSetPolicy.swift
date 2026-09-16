//
//  ResultSetPolicy.swift
//  TablePro
//
//  Decides when a result can be pinned. The View menu and the result-set chooser both ask here,
//  so the command and the control it mirrors never disagree.
//

import Foundation

enum ResultSetPolicy {
    /// Whether this tab holds a result that pinning means anything for.
    ///
    /// This used to be `showsTabBar`, and the strip it named is gone: `QueryResultPresentation`
    /// owns the question of what the results pane draws. What survives is the narrower question of
    /// whether there is an active result to hold on to.
    static func canPin(tabType: TabType, display: TabDisplayState) -> Bool {
        guard tabType == .query else { return false }
        guard display.resultsViewMode != .structure else { return false }
        return display.activeResultSet != nil
    }
}
