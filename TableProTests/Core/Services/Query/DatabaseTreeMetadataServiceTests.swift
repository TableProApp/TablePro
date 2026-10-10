import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DatabaseTreeMetadataServiceTests {
    private typealias ObjectsKey = DatabaseTreeMetadataService.ObjectsKey

    @Test("connectionObjectKeys unions table and routine keys for the connection")
    func unionsTableAndRoutineKeys() {
        let connectionId = UUID()
        let tableOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "public")
        let routineOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "billing")
        let shared = ObjectsKey(connectionId: connectionId, database: "shop", schema: nil)

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [tableOnly, shared],
            routineKeys: [routineOnly, shared],
            triggerKeys: [ObjectsKey](),
            connectionId: connectionId
        )

        #expect(Set(keys) == [tableOnly, routineOnly, shared])
    }

    @Test("connectionObjectKeys includes a type key with no matching table, routine or trigger key")
    func includesOrphanTypeKey() {
        let connectionId = UUID()
        let typeOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "public")
        let otherConnection = ObjectsKey(connectionId: UUID(), database: "shop", schema: "public")

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [ObjectsKey](),
            routineKeys: [ObjectsKey](),
            triggerKeys: [ObjectsKey](),
            typeKeys: [typeOnly, otherConnection],
            connectionId: connectionId
        )

        #expect(keys == [typeOnly])
    }

    @Test("connectionObjectKeys includes a routine key with no matching table key")
    func includesOrphanRoutineKey() {
        let connectionId = UUID()
        let routineOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "public")

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [ObjectsKey](),
            routineKeys: [routineOnly],
            triggerKeys: [ObjectsKey](),
            connectionId: connectionId
        )

        #expect(keys == [routineOnly])
    }

    /// A trigger key with no table or routine key beside it is still this connection's, and the
    /// teardown that walks these keys has to reach it or its state outlives the connection.
    @Test("connectionObjectKeys includes a trigger key with no matching table or routine key")
    func includesOrphanTriggerKey() {
        let connectionId = UUID()
        let triggerOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "audit")

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [ObjectsKey](),
            routineKeys: [ObjectsKey](),
            triggerKeys: [triggerOnly],
            connectionId: connectionId
        )

        #expect(keys == [triggerOnly])
    }

    @Test("connectionObjectKeys excludes keys from other connections")
    func excludesOtherConnections() {
        let connectionId = UUID()
        let other = UUID()
        let mine = ObjectsKey(connectionId: connectionId, database: "shop", schema: nil)
        let theirs = ObjectsKey(connectionId: other, database: "shop", schema: nil)

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [mine, theirs],
            routineKeys: [theirs],
            triggerKeys: [ObjectsKey](),
            connectionId: connectionId
        )

        #expect(keys == [mine])
    }
}

/// Uses PGlite because it is the one engine that cannot open a pooled connection, so a
/// metadata read stays on the injected session driver instead of trying to dial a real
/// server. Every other engine now reaches the tree through the pool.
@MainActor
struct DatabaseTreeMetadataServiceRefreshTests {
    private let service = DatabaseTreeMetadataService.shared

    private func connect(_ tables: [String: [TableInfo]]) -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.schemaTablesToReturn = tables
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func tableNames(_ connection: DatabaseConnection, _ schema: String) -> [String] {
        service.tables(connectionId: connection.id, database: connection.database, schema: schema).map(\.name)
    }

    @Test("Marking stale keeps the rows, and the next load reads them again")
    func markingStaleKeepsRowsUntilTheNextLoad() async {
        let (connection, driver) = connect(["public": [TestFixtures.makeTableInfo(name: "users")]])
        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "public")

        driver.schemaTablesToReturn = ["public": []]
        service.markListsStale(connectionId: connection.id)

