import Testing
import Foundation
@testable import TableProDatabase
@testable import TableProModels

// MARK: - Mock Types

private final class MockDatabaseDriver: DatabaseDriver, @unchecked Sendable {
    var isConnected = false
    var shouldFailConnect = false
    var holdsSuspensionBlockingResource = false
    var onConnect: (@Sendable () -> Void)?
    var beforeDisconnect: (@Sendable () async -> Void)?
    private(set) var disconnectCount = 0

    func connect() async throws {
        if shouldFailConnect { throw NSError(domain: "test", code: 1) }
        onConnect?()
        isConnected = true
    }

    func disconnect() async throws {
        await beforeDisconnect?()
        isConnected = false
        disconnectCount += 1
    }
    func ping() async throws -> Bool { isConnected }

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0, isTruncated: false, statusMessage: nil)
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

private final class MockDriverFactory: DriverFactory, @unchecked Sendable {
    var drivers: [String: any DatabaseDriver] = [:]

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        guard let driver = drivers[connection.type.rawValue] else {
            throw ConnectionError.driverNotFound(connection.type.rawValue)
        }
        return driver
    }

    func supportedTypes() -> [DatabaseType] { [] }
}

private final class MockSecureStore: SecureStore, Sendable {
    private let passwords: [String: String]

    init(passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    func store(_ value: String, forKey key: String) throws {}

    func retrieve(forKey key: String) throws -> String? {
        passwords[key]
    }

    func delete(forKey key: String) throws {}
}

// MARK: - Synchronisation Helpers

private actor Gate {
    private var isOpen = false
    private var hasEntered = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        hasEntered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in blocked { waiter.resume() }
        blocked.removeAll()
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
}

private actor Barrier {
    private static let pollInterval: UInt64 = 20_000_000
    private static let maxPolls = 250

    private let expected: Int
    private var arrived = 0
    private(set) var overlapped = 0

    init(expected: Int) {
        self.expected = expected
    }

    func arriveAndWait() async {
        arrived += 1
        var polls = 0
        while arrived < expected, polls < Self.maxPolls {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            polls += 1
        }
        guard arrived >= expected else { return }
        overlapped += 1
    }
}

@Suite("ConnectionManager Tests")
struct ConnectionManagerTests {
    @Test("Connect creates a session")
    func connectCreatesSession() async throws {
        let factory = MockDriverFactory()
        factory.drivers["mock"] = MockDatabaseDriver()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock"),
            host: "localhost",
            port: 5432
        )

        let session = try await manager.connect(connection)
        #expect(session.connectionId == connection.id)
        #expect(session.activeDatabase == connection.database)

        let retrieved = manager.session(for: connection.id)
        #expect(retrieved != nil)
    }

    @Test("Disconnect removes session")
    func disconnectRemovesSession() async throws {
        let factory = MockDriverFactory()
        factory.drivers["mock"] = MockDatabaseDriver()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )

        _ = try await manager.connect(connection)
        await manager.disconnect(connection.id)

