import Testing
import Foundation
@testable import TableProDatabase
@testable import TableProModels

// MARK: - Mock Types

private final class MockDatabaseDriver: DatabaseDriver, @unchecked Sendable {
    var isConnected = false
    var shouldFailConnect = false

    func connect() async throws {
        if shouldFailConnect { throw NSError(domain: "test", code: 1) }
        isConnected = true
    }

    func disconnect() async throws { isConnected = false }
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
