//
//  DatabaseTreeSearchReadsTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// A real outline over the shared tree service, on a PGlite session so every read stays on the
/// injected driver. The search finds `timesheet` in two schemas the tree never opened.
@MainActor
struct DatabaseTreeSearchReadsTests {
    private struct Fixture {
        let scrollView: NSScrollView
        let outlineView: NSOutlineView
        let coordinator: DatabaseTreeOutlineCoordinator
        let windowState: WindowSidebarState
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver
    }

    private let service = DatabaseTreeMetadataService.shared

    private func table(_ name: String, _ schema: String) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, schema: schema)
    }

    private func makeFixture(layout: SidebarLayout) async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        let rows: [String: [TableInfo]] = [
            "public": [table("users", "public")],
            "attendance": [table("timesheet", "attendance"), table("shift", "attendance")],
            "payroll": [table("timesheet", "payroll"), table("salary", "payroll")],
            "timesheets": [table("archive", "timesheets")]
        ]
        driver.databasesToReturn = ["shop"]
        driver.schemasToReturn = ["public", "attendance", "payroll", "timesheets"]
        driver.schemaTablesToReturn = rows
        driver.allSchemaTablesToReturn = ["public", "attendance", "payroll", "timesheets"].flatMap { rows[$0] ?? [] }
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        await service.loadDatabases(connectionId: connection.id, databaseType: .pglite)
        await service.loadSchemas(connectionId: connection.id, database: "shop")
        await service.loadAllSchemaTables(connectionId: connection.id, database: "shop")

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "SearchReadsColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let sidebarState = SharedSidebarState.forConnection(connection.id)
        sidebarState.sidebarLayout = layout
        let windowState = WindowSidebarState()
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connection.id
        coordinator.databaseType = .pglite
        coordinator.sidebarState = sidebarState
        coordinator.windowState = windowState
        coordinator.activeDatabase = "shop"
        coordinator.activeSchema = "public"
        coordinator.showRecentTables = false
        coordinator.searchText = "timesheet"
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(
            scrollView: scrollView,
            outlineView: outlineView,
            coordinator: coordinator,
            windowState: windowState,
            connection: connection,
            driver: driver
        )
    }

    private func tearDown(_ fixture: Fixture) async {
        await service.handleDisconnect(connectionId: fixture.connection.id)
        ExternalSchemaTracker.shared.reset(connectionId: fixture.connection.id)
        DatabaseManager.shared.removeSession(for: fixture.connection.id)
        SharedSidebarState.removeConnection(fixture.connection.id)
        _ = fixture.scrollView
    }

    private func nodes(_ fixture: Fixture) -> [DatabaseTreeNode] {
        (0..<fixture.outlineView.numberOfRows).compactMap { fixture.outlineView.item(atRow: $0) as? DatabaseTreeNode }
    }

    private func tableRows(_ fixture: Fixture) -> Set<String> {
        Set(nodes(fixture).compactMap { node -> String? in
            guard case .table(let ref) = node.kind else { return nil }
            return "\(ref.schema ?? "").\(ref.table.name)"
        })
    }

    private func schemaNode(_ fixture: Fixture, _ schema: String) -> DatabaseTreeNode? {
        nodes(fixture).first { node in
            guard case .schema(_, let name) = node.kind else { return false }
            return name == schema
        }
    }

    private func tableNode(_ fixture: Fixture, _ schema: String, _ name: String) -> DatabaseTreeNode? {
        nodes(fixture).first { node in
            guard case .table(let ref) = node.kind else { return false }
            return ref.schema == schema && ref.table.name == name
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("The flat list shows a match in two unopened schemas without reading either")
    func flatSearchReadsNoSchema() async throws {
        let fixture = try await makeFixture(layout: .flat)

        #expect(tableRows(fixture) == ["attendance.timesheet", "payroll.timesheet"])
        #expect(fixture.driver.fetchSchemaTablesCalls.isEmpty)
        await tearDown(fixture)
    }

    @Test("The tree opens the schemas holding a match and draws them from the listing")
    func treeSearchReadsNoSchema() async throws {
        let fixture = try await makeFixture(layout: .tree)

        #expect(tableRows(fixture) == ["attendance.timesheet", "payroll.timesheet"])
        let attendance = try #require(schemaNode(fixture, "attendance"))
        #expect(fixture.outlineView.isItemExpanded(attendance))
        #expect(fixture.driver.fetchSchemaTablesCalls.isEmpty)
        await tearDown(fixture)
    }

    @Test("A schema that matched by its own name alone stays closed")
    func nameOnlyMatchStaysClosed() async throws {
        let fixture = try await makeFixture(layout: .tree)

        let timesheets = try #require(schemaNode(fixture, "timesheets"))
        #expect(!fixture.outlineView.isItemExpanded(timesheets))
        #expect(fixture.driver.fetchSchemaTablesCalls.isEmpty)
        await tearDown(fixture)
    }

    @Test("A schema opened by hand during a search is read, once")
    func handExpansionReadsOnce() async throws {
        let fixture = try await makeFixture(layout: .tree)
        let timesheets = try #require(schemaNode(fixture, "timesheets"))

        fixture.outlineView.expandItem(timesheets)
        await waitUntil {
            service.tablesLoadState(connectionId: fixture.connection.id, database: "shop", schema: "timesheets").value != nil
        }
        fixture.coordinator.refresh()
        fixture.coordinator.refresh()

        #expect(fixture.driver.fetchSchemaTablesCalls == ["timesheets"])
        #expect(fixture.outlineView.isItemExpanded(timesheets))
        await tearDown(fixture)
    }

    @Test("During a search a stale schema the user has open reads again, one the search opened does not")
    func staleUserOpenedSchemaReadsDuringSearch() async throws {
        let fixture = try await makeFixture(layout: .tree)
        let connectionId = fixture.connection.id
        fixture.windowState.expandedTreeDatabaseSchemas.insert(DatabaseSchemaKey(database: "shop", schema: "attendance"))
        await service.loadObjects(connectionId: connectionId, database: "shop", schema: "attendance")
        await service.loadObjects(connectionId: connectionId, database: "shop", schema: "payroll")
        let readsBefore = fixture.driver.fetchSchemaTablesCalls.count

        service.markListsStale(connectionId: connectionId)
        fixture.coordinator.refresh()
        await waitUntil { service.isTablesCurrent(connectionId: connectionId, database: "shop", schema: "attendance") }

        #expect(Array(fixture.driver.fetchSchemaTablesCalls.dropFirst(readsBefore)) == ["attendance"])
        #expect(!service.isTablesCurrent(connectionId: connectionId, database: "shop", schema: "payroll"))
        await tearDown(fixture)
    }

    @Test("A schema the search opened hides a routine list a change overtook, and reads nothing")
    func searchOpenedSchemaHidesOvertakenRoutines() async throws {
        let fixture = try await makeFixture(layout: .tree)
        let connectionId = fixture.connection.id
        fixture.driver.schemaRoutinesToReturn = ["payroll": [RoutineInfo(name: "timesheet_total", kind: .function, schema: "payroll")]]
        await service.loadObjects(connectionId: connectionId, database: "shop", schema: "payroll")
        fixture.coordinator.refresh()
        #expect(routineNames(fixture).contains("timesheet_total"))
        let readsBefore = fixture.driver.fetchSchemaTablesCalls.count

        service.markListsStale(connectionId: connectionId)
        fixture.coordinator.refresh()

        #expect(!routineNames(fixture).contains("timesheet_total"))
        #expect(fixture.driver.fetchSchemaTablesCalls.count == readsBefore)
        await tearDown(fixture)
    }

    private func routineNames(_ fixture: Fixture) -> Set<String> {
        for node in nodes(fixture) where !fixture.outlineView.isItemExpanded(node) {
            guard case .containerObjectKindSection = node.kind else { continue }
            fixture.outlineView.expandItem(node)
        }
        return Set(nodes(fixture).compactMap { node -> String? in
            guard case .routine(let ref) = node.kind else { return nil }
            return ref.routine.name
        })
    }

    @Test("A row drawn from the listing is the row the schema's own read keeps, still selected")
    func listingRowSurvivesTheLoad() async throws {
        let fixture = try await makeFixture(layout: .tree)
        let listed = try #require(tableNode(fixture, "attendance", "timesheet"))
        let ref = try #require(listed.tableRef)
        fixture.windowState.selectedTables = [ref]
        fixture.coordinator.syncSelectionToModel()
        #expect(fixture.outlineView.selectedRowIndexes == IndexSet([fixture.outlineView.row(forItem: listed)]))

        await service.loadTables(connectionId: fixture.connection.id, database: "shop", schema: "attendance")
        fixture.coordinator.refresh()

        let loaded = try #require(tableNode(fixture, "attendance", "timesheet"))
        #expect(loaded === listed)
        #expect(fixture.outlineView.selectedRowIndexes == IndexSet([fixture.outlineView.row(forItem: loaded)]))
        #expect(fixture.driver.fetchSchemaTablesCalls == ["attendance"])
        await tearDown(fixture)
    }
}
