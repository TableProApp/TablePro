//
//  DatabaseTreeConnectionsInTreeTests.swift
//  TableProTests
//

import AppKit
import Combine
import Foundation
import SwiftUI
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
import TableProTestSupport
import Testing

/// The tree with the saved connections at its top: groups, then connections, with the tree's own
/// connection opened to its databases. The library, events, window and router are the connections
/// column's test doubles, so nothing reaches the app's real library or opens a window. The tree's
/// own connection is a PGlite session, so every read stays on the injected driver.
@MainActor
struct DatabaseTreeConnectionsInTreeTests {
    private struct Fixture {
        let library: ConnectionNavigatorFixture
        let own: DatabaseConnection
        let billing: DatabaseConnection
        let local: DatabaseConnection
        let work: ConnectionGroup
        let coordinator: DatabaseTreeOutlineCoordinator
        let outlineView: NSOutlineView
        let scrollView: NSScrollView
        let viewModel: SidebarViewModel
        let defaults: EphemeralDefaults
    }

    private let service = DatabaseTreeMetadataService.shared

    /// "Work" holds this tree's own connection, Shop, and Billing, which this window also hosts.
    /// Local sits outside any group and nobody hosts it.
    private func makeFixture(
        showsConnections: Bool = true,
        layout: SidebarLayout = .tree,
        searchText: String = ""
    ) async throws -> Fixture {
        let library = try ConnectionNavigatorFixture()
        let work = ConnectionGroup(name: "Work")
        try library.groupStorage.addGroup(work)
        var own = TestFixtures.makeConnection(name: "Shop", database: "shop", type: .pglite)
        own.groupId = work.id
        var billing = TestFixtures.makeConnection(name: "Billing", database: "billing", type: .mysql)
        billing.groupId = work.id
        let local = TestFixtures.makeConnection(name: "Local", database: "local", type: .postgresql)
        library.save([own, billing, local])
        library.host.hosted = [own.id, billing.id]
        library.host.selected = own.id
        library.statuses[own.id] = .connected

        let driver = MockDatabaseDriver(connection: own)
        driver.databasesToReturn = ["shop", "analytics"]
        var session = ConnectionSession(connection: own, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: own.id)
        await service.loadDatabases(connectionId: own.id, databaseType: .pglite)

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "ConnectionsInTreeColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let sidebarState = SharedSidebarState.forConnection(own.id)
        sidebarState.sidebarLayout = layout
        let defaults = try EphemeralDefaults()
        let viewModel = SidebarViewModel(
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .pglite,
            connectionId: own.id,
            defaults: defaults.defaults
        )
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = own.id
        coordinator.databaseType = .pglite
        coordinator.sidebarState = sidebarState
        coordinator.windowState = WindowSidebarState()
        coordinator.viewModel = viewModel
        coordinator.activeDatabase = "shop"
        coordinator.showRecentTables = false
        coordinator.searchText = searchText
        coordinator.showsConnectionsInTree = showsConnections
        coordinator.connectionsModel = library.makeModel()
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(
            library: library,
            own: own,
            billing: billing,
            local: local,
            work: work,
            coordinator: coordinator,
            outlineView: outlineView,
            scrollView: scrollView,
            viewModel: viewModel,
            defaults: defaults
        )
    }

    private func tearDown(_ fixture: Fixture) async {
        fixture.coordinator.connectionsModel?.stop()
        await service.handleDisconnect(connectionId: fixture.own.id)
        ExternalSchemaTracker.shared.reset(connectionId: fixture.own.id)
        DatabaseManager.shared.removeSession(for: fixture.own.id)
        SharedSidebarState.removeConnection(fixture.own.id)
        _ = fixture.scrollView
        _ = fixture.viewModel
        _ = fixture.defaults
    }

    private func roots(_ fixture: Fixture) -> [DatabaseTreeNode] {
        fixture.coordinator.resolvedChildren(of: nil)
    }

    private func rowNodes(_ fixture: Fixture) -> [DatabaseTreeNode] {
        (0..<fixture.outlineView.numberOfRows).compactMap { fixture.outlineView.item(atRow: $0) as? DatabaseTreeNode }
    }

