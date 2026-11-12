//
//  SidebarContainerConnectionsInTreeTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    /// With the saved connections in the tree, the sidebar is the filter field and the tree: the
    /// Tables and Favorites switcher stands aside while Tables shows, and comes back with Favorites
    /// so the user has the way back.
    @MainActor
    struct SidebarContainerConnectionsInTreeTests {
        @MainActor
        private struct Host {
            let controller = SidebarContainerViewController()
            let connection: DatabaseConnection
            let state: SharedSidebarState

            init(type: DatabaseType = .mysql, layout: SidebarLayout = .tree, tab: SidebarTab = .tables) {
                connection = TestFixtures.makeConnection(name: "Shop", type: type)
                DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
                state = SharedSidebarState.forConnection(connection.id)
                state.sidebarLayout = layout
                state.selectedSidebarTab = tab
                controller.loadView()
                controller.updateSidebarState(state)
            }

            func tearDown() {
                controller.updateSidebarState(nil)
                DatabaseManager.shared.removeSession(for: connection.id)
                SharedSidebarState.removeConnection(connection.id)
                SidebarPersistenceKey.removeAll(connectionId: connection.id)
            }
        }

        @Test(
            "Tables in a tree that lists the connections hides the switcher, and Favorites brings it back",
            .appSettings { $0.general.showsConnectionsInTree = true }
        )
        func switcherStandsAsideForTheTree() async throws {
            let host = Host()
            defer { host.tearDown() }

            #expect(host.controller.treeListsConnections)
            #expect(host.controller.isScopeHidden)

            host.state.selectedSidebarTab = .favorites

            try await waitUntil { !host.controller.isScopeHidden }
            #expect(host.controller.treeListsConnections, "The tree still lists them, so the strip still stands aside")
        }

        @Test("With the setting off the switcher stands", .appSettings { $0.general.showsConnectionsInTree = false })
        func settingOffKeepsTheSwitcher() {
            let host = Host()
            defer { host.tearDown() }

            #expect(!host.controller.treeListsConnections)
            #expect(!host.controller.isScopeHidden)
        }

        @Test(
            "The list layout and an engine with no database tree keep the switcher",
            .appSettings { $0.general.showsConnectionsInTree = true }
        )
        func onlyTheDatabaseTreeHidesTheSwitcher() {
            let list = Host(layout: .flat)
            let file = Host(type: .sqlite)
            defer {
                list.tearDown()
                file.tearDown()
            }

            #expect(!list.controller.isScopeHidden)
            #expect(!file.controller.isScopeHidden)
        }

        @Test(
            "Switching the layout to Tree tells the window, which keeps the strip away",
            .appSettings { $0.general.showsConnectionsInTree = true }
        )
        func layoutChangeIsReported() async throws {
            let host = Host(layout: .flat)
            defer { host.tearDown() }
            var reports = 0
            host.controller.onTreeListsConnectionsChange = { reports += 1 }

            host.state.sidebarLayout = .tree

            try await waitUntil { reports == 1 }
            #expect(host.controller.isScopeHidden)
        }

        @Test(
            "Turning the setting off brings the switcher back",
            .appSettings { $0.general.showsConnectionsInTree = true }
        )
        func settingChangeIsApplied() async throws {
            let host = Host()
            defer { host.tearDown() }
            #expect(host.controller.isScopeHidden)

            AppSettingsManager.shared.general.showsConnectionsInTree = false

            try await waitUntil { !host.controller.isScopeHidden }
        }
    }
}
