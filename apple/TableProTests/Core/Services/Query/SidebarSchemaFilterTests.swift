//
//  SidebarSchemaFilterTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
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
    func searchListsKeptSchemasOnly() async throws {
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
        try await waitUntil { service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value != nil }

        let listed = service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value
        #expect(Set(listed?.tables.compactMap(\.schema) ?? []) == ["attendance", "public"])
        #expect(driver.fetchSchemaTablesCalls.sorted() == ["attendance", "public"])
        #expect(driver.fetchSchemasCallCount == 0)
        viewModel.searchText = ""
        await disconnect(connection)
    }

    @Test("A failed listing is asked for once per search, not again on every refinement")
    func failedListingIsAskedForOncePerSearch() async throws {
        let (connection, driver) = connect { driver in
            driver.allSchemaTablesError = DatabaseError.queryFailed("listing timed out")
        }
        let viewModel = SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .pglite,
            connectionId: connection.id
        )

        for query in ["t", "ti", "tim"] {
            viewModel.searchText = query
            try await waitUntil { viewModel.filterQuery == query }
            try await waitUntil {
                if case .failed = service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop") { return true }
                return false
            }
        }
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)

        viewModel.searchText = ""
        try await waitUntil { viewModel.filterQuery.isEmpty }
        viewModel.searchText = "o"
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 2 }
        viewModel.searchText = ""
        await disconnect(connection)
    }

    @Test("Sidebar search and Open Quickly share one listing for one filter, read schema by schema")
    func sidebarAndOpenQuicklyReadOnce() async throws {
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
        try await waitUntil { service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value != nil }
        await switcher.loadItems(databaseType: .pglite)
        switcher.searchText = "timesheet"
        try await waitUntil { !switcher.isLoadingTables }

        #expect(driver.fetchTablesInAllSchemasCallCount == 0)
        #expect(driver.fetchSchemaTablesCalls.filter { $0 == "attendance" }.count == 1)
        #expect(!driver.fetchSchemaTablesCalls.contains("payroll"))
        #expect(service.allSchemaTablesSelection(connectionId: connection.id, database: "shop") == .only(["attendance", "public"]))
        viewModel.searchText = ""
        await disconnect(connection)
    }

    private func makeViewModel(_ connection: DatabaseConnection) -> SidebarViewModel {
        SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .pglite,
            connectionId: connection.id
        )
    }

    // The window's filter field, bound to the connection and holding the keyboard.
    private func focusFilter(of connection: DatabaseConnection) -> (container: SidebarContainerViewController, window: NSWindow) {
        let container = SidebarContainerViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        container.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        window.contentView?.addSubview(container.view)
        container.updateSidebarState(SharedSidebarState.forConnection(connection.id))
        container.focusSearchField()
        return (container, window)
    }

    private func release(_ filter: (container: SidebarContainerViewController, window: NSWindow)) {
        _ = filter.window.makeFirstResponder(nil)
        filter.container.updateSidebarState(nil)
        filter.container.view.removeFromSuperview()
    }

    private func isListingLoading(_ connection: DatabaseConnection) -> Bool {
        if case .loading = service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop") { return true }
        return false
    }

    // Sinks deliver through `RunLoop.main.perform` and answer on the main actor; both have run once this returns.
    private func afterQueuedMainWork() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Focusing the filter reads the listing with nothing typed, and the first keystroke joins that read")
    func focusReadsTheListingBeforeTheFirstKeystroke() async throws {
        let (connection, driver) = connect { driver in
            driver.allSchemaTablesToReturn = [table("users", "public"), table("timesheet", "attendance")]
            driver.pausesNextAllSchemaTablesFetch = true
        }
        let viewModel = makeViewModel(connection)

        let filter = focusFilter(of: connection)
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 }
        #expect(viewModel.filterQuery.isEmpty)

        viewModel.searchText = "time"
        await afterQueuedMainWork()
        #expect(isListingLoading(connection))
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)

        driver.resumeAllSchemaTablesFetch()
        try await waitUntil { service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop").value != nil }
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        #expect(viewModel.schemaListingMatches(database: "shop", searchText: "time")?.matched.contains("attendance") == true)
        viewModel.searchText = ""
        release(filter)
        await disconnect(connection)
    }

    @Test("A listing that failed at focus is asked for again by the next search, not by the first keystroke")
    func failedFocusListingIsNotReadAgainByTheFirstKeystroke() async throws {
        let (connection, driver) = connect { driver in
            driver.allSchemaTablesError = DatabaseError.queryFailed("listing timed out")
        }
        let viewModel = makeViewModel(connection)

        let filter = focusFilter(of: connection)
        try await waitUntil {
            if case .failed = service.allSchemaTablesLoadState(connectionId: connection.id, database: "shop") { return true }
            return false
        }
        viewModel.searchText = "t"
        try await waitUntil { viewModel.filterQuery == "t" }
        await afterQueuedMainWork()
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)

        viewModel.searchText = ""
        try await waitUntil { viewModel.filterQuery.isEmpty }
        viewModel.searchText = "o"
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 2 }
        viewModel.searchText = ""
        release(filter)
        await disconnect(connection)
    }

    @Test("Focusing the filter on Favorites reads no listing")
    func favoritesFocusReadsNoListing() async throws {
        let (connection, driver) = connect { driver in
            driver.allSchemaTablesToReturn = [table("users", "public"), table("timesheet", "attendance")]
        }
        let viewModel = makeViewModel(connection)
        SharedSidebarState.forConnection(connection.id).selectedSidebarTab = .favorites

        let filter = focusFilter(of: connection)
        await afterQueuedMainWork()

        #expect(filter.window.firstResponder is NSText)
        #expect(service.requestedAllSchemaTablesSelection(connectionId: connection.id, database: "shop") == nil)
        #expect(driver.fetchTablesInAllSchemasCallCount == 0)
        #expect(viewModel.filterQuery.isEmpty)
        release(filter)
        await disconnect(connection)
    }
}
