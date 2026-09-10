import Foundation
@testable import TableProDatabase
@testable import TableProModels
import Testing

// MARK: - Mock Types

final class MockDatabaseDriver: DatabaseDriver, @unchecked Sendable {
    var isConnected = false
    var shouldFailConnect = false
    var holdsSuspensionBlockingResource = false
    var onConnect: (@Sendable () -> Void)?
    var beforeConnect: (@Sendable () async -> Void)?
    var beforeDisconnect: (@Sendable () async -> Void)?
    private(set) var disconnectCount = 0

    func connect() async throws {
        await beforeConnect?()
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

final class MockDriverFactory: DriverFactory, @unchecked Sendable {
    var drivers: [String: any DatabaseDriver] = [:]

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        guard let driver = drivers[connection.type.rawValue] else {
            throw ConnectionError.driverNotFound(connection.type.rawValue)
        }
        return driver
    }

    func supportedTypes() -> [DatabaseType] { [] }
}

final class MockSecureStore: SecureStore, Sendable {
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

actor Gate {
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

actor Barrier {
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

// MARK: - Mock SSH Provider

final class MockSSHProvider: SSHProvider, @unchecked Sendable {
    var closedTunnels: Set<UUID> = []
    var closedTunnelIds: Set<UUID> = []
    var openedTunnelIds: [UUID] = []
    var tunnelledConnectionIds: [UUID] = []

    func createTunnel(
        config: SSHConfiguration,
        connectionId: UUID,
        remoteHost: String,
        remotePort: Int
    ) async throws -> SSHTunnel {
        tunnelledConnectionIds.append(connectionId)
        let id = UUID()
        openedTunnelIds.append(id)
        return SSHTunnel(id: id, localHost: "127.0.0.1", localPort: 33_306)
    }

    func closeTunnel(for connectionId: UUID) async throws {
        closedTunnels.insert(connectionId)
    }

    func closeTunnel(id: UUID) async throws {
        closedTunnelIds.insert(id)
    }
}