        let session = manager.session(for: connection.id)
        #expect(session == nil)
    }

    @Test("Reconnecting for the same id tears down the previous session")
    func reconnectDisconnectsPrevious() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )

        let first = MockDatabaseDriver()
        factory.drivers["mock"] = first
        _ = try await manager.connect(connection)

        let second = MockDatabaseDriver()
        factory.drivers["mock"] = second
        _ = try await manager.connect(connection)

        #expect(first.disconnectCount == 1)
        #expect(second.isConnected)
        #expect(manager.session(for: connection.id)?.driver === second)
    }

    @Test("Connect with unknown type throws driverNotFound")
    func connectUnknownType() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "nonexistent")
        )

        await #expect(throws: ConnectionError.self) {
            _ = try await manager.connect(connection)
        }
    }

    @Test("Connect with SSH but no provider throws error")
    func connectSSHNoProvider() async throws {
        let factory = MockDriverFactory()
        factory.drivers["mock"] = MockDatabaseDriver()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store, sshProvider: nil)

        var connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )
        connection.sshEnabled = true
        connection.sshConfiguration = SSHConfiguration(host: "jump.example.com")

        await #expect(throws: ConnectionError.self) {
            _ = try await manager.connect(connection)
        }
    }

    @Test("SSH tunnel cleanup on connect failure")
    func sshTunnelCleanupOnFailure() async throws {
        let factory = MockDriverFactory()
        let failingDriver = MockDatabaseDriver()
        failingDriver.shouldFailConnect = true
        factory.drivers["mock"] = failingDriver

        let store = MockSecureStore()
        let sshProvider = MockSSHProvider()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store, sshProvider: sshProvider)

        var connection = DatabaseConnection(
            name: "Test",
            type: DatabaseType(rawValue: "mock")
        )
        connection.sshEnabled = true
        connection.sshConfiguration = SSHConfiguration(host: "jump.example.com")

        await #expect(throws: Error.self) {
            _ = try await manager.connect(connection)
        }

        #expect(sshProvider.closedTunnels.contains(connection.id))
    }

    @Test("Only sessions holding a suspension blocking resource are released")
    func releaseOnlyTouchesBlockingSessions() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)

        let blockingDriver = MockDatabaseDriver()
        blockingDriver.holdsSuspensionBlockingResource = true
        factory.drivers["blocking"] = blockingDriver
        let blocking = DatabaseConnection(name: "File", type: DatabaseType(rawValue: "blocking"))
        _ = try await manager.connect(blocking)

        let remoteDriver = MockDatabaseDriver()
        factory.drivers["remote"] = remoteDriver
        let remote = DatabaseConnection(name: "Remote", type: DatabaseType(rawValue: "remote"))
        _ = try await manager.connect(remote)

        #expect(manager.hasSuspensionBlockingResources)

        await manager.releaseSuspensionBlockingResources()

        #expect(blockingDriver.disconnectCount == 1)
        #expect(remoteDriver.disconnectCount == 0)
        #expect(manager.session(for: blocking.id) == nil)
        #expect(manager.session(for: remote.id) != nil)
        #expect(!manager.hasSuspensionBlockingResources)
    }

    @Test("Releasing several blocking sessions runs them concurrently")
    func releaseRunsConcurrently() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)
        let barrier = Barrier(expected: 2)

        let firstDriver = MockDatabaseDriver()
        firstDriver.holdsSuspensionBlockingResource = true
        firstDriver.beforeDisconnect = { await barrier.arriveAndWait() }
        factory.drivers["first"] = firstDriver
        _ = try await manager.connect(DatabaseConnection(name: "First", type: DatabaseType(rawValue: "first")))

        let secondDriver = MockDatabaseDriver()
        secondDriver.holdsSuspensionBlockingResource = true
        secondDriver.beforeDisconnect = { await barrier.arriveAndWait() }
        factory.drivers["second"] = secondDriver
        _ = try await manager.connect(DatabaseConnection(name: "Second", type: DatabaseType(rawValue: "second")))

        await manager.releaseSuspensionBlockingResources()

        #expect(await barrier.overlapped == 2)
        #expect(firstDriver.disconnectCount == 1)
        #expect(secondDriver.disconnectCount == 1)
    }

    @Test("A teardown still in flight keeps counting as a blocking resource")
    func inFlightTeardownStillBlocks() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)
        let connection = DatabaseConnection(name: "File", type: DatabaseType(rawValue: "mock"))
        let gate = Gate()

        let driver = MockDatabaseDriver()
        driver.holdsSuspensionBlockingResource = true
        driver.beforeDisconnect = { await gate.enter() }
        factory.drivers["mock"] = driver
        _ = try await manager.connect(connection)

        let teardown = Task { await manager.disconnect(connection.id) }
        await gate.waitUntilEntered()

        #expect(manager.session(for: connection.id) == nil)
        #expect(manager.hasSuspensionBlockingResources)

        await gate.open()
        await teardown.value

        #expect(!manager.hasSuspensionBlockingResources)
    }

    @Test("Connecting waits for an in-flight teardown of the same connection")
    func connectWaitsForInFlightTeardown() async throws {
        let factory = MockDriverFactory()
        let store = MockSecureStore()
        let manager = ConnectionManager(driverFactory: factory, secureStore: store)
        let connection = DatabaseConnection(name: "Test", type: DatabaseType(rawValue: "mock"))
        let gate = Gate()

        let first = MockDatabaseDriver()
        first.beforeDisconnect = { await gate.enter() }
        factory.drivers["mock"] = first
        _ = try await manager.connect(connection)

        let teardown = Task { await manager.disconnect(connection.id) }
        await gate.waitUntilEntered()

        let second = MockDatabaseDriver()
        factory.drivers["mock"] = second
        let reconnect = Task { try await manager.connect(connection) }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!second.isConnected)

        await gate.open()
        _ = try await reconnect.value
        await teardown.value

        #expect(first.disconnectCount == 1)
        #expect(second.isConnected)
    }
}

// MARK: - Mock SSH Provider

private final class MockSSHProvider: SSHProvider, @unchecked Sendable {
    var closedTunnels: Set<UUID> = []

    func createTunnel(
        config: SSHConfiguration,
        remoteHost: String,
        remotePort: Int
    ) async throws -> SSHTunnel {
        SSHTunnel(localHost: "127.0.0.1", localPort: 33306)
    }

    func closeTunnel(for connectionId: UUID) async throws {
        closedTunnels.insert(connectionId)
    }
}