        #expect(tableNames(connection, "public") == ["users"])
        #expect(service.tablesNeedFetch(connectionId: connection.id, database: connection.database, schema: "public"))

        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "public")

        #expect(tableNames(connection, "public").isEmpty)
        await disconnect(connection)
    }

    @Test("Marking stale reads nothing, and each schema is read again alone when asked")
    func markingStaleReadsEachSchemaAloneWhenAsked() async {
        let (connection, driver) = connect([
            "public": [TestFixtures.makeTableInfo(name: "users")],
            "sales": [TestFixtures.makeTableInfo(name: "orders")]
        ])
        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "public")
        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "sales")
        #expect(driver.fetchSchemaTablesCalls == ["public", "sales"])

        driver.schemaTablesToReturn = [
            "public": [],
            "sales": [TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "invoices")]
        ]
        service.markListsStale(connectionId: connection.id)
        #expect(driver.fetchSchemaTablesCalls == ["public", "sales"])

        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "sales")

        #expect(driver.fetchSchemaTablesCalls == ["public", "sales", "sales"])
        #expect(tableNames(connection, "sales") == ["orders", "invoices"])
        #expect(tableNames(connection, "public") == ["users"])
        #expect(service.tablesNeedFetch(connectionId: connection.id, database: connection.database, schema: "public"))
        await disconnect(connection)
    }

    @Test("Marking a connection with nothing loaded publishes nothing")
    func markingWithNothingLoadedPublishesNothing() {
        let connection = TestFixtures.makeConnection()

        service.markListsStale(connectionId: connection.id)

        #expect(service.listsRevision(for: connection.id) == 0)
        #expect(tableNames(connection, "public").isEmpty)
    }
}

/// A list a change overtakes keeps its rows and is read again only by the next reader that asks,
/// once per change. The counting driver records every catalog read the tree sends.
@MainActor
struct DatabaseTreeListFreshnessTests {
    private struct ReadFailed: Error {}

    private let service = DatabaseTreeMetadataService.shared

    private func connect(schemas: [String]) -> (DatabaseConnection, CatalogReadCountingDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = CatalogReadCountingDriver(connection: connection)
        driver.schemasToReturn = schemas
        for schema in schemas {
            driver.tablesBySchema[schema] = [TableInfo(name: "\(schema)_orders", type: .table, rowCount: nil, schema: schema)]
        }
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func loadTree(_ connection: DatabaseConnection, schemas: [String]) async {
        await service.loadSchemas(connectionId: connection.id, database: connection.database)
        for schema in schemas {
            await service.loadObjects(connectionId: connection.id, database: connection.database, schema: schema)
        }
    }

    private func commit(_ connection: DatabaseConnection, kinds: CatalogObjectKinds = [.objects, .schemas]) async {
        await service.refreshCatalog(for: CatalogChange(connectionId: connection.id, kinds: kinds))
    }

    private func tableNames(_ connection: DatabaseConnection, _ schema: String) -> [String] {
        service.tables(connectionId: connection.id, database: connection.database, schema: schema).map(\.name)
    }

    private func loadTables(_ connection: DatabaseConnection, _ schema: String) async {
        await service.loadTables(connectionId: connection.id, database: connection.database, schema: schema)
    }

    @Test("A COMMIT with 50 loaded schemas reads nothing and keeps every row")
    func commitReadsNothing() async {
        let schemas = (0..<50).map { "s\($0)" }
        let (connection, driver) = connect(schemas: schemas)
        await loadTree(connection, schemas: schemas)
        #expect(!driver.reads(ofSchema: "s49").isEmpty)
        driver.forgetReads()

        await commit(connection)

        #expect(driver.reads.isEmpty)
        #expect(service.listsRevision(for: connection.id) == 1)
        #expect(tableNames(connection, "s0") == ["s0_orders"])
        #expect(service.objectsNeedFetch(connectionId: connection.id, database: connection.database, schema: "s7"))
        #expect(service.schemaListNeedsFetch(connectionId: connection.id, database: connection.database))
        await disconnect(connection)
    }

    @Test("Asking for one stale schema reads that schema alone")
    func staleSchemaIsReadAlone() async {
        let schemas = (0..<10).map { "s\($0)" }
        let (connection, driver) = connect(schemas: schemas)
        await loadTree(connection, schemas: schemas)
        await commit(connection)
        driver.forgetReads()

        await service.loadObjects(connectionId: connection.id, database: connection.database, schema: "s7")

        #expect(driver.reads.contains("tables:s7"))
        #expect(driver.reads.allSatisfy { $0.hasSuffix(":s7") })
        #expect(!service.objectsNeedFetch(connectionId: connection.id, database: connection.database, schema: "s7"))
        #expect(service.objectsNeedFetch(connectionId: connection.id, database: connection.database, schema: "s8"))
        await disconnect(connection)
    }

    @Test("A change to one kind reads that kind alone when the container asks")
    func changeToOneKindReadsThatKindAlone() async {
        let (connection, driver) = connect(schemas: ["s0"])
        await loadTree(connection, schemas: ["s0"])
        await commit(connection, kinds: .routines)
        driver.forgetReads()

        await service.loadObjects(connectionId: connection.id, database: connection.database, schema: "s0")

        #expect(driver.reads == ["routines:s0"])
        await disconnect(connection)
    }

    @Test("A failed refetch keeps the rows and waits for the next change")
    func failedRefetchWaitsForTheNextChange() async {
        let (connection, driver) = connect(schemas: ["s0"])
        await loadTables(connection, "s0")
        await commit(connection, kinds: .tables)

        driver.tablesError = ReadFailed()
        await loadTables(connection, "s0")

        #expect(tableNames(connection, "s0") == ["s0_orders"])
        if case .loaded = service.tablesLoadState(connectionId: connection.id, database: connection.database, schema: "s0") {
        } else {
            Issue.record("A failed refetch must leave the rows loaded")
        }
        #expect(!service.tablesNeedFetch(connectionId: connection.id, database: connection.database, schema: "s0"))

        await commit(connection, kinds: .tables)
        #expect(service.tablesNeedFetch(connectionId: connection.id, database: connection.database, schema: "s0"))
        await disconnect(connection)
    }

    @Test("A read that began before a change delivers its rows but stays stale")
    func readOvertakenByChangeStaysStale() async {
        let (connection, driver) = connect(schemas: ["s0"])
        driver.pausesNextTableFetch = true
        var first: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            driver.onTableFetchPaused = { paused.resume() }
            first = Task { await loadTables(connection, "s0") }
        }
        await commit(connection, kinds: .tables)
        driver.resumeTableFetch()
        await first?.value

        #expect(tableNames(connection, "s0") == ["s0_orders"])
        #expect(service.tablesNeedFetch(connectionId: connection.id, database: connection.database, schema: "s0"))

        driver.forgetReads()
        await loadTables(connection, "s0")
        #expect(driver.reads == ["tables:s0"])
        #expect(service.isTablesCurrent(connectionId: connection.id, database: connection.database, schema: "s0"))
        await disconnect(connection)
    }

