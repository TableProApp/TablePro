//
//  NavigatorLayoutPreset.swift
//  TablePro
//

import Foundation

/// The Layout buttons in Settings > General: table details, favorite tables at the top of the tree,
/// the Objects tab on selection, the Objects toolbar buttons, labels under the toolbar's icons, the
/// saved connections in the tree and Tree as the default sidebar layout, on or off in one step. The
/// same buttons switch the table tab's data view and the query bar (`applyDataView`).
///
/// The tree lists the saved connections itself, so the layout keeps the separate connections column
/// off: the sidebar is one tree, with the connection on screen opened in it.
///
/// It edits the same values the separate controls edit and leaves the write to the caller. Settings
/// passes its General settings binding, so the change lands on `AppSettingsManager.general` in one
/// write and the toolbar and the connections column react as they do to each toggle.
internal enum NavigatorLayoutPreset {
    internal static func apply(to settings: inout GeneralSettings, defaultLayout: inout SidebarLayout) {
        settings.showTableDetails = true
        settings.showsFavoritesSection = true
        settings.showsObjectsOnSelection = true
        settings.showsObjectToolbar = true
        settings.showsToolbarLabels = true
        settings.showsConnectionsInTree = true
        settings.showsConnectionNavigator = false
        defaultLayout = .tree
    }

    internal static func restore(to settings: inout GeneralSettings, defaultLayout: inout SidebarLayout) {
        let standard = GeneralSettings.default
        settings.showTableDetails = standard.showTableDetails
        settings.showsFavoritesSection = standard.showsFavoritesSection
        settings.showsObjectsOnSelection = standard.showsObjectsOnSelection
        settings.showsObjectToolbar = standard.showsObjectToolbar
        settings.showsToolbarLabels = standard.showsToolbarLabels
        settings.showsConnectionsInTree = standard.showsConnectionsInTree
        settings.showsConnectionNavigator = standard.showsConnectionNavigator
        defaultLayout = .flat
    }

    /// The tabs' half of the layout: types under the column names, the sort and a Text mode in the
    /// filter panel, that panel open with each table, the result bar above the grid, tab titles that
    /// name the database and connection, and the query bar on two rows. These live in the Data Grid,
    /// Tab and Editor settings, so the caller passes those bindings beside the General one.
    internal static func applyDataView(
        tabs: inout TabSettings,
        dataGrid: inout DataGridSettings,
        editor: inout EditorSettings
    ) {
        dataGrid.showsColumnTypesInHeader = true
        dataGrid.showsSortInFilterPanel = true
        dataGrid.opensFilterPanelForTables = true
        dataGrid.resultBarAtTop = true
        tabs.titleShowsLocation = true
        editor.queryBarTwoRows = true
    }

    internal static func restoreDataView(
        tabs: inout TabSettings,
        dataGrid: inout DataGridSettings,
        editor: inout EditorSettings
    ) {
        let standardGrid = DataGridSettings.default
        dataGrid.showsColumnTypesInHeader = standardGrid.showsColumnTypesInHeader
        dataGrid.showsSortInFilterPanel = standardGrid.showsSortInFilterPanel
        dataGrid.opensFilterPanelForTables = standardGrid.opensFilterPanelForTables
        dataGrid.resultBarAtTop = standardGrid.resultBarAtTop
        tabs.titleShowsLocation = TabSettings.default.titleShowsLocation
        editor.queryBarTwoRows = EditorSettings.default.queryBarTwoRows
    }

    /// The default layout reaches only connections opened later, so each open one is switched the way
    /// the View menu switches it. An engine with no database tree is skipped, as the menu skips it.
    @MainActor
    internal static func switchOpenConnections(to layout: SidebarLayout) {
        for session in DatabaseManager.shared.activeSessions.values
        where PluginManager.shared.supportsDatabaseTree(for: session.connection.type) {
            SharedSidebarState.forConnection(session.connection.id).sidebarLayout = layout
        }
    }
}
