//
//  SidebarSchemaFilterTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

/// PGlite keeps every read on the injected session driver and groups by schema.
@MainActor
struct SidebarSchemaFilterTests {
    private let service = DatabaseTreeMetadataService.shared

    private func connect(_ configure: (MockDatabaseDriver) -> Void = { _ in }) -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(database: "shop", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        configure(driver)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await service.handleDisconnect(connectionId: connection.id)
        await SchemaService.shared.invalidate(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
        SharedSidebarState.removeConnection(connection.id)
        DatabaseTreeFilterStorage.shared.removeFilter(for: connection.id)
    }

    private func table(_ name: String, _ schema: String) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, schema: schema)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("The kept set adds the browsed schema for the browsed database only")
    func browsedSchemaJoinsTheBrowsedDatabase() async {
        let (connection, _) = connect()
        let state = SharedSidebarState.forConnection(connection.id)
        state.setSchemaFilter(["sales"], for: "shop")
        state.setSchemaFilter(["posts"], for: "blog")

        let filter = SidebarSchemaFilter()
        #expect(filter.keptSchemas(connectionId: connection.id, database: "shop") == ["sales", "public"])
        #expect(filter.keptSchemas(connectionId: connection.id, database: "blog") == ["posts"])
        #expect(filter.keptSchemas(connectionId: connection.id, database: "archive") == nil)
        #expect(filter.selection(connectionId: connection.id, database: "shop") == .only(["sales", "public"]))
        #expect(filter.selection(connectionId: connection.id, database: "archive") == .all)
        await disconnect(connection)
    }

    @Test("A connection with no session has no filter to apply")
    func noSessionNoFilter() {
        let connectionId = UUID()
        SharedSidebarState.forConnection(connectionId).setSchemaFilter(["sales"], for: "shop")
        defer {
            SharedSidebarState.removeConnection(connectionId)
            DatabaseTreeFilterStorage.shared.removeFilter(for: connectionId)
        }

        #expect(SidebarSchemaFilter().keptSchemas(connectionId: connectionId, database: "shop") == nil)
    }

    @Test("A schema the database no longer lists is set aside")
    func droppedSchemaIsSetAside() async {
        let (connection, _) = connect { $0.schemasToReturn = ["public", "sales"] }
        await service.loadSchemas(connectionId: connection.id, database: "shop")
        SharedSidebarState.forConnection(connection.id).setSchemaFilter(["sales", "dropped"], for: "shop")

        #expect(SidebarSchemaFilter().keptSchemas(connectionId: connection.id, database: "shop") == ["sales", "public"])
        await disconnect(connection)
    }

    @Test("A sidebar search with a schema filter lists the kept schemas alone")
    func searchListsKeptSchemasOnly() async {
        let (connection, driver) = connect { driver in
            driver.schemaTablesToReturn = [
                "public": [table("timesheet", "public")],
                "attendance": [table("timesheet", "attendance")],
                "payroll": [table("timesheet", "payroll")]
            ]
        }
        SharedSidebarState.forConnection(connection.id).setSchemaFilter(["attendance"], for: "shop")
        let viewModel = SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .pglite,
            connectionId: connection.id
        )

        viewModel.searchText = "timesheet"
        await waitUntil { service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value != nil }

        let listed = service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value
        #expect(Set(listed?.tables.compactMap(\.schema) ?? []) == ["attendance", "public"])
        #expect(driver.fetchSchemaTablesCalls.sorted() == ["attendance", "public"])
        #expect(driver.fetchSchemasCallCount == 0)
        viewModel.searchText = ""
        await disconnect(connection)
    }

    @Test("Sidebar search and Open Quickly share one listing for one filter, read schema by schema")
    func sidebarAndOpenQuicklyReadOnce() async {
        let (connection, driver) = connect { driver in
            driver.allSchemaTablesToReturn = [
                table("timesheet", "public"), table("timesheet", "attendance"), table("timesheet", "payroll")
            ]
            driver.schemaTablesToReturn = [
                "public": [table("timesheet", "public")],
                "attendance": [table("timesheet", "attendance")],
                "payroll": [table("timesheet", "payroll")]
            ]
        }
        SharedSidebarState.forConnection(connection.id).setSchemaFilter(["attendance"], for: "shop")
        let viewModel = SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .pglite,
            connectionId: connection.id
        )
        let switcher = QuickSwitcherViewModel(connectionId: connection.id, services: .live)

        viewModel.searchText = "timesheet"
        await waitUntil { service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value != nil }
        await switcher.loadItems(databaseType: .pglite)
        switcher.searchText = "timesheet"
        await waitUntil { !switcher.isLoadingTables }

        #expect(driver.fetchTablesInAllSchemasCallCount == 0)
        #expect(driver.fetchSchemaTablesCalls.filter { $0 == "attendance" }.count == 1)
        #expect(!driver.fetchSchemaTablesCalls.contains("payroll"))
        #expect(service.allSchemaTablesSelection(connectionId: connection.id, database: "shop") == .only(["attendance", "public"]))
        viewModel.searchText = ""
        await disconnect(connection)
    }
}