    private func connectionNode(_ id: UUID, in fixture: Fixture) -> DatabaseTreeNode? {
        rowNodes(fixture).first { $0.savedConnectionRef?.id == id }
    }

    private func groupNode(_ fixture: Fixture) -> DatabaseTreeNode? {
        roots(fixture).first { node in
            guard case .connectionGroup(let group) = node.kind else { return false }
            return group.id == fixture.work.id
        }
    }

    private func databaseNames(under node: DatabaseTreeNode, in fixture: Fixture) -> [String] {
        fixture.coordinator.resolvedChildren(of: node).compactMap { node in
            guard case .database(let metadata) = node.kind else { return nil }
            return metadata.name
        }
    }

    // MARK: - Shape

    @Test("The tree lists the saved connections in their groups, with its own opened to its databases")
    func connectionsAboveTheDatabases() async throws {
        let fixture = try await makeFixture()

        let group = try #require(groupNode(fixture))
        #expect(roots(fixture).contains { $0.savedConnectionRef?.id == fixture.local.id })
        #expect(fixture.outlineView.isItemExpanded(group), "The group holding the tree's own connection opens")

        let own = try #require(connectionNode(fixture.own.id, in: fixture))
        #expect(own.savedConnectionRef?.ownsTree == true)
        #expect(fixture.outlineView.isItemExpanded(own))
        #expect(Set(databaseNames(under: own, in: fixture)) == ["shop", "analytics"])
        #expect(fixture.outlineView.parent(forItem: own) as? DatabaseTreeNode === group)

        for other in [fixture.billing.id, fixture.local.id] {
            let node = try #require(connectionNode(other, in: fixture))
            #expect(node.savedConnectionRef?.ownsTree == false)
            #expect(!fixture.outlineView.isExpandable(node))
            #expect(fixture.coordinator.resolvedChildren(of: node).isEmpty)
        }
        await tearDown(fixture)
    }

    @Test("With the setting off the databases are the tree's top rows, as before")
    func settingOffKeepsDatabasesAtTheTop() async throws {
        let fixture = try await makeFixture(showsConnections: false)

        #expect(!roots(fixture).contains { $0.savedConnectionRef != nil })
        let databases = roots(fixture).compactMap { node -> String? in
            guard case .database(let metadata) = node.kind else { return nil }
            return metadata.name
        }
        #expect(Set(databases) == ["shop", "analytics"])
        #expect(fixture.coordinator.connectionsModel?.rows.isEmpty == true, "A tree that lists no connections reads no library")
        await tearDown(fixture)
    }

    @Test("The flat layout lists no connections even with the setting on")
    func flatLayoutListsNoConnections() async throws {
        let fixture = try await makeFixture(layout: .flat)

        #expect(!roots(fixture).contains { $0.savedConnectionRef != nil })
        await tearDown(fixture)
    }

    /// AppKit lays a source list group out at the root's own depth, so a Recent or Favorites section
    /// under the connection would be pulled out from under it.
    @Test("Under a connection no section is a source list group")
    func sectionsAreOrdinaryRowsUnderAConnection() async throws {
        let listing = try await makeFixture()
        let flat = try await makeFixture(showsConnections: false)
        let section = DatabaseTreeNode(id: DatabaseTreeNode.recentSectionId, kind: .recentSection)

        #expect(!listing.coordinator.outlineView(listing.outlineView, isGroupItem: section))
        #expect(flat.coordinator.outlineView(flat.outlineView, isGroupItem: section))
        await tearDown(listing)
        await tearDown(flat)
    }

    // MARK: - Filter

    @Test("The filter keeps the tree's own connection and the connections whose names match")
    func filterNarrowsTheConnections() async throws {
        let fixture = try await makeFixture(searchText: "bill")

        #expect(connectionNode(fixture.own.id, in: fixture) != nil, "The objects the filter finds hang from it")
        #expect(connectionNode(fixture.billing.id, in: fixture) != nil)
        #expect(!roots(fixture).contains { $0.savedConnectionRef?.id == fixture.local.id })
        await tearDown(fixture)
    }

    // MARK: - Expansion

