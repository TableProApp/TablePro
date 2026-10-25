import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct QuickSwitcherListingDemandTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

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
            isResolved: resolved.contains,
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
        QuickSwitcherViewModel(
            connectionId: connection.id,
            services: .live,
            defaults: suite.defaults,
            catalogStore: QuickSwitcherCatalogStore()
        )
    }

    @Test("Opening with nothing typed reads no other schema, and the first keystroke reads them once")
    func listingWaitsForTheFirstKeystroke() async throws {
        let (connection, driver) = connect()
        let switcher = makeSwitcher(connection)

        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        // A listing sets isLoadingTables before its task runs, so after the barrier one is either still flagged or counted.
        await switcher.flushPendingFilter()
        #expect(driver.fetchTablesInAllSchemasCallCount == 0)
        #expect(!switcher.isLoadingTables)

        switcher.searchText = "time"
        #expect(switcher.isLoadingTables)
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 && !switcher.isLoadingTables }
        switcher.searchText = "times"

        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        #expect(!switcher.isLoadingTables)
        await disconnect(connection)
    }

    @Test("A listing another reader started counts as loading, so a search waits for it instead of reporting a miss")
    func listingAnotherReaderStartedCountsAsLoading() async throws {
        let (connection, driver) = connect()
        let switcher = makeSwitcher(connection)
        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        await switcher.flushPendingFilter()

        driver.pausesNextAllSchemaTablesFetch = true
        var sidebarDemand = AllSchemaTablesDemand()
        sidebarDemand.requestIfNeeded(
            connectionId: connection.id,
            database: "shop",
            selection: SidebarSchemaFilter().selection(connectionId: connection.id, database: "shop"),
            isConnected: true,
            service: .shared
        )
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 }
        switcher.searchText = "time"

        try await waitUntil { switcher.isLoadingTables }
        driver.resumeAllSchemaTablesFetch()
        try await waitUntil { !switcher.isLoadingTables }
        await switcher.flushPendingFilter()
        #expect(switcher.flatItems.contains { $0.name == "timesheet" })
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        await disconnect(connection)
    }

    @Test("The Tables scope lists every schema's tables, so it reads them on open")
    func tablesScopeReadsOnOpen() async throws {
        let (connection, driver) = connect()
        let switcher = makeSwitcher(connection)
        switcher.scope = .tables

        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 && !switcher.isLoadingTables }

        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        await disconnect(connection)
    }

    @Test("The next Open Quickly finds a current listing and neither reads it again nor rebuilds its rows")
    func currentListingIsNotAskedForOnReopen() async throws {
        let (connection, driver) = connect()
        let first = makeSwitcher(connection)
        await first.loadItems(databaseType: .pglite, browseSchema: "public")
        first.searchText = "time"
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 && !first.isLoadingTables }

        let second = makeSwitcher(connection)
        await second.loadItems(databaseType: .pglite, browseSchema: "public")
        await afterQueuedMainWork()
        let opened = second.tableItemsBuildCount
        second.searchText = "time"

        #expect(!second.isLoadingTables)
        await second.flushPendingFilter()
        await afterQueuedMainWork()
        #expect(second.tableItemsBuildCount == opened)
        #expect(second.flatItems.contains { $0.name == "timesheet" })
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        await disconnect(connection)
    }

    // MARK: - Table rows

    // Sinks deliver through `RunLoop.main.perform` and answer on the main actor; both have run once this returns.
    private func afterQueuedMainWork() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Reopening over a loaded catalog builds the table rows once")
    func reopenBuildsRowsOnce() async {
        let (connection, _) = connect()
        await makeSwitcher(connection).loadItems(databaseType: .pglite, browseSchema: "public")
        let switcher = makeSwitcher(connection)

        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        await afterQueuedMainWork()

        #expect(switcher.tableItemsBuildCount == 1)
        #expect(switcher.allItems.contains { $0.name == "users" })
        await disconnect(connection)
    }

    @Test("The listing landing rebuilds the table rows once")
    func listingLandingRebuildsOnce() async throws {
        let (connection, driver) = connect()
        let switcher = makeSwitcher(connection)
        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        await afterQueuedMainWork()
        let opened = switcher.tableItemsBuildCount

        switcher.searchText = "time"
        try await waitUntil { driver.fetchTablesInAllSchemasCallCount == 1 && !switcher.isLoadingTables }
        await afterQueuedMainWork()

        #expect(switcher.tableItemsBuildCount == opened + 1)
        #expect(switcher.allItems.contains { $0.name == "timesheet" })
        await disconnect(connection)
    }

    @Test("A change on another connection rebuilds none of this connection's rows")
    func otherConnectionChangeRebuildsNothing() async {
        let (connection, _) = connect()
        let switcher = makeSwitcher(connection)
        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        await afterQueuedMainWork()
        let opened = switcher.tableItemsBuildCount
        let elsewhere = UUID()

        DatabaseTreeMetadataService.shared.markAllSchemaTablesChanged([
            DatabaseTreeMetadataService.DatabaseKey(connectionId: elsewhere, database: "shop")
        ])
        SchemaService.shared.forget(database: "shop", connectionId: elsewhere)
        await afterQueuedMainWork()

        #expect(switcher.tableItemsBuildCount == opened)
        await SchemaService.shared.invalidate(connectionId: elsewhere)
        await DatabaseTreeMetadataService.shared.handleDisconnect(connectionId: elsewhere)
        await disconnect(connection)
    }

    @Test("A burst of changes to this connection in one turn rebuilds the rows once")
    func burstRebuildsOnce() async {
        let (connection, _) = connect()
        let switcher = makeSwitcher(connection)
        await switcher.loadItems(databaseType: .pglite, browseSchema: "public")
        await afterQueuedMainWork()
        let opened = switcher.tableItemsBuildCount

        SchemaService.shared.forget(database: "archive", connectionId: connection.id)
        DatabaseTreeMetadataService.shared.markAllSchemaTablesChanged([
            DatabaseTreeMetadataService.DatabaseKey(connectionId: connection.id, database: "shop")
        ])
        SchemaService.shared.forget(database: "archive", connectionId: connection.id)
        await afterQueuedMainWork()

        #expect(switcher.tableItemsBuildCount == opened + 1)
        #expect(switcher.allItems.contains { $0.name == "users" })
        await disconnect(connection)
    }
}
