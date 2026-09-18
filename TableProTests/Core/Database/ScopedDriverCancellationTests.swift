//
//  ScopedDriverCancellationTests.swift
//  TableProTests
//
//  Who a cancel reaches, and which thread pays for it. A cancel names the lease owner whose work it
//  is ending: keyed by connection alone it reached every tab and every window on that connection, so
//  starting a query in one tab rolled back the batch another tab was running (#2061 for the thread,
//  and the tab-cancel defect for the owner).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Scoped driver cancellation", .serialized)
@MainActor
struct ScopedDriverCancellationTests {
    @Test("A background delivery never cancels on the main thread")
    func backgroundDeliveryCancelsOffTheMainThread() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        Self.seed(driver, policy: .cancellableRead(owner), for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .background)

        #expect(await Self.awaitCancel(driver))
        #expect(driver.cancelledOnMainThread == false)
        #expect(driver.cancelCount == 1)
    }

    /// Stop is the opposite trade: the user is waiting on it, so it stays synchronous and is
    /// already done by the time the call returns. Nothing here awaits before asserting.
    @Test("Stop cancels inline on the caller's thread")
    func immediateDeliveryCancelsSynchronously() throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        Self.seed(driver, policy: .cancellableRead(owner), for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .immediate)

        #expect(driver.cancelCount == 1)
        #expect(driver.cancelledOnMainThread == true)
    }

    /// The whole point of the owner. Two tabs queue on one connection, and stopping one of them must
    /// leave the other's handle alone.
    @Test("A cancel reaches only the lease that owns it")
    func cancelReachesOneOwnerOnly() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let mine = CancelRecordingDriver(connection: connection)
        let theirs = CancelRecordingDriver(connection: connection)
        let myOwner = DriverLeaseOwner()
        let theirOwner = DriverLeaseOwner()
        DatabaseManager.shared.runningDrivers[connection.id] = [
            UUID(): RunningDriver(driver: mine, policy: .cancellableRead(myOwner)),
            UUID(): RunningDriver(driver: theirs, policy: .cancellableRead(theirOwner)),
        ]
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: myOwner, on: connection.id, delivery: .immediate)

        #expect(mine.cancelCount == 1)
        #expect(await Self.awaitCancel(theirs) == false)
        #expect(theirs.cancelCount == 0)
    }

    /// A commit or a DDL statement that is half applied cannot be undone by retrying, so neither
    /// delivery may abort one.
    @Test("A protected write is never aborted, by Stop or by a supersede")
    func protectedWriteIsNeverCancelled() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        Self.seed(driver, policy: .protectedWrite, for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .background)
        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .immediate)

        #expect(await Self.awaitCancel(driver) == false)
        #expect(driver.cancelCount == 0)
    }

    /// There is no session-driver fallback any more. An owner with nothing registered has nothing
    /// running, and aborting whatever the shared driver happened to be doing is how one tab's Run
    /// stopped another tab's batch.
    @Test("An owner with nothing registered cancels nothing, at either delivery")
    func nothingRegisteredCancelsNothing() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: driver),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .background)
        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .immediate)

        #expect(await Self.awaitCancel(driver) == false)
        #expect(driver.cancelCount == 0)
    }

    /// The shape a committing batch actually has: its statements ran under one `.cancellableRead`
    /// lease that is still open, and the commit registered the same handle again as a protected
    /// write. Without the identity check the cancel would reach the commit through the lease.
    @Test("A cancellable lease over the same handle as a protected write is not cancelled")
    func protectedHandleIsExcludedFromItsOwnLease() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        Self.seed(driver, policy: .cancellableRead(owner), for: connection.id)
        let token = DatabaseManager.shared.beginProtectedWrite(on: driver, for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .immediate)
        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .background)

        #expect(await Self.awaitCancel(driver) == false)
        #expect(driver.cancelCount == 0)

        DatabaseManager.shared.endProtectedWrite(token, for: connection.id)
        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .immediate)
        #expect(driver.cancelCount == 1)
    }

    /// The exclusion is by handle, not by connection. The owner's second lease on its own pooled
    /// driver is still ordinary cancellable work while its first handle commits.
    @Test("A different handle beside a protected write is still cancelled")
    func otherHandlesStayCancellable() throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let committing = CancelRecordingDriver(connection: connection)
        let reading = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        DatabaseManager.shared.runningDrivers[connection.id] = [
            UUID(): RunningDriver(driver: committing, policy: .cancellableRead(owner)),
            UUID(): RunningDriver(driver: reading, policy: .cancellableRead(owner)),
        ]
        _ = DatabaseManager.shared.beginProtectedWrite(on: committing, for: connection.id)
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .immediate)

        #expect(committing.cancelCount == 0)
        #expect(reading.cancelCount == 1)
    }

    /// A background cancel outlives the call that issued it, so the lease has to wait it out before
    /// releasing the handle. Left unawaited it lands on whatever the connection runs next, which on
    /// MariaDB is a `KILL QUERY` arriving at the following statement.
    @Test("Releasing a lease hands back the pending background cancel")
    func releaseHandsBackThePendingCancel() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        let token = UUID()
        DatabaseManager.shared.runningDrivers[connection.id] = [
            token: RunningDriver(driver: driver, policy: .cancellableRead(owner))
        ]
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .background)
        let pending = try #require(DatabaseManager.shared.releaseRunningDriver(token, for: connection.id))
        await pending.value

        #expect(driver.cancelCount == 1)
        #expect(DatabaseManager.shared.runningDrivers[connection.id] == nil)
    }

    /// The other half: once the lease is gone, a cancel for its owner reaches nothing at all.
    @Test("A cancel issued after the lease was released reaches nothing")
    func cancelAfterReleaseReachesNothing() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        let owner = DriverLeaseOwner()
        let token = UUID()
        DatabaseManager.shared.runningDrivers[connection.id] = [
            token: RunningDriver(driver: driver, policy: .cancellableRead(owner))
        ]
        defer { DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id) }

        _ = DatabaseManager.shared.releaseRunningDriver(token, for: connection.id)
        try DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connection.id, delivery: .immediate)

        #expect(await Self.awaitCancel(driver) == false)
        #expect(driver.cancelCount == 0)
    }

    /// A lease whose task was cancelled before its turn came never runs its body, so nothing lands
    /// on the driver for a cancel to have to chase. `trackedLease` re-asks after registering too, so
    /// the pooled route answers the same as the session route does here.
    @Test("A lease cancelled before its turn never runs its body")
    func cancelledLeaseNeverRunsTheBody() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = CancelRecordingDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        let ran = LockedFlag()
        let task = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: .sessionDriver,
                cancellation: .cancellableRead(DriverLeaseOwner())
            ) { _ in
                ran.raise()
            }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ran.isRaised == false)
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

/// Raised from inside a `@Sendable` lease body and read from the test, so it needs its own lock.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}
