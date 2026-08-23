import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseTreeMetadataService")
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
@Suite("DatabaseTreeMetadataService refreshLoadedTables")
@MainActor
struct DatabaseTreeMetadataServiceRefreshTests {
    @Test("reload drops previously loaded tables and refetches the current list")
    func refreshReloadsLoadedTables() async {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.schemaTablesToReturn = ["public": [TestFixtures.makeTableInfo(name: "users")]]

        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let service = DatabaseTreeMetadataService.shared
        let database = connection.database

        await service.loadTables(connectionId: connection.id, database: database, schema: "public")
        let initial = service.tables(connectionId: connection.id, database: database, schema: "public")
        #expect(initial.map(\.name) == ["users"])

        driver.schemaTablesToReturn = ["public": []]
        await service.refreshLoadedTables(connectionId: connection.id)

        let refreshed = service.tables(connectionId: connection.id, database: database, schema: "public")
        #expect(refreshed.isEmpty)

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("reload refetches every loaded schema, not just the one that changed")
    func refreshReloadsAllLoadedSchemas() async {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.schemaTablesToReturn = [
            "public": [TestFixtures.makeTableInfo(name: "users")],
            "sales": [TestFixtures.makeTableInfo(name: "orders")]
        ]

        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let service = DatabaseTreeMetadataService.shared
        let database = connection.database

        await service.loadTables(connectionId: connection.id, database: database, schema: "public")
        await service.loadTables(connectionId: connection.id, database: database, schema: "sales")

        driver.schemaTablesToReturn = [
            "public": [],
            "sales": [TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "invoices")]
        ]
        await service.refreshLoadedTables(connectionId: connection.id)

        let publicTables = service.tables(connectionId: connection.id, database: database, schema: "public")
        let salesTables = service.tables(connectionId: connection.id, database: database, schema: "sales")
        #expect(publicTables.isEmpty)
        #expect(salesTables.map(\.name) == ["orders", "invoices"])

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("refresh is a no-op when no tables are loaded for the connection")
    func refreshWithoutLoadedTablesIsNoOp() async {
        let connection = TestFixtures.makeConnection()

        await DatabaseTreeMetadataService.shared.refreshLoadedTables(connectionId: connection.id)

        let tables = DatabaseTreeMetadataService.shared.tables(
            connectionId: connection.id,
            database: connection.database,
            schema: "public"
        )
        #expect(tables.isEmpty)
    }
}

/// A refresh must never empty the list it is refreshing: the tree renders `.loading`
/// with no content as a spinner, so clearing first blanks the sidebar mid-refresh.
@Suite("DatabaseTreeMetadataService refreshDatabases")
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
@Suite("DatabaseTreeMetadataService refreshObjects")
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
