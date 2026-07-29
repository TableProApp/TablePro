//
//  ResultTabBarPolicy.swift
//  TablePro
//
//  Decides when the result tab strip is on screen and when a result can be pinned.
//  Both answers come from here so the strip, its context menus, and the View menu never disagree.
//

import Foundation

enum ResultTabBarPolicy {
    static func showsTabBar(tabType: TabType, display: TabDisplayState) -> Bool {
        guard tabType == .query else { return false }
        guard display.explainText == nil else { return false }
        guard display.resultsViewMode != .structure else { return false }
        return !display.resultSets.isEmpty
    }

    static func canPin(tabType: TabType, display: TabDisplayState) -> Bool {
        guard showsTabBar(tabType: tabType, display: display) else { return false }
        return display.activeResultSet != nil
    }
}