    @Test("Two readers asking for one stale list read it once")
    func twoReadersReadOnce() async {
        let (connection, driver) = connect(schemas: ["s0"])
        await loadTables(connection, "s0")
        await commit(connection, kinds: .tables)
        driver.forgetReads()

        async let first: Void = loadTables(connection, "s0")
        async let second: Void = loadTables(connection, "s0")
        _ = await (first, second)

        #expect(driver.reads == ["tables:s0"])
        await disconnect(connection)
    }

    @Test("A reconnect marks every list stale and keeps its rows")
    func reconnectMarksEveryListStale() async {
        let (connection, driver) = connect(schemas: ["s0"])
        await loadTree(connection, schemas: ["s0"])
        driver.forgetReads()

        await service.handleReconnect(connectionId: connection.id)

        #expect(driver.reads.isEmpty)
        #expect(tableNames(connection, "s0") == ["s0_orders"])
        #expect(service.schemas(connectionId: connection.id, database: connection.database) == ["s0"])
        #expect(service.objectsNeedFetch(connectionId: connection.id, database: connection.database, schema: "s0"))
        #expect(service.schemaListNeedsFetch(connectionId: connection.id, database: connection.database))
        await disconnect(connection)
    }

    @Test("A table change marks a partition list, and asking reads it once")
    func tableChangeMarksPartitions() async {
        let (connection, driver) = connect(schemas: ["s0"])
        driver.partitionsByTable["events"] = [PartitionInfo(name: "events_2026", schema: "s0", relationType: .table)]
        let database = connection.database
        await service.loadPartitions(connectionId: connection.id, database: database, schema: "s0", table: "events")
        driver.forgetReads()

        await commit(connection, kinds: .tables)
        #expect(driver.reads.isEmpty)
        #expect(service.partitionsNeedFetch(connectionId: connection.id, database: database, schema: "s0", table: "events"))

        await service.loadPartitions(connectionId: connection.id, database: database, schema: "s0", table: "events")
        await service.loadPartitions(connectionId: connection.id, database: database, schema: "s0", table: "events")

        #expect(driver.reads == ["partitions:events"])
        #expect(!service.partitionsNeedFetch(connectionId: connection.id, database: database, schema: "s0", table: "events"))
        await disconnect(connection)
    }

