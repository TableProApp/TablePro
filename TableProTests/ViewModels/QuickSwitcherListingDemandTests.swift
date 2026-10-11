//
//  QuickSwitcherListingDemandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QuickSwitcherListingDemandTests {
    // MARK: - Pure rules

    @Test("All asks for the listing on a query or for Recent, Tables always, the rest never")
    func wantsListingPerScope() {
        let wants: (QuickSwitcherScope, String, Bool) -> Bool = { scope, query, recent in
            QuickSwitcherViewModel.wantsAllSchemaListing(scope: scope, query: query, recentNeedsListing: { recent })
        }

        #expect(!wants(.all, "", false))
        #expect(wants(.all, "", true))
        #expect(wants(.all, "ord", false))
        #expect(wants(.tables, "", false))
        #expect(!wants(.containers, "ord", true))
        #expect(!wants(.queries, "ord", true))
        #expect(!wants(.connections, "ord", true))
    }

    private let qualifier = QuickSwitcherFrecencyKey.DatabaseQualifier(database: nil, connectionSwitchesDatabases: false)

    private func tableKey(_ name: String, _ schema: String) -> String {
        QuickSwitcherFrecencyKey.table(name: name, schema: schema, in: qualifier)
    }

    private func needsListing(recent: [String], resolved: Set<String>, limit: Int = 10) -> Bool {
        QuickSwitcherViewModel.recentNeedsListing(
            recentKeys: recent,
            resolvedKeys: resolved,
            isTableKey: { QuickSwitcherFrecencyKey.isTable($0, in: qualifier) },
            limit: limit
        )
    }

    @Test("Recent needs the listing for a table it cannot resolve yet")
    func unresolvedTableNeedsListing() {
        let resolved = tableKey("users", "public")
        let unresolved = tableKey("timesheet", "attendance")

        #expect(needsListing(recent: [resolved, unresolved], resolved: [resolved]))
    }

    @Test("A saved query Recent cannot resolve is no reason to read tables")
    func unresolvedSavedQueryNeedsNothing() {
        #expect(!needsListing(recent: [QuickSwitcherFrecencyKey.savedQuery(UUID())], resolved: []))
    }

    @Test("A Recent section already full asks for nothing further down")
    func fullRecentNeedsNothing() {
        let resolved = (0..<10).map { tableKey("t\($0)", "public") }
        let recent = resolved + [tableKey("timesheet", "attendance")]

        #expect(!needsListing(recent: recent, resolved: Set(resolved)))
    }

    @Test("A table key is recognized with and without a database qualifier")
    func tableKeyRecognition() {
        let qualified = QuickSwitcherFrecencyKey.DatabaseQualifier(database: "shop", connectionSwitchesDatabases: true)
        let inShop = QuickSwitcherFrecencyKey.table(name: "orders", schema: "public", in: qualified)

        #expect(QuickSwitcherFrecencyKey.isTable(inShop, in: qualified))
        #expect(!QuickSwitcherFrecencyKey.isTable(inShop, in: qualifier))
        #expect(QuickSwitcherFrecencyKey.isTable(tableKey("orders", "public"), in: qualifier))
        #expect(!QuickSwitcherFrecencyKey.isTable(QuickSwitcherFrecencyKey.schema("public", in: qualifier), in: qualifier))
    }

    // MARK: - Reads

    private func connect() -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(database: "shop", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users", schema: "public")]
        driver.allSchemaTablesToReturn = [
            TestFixtures.makeTableInfo(name: "users", schema: "public"),
            TestFixtures.makeTableInfo(name: "timesheet", schema: "attendance")
        ]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await DatabaseTreeMetadataService.shared.handleDisconnect(connectionId: connection.id)
        await SchemaService.shared.invalidate(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
        SharedSidebarState.removeConnection(connection.id)
    }

    private func makeSwitcher(_ connection: DatabaseConnection) -> QuickSwitcherViewModel {
        let defaults = UserDefaults(suiteName: "QuickSwitcherListingDemandTests.\(UUID().uuidString)") ?? .standard
        return QuickSwitcherViewModel(
            connectionId: connection.id,
            services: .live,
            defaults: defaults,
            catalogStore: QuickSwitcherCatalogStore()
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("Opening with nothing typed reads no other schema, and the first keystroke reads them once")
    func listingWaitsForTheFirstKeystroke() async {
        let (connection, driver) = connect()
        let switcher = makeSwitcher(connection)

        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(driver.fetchTablesInAllSchemasCallCount == 0)
        #expect(!switcher.isLoadingTables)

        switcher.searchText = "time"
        #expect(switcher.isLoadingTables)
        await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 && !switcher.isLoadingTables }
        switcher.searchText = "times"

        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        #expect(!switcher.isLoadingTables)
        await disconnect(connection)
    }

    @Test("The Tables scope lists every schema's tables, so it reads them on open")
    func tablesScopeReadsOnOpen() async {
        let (connection, driver) = connect()
        let switcher = makeSwitcher(connection)
        switcher.scope = .tables

        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 && !switcher.isLoadingTables }

        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        await disconnect(connection)
    }
}
