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
            connectionId: connectionId
        )

        #expect(keys == [routineOnly])
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
            connectionId: connectionId
        )

        #expect(keys == [mine])
    }
}

@Suite("DatabaseTreeMetadataService refreshLoadedTables")
@MainActor
struct DatabaseTreeMetadataServiceRefreshTests {
    @Test("reload drops previously loaded tables and refetches the current list")
    func refreshReloadsLoadedTables() async {
        let connection = TestFixtures.makeConnection()
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
        let connection = TestFixtures.makeConnection()
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
