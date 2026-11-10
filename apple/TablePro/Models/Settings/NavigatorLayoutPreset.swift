//
//  NavigatorLayoutPreset.swift
//  TablePro
//

import Foundation

/// The Layout buttons in Settings > General: table details, favorite tables at the top of the tree,
/// the Objects tab on selection, the Objects toolbar buttons, labels under the toolbar's icons, the
/// connections list and Tree as the default sidebar layout, on or off in one step.
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
        settings.showsConnectionNavigator = true
        defaultLayout = .tree
    }

    internal static func restore(to settings: inout GeneralSettings, defaultLayout: inout SidebarLayout) {
        let standard = GeneralSettings.default
        settings.showTableDetails = standard.showTableDetails
        settings.showsFavoritesSection = standard.showsFavoritesSection
        settings.showsObjectsOnSelection = standard.showsObjectsOnSelection
        settings.showsObjectToolbar = standard.showsObjectToolbar
        settings.showsToolbarLabels = standard.showsToolbarLabels
        settings.showsConnectionNavigator = standard.showsConnectionNavigator
        defaultLayout = .flat
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