    @Test("Closing the group and the own connection is remembered, and survives a reload")
    func closingIsRemembered() async throws {
        let fixture = try await makeFixture()
        let own = try #require(connectionNode(fixture.own.id, in: fixture))
        let group = try #require(groupNode(fixture))

        fixture.outlineView.collapseItem(own)
        #expect(!fixture.viewModel.isOwnConnectionExpanded)

        fixture.outlineView.collapseItem(group)
        fixture.coordinator.refresh()

        #expect(!fixture.outlineView.isItemExpanded(group))
        #expect(!fixture.library.expansionStore.load(keeping: [fixture.work.id]).contains(fixture.work.id))

        fixture.outlineView.expandItem(group)
        #expect(fixture.library.expansionStore.load(keeping: [fixture.work.id]) == [fixture.work.id])
        #expect(!fixture.outlineView.isItemExpanded(own), "The own connection stays as the user left it")
        await tearDown(fixture)
    }

    // MARK: - Interaction

    @Test("Opening another connection this window hosts switches to it")
    func activatingAHostedConnectionSwitches() async throws {
        let fixture = try await makeFixture()
        let billing = try #require(connectionNode(fixture.billing.id, in: fixture)?.savedConnectionRef)

        fixture.coordinator.activateConnection(billing)

        #expect(fixture.library.host.selected == fixture.billing.id)
        #expect(fixture.library.router.openedConnections.isEmpty)
        await tearDown(fixture)
    }

    @Test("Opening a connection nobody hosts goes through the router")
    func activatingAClosedConnectionRoutes() async throws {
        let fixture = try await makeFixture()
        let local = try #require(connectionNode(fixture.local.id, in: fixture)?.savedConnectionRef)

        fixture.coordinator.activateConnection(local)

        try await waitUntil { fixture.library.router.openedConnections == [fixture.local.id] }
        #expect(fixture.library.host.selected == fixture.own.id)
        await tearDown(fixture)
    }

    @Test("A connection row takes the connections column's menu, and the tree's own needs no way to reach it")
    func connectionRowsTakeTheNavigatorMenu() async throws {
        let fixture = try await makeFixture()
        let menu = NSMenu()
        let titles = { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

        #expect(fixture.coordinator.fillConnectionMenu(menu, clicked: connectionNode(fixture.local.id, in: fixture)))
        #expect(titles().first == ConnectionNavigatorMenu.Titles.connect)
        #expect(titles().contains(ConnectionNavigatorMenu.Titles.editConnection))

        #expect(fixture.coordinator.fillConnectionMenu(menu, clicked: connectionNode(fixture.billing.id, in: fixture)))
        #expect(titles().first == ConnectionNavigatorMenu.Titles.switchTo)

        #expect(fixture.coordinator.fillConnectionMenu(menu, clicked: connectionNode(fixture.own.id, in: fixture)))
        #expect(!titles().contains(ConnectionNavigatorMenu.Titles.switchTo))
        #expect(!titles().contains(ConnectionNavigatorMenu.Titles.connect))

        let database = try #require(fixture.coordinator.resolvedChildren(
            of: try #require(connectionNode(fixture.own.id, in: fixture))
        ).first)
        #expect(!fixture.coordinator.fillConnectionMenu(menu, clicked: database), "Other rows keep the tree's own menu")
        await tearDown(fixture)
    }

    // MARK: - Library and status

    @Test("A connection saved elsewhere appears in the tree")
    func libraryChangeRebuildsTheRows() async throws {
        let fixture = try await makeFixture()
        let added = TestFixtures.makeConnection(name: "Added")

        fixture.library.save([fixture.own, fixture.billing, fixture.local, added])
        fixture.library.events.connectionUpdated.send(nil)

        try await waitUntil { roots(fixture).contains { $0.savedConnectionRef?.id == added.id } }
        await tearDown(fixture)
    }

    @Test("A status change re-marks a connection's row in place")
    func statusChangeReMarksTheRow() async throws {
        let fixture = try await makeFixture()
        let node = try #require(connectionNode(fixture.local.id, in: fixture))

        fixture.library.statuses[fixture.local.id] = .connecting
        fixture.library.events.connectionPhaseChanged.send(fixture.local.id)

        try await waitUntil { node.savedConnectionRef?.row.status == .connecting }
        #expect(connectionNode(fixture.local.id, in: fixture) === node, "The row is the same node, reconfigured")
        await tearDown(fixture)
    }
}
