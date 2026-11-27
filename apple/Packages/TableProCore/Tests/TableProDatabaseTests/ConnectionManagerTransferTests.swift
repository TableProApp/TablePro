import Foundation
@testable import TableProDatabase
@testable import TableProModels
import TableProTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ConnectionManagerTransferTests {
    private static let type = DatabaseType(rawValue: "mock")

    private func connection() -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Test", type: Self.type, host: "db.example.com", port: 5_432, database: "app")
        connection.queryTimeoutSeconds = 30
        return connection
    }

    @Test("A transfer gets a driver of its own on the asked database, with no catalog preparation and no query timeout")
    func opensItsOwnDriver() async throws {
        let factory = TransferDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        let session = try await manager.connect(connection)

        let transfer = try await manager.openDedicatedDriver(for: connection.id, database: "sales")

        let dialed = factory.dialed
        #expect(transfer !== session.driver)
        #expect((transfer as? MockDatabaseDriver)?.isConnected == true)
        #expect(dialed.last?.database == "sales")
        #expect(dialed.last?.queryTimeoutSeconds == nil)
        #expect(factory.prepared.isEmpty)
    }

    @Test("Closing the transfer's driver leaves the session alone, and a second close does nothing")
    func closeLeavesTheSession() async throws {
        let factory = TransferDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        let session = try await manager.connect(connection)
        let transfer = try #require(try await manager.openDedicatedDriver(for: connection.id, database: nil) as? MockDatabaseDriver)

        await manager.closeDedicatedDriver(transfer, for: connection.id)
        await manager.closeDedicatedDriver(transfer, for: connection.id)
        await manager.closeDedicatedDriver(session.driver, for: connection.id)

        #expect(transfer.disconnectCount == 1)
        #expect((session.driver as? MockDatabaseDriver)?.isConnected == true)
    }

    @Test("A disconnect ends the transfer's driver before the session's")
    func disconnectEndsTheTransferFirst() async throws {
        let factory = TransferDriverFactory()
        let order = DisconnectOrder()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        let session = try await manager.connect(connection)
        let sessionDriver = try #require(session.driver as? MockDatabaseDriver)
        let transfer = try #require(try await manager.openDedicatedDriver(for: connection.id, database: nil) as? MockDatabaseDriver)
        transfer.beforeDisconnect = { await order.record("transfer") }
        sessionDriver.beforeDisconnect = { await order.record("session") }

        await manager.disconnect(connection.id)

        #expect(transfer.disconnectCount == 1)
        #expect(await order.names == ["transfer", "session"])
    }

    @Test("A catalog hold ends the transfer's driver and opens none until it is released")
    func holdEndsTheTransfer() async throws {
        let factory = TransferDriverFactory()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)
        let transfer = try #require(try await manager.openDedicatedDriver(for: connection.id, database: nil) as? MockDatabaseDriver)

        await manager.holdCatalogConnections(for: connection.id)

        #expect(transfer.disconnectCount == 1)
        await #expect(throws: TransferConnectionError.connectionHeld) {
            _ = try await manager.openDedicatedDriver(for: connection.id, database: nil)
        }
        manager.releaseCatalogConnections(for: connection.id)
        _ = try await manager.openDedicatedDriver(for: connection.id, database: nil)
    }

    @Test("A session driver that gives its own transfer connection is asked, and its answer of itself is not owned")
    func sessionDriverGivesItsOwn() async throws {
        let session = OwnTransferDriver()
        let factory = TransferDriverFactory(sessionDriver: session)
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore())
        let connection = connection()
        _ = try await manager.connect(connection)

        let own = try await manager.openDedicatedDriver(for: connection.id, database: nil)
        session.answersWithItself = true
        let itself = try await manager.openDedicatedDriver(for: connection.id, database: nil)
        await manager.disconnect(connection.id)

        #expect(own === session.given)
        #expect(itself === session)
        #expect(factory.dialed.count == 1)
        #expect(session.given.disconnectCount == 1)
        #expect(session.disconnectCount == 1)
    }

    @Test("No session, no transfer driver")
    func noSession() async {
        let manager = ConnectionManager(driverFactory: TransferDriverFactory(), secureStore: MockSecureStore())

        await #expect(throws: ConnectionError.notConnected) {
            _ = try await manager.openDedicatedDriver(for: UUID(), database: nil)
        }
    }

    @Test("A held connection keeps its file through a background release, and the last release says so")
    func holdKeepsTheFile() async throws {
        let session = MockDatabaseDriver()
        session.holdsSuspensionBlockingResource = true
        let manager = ConnectionManager(
            driverFactory: TransferDriverFactory(sessionDriver: session), secureStore: MockSecureStore()
        )
        let connection = connection()
        _ = try await manager.connect(connection)
        let ended = EndedHolds()
        manager.observeTransferHoldsEnded { ended.record($0) }

        let first = manager.holdForTransfer(connection.id)
        let second = manager.holdForTransfer(connection.id)
        let releasedWhileHeld = await manager.releaseSuspensionBlockingResources()
        let blockingWhileHeld = manager.hasSuspensionBlockingResources
        first.release()
        let endedAfterOne = ended.ids
        second.release()
        second.release()

        #expect(releasedWhileHeld.isEmpty)
        #expect(!blockingWhileHeld)
        #expect(session.isConnected)
        #expect(endedAfterOne.isEmpty)
        #expect(ended.ids == [connection.id])
        #expect(manager.hasSuspensionBlockingResources)
    }
}

