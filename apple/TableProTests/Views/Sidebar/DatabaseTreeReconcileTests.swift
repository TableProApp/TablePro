//
//  DatabaseTreeReconcileTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// The outline's services publish for every connection and every property; only a change to what this
// connection's outline draws may rebuild it.
@MainActor
struct DatabaseTreeReconcileTests {
    private final class CountingOutlineView: NSOutlineView {
        var reloads = 0

        override func reloadData() {
            reloads += 1
            super.reloadData()
        }
    }

    private struct Fixture {
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver
        let coordinator: DatabaseTreeOutlineCoordinator
        let outlineView: CountingOutlineView
        let sidebarState: SharedSidebarState
        let viewModel: SidebarViewModel
        let scrollView: NSScrollView
    }

    private func makeFixture() async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "customers")]
        await SchemaService.shared.load(connectionId: connection.id, driver: driver, connection: connection)

        let outlineView = CountingOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "ReconcileColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let sidebarState = SharedSidebarState.forConnection(connection.id)
        sidebarState.sidebarLayout = .flat
        let viewModel = SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .mysql,
            connectionId: connection.id
        )
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connection.id
        coordinator.databaseType = .mysql
        coordinator.sidebarState = sidebarState
        coordinator.windowState = WindowSidebarState()
        coordinator.viewModel = viewModel
        coordinator.activeDatabase = "shop"
        coordinator.showRecentTables = true
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(
            connection: connection,
            driver: driver,
            coordinator: coordinator,
            outlineView: outlineView,
            sidebarState: sidebarState,
            viewModel: viewModel,
            scrollView: scrollView
        )
    }

    private func tearDown(_ fixture: Fixture) async {
        await SchemaService.shared.invalidate(connectionId: fixture.connection.id)
        SharedSidebarState.removeConnection(fixture.connection.id)
        _ = fixture.scrollView
        _ = fixture.viewModel
    }

    private func tableRows(_ fixture: Fixture) throws -> [DatabaseTreeNode] {
        let section = try #require(fixture.coordinator.resolvedChildren(of: nil).first { node in
            guard case .objectKindSection(.table) = node.kind else { return false }
            return true
        })
        return fixture.coordinator.resolvedChildren(of: section)
    }

    private func tableNames(_ fixture: Fixture) throws -> [String] {
        try tableRows(fixture).compactMap { node -> String? in
            guard case .table(let ref) = node.kind else { return nil }
            return ref.table.name
        }
    }

    @Test("A catalog load on another connection does not reload the outline")
    func otherConnectionDoesNotReload() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads
        let other = TestFixtures.makeConnection(database: "blog", type: .mysql)
        let otherDriver = MockDatabaseDriver(connection: other)
        otherDriver.tablesToReturn = [TestFixtures.makeTableInfo(name: "posts")]

        await SchemaService.shared.load(connectionId: other.id, driver: otherDriver, connection: other)
        fixture.coordinator.reconcile()

        #expect(fixture.outlineView.reloads == reloads)
        await SchemaService.shared.invalidate(connectionId: other.id)
        await tearDown(fixture)
    }

    @Test("A change to this connection's tables reloads the outline with them")
    func ownTablesReload() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads
        fixture.driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "invoices")]

        await SchemaService.shared.reload(
            connectionId: fixture.connection.id, driver: fixture.driver, connection: fixture.connection
        )

        try await waitUntil { fixture.outlineView.reloads > reloads }
        #expect(try tableNames(fixture).contains("invoices"))
        await tearDown(fixture)
    }

    @Test("Typing in the filter field alone does not reload the outline")
    func searchTextWriteDoesNotReload() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads

        fixture.sidebarState.searchText = "ord"
        fixture.coordinator.reconcile()

        #expect(fixture.outlineView.reloads == reloads)
        await tearDown(fixture)
    }

    @Test("A recent table recorded for this connection reloads the outline")
    func recentTableReloads() async throws {
        let fixture = try await makeFixture()
        let reloads = fixture.outlineView.reloads

        fixture.sidebarState.recentTables = [RecentTableEntry(
            database: "shop", schema: nil, name: "orders", isView: false, objectType: nil, openedAt: Date()
        )]
        fixture.coordinator.reconcile()

        #expect(fixture.outlineView.reloads == reloads + 1)
        await tearDown(fixture)
    }

    @Test("A reload over the same rows hands back the same row nodes")
    func unchangedRowsKeepTheirNodes() async throws {
        let fixture = try await makeFixture()
        let before = try tableRows(fixture)

        fixture.coordinator.refresh()
        let after = try tableRows(fixture)

        #expect(before.map { $0.id } == after.map { $0.id })
        #expect(SameRows(rows: before) == SameRows(rows: after))
        await tearDown(fixture)
    }
}