    @Test("A database change still reads the database list at once")
    func databaseChangeReadsTheDatabaseList() async {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.databasesToReturn = ["sales"]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        await service.loadDatabases(connectionId: connection.id, databaseType: connection.type)

        driver.databasesToReturn = ["sales", "analytics"]
        await service.refreshCatalog(for: CatalogChange(connectionId: connection.id, kinds: .databases))

        #expect(service.databases(for: connection.id).map(\.name) == ["analytics", "sales"])
        await disconnect(connection)
    }

    @Test("Nothing needs a read while the session is not connected")
    func predicatesAreFalseWhileDisconnected() async {
        let (connection, _) = connect(schemas: ["s0"])
        await loadTree(connection, schemas: ["s0"])
        await commit(connection)
        #expect(service.objectsNeedFetch(connectionId: connection.id, database: connection.database, schema: "s0"))

        var session = ConnectionSession(connection: connection, driver: CatalogReadCountingDriver(connection: connection))
        session.status = .connecting
        DatabaseManager.shared.injectSession(session, for: connection.id)

        #expect(!service.objectsNeedFetch(connectionId: connection.id, database: connection.database, schema: "s0"))
        #expect(!service.schemaListNeedsFetch(connectionId: connection.id, database: connection.database))
        #expect(!service.isTablesCurrent(connectionId: connection.id, database: connection.database, schema: "s0"))
        await disconnect(connection)
    }
}

/// A refresh must never empty the list it is refreshing: the tree renders `.loading`
/// with no content as a spinner, so clearing first blanks the sidebar mid-refresh.
@MainActor
struct DatabaseTreeMetadataServiceRefreshDatabasesTests {
    @Test("A refresh commits the new list over the old one")
    func refreshCommitsNewList() async {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.databasesToReturn = ["sales", "analytics"]

        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let service = DatabaseTreeMetadataService.shared

        await service.loadDatabases(connectionId: connection.id, databaseType: connection.type)
        #expect(service.databases(for: connection.id).map(\.name) == ["analytics", "sales"])

        driver.databasesToReturn = ["sales"]
        await service.refreshDatabases(connectionId: connection.id, databaseType: connection.type)

        #expect(service.databases(for: connection.id).map(\.name) == ["sales"])

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("A failed refresh keeps the databases already on screen")
    func failedRefreshKeepsPreviousList() async {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.databasesToReturn = ["sales", "analytics"]

        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let service = DatabaseTreeMetadataService.shared

        await service.loadDatabases(connectionId: connection.id, databaseType: connection.type)
        driver.fetchDatabasesError = DatabaseError.notConnected
        await service.refreshDatabases(connectionId: connection.id, databaseType: connection.type)

        #expect(service.databases(for: connection.id).map(\.name) == ["analytics", "sales"])
        if case .loaded = service.databaseListState(for: connection.id) {} else {
            Issue.record("A failed refresh must leave the list loaded, not failed or loading")
        }

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }
}

/// The sidebar's own Refresh, reached from the database and schema contextual menus. It has to
/// obey the same rule `refreshDatabases` does: the tree renders a container with no loaded
/// content as a single spinner row, so clearing first empties the subtree mid-refresh.
@MainActor
struct DatabaseTreeMetadataServiceRefreshObjectsTests {
    private func connectedDriver() -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    @Test("A refresh commits the new tables over the old ones")
    func refreshCommitsNewTables() async {
        let (connection, driver) = connectedDriver()
        driver.schemaTablesToReturn = ["public": [TestFixtures.makeTableInfo(name: "users")]]
        let service = DatabaseTreeMetadataService.shared

        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "public")

        driver.schemaTablesToReturn = [
            "public": [TestFixtures.makeTableInfo(name: "users"), TestFixtures.makeTableInfo(name: "orders")]
        ]
        await service.refreshObjects(connectionId: connection.id, database: connection.database, schema: "public")

        let tables = service.tables(connectionId: connection.id, database: connection.database, schema: "public")
        #expect(tables.map(\.name) == ["users", "orders"])

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("A refresh never leaves the subtree without loaded content")
    func refreshKeepsContentLoaded() async {
        let (connection, driver) = connectedDriver()
        driver.schemaTablesToReturn = ["public": [TestFixtures.makeTableInfo(name: "users")]]
        let service = DatabaseTreeMetadataService.shared

        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "public")
        await service.refreshObjects(connectionId: connection.id, database: connection.database, schema: "public")

