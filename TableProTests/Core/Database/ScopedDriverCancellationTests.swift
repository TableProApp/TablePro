//
//  ScopedDriverCancellationTests.swift
//  TableProTests
//
//  Who a cancel reaches, and which thread pays for it. A superseded navigation cancels off the
//  main thread because a PostgreSQL cancel opens a second connection to deliver the request, and
//  through an SSH tunnel that round trip cost 68-157ms of main-thread stall per click (#2061).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Scoped driver cancellation", .serialized)
@MainActor
struct ScopedDriverCancellationTests {
    @Test("A superseded navigation never cancels on the main thread")
    func supersededNavigationCancelsOffTheMainThread() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        Self.seed(driver, policy: .cancellableRead, for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(for: connection.id, reach: .supersededNavigation)

        #expect(await Self.awaitCancel(driver))
        #expect(driver.cancelledOnMainThread == false)
    }

    /// The cancel is fire-and-forget now, so the half that matters is that it still arrives.
    /// Correctness never depended on it landing first, but the server keeps working until it does.
    @Test("A superseded navigation still delivers the cancel")
    func supersededNavigationStillCancels() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        Self.seed(driver, policy: .cancellableRead, for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(for: connection.id, reach: .supersededNavigation)

        #expect(await Self.awaitCancel(driver))
        #expect(driver.cancelCount == 1)
    }

    /// Stop is the opposite trade: the user is waiting on it, so it stays synchronous and is
    /// already done by the time the call returns. Nothing here awaits before asserting.
    @Test("Stop cancels inline on the caller's thread")
    func userStopCancelsSynchronously() throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        Self.seed(driver, policy: .cancellableRead, for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(for: connection.id, reach: .userStop)

        #expect(driver.cancelCount == 1)
        #expect(driver.cancelledOnMainThread == true)
    }

    /// A commit or a DDL statement that is half applied cannot be undone by retrying, so neither
    /// reach may abort one.
    @Test("A protected write is never aborted, by Stop or by a supersede")
    func protectedWriteIsNeverCancelled() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        Self.seed(driver, policy: .protectedWrite, for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(for: connection.id, reach: .supersededNavigation)
        try DatabaseManager.shared.cancelRunningQuery(for: connection.id, reach: .userStop)

        #expect(await Self.awaitCancel(driver) == false)
        #expect(driver.cancelCount == 0)
    }

    /// The session-driver fallback aborts whatever the connection happens to be running without
    /// knowing what it is, so only an explicit Stop may take it.
    @Test("A supersede with nothing registered cancels nothing")
    func supersededNavigationDoesNotFallBackToTheSessionDriver() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: driver),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(for: connection.id, reach: .supersededNavigation)

        #expect(await Self.awaitCancel(driver) == false)
        #expect(driver.cancelCount == 0)
    }

    private static func seed(
        _ driver: DatabaseDriver,
        policy: DriverCancellationPolicy,
        for connectionId: UUID
    ) {
        DatabaseManager.shared.runningDrivers[connectionId] = [
            UUID(): RunningDriver(driver: driver, policy: policy)
        ]
    }

    /// The cancel now lands on a global queue, so the assertion has to wait for it. Polling keeps
    /// the main actor free for anything the cancel path might still hop back to, and the deadline
    /// means a regression fails the test instead of hanging the suite.
    private static func awaitCancel(
        _ driver: CancelRecordingDriver,
        within timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if driver.cancelCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// Records which thread `cancelQuery()` ran on. The shared `MockDatabaseDriver` counts calls with
/// an unsynchronised `var`, which is fine while every cancel is on the main actor and a data race
/// the moment one is not, so this path needs its own locked fake.
private final class CancelRecordingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected

    private let lock = NSLock()
    private var calls = 0
    private var onMainThread: Bool?

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var cancelledOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return onMainThread
    }

    func cancelQuery() throws {
        lock.lock()
        calls += 1
        onMainThread = Thread.isMainThread
        lock.unlock()
    }

    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}
    func execute(query: String) async throws -> QueryResult { Self.emptyResult }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { Self.emptyResult }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        Self.emptyResult
    }

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database,
            name: database,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: false,
            icon: "cylinder"
        )
    }

    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    func fetchViewDefinition(view: String) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    private static var emptyResult: QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }
}
