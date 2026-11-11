//
//  NavigatorLayoutPresetTests.swift
//  TableProTests
//

import AppKit
import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct NavigatorLayoutPresetTests {
    private static func navigatorLayout(from settings: GeneralSettings) -> GeneralSettings {
        var expected = settings
        expected.showTableDetails = true
        expected.showsFavoritesSection = true
        expected.showsObjectsOnSelection = true
        expected.showsObjectToolbar = true
        expected.showsToolbarLabels = true
        expected.showsToolbarLocationItems = false
        expected.showsConnectionsInTree = true
        expected.showsConnectionNavigator = false
        return expected
    }

    @Test("Use Navigator Layout turns on all six features, takes the location out of the toolbar and makes Tree the default layout")
    func applyTurnsEverythingOn() {
        var settings = GeneralSettings.default
        var layout = SidebarLayout.flat

        NavigatorLayoutPreset.apply(to: &settings, defaultLayout: &layout)

        #expect(settings.showTableDetails)
        #expect(settings.showsFavoritesSection)
        #expect(settings.showsObjectsOnSelection)
        #expect(settings.showsObjectToolbar)
        #expect(settings.showsToolbarLabels)
        #expect(!settings.showsToolbarLocationItems, "The tree, the query bar and the tab titles name both")
        #expect(settings.showsConnectionsInTree)
        #expect(layout == .tree)
    }

    /// The tree lists the saved connections itself, so a second list of them in its own column
    /// would put the window back at two columns.
    @Test("Use Navigator Layout turns the separate connections column off")
    func applyTurnsTheConnectionsColumnOff() {
        var settings = GeneralSettings.default
        settings.showsConnectionNavigator = true
        var layout = SidebarLayout.flat

        NavigatorLayoutPreset.apply(to: &settings, defaultLayout: &layout)

        #expect(settings.showsConnectionsInTree)
        #expect(!settings.showsConnectionNavigator)
    }

    @Test("Use Standard Layout puts all seven back to their defaults")
    func restorePutsTheDefaultsBack() {
        var settings = Self.navigatorLayout(from: .default)
        settings.showsConnectionNavigator = true
        var layout = SidebarLayout.tree

        NavigatorLayoutPreset.restore(to: &settings, defaultLayout: &layout)

        #expect(settings.showTableDetails == GeneralSettings.default.showTableDetails)
        #expect(settings.showsFavoritesSection == GeneralSettings.default.showsFavoritesSection)
        #expect(settings.showsObjectsOnSelection == GeneralSettings.default.showsObjectsOnSelection)
        #expect(settings.showsObjectToolbar == GeneralSettings.default.showsObjectToolbar)
        #expect(!settings.showsToolbarLabels, "Standard Layout is icons only")
        #expect(settings.showsToolbarLocationItems, "Standard Layout puts the connection and database back")
        #expect(settings.showsConnectionsInTree == GeneralSettings.default.showsConnectionsInTree)
        #expect(settings.showsConnectionNavigator == GeneralSettings.default.showsConnectionNavigator)
        #expect(settings == GeneralSettings.default)
        #expect(layout == .flat)
    }

    @Test("Using the navigator layout a second time changes nothing")
    func applyingTwiceIsHarmless() {
        var settings = GeneralSettings.default
        var layout = SidebarLayout.flat
        NavigatorLayoutPreset.apply(to: &settings, defaultLayout: &layout)
        let once = settings

        NavigatorLayoutPreset.apply(to: &settings, defaultLayout: &layout)

        #expect(settings == once)
        #expect(layout == .tree)
    }

    @Test("Neither button touches any other General setting")
    func otherSettingsStayPut() {
        var settings = GeneralSettings.default
        settings.showRecentTables = true
        settings.showWorkspaceRail = false
        settings.showPartitions = false
        settings.queryTimeoutSeconds = 90
        let before = settings
        var layout = SidebarLayout.flat

        NavigatorLayoutPreset.apply(to: &settings, defaultLayout: &layout)
        #expect(settings == Self.navigatorLayout(from: before))

        NavigatorLayoutPreset.restore(to: &settings, defaultLayout: &layout)
        #expect(settings == before)
    }

    @Test("Use Navigator Layout turns on the data view, the two-row query bar, the run tabs and colorful icons, and Standard Layout turns them off")
    func dataViewFollowsTheButtons() {
        var tabs = TabSettings.default
        var grid = DataGridSettings.default
        var editor = EditorSettings.default
        var appearance = AppearanceSettings.default

        NavigatorLayoutPreset.applyDataView(tabs: &tabs, dataGrid: &grid, editor: &editor, appearance: &appearance)

        #expect(grid.showsColumnTypesInHeader)
        #expect(grid.showsSortInFilterPanel)
        #expect(grid.opensFilterPanelForTables)
        #expect(grid.resultBarAtTop)
        #expect(tabs.titleShowsLocation)
        #expect(editor.queryBarTwoRows)
        #expect(editor.queryResultTabs)
        #expect(appearance.objectIconStyle == .colorful)

        NavigatorLayoutPreset.restoreDataView(tabs: &tabs, dataGrid: &grid, editor: &editor, appearance: &appearance)

        #expect(grid == DataGridSettings.default)
        #expect(tabs == TabSettings.default)
        #expect(editor == EditorSettings.default)
        #expect(!editor.queryBarTwoRows)
        #expect(!editor.queryResultTabs)
        #expect(appearance == AppearanceSettings.default)
    }

    @Test("The data view buttons leave every other Data Grid, Tab and Editor setting alone")
    func dataViewKeepsOtherSettings() {
        var tabs = TabSettings.default
        tabs.enablePreviewTabs = !tabs.enablePreviewTabs
        var grid = DataGridSettings.default
        grid.showRowNumbers = !grid.showRowNumbers
        grid.defaultPageSize = 250
        var editor = EditorSettings.default
        editor.wordWrap = !editor.wordWrap
        editor.keyBindings = .vim
        var appearance = AppearanceSettings.default
        let appearanceBefore = appearance
        let tabsBefore = tabs
        let gridBefore = grid
        let editorBefore = editor

        NavigatorLayoutPreset.applyDataView(tabs: &tabs, dataGrid: &grid, editor: &editor, appearance: &appearance)
        #expect(tabs.enablePreviewTabs == tabsBefore.enablePreviewTabs)
        #expect(grid.showRowNumbers == gridBefore.showRowNumbers)
        #expect(grid.defaultPageSize == 250)
        var expectedEditor = editorBefore
        expectedEditor.queryBarTwoRows = true
        expectedEditor.queryResultTabs = true
        #expect(editor == expectedEditor)
        #expect(appearance.objectIconStyle == .colorful)

        NavigatorLayoutPreset.restoreDataView(tabs: &tabs, dataGrid: &grid, editor: &editor, appearance: &appearance)
        #expect(tabs == tabsBefore)
        #expect(grid == gridBefore)
        #expect(editor == editorBefore)
        #expect(appearance == appearanceBefore)
    }

    /// The View menu switches one connection through its shared sidebar state; the preset does the
    /// same for each open one, and skips an engine that has no tree to switch to.
    @MainActor
    @Test("Open connections that can show a tree switch layout, and the others keep theirs")
    func openConnectionsSwitchLayout() {
        let networked = TestFixtures.makeConnection(name: "Networked", type: .mysql)
        let file = TestFixtures.makeConnection(name: "File", type: .sqlite)
        let connections = [networked, file]
        for connection in connections {
            DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        }
        defer {
            for connection in connections {
                DatabaseManager.shared.removeSession(for: connection.id)
                SharedSidebarState.removeConnection(connection.id)
                SidebarPersistenceKey.removeAll(connectionId: connection.id)
            }
        }
        let fileLayout = SharedSidebarState.forConnection(file.id).sidebarLayout

        NavigatorLayoutPreset.switchOpenConnections(to: .tree)

        #expect(SharedSidebarState.forConnection(networked.id).sidebarLayout == .tree)
        #expect(SharedSidebarState.forConnection(file.id).sidebarLayout == fileLayout)

        NavigatorLayoutPreset.switchOpenConnections(to: .flat)

        #expect(SharedSidebarState.forConnection(networked.id).sidebarLayout == .flat)
    }
}