        let state = service.tablesLoadState(
            connectionId: connection.id, database: connection.database, schema: "public"
        )
        if case .loaded = state {} else {
            Issue.record("A refresh must leave the tables loaded, never idle or loading")
        }

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("A failed refresh keeps the tables already on screen")
    func failedRefreshKeepsPreviousTables() async {
        let (connection, driver) = connectedDriver()
        driver.schemaTablesToReturn = ["public": [TestFixtures.makeTableInfo(name: "users")]]
        let service = DatabaseTreeMetadataService.shared

        await service.loadTables(connectionId: connection.id, database: connection.database, schema: "public")

        driver.fetchTablesError = DatabaseError.notConnected
        await service.refreshObjects(connectionId: connection.id, database: connection.database, schema: "public")

        let tables = service.tables(connectionId: connection.id, database: connection.database, schema: "public")
        #expect(tables.map(\.name) == ["users"])
        let state = service.tablesLoadState(
            connectionId: connection.id, database: connection.database, schema: "public"
        )
        if case .loaded = state {} else {
            Issue.record("A failed refresh must leave the previous tables loaded, not failed")
        }

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("A refresh loads a subtree that was never loaded")
    func refreshLoadsUnloadedSubtree() async {
        let (connection, driver) = connectedDriver()
        driver.schemaTablesToReturn = ["public": [TestFixtures.makeTableInfo(name: "users")]]
        let service = DatabaseTreeMetadataService.shared

        await service.refreshObjects(connectionId: connection.id, database: connection.database, schema: "public")

        let tables = service.tables(connectionId: connection.id, database: connection.database, schema: "public")
        #expect(tables.map(\.name) == ["users"])

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }
}

/// Every fetch below names its schema itself, so the tree's routine, trigger and type lists for one
/// database share one pooled connection. A scope per schema took one pooled connection per expanded
/// schema node, which is how one saved PostgreSQL connection came to hold dozens of server backends
/// (#3103). They stay on `.bulk`, off the connection a query tab on that database runs its SQL on.
@Suite("DatabaseTreeMetadataService pooled scope", .serialized)
@MainActor
struct DatabaseTreeMetadataServicePooledScopeTests {
    private let schemas = ["public", "sales", "hr"]

    private func pooledSession() -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseDatabase = "shop"
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let pooled = MockDatabaseDriver(connection: connection)
        MetadataConnectionPool.shared.injectEntry(
            pooled,
            scope: DatabaseScope(connectionId: connection.id, database: "shop", schema: "public"),
            workload: .bulk
        )
        return (connection, pooled)
    }

    private func tearDown(_ connection: DatabaseConnection) async {
        await DatabaseTreeMetadataService.shared.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("Routines for every schema of a database load on the database's one pooled connection")
    func routinesShareTheDatabaseConnection() async {
        let (connection, _) = pooledSession()
        let service = DatabaseTreeMetadataService.shared

        for schema in schemas {
            await service.loadRoutines(connectionId: connection.id, database: "shop", schema: schema)
        }

        for schema in schemas {
            let state = service.routinesLoadState(connectionId: connection.id, database: "shop", schema: schema)
            if case .loaded = state {} else {
                Issue.record("Routines for \(schema) did not load on the database's pooled connection")
            }
        }
        #expect(MetadataConnectionPool.shared.pooledDriverCount(for: connection.id) == 1)
        await tearDown(connection)
    }

    @Test("Triggers and types for every schema of a database load on the database's one pooled connection")
    func triggersAndTypesShareTheDatabaseConnection() async {
        let (connection, _) = pooledSession()
        let service = DatabaseTreeMetadataService.shared

        for schema in schemas {
            await service.loadTriggers(connectionId: connection.id, database: "shop", schema: schema)
            await service.loadUserDefinedTypes(connectionId: connection.id, database: "shop", schema: schema)
        }

        for schema in schemas {
            let triggers = service.triggersLoadState(connectionId: connection.id, database: "shop", schema: schema)
            if case .loaded = triggers {} else {
                Issue.record("Triggers for \(schema) did not load on the database's pooled connection")
            }
            let types = service.typesLoadState(connectionId: connection.id, database: "shop", schema: schema)
            if case .loaded = types {} else {
                Issue.record("Types for \(schema) did not load on the database's pooled connection")
            }
        }
        #expect(MetadataConnectionPool.shared.pooledDriverCount(for: connection.id) == 1)
        await tearDown(connection)
    }
}
