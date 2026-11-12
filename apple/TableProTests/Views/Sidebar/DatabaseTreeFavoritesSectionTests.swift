//
//  DatabaseTreeFavoritesSectionTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProSyncTransport
import TableProTestSupport
import Testing

// The Favorites section: the browsed database's starred tables above Recent, each a second row for a
// table the tree already lists.
@MainActor
struct DatabaseTreeFavoritesSectionTests {
    private struct Fixture {
        let connection: DatabaseConnection
        let coordinator: DatabaseTreeOutlineCoordinator
        let favorites: FavoriteTablesStorage
        let outlineView: NSOutlineView
        let scrollView: NSScrollView
        let viewModel: SidebarViewModel
        let defaults: [EphemeralDefaults]
    }

    private func makeFixture(showsFavoritesSection: Bool = true) async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "customers"),
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "v_orders", type: .view),
        ]
        await SchemaService.shared.load(connectionId: connection.id, driver: driver, connection: connection)

        let favoritesDefaults = try EphemeralDefaults()
        let syncDefaults = try EphemeralDefaults()
        let favorites = FavoriteTablesStorage(
            userDefaults: favoritesDefaults.defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults.defaults))
        )

        let outlineView = NSOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "FavoritesColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let sidebarState = SharedSidebarState.forConnection(connection.id)
        sidebarState.sidebarLayout = .flat
        let viewModel = SidebarViewModel(
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .mysql,
            connectionId: connection.id
        )
        let coordinator = DatabaseTreeOutlineCoordinator(favoriteTablesStorage: favorites)
        coordinator.connectionId = connection.id
        coordinator.databaseType = .mysql
        coordinator.sidebarState = sidebarState
        coordinator.windowState = WindowSidebarState()
        coordinator.viewModel = viewModel
        coordinator.activeDatabase = "shop"
        coordinator.showsFavoritesSection = showsFavoritesSection
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(
            connection: connection,
            coordinator: coordinator,
            favorites: favorites,
            outlineView: outlineView,
            scrollView: scrollView,
            viewModel: viewModel,
            defaults: [favoritesDefaults, syncDefaults]
        )
    }

    private func tearDown(_ fixture: Fixture) async {
        await SchemaService.shared.invalidate(connectionId: fixture.connection.id)
        SharedSidebarState.removeConnection(fixture.connection.id)
        _ = fixture.scrollView
        _ = fixture.viewModel
    }

    private func favoritesSection(_ fixture: Fixture) -> DatabaseTreeNode? {
        fixture.coordinator.resolvedChildren(of: nil).first { node in
            guard case .favoritesSection = node.kind else { return false }
            return true
        }
    }

    private func star(_ name: String, database: String? = "shop", in fixture: Fixture) {
        fixture.favorites.toggle(name: name, schema: nil, database: database, connectionId: fixture.connection.id)
    }

    // The coordinator hears the change through the storage's notification, on the main queue.
    private func waitForSection(_ fixture: Fixture, present: Bool) async throws {
        try await waitUntil { (favoritesSection(fixture) != nil) == present }
    }

    @Test("A starred table gets a Favorites section at the top of the tree, before Recent and the object groups")
    func starredTableAddsTheSection() async throws {
        let fixture = try await makeFixture()
        #expect(favoritesSection(fixture) == nil)

        star("orders", in: fixture)
        try await waitForSection(fixture, present: true)

        let section = try #require(favoritesSection(fixture))
        #expect(fixture.coordinator.resolvedChildren(of: nil).first?.id == section.id)
        let rows = fixture.coordinator.resolvedChildren(of: section)
        #expect(rows.map { $0.favoriteTableRef?.table.name } == ["orders"])
        #expect(rows.first?.id == DatabaseTreeNode.favoriteTableId(try #require(rows.first?.favoriteTableRef)))
        await tearDown(fixture)
    }

    @Test("The section lists the browsed database's favorites only, by name, and a listed view stays a view")
    func sectionListsTheBrowsedDatabase() async throws {
        let fixture = try await makeFixture()
        star("v_orders", in: fixture)
        star("customers", in: fixture)
        star("events", database: "analytics", in: fixture)
        try await waitUntil {
            fixture.coordinator.favoriteTableRefs().count == 2
        }

        let section = try #require(favoritesSection(fixture))
        let refs = fixture.coordinator.resolvedChildren(of: section).compactMap(\.favoriteTableRef)

        #expect(refs.map(\.table.name) == ["customers", "v_orders"])
        #expect(refs.last?.table.type == .view)
        #expect(refs.allSatisfy { $0.database == "shop" })
        await tearDown(fixture)
    }

    @Test("With the option off, starring a table adds no section")
    func optionOffShowsNoSection() async throws {
        let fixture = try await makeFixture(showsFavoritesSection: false)

        star("orders", in: fixture)
        fixture.coordinator.refresh()

        #expect(favoritesSection(fixture) == nil)
        await tearDown(fixture)
    }

    @Test("Removing the last favorite removes the section")
    func unstarringTheLastRemovesTheSection() async throws {
        let fixture = try await makeFixture()
        star("orders", in: fixture)
        try await waitForSection(fixture, present: true)

        star("orders", in: fixture)

        try await waitForSection(fixture, present: false)
        await tearDown(fixture)
    }

    @Test("A favorite row is selectable and opens its table; the section heading is neither")
    func favoriteRowSelectsLikeATable() {
        let ref = DatabaseTreeTableRef(
            database: "shop",
            schema: nil,
            table: TableInfo(name: "orders", type: .table, rowCount: nil, schema: nil)
        )
        let row = DatabaseTreeNode(id: DatabaseTreeNode.favoriteTableId(ref), kind: .favoriteTable(ref))
        let section = DatabaseTreeNode(id: DatabaseTreeNode.favoritesSectionId, kind: .favoritesSection)

        #expect(DatabaseTreeSelection.isSelectable(row.kind))
        #expect(!DatabaseTreeSelection.isSelectable(section.kind))
        #expect(DatabaseTreeSelection.tableRef(of: row) == ref)
        #expect(DatabaseTreeSelection.tableRef(of: section) == nil)
        #expect(section.isGroupRow)
        #expect(!row.isExpandable)
        #expect(row.id != DatabaseTreeNode.tableId(ref))
        #expect(row.id != DatabaseTreeNode.recentTableId(ref))
    }
}