private actor DisconnectOrder {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }
}

private final class EndedHolds: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UUID] = []

    var ids: [UUID] {
        lock.withLock { recorded }
    }

    func record(_ id: UUID) {
        lock.withLock { recorded.append(id) }
    }
}

// The session's driver first, then a new one for each later dial.
private final class TransferDriverFactory: DriverFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sessionDriver: (any DatabaseDriver)?
    private var connections: [DatabaseConnection] = []
    private var preparedDrivers: [any DatabaseDriver] = []

    init(sessionDriver: (any DatabaseDriver)? = nil) {
        self.sessionDriver = sessionDriver ?? MockDatabaseDriver()
    }

    var dialed: [DatabaseConnection] {
        lock.withLock { connections }
    }

    var prepared: [any DatabaseDriver] {
        lock.withLock { preparedDrivers }
    }

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        lock.withLock {
            connections.append(connection)
            defer { sessionDriver = nil }
            return sessionDriver ?? MockDatabaseDriver()
        }
    }

    func supportedTypes() -> [DatabaseType] { [DatabaseType(rawValue: "mock")] }

    func opensCatalogConnections(for connection: DatabaseConnection) -> Bool { true }

    func prepareCatalogDriver(_ driver: any DatabaseDriver, for connection: DatabaseConnection) async throws {
        lock.withLock { preparedDrivers.append(driver) }
    }
}

// SQLite and DuckDB's shape: the session makes the transfer's connection itself, or answers with itself.
private final class OwnTransferDriver: DatabaseDriver, DedicatedTransferConnection, @unchecked Sendable {
    let given = MockDatabaseDriver()
    var answersWithItself = false
    private(set) var disconnectCount = 0

    func openTransferDriver() async throws -> any DatabaseDriver {
        if answersWithItself { return self }
        try await given.connect()
        return given
    }

    func connect() async throws {}
    func disconnect() async throws { disconnectCount += 1 }
    func ping() async throws -> Bool { true }
    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func cancelCurrentQuery() async throws {}
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func switchDatabase(to name: String) async throws {}
    var supportsSchemas: Bool { false }
    func switchSchema(to name: String) async throws {}
    func fetchSchemas() async throws -> [String] { [] }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { false }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    var serverVersion: String? { nil }
}
