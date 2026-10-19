//
//  DatabaseTreeFlatRootTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

/// The flat sidebar's root, built by the real outline coordinator over the connection's schema service.
///
/// The report: a PostgreSQL schema with tables, views and functions, and no procedures, triggers or
/// types, listed a Procedures and a Triggers section reading "No items" and a Types section with
/// nothing under it.
@MainActor
struct DatabaseTreeFlatRootTests {
    private struct Fixture {
        let connectionId: UUID
        let coordinator: DatabaseTreeOutlineCoordinator
        let viewModel: SidebarViewModel
        let scrollView: NSScrollView
    }

    private let boom = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "permission denied"])

    private func makeFixture(_ configure: (SideObjectsMockDriver) -> Void) async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let driver = SideObjectsMockDriver(connection: connection)
        configure(driver)
        await SchemaService.shared.load(connectionId: connection.id, driver: driver, connection: connection)

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "FlatRootColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let sidebarState = SharedSidebarState.forConnection(connection.id)
        sidebarState.sidebarLayout = .flat
        let viewModel = SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .postgresql,
            connectionId: connection.id
        )
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connection.id
        coordinator.databaseType = .postgresql
        coordinator.sidebarState = sidebarState
        coordinator.windowState = WindowSidebarState()
        coordinator.viewModel = viewModel
        coordinator.activeDatabase = "shop"
        coordinator.activeSchema = "public"
        coordinator.showRecentTables = false
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(connectionId: connection.id, coordinator: coordinator, viewModel: viewModel, scrollView: scrollView)
    }

    private func tearDown(_ fixture: Fixture) async {
        await SchemaService.shared.invalidate(connectionId: fixture.connectionId)
        SharedSidebarState.removeConnection(fixture.connectionId)
        _ = fixture.scrollView
        _ = fixture.viewModel
    }

    private func rootSections(_ fixture: Fixture) -> [SidebarObjectKind] {
        fixture.coordinator.resolvedChildren(of: nil).compactMap { node in
            guard case .objectKindSection(let kind) = node.kind else { return nil }
            return kind
        }
    }

    private func rootStatuses(_ fixture: Fixture) -> [DatabaseTreeNode.Status] {
        fixture.coordinator.resolvedChildren(of: nil).compactMap { node in
            guard case .status(let status) = node.kind else { return nil }
            return status
        }
    }

    private func section(_ fixture: Fixture, _ kind: SidebarObjectKind) -> DatabaseTreeNode? {
        fixture.coordinator.resolvedChildren(of: nil).first { node in
            guard case .objectKindSection(let listed) = node.kind else { return false }
            return listed == kind
        }
    }

    @Test("Only the kinds the schema holds get a section")
    func onlyKindsWithObjectsAreListed() async throws {
        #expect(DatabaseType.postgresql.declaredObjectKinds.isSuperset(of: [.procedure, .function, .trigger]))
        let fixture = try await makeFixture { driver in
            driver.tablesToReturn = [
                TestFixtures.makeTableInfo(name: "orders", schema: "public"),
                TestFixtures.makeTableInfo(name: "big_orders", type: .view, schema: "public"),
            ]
            driver.routinesBySchema[""] = [RoutineInfo(name: "order_total", kind: .function, schema: "public")]
        }

        #expect(rootSections(fixture) == [.table, .view, .function])
        #expect(rootStatuses(fixture).isEmpty)
        await tearDown(fixture)
    }

    @Test("A schema holding nothing says so in one row instead of listing empty sections")
    func emptySchemaSaysSo() async throws {
        let fixture = try await makeFixture { _ in }

        #expect(rootSections(fixture).isEmpty)
        #expect(rootStatuses(fixture) == [.empty])
        await tearDown(fixture)
    }

    /// Hiding the sections of a fetch that failed would make the refused list read as an empty one.
    @Test("A routine fetch that failed keeps its sections, showing the error")
    func failedFetchKeepsItsSections() async throws {
        let fixture = try await makeFixture { driver in
            driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders", schema: "public")]
            driver.routinesError = boom
        }

        #expect(rootSections(fixture) == [.table, .procedure, .function])
        let procedures = try #require(section(fixture, .procedure))
        let rows = fixture.coordinator.resolvedChildren(of: procedures)
        #expect(rows.count == 1)
        guard case .status(let status) = rows.first?.kind else {
            Issue.record("The failed section shows no status row")
            await tearDown(fixture)
            return
        }
        #expect(status == .error("permission denied"))
        #expect(rootStatuses(fixture).isEmpty)
        await tearDown(fixture)
    }
}