extension GlobalStateSuites {
    /// The preset written the way Settings writes it, through the General settings value in one
    /// step, reaching what each toggle reaches when flipped by hand.
    @MainActor
    struct NavigatorLayoutPresetSettingTests {
        @Test(
            "Through the settings manager, the preset reaches the toolbar and the connections column",
            .appSettings {
                $0.general.showTableDetails = false
                $0.general.showsObjectsOnSelection = false
                $0.general.showsObjectToolbar = false
                $0.general.showsToolbarLabels = false
                $0.general.showsToolbarLocationItems = true
                $0.general.showsConnectionNavigator = false
                $0.general.showsConnectionsInTree = false
            }
        )
        func presetReachesAnOpenWindow() throws {
            let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861))
            defer { fixture.tearDown() }
            let storage = try EphemeralDefaults()
            fixture.toolbarOwner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
            fixture.toolbarOwner.labelsRecord = ToolbarLabelsRecord(defaults: storage.defaults)
            fixture.toolbarOwner.locationItemsRecord = ToolbarLocationItemsRecord(defaults: storage.defaults)
            let toolbar = try #require(fixture.window.toolbar)
            let location = Set(MainWindowToolbar.locationItemIdentifiers)
            let hasLocation = { toolbar.items.contains { location.contains($0.itemIdentifier) } }
            #expect(hasLocation())
            #expect(toolbar.displayMode == .iconOnly)
            let objectKinds = Set(MainWindowToolbar.objectKindItemIdentifiers)
            let hasButtons = { toolbar.items.contains { objectKinds.contains($0.itemIdentifier) } }
            var railChanges = 0
            let subscription = AppEvents.shared.workspaceRailVisibilityChanged.sink { railChanges += 1 }
            defer { subscription.cancel() }
            var layout = SidebarLayout.flat

            NavigatorLayoutPreset.apply(to: &AppSettingsManager.shared.general, defaultLayout: &layout)

            #expect(hasButtons(), "The Objects buttons reach the open window")
            #expect(toolbar.displayMode == .iconAndLabel, "Labels go under the toolbar's icons")
            #expect(!hasLocation(), "The connection and database leave the open window's toolbar")
            #expect(railChanges == 1, "The connections column is told the tree now lists the connections")

            NavigatorLayoutPreset.restore(to: &AppSettingsManager.shared.general, defaultLayout: &layout)

            #expect(!hasButtons(), "The Objects buttons leave the open window")
            #expect(toolbar.displayMode == .iconOnly, "Standard Layout puts the icons back alone")
            #expect(hasLocation(), "Standard Layout puts the connection and database back")
            #expect(railChanges == 2, "The connections column is told the tree stops listing them")
        }
    }
}
