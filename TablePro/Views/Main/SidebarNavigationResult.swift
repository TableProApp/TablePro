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
    /// No existing tabs: navigate in-place inside this window.
    case openInPlace
    /// Existing tabs present: revert sidebar to the current tab immediately,
    /// then open the clicked table in a new native window tab.
    /// Reverting synchronously prevents SwiftUI from rendering the [B] state
    /// before coalescing back to [A] — eliminating the visible flash.
    case revertAndOpenNewWindow
    /// Preview mode: replace the contents of the existing preview tab.
    case replacePreviewTab
    /// Preview mode: no preview tab exists yet, so create a new one.
    case openNewPreviewTab

    /// Pure function — no side effects. Determines how a sidebar click should be handled.
    ///
    /// - Parameters:
    ///   - clickedTableName: The name of the table the user clicked in the sidebar.
    ///   - currentTabTableName: The table name of this window's active tab
    ///     (`nil` when the active tab is a query or create-table tab).
    ///   - hasExistingTabs: `true` when this window already has at least one tab open.
    ///   - isPreviewTabMode: `true` when preview/temporary tab mode is enabled.
    ///   - hasPreviewTab: `true` when a preview tab already exists in this window.
    static func resolve(
        clickedTableName: String,
        currentTabTableName: String?,
        hasExistingTabs: Bool,
        isPreviewTabMode: Bool = false,
        hasPreviewTab: Bool = false
    ) -> SidebarNavigationResult {
        // Programmatic sync (e.g. didBecomeKeyNotification): the selection already
        // reflects the active tab — nothing to do.
        if currentTabTableName == clickedTableName { return .skip }
        // No existing tabs: open the table in-place within this window.
        if !hasExistingTabs { return .openInPlace }

        // Preview tab logic: reuse or create a preview tab instead of opening a new window tab.
        if isPreviewTabMode {
            if hasPreviewTab {
                return .replacePreviewTab
            }
            return .openNewPreviewTab
        }

        // Default: revert sidebar synchronously (no flash), then open in a new native tab.
        return .revertAndOpenNewWindow
    }
}
