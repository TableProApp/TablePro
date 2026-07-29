//
//  SidebarNavigationResult.swift
//  TablePro
//
//  Pure, side-effect-free logic for deciding what to do when the sidebar
//  selection changes. Extracted from MainContentView so it can be unit-tested.
//

import Foundation

/// The action MainContentView should take when the sidebar selection changes.
enum SidebarNavigationResult: Equatable {
    /// The selected table already matches the active tab — skip all navigation.
    case skip
    /// Replace the focused window's active tab in place.
    case reuseActiveTab
    /// Open the clicked table in a new native window tab.
    case openNewTab

    /// Pure function with no side effects. Decides how a sidebar single-click is
    /// handled, scoped to the focused window's active tab.
    ///
    /// - Parameters:
    ///   - clickedTableName: The name of the table the user clicked in the sidebar.
    ///   - currentTabTableName: The table name of this window's active tab
    ///     (`nil` when the active tab is a query or non-table tab).
    ///   - hasExistingTabs: `true` when this window already has at least one tab open.
    ///   - isActiveTabReusable: `true` when the active tab can be replaced in place
    ///     (a preview tab, or a blank never-executed query tab).
    static func resolve(
        clickedTableName: String,
        currentTabTableName: String?,
        hasExistingTabs: Bool,
        isActiveTabReusable: Bool
    ) -> SidebarNavigationResult {
        if currentTabTableName == clickedTableName { return .skip }
        if !hasExistingTabs { return .reuseActiveTab }
        if isActiveTabReusable { return .reuseActiveTab }
        return .openNewTab
    }
}
