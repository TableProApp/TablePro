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

    private func makeFixture(
        injectsSession: Bool = false,
        _ configure: (SideObjectsMockDriver) -> Void
    ) async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let driver = SideObjectsMockDriver(connection: connection)
        configure(driver)
        // The outline asks the session's driver which kinds it declares.
        if injectsSession {
            DatabaseManager.shared.injectSession(ConnectionSession(connection: connection, driver: driver), for: connection.id)
        }
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
        if DatabaseManager.shared.session(for: fixture.connectionId) != nil {
            DatabaseManager.shared.removeSession(for: fixture.connectionId)
        }
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

    private var extensionKind: PluginServerObjectKind {
        PluginServerObjectKind(
            id: "extension", displayName: "Extension", pluralDisplayName: "Extensions",
            iconName: "puzzlepiece.extension", scope: .database
        )
    }

    private var extensions: SidebarObjectKind {
        .server(SidebarServerObjectKind(extensionKind))
    }

    @Test("A declared kind with objects gets a section after the built-in kinds")
    func declaredKindIsListedAfterBuiltIns() async throws {
        let fixture = try await makeFixture(injectsSession: true) { driver in
            driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders", schema: "public")]
            driver.declaredServerKinds = [extensionKind]
            driver.serverObjectsByKind["extension"] = [
                ServerObjectInfo(kindId: "extension", name: "pgcrypto", schema: "public", identity: "16384", detail: "1.3")
            ]
        }

        #expect(rootSections(fixture) == [.table, extensions])
        let section = try #require(section(fixture, extensions))
        let rows = fixture.coordinator.resolvedChildren(of: section)
        guard case .serverObject(let ref) = rows.first?.kind else {
            Issue.record("The Extensions section lists no extension row")
            await tearDown(fixture)
            return
        }
        #expect(rows.count == 1)
        #expect(ref.object.name == "pgcrypto")
        #expect(ref.kind.pluralDisplayName == "Extensions")
        #expect(ref.objectRef.kind == .serverObject)
        await tearDown(fixture)
    }

    @Test("A declared kind that returned nothing gets no section")
    func emptyDeclaredKindIsOmitted() async throws {
        let fixture = try await makeFixture(injectsSession: true) { driver in
            driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders", schema: "public")]
            driver.declaredServerKinds = [extensionKind]
        }

        #expect(rootSections(fixture) == [.table])
        await tearDown(fixture)
    }

    @Test("A declared kind whose fetch failed keeps its section, showing the error")
    func failedDeclaredKindKeepsItsSection() async throws {
        let fixture = try await makeFixture(injectsSession: true) { driver in
            driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders", schema: "public")]
            driver.declaredServerKinds = [extensionKind]
            driver.serverObjectsError = boom
        }

        #expect(rootSections(fixture) == [.table, extensions])
        let section = try #require(section(fixture, extensions))
        let rows = fixture.coordinator.resolvedChildren(of: section)
        guard case .status(let status) = rows.first?.kind else {
            Issue.record("The failed section shows no status row")
            await tearDown(fixture)
            return
        }
        #expect(status == .error("permission denied"))
        await tearDown(fixture)
    }

    @Test("A search that matches only a server object keeps its section")
    func searchMatchingOnlyAServerObject() async throws {
        let fixture = try await makeFixture(injectsSession: true) { driver in
            driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders", schema: "public")]
            driver.declaredServerKinds = [extensionKind]
            driver.serverObjectsByKind["extension"] = [ServerObjectInfo(kindId: "extension", name: "pgcrypto", schema: "public")]
        }
        fixture.viewModel.searchText = "crypto"
        fixture.coordinator.searchText = "crypto"
        fixture.coordinator.refresh()

        #expect(rootSections(fixture) == [extensions])
        await tearDown(fixture)
    }
}
