//
//  DatabaseTreeHierarchicalSearchTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

/// An Oracle-shaped tree, one row per schema, over a session with no database name so every read stays
/// on the injected driver. The search finds `timesheet` in two schemas the tree never opened.
@MainActor
struct DatabaseTreeHierarchicalSearchTests {
    private struct Fixture {
        let scrollView: NSScrollView
        let outlineView: NSOutlineView
        let coordinator: DatabaseTreeOutlineCoordinator
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver
    }

    private func table(_ name: String, _ schema: String) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, schema: schema)
    }

    private func makeFixture(
        searchText: String = "timesheet",
        showsSystem: Bool = false,
        loadsListing: Bool = true
    ) async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "", type: .oracle)
        let driver = MockDatabaseDriver(connection: connection)
        let rows: [String: [TableInfo]] = [
            "app": [table("users", "app")],
            "attendance": [table("timesheet", "attendance"), table("shift", "attendance")],
            "payroll": [table("timesheet", "payroll"), table("salary", "payroll")],
            "CTXSYS": [table("ctx_parameters", "CTXSYS")]
        ]
        driver.schemasToReturn = ["app", "attendance", "payroll", "CTXSYS"]
        driver.schemaTablesToReturn = rows
        driver.allSchemaTablesToReturn = ["app", "attendance", "payroll"].flatMap { rows[$0] ?? [] }
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseSchema = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let scope = try #require(DatabaseManager.shared.browseScope(for: connection.id))
        await SchemaService.shared.load(connectionId: connection.id, driver: driver, connection: connection, scope: scope)
        if loadsListing {
            await DatabaseTreeMetadataService.shared.loadAllSchemaTables(connectionId: connection.id, database: scope.database)
        }

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "HierarchicalSearchColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connection.id
        coordinator.databaseType = .oracle
        coordinator.sidebarState = SharedSidebarState.forConnection(connection.id)
        coordinator.windowState = WindowSidebarState()
        coordinator.activeSchema = "app"
        coordinator.showRecentTables = false
        coordinator.showSystemContainers = showsSystem
        coordinator.searchText = searchText
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(
            scrollView: scrollView, outlineView: outlineView, coordinator: coordinator, connection: connection, driver: driver
        )
    }

    private func tearDown(_ fixture: Fixture) async {
        await DatabaseTreeMetadataService.shared.handleDisconnect(connectionId: fixture.connection.id)
        await SchemaService.shared.invalidate(connectionId: fixture.connection.id)
        DatabaseManager.shared.removeSession(for: fixture.connection.id)
        SharedSidebarState.removeConnection(fixture.connection.id)
        _ = fixture.scrollView
    }

    private func nodes(_ fixture: Fixture) -> [DatabaseTreeNode] {
        (0..<fixture.outlineView.numberOfRows).compactMap { fixture.outlineView.item(atRow: $0) as? DatabaseTreeNode }
    }

    @Test("A search opens the schemas holding a match and draws them from the listing")
    func searchDrawsFromTheListing() async throws {
        let fixture = try await makeFixture()

        let tables = Set(nodes(fixture).compactMap { node -> String? in
            guard case .table(let ref) = node.kind else { return nil }
            return "\(ref.schema ?? "").\(ref.table.name)"
        })
        let loadingRows = nodes(fixture).filter { node in
            guard case .status(.loading) = node.kind else { return false }
            return true
        }
        #expect(tables == ["attendance.timesheet", "payroll.timesheet"])
        #expect(loadingRows.isEmpty)
        await tearDown(fixture)
    }

    @Test("A schema the listing cannot answer for still reads when the search opens it")
    func uncoveredSchemaReads() async throws {
        let fixture = try await makeFixture(searchText: "ctxsys", showsSystem: true)

        try await waitUntil { fixture.driver.fetchSchemaTablesCalls.contains("CTXSYS") }
        await tearDown(fixture)
    }

    @Test("A search naming a schema reads it, since the listing holds its tables alone")
    func namedSchemaReads() async throws {
        let fixture = try await makeFixture(searchText: "payroll.")

        try await waitUntil { fixture.driver.fetchSchemaTablesCalls.contains("payroll") }
        #expect(!fixture.driver.fetchSchemaTablesCalls.contains("attendance"))
        await tearDown(fixture)
    }

    @Test("A search reads no schema before the listing lands, then reads the one it names")
    func namedSchemaWaitsForTheListing() async throws {
        let fixture = try await makeFixture(searchText: "payroll", loadsListing: false)
        let skippedBeforeListing = fixture.coordinator.hierarchicalSearchSkipsRead("payroll")

        let database = try #require(DatabaseManager.shared.browseScope(for: fixture.connection.id)).database
        await DatabaseTreeMetadataService.shared.loadAllSchemaTables(connectionId: fixture.connection.id, database: database)
        fixture.coordinator.refresh()

        #expect(skippedBeforeListing)
        #expect(!fixture.coordinator.hierarchicalSearchSkipsRead("payroll"))
        try await waitUntil { fixture.driver.fetchSchemaTablesCalls.contains("payroll") }
        await tearDown(fixture)
    }

    @Test("A plain search that matches a schema's name reads it")
    func nameMatchReads() async throws {
        let fixture = try await makeFixture(searchText: "payroll")

        try await waitUntil { fixture.driver.fetchSchemaTablesCalls.contains("payroll") }
        await tearDown(fixture)
    }
}
